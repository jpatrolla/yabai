// edge_guard.inc.m — multi_display_edge_guard nudge animator.
//
// Drives the SA_OPCODE_SPACE_NUDGE opcode (scripting_addition_animate_edge_nudge,
// sa_inc/sa_experimental). When `space --focus next/prev` hits a display edge,
// the daemon (space_manager_multi_display_edge_guard) sends this op and the
// active space's content springs out and back to signal the boundary.
//
// A 2D underdamped harmonic oscillator integrated at the display VBL rate via
// CVDisplayLink; each kick applies a position impulse to live spring state
// (velocity carries forward, so a kick mid-decay smoothly retargets).
// Depends only on the SkyLight / CV / spring externs already in payload.m.

struct sa_nudge_spring {
    CVDisplayLinkRef link;
    pthread_mutex_t  mutex;
    volatile uint64_t sid;          // 0 = idle (no current target)
    volatile bool     active;       // link is running
    double x,  y;                   // current displacement (px from rest)
    double vx, vy;                  // current velocity (px/s)
    double k;                       // stiffness (omega_n^2)
    double c;                       // damping  (2*zeta*omega_n)
    uint64_t last_mach;             // for dt
    double   mach_to_s;
    bool     initialized;
};

static struct sa_nudge_spring g_nudge_spring;

static CVReturn payload_nudge_spring_tick(CVDisplayLinkRef link,
                                          const CVTimeStamp *now,
                                          const CVTimeStamp *output_time,
                                          CVOptionFlags flags_in,
                                          CVOptionFlags *flags_out,
                                          void *context)
{
    (void)link; (void)now; (void)output_time; (void)flags_in; (void)flags_out;
    struct sa_nudge_spring *s = (struct sa_nudge_spring *)context;

    pthread_mutex_lock(&s->mutex);
    uint64_t sid = s->sid;
    if (!sid) {
        pthread_mutex_unlock(&s->mutex);
        return kCVReturnSuccess;
    }

    uint64_t now_mach = mach_absolute_time();
    double dt = (double)(now_mach - s->last_mach) * s->mach_to_s;
    s->last_mach = now_mach;
    if (dt > 0.05) dt = 0.05;   // clamp catastrophic gaps (sleep/wake)
    if (dt < 0.0)  dt = 0.0;    // defensive

    // Semi-implicit Euler.
    double ax = -s->k * s->x - s->c * s->vx;
    double ay = -s->k * s->y - s->c * s->vy;
    s->vx += ax * dt;
    s->vy += ay * dt;
    s->x  += s->vx * dt;
    s->y  += s->vy * dt;

    int cid = SLSMainConnectionID();
    CGAffineTransform xf = { 1.0, 0.0, 0.0, 1.0, s->x, s->y };
    CFTypeRef tx = SLSTransactionCreate(cid);
    if (tx) {   // NULL: skip this frame, spring state still advances
        SLSTransactionSetSpaceTransform(tx, sid, 0, &xf);
        SLSTransactionCommit(tx, 0);
        CFRelease(tx);
    }

    // Settled? Stop the link and snap to identity with the state-clear flag.
    bool settled = (fabs(s->x)  < 0.5)  && (fabs(s->y)  < 0.5)
                && (fabs(s->vx) < 1.0)  && (fabs(s->vy) < 1.0);
    if (settled) {
        CGAffineTransform identity = CGAffineTransformIdentity;
        CFTypeRef rtx = SLSTransactionCreate(cid);
        if (rtx) {
            SLSTransactionSetSpaceTransform(rtx, sid, SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
            SLSTransactionCommit(rtx, 0);
            CFRelease(rtx);
        } else {
            logpf("PAYLOAD", "edge_guard settle: SLSTransactionCreate FAIL sid=%llu", sid);
        }
        s->x = s->y = 0.0;
        s->vx = s->vy = 0.0;
        s->sid = 0;
        s->active = false;
        CVDisplayLinkStop(s->link);
    }

    pthread_mutex_unlock(&s->mutex);
    return kCVReturnSuccess;
}

static void payload_nudge_spring_kick(int cid, uint64_t sid,
                                      double dx, double dy,
                                      uint32_t duration_ms)
{
    if (!sid) return;

    if (!g_nudge_spring.initialized) {
        // Lazy one-time setup. Nudges fire off a user keypress and never
        // concurrently, so the first-kick race isn't guarded.
        struct mach_timebase_info tb;
        mach_timebase_info(&tb);
        g_nudge_spring.mach_to_s = (double)tb.numer / ((double)tb.denom * 1e9);
        pthread_mutex_init(&g_nudge_spring.mutex, NULL);
        CVDisplayLinkCreateWithActiveCGDisplays(&g_nudge_spring.link);
        CVDisplayLinkSetOutputCallback(g_nudge_spring.link,
                                       payload_nudge_spring_tick,
                                       &g_nudge_spring);
        g_nudge_spring.initialized = true;
    }

    pthread_mutex_lock(&g_nudge_spring.mutex);

    // Retargeting: if an animation is in flight on a different space, snap
    // it home before redirecting state to the new sid.
    if (g_nudge_spring.sid != 0 && g_nudge_spring.sid != sid) {
        CGAffineTransform identity = CGAffineTransformIdentity;
        CFTypeRef tx = SLSTransactionCreate(cid);
        if (tx) {
            SLSTransactionSetSpaceTransform(tx, g_nudge_spring.sid, SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
            SLSTransactionCommit(tx, 0);
            CFRelease(tx);
        } else {
            logpf("PAYLOAD", "edge_guard retarget: SLSTransactionCreate FAIL sid=%llu", g_nudge_spring.sid);
        }
        g_nudge_spring.x = g_nudge_spring.y = 0.0;
        g_nudge_spring.vx = g_nudge_spring.vy = 0.0;
    }
    g_nudge_spring.sid = sid;

    // Symmetric spring tuned for "one bounce on the opposite side."
    //   omega_n = 2*pi * cycles / duration_s ; k = omega_n^2 ; c = 2*zeta*omega_n
    // zeta = 0.45 -> travel out, return, one small overshoot, done.
    double duration_s = (double)duration_ms / 1000.0;
    if (duration_s < 0.12) duration_s = 0.12;
    const double zeta   = 0.45;
    const double cycles = 2.0;
    double omega_n = 2.0 * M_PI * cycles / duration_s;
    g_nudge_spring.k = omega_n * omega_n;
    g_nudge_spring.c = 2.0 * zeta * omega_n;

    // Position impulse: add to current displacement, preserve velocity
    // (compose mid-flight — a kick during decay retargets smoothly).
    g_nudge_spring.x += dx;
    g_nudge_spring.y += dy;
    g_nudge_spring.last_mach = mach_absolute_time();

    if (!g_nudge_spring.active) {
        g_nudge_spring.active = true;
        CVDisplayLinkStart(g_nudge_spring.link);
    }

    pthread_mutex_unlock(&g_nudge_spring.mutex);
}

// Wire format:
//   { uint64_t sid; int32_t dx; int32_t dy; uint32_t duration_ms;
//     uint32_t steps; }   // `steps` retained for wire compat; unused by spring
static void do_animate_edge_guard_nudge(char *message)
{
    uint64_t sid;          unpack(sid);
    int32_t  dx;           unpack(dx);
    int32_t  dy;           unpack(dy);
    uint32_t duration_ms;  unpack(duration_ms);
    uint32_t steps;        unpack(steps);
    (void)steps;

    if (!sid || duration_ms == 0 || duration_ms > 10000) return;

    int cid = SLSMainConnectionID();
    payload_nudge_spring_kick(cid, sid, (double)dx, (double)dy, duration_ms);
}
