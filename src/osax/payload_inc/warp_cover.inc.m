// payload_inc/warp_cover.inc.m
//
// WM-9 phase-2: 9-slice warp snap cover for duration==0 placements.

#define WARP_SNAP_MAX         16
#define WARP_SNAP_SETTLE_PX   1.0   // match SA_ANIM_SETTLE_PX
#define WARP_SNAP_CAP_S       0.400 // default hard clear (cap_ms==0)
#define WARP_SNAP_COOLDOWN_S  0.100 // match ANIM_COOLDOWN_S
#define WARP_SNAP_TICK_S      0.016 // settle poll cadence

struct warp_snap_cover {
    uint32_t wid;
    uint64_t gen;        // monotonic per slot; stale scheduled blocks no-op
    CGRect   cur;        // backing rect the mesh was built against (tween start)
    CGRect   dst;
    double   deadline;   // mach-seconds deadline: mach_absolute_time()*dl_mach_to_s() + cap
    double   t0;         // tween start (mach-seconds)
    double   warp_s;     // mesh tween length; 0 = instant snap
    bool     lb;         // WARP_SNAP_FLAG_LB live -> finish clears LockedBounds too
    bool     active;
};
static struct warp_snap_cover g_warp_snap[WARP_SNAP_MAX];
static pthread_mutex_t g_warp_snap_lock = PTHREAD_MUTEX_INITIALIZER;

static void warp_snap_finish(int i, uint64_t gen)
{
    uint32_t wid = 0;
    bool lb = false;
    pthread_mutex_lock(&g_warp_snap_lock);
    if (g_warp_snap[i].active && g_warp_snap[i].gen == gen) {
        wid = g_warp_snap[i].wid;
        lb  = g_warp_snap[i].lb;
        g_warp_snap[i].active = false;
    }
    pthread_mutex_unlock(&g_warp_snap_lock);
    if (!wid) return;

    int cid = SLSMainConnectionID();
    // NOTE: clear warp+LB in one transaction (warp-first snaps to the LB rect); a
    // same-tx geometry op invalidates a standing mesh — re-set the warp last.
    if (lb) {
        CFTypeRef tx = SLSTransactionCreate(cid);
        if (tx) {
            SLSTransactionSetWindowWarp(tx, wid, 0, 0, NULL);
            SLSTransactionClearWindowLockedBounds(tx, wid);
            SLSTransactionCommit(tx, 0);
            CFRelease(tx);
        } else {
            logpf("WARP", "warp_snap: tx create failed at release — LB pin on wid=%u leaks until the next cover", wid);
        }
    }
    // NOTE: keep — insurance for the tx-encoded clear (empty-mesh tx decode unverified live).
    SLSSetWindowWarp(cid, wid, 0, 0, NULL);

    // NOTE: scan by wid, not slot-gen — a begin during the cooldown can re-arm in a DIFFERENT slot.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(WARP_SNAP_COOLDOWN_S * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        bool live = false;
        pthread_mutex_lock(&g_warp_snap_lock);
        for (int j = 0; j < WARP_SNAP_MAX; j++) {
            if (g_warp_snap[j].active && g_warp_snap[j].wid == wid) { live = true; break; }
        }
        pthread_mutex_unlock(&g_warp_snap_lock);
        if (!live) lb_set_animating_prop(wid, false);
    });
}

static void warp_snap_tick(int i, uint64_t gen)
{
    uint32_t wid = 0; CGRect cur = {0}, dst = {0};
    double deadline = 0, t0 = 0, warp_s = 0;
    pthread_mutex_lock(&g_warp_snap_lock);
    if (g_warp_snap[i].active && g_warp_snap[i].gen == gen) {
        wid = g_warp_snap[i].wid;
        cur = g_warp_snap[i].cur; dst = g_warp_snap[i].dst;
        deadline = g_warp_snap[i].deadline;
        t0 = g_warp_snap[i].t0; warp_s = g_warp_snap[i].warp_s;
    }
    pthread_mutex_unlock(&g_warp_snap_lock);
    if (!wid) return;

    int cid = SLSMainConnectionID();
    double now = (double)mach_absolute_time() * dl_mach_to_s();
    double t = (warp_s > 0.0) ? (now - t0) / warp_s : 1.0;

    CGRect real = {0};
    bool have_real = SLSGetScreenRectForWindow(cid, wid, &real) == kCGErrorSuccess &&
                     real.size.width > 0.0 && real.size.height > 0.0;

    double src_w = have_real ? real.size.width  : cur.size.width;
    double src_h = have_real ? real.size.height : cur.size.height;
    CGRect target = dst;
    if (t < 1.0) {
        double e = payload_ease(3, t);                 // ease-out expo
        target = CGRectMake(
            cur.origin.x + (dst.origin.x - cur.origin.x) * e,
            cur.origin.y + (dst.origin.y - cur.origin.y) * e,
            cur.size.width  + (dst.size.width  - cur.size.width)  * e,
            cur.size.height + (dst.size.height - cur.size.height) * e);
    }
    float mesh[4 * 4 * 4];
    warp_mesh_9slice(src_w, src_h, target,
                     WARP_SNAP_BAND_L, WARP_SNAP_BAND_R,
                     WARP_SNAP_BAND_T, WARP_SNAP_BAND_B, mesh);
    SLSSetWindowWarp(cid, wid, 4, 4, mesh);

    bool settled = false;
    if (t >= 1.0 && have_real) {
        settled = fabs(real.origin.x - dst.origin.x) <= WARP_SNAP_SETTLE_PX &&
                  fabs(real.origin.y - dst.origin.y) <= WARP_SNAP_SETTLE_PX &&
                  fabs(real.size.width  - dst.size.width)  <= WARP_SNAP_SETTLE_PX &&
                  fabs(real.size.height - dst.size.height) <= WARP_SNAP_SETTLE_PX;
    }
    if (settled || now >= deadline) {
        warp_snap_finish(i, gen);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(WARP_SNAP_TICK_S * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ warp_snap_tick(i, gen); });
}

// NOTE: must stay byte-identical with the daemon packer (sa_inc/sa_experimental.inc.m).
struct __attribute__((packed)) sa_warp_snap {
    uint32_t wid;
    float    dst_x, dst_y, dst_w, dst_h;
    uint32_t cap_ms;
    uint32_t flags;      // WARP_SNAP_FLAG_LB
    uint32_t warp_ms;    // mesh tween length; 0 = instant snap
};

static void payload_warp_snap_begin(char *message)
{
    struct sa_warp_snap p;
    memcpy(&p, message, sizeof(p));
    if (!p.wid || p.dst_w < 8.0f || p.dst_h < 8.0f) return;

    int cid = SLSMainConnectionID();
    CGRect cur = {0};
    if (SLSGetWindowBounds(cid, p.wid, &cur) != kCGErrorSuccess ||
        cur.size.width <= 0.0 || cur.size.height <= 0.0) return;

    CGRect dst = CGRectMake(p.dst_x, p.dst_y, p.dst_w, p.dst_h);
    double warp_s = (double)p.warp_ms / 1000.0;
    float mesh[4 * 4 * 4];
    warp_mesh_9slice(cur.size.width, cur.size.height,
                     (warp_s > 0.0) ? cur : dst,
                     WARP_SNAP_BAND_L, WARP_SNAP_BAND_R,
                     WARP_SNAP_BAND_T, WARP_SNAP_BAND_B, mesh);
    CGError rc = SLSSetWindowWarp(cid, p.wid, 4, 4, mesh);
    if (rc != kCGErrorSuccess) {
        logpf("WARP", "warp_snap: SLSSetWindowWarp wid=%u rc=%d (no cover)", p.wid, rc);
        return;
    }

    // NOTE: one tx, order move -> LB(cur) -> warp (warp last re-establishes the mesh a geometry
    // op invalidates, same server frame). sync=1: server-applied before our connection closes,
    // so the daemon's AX fire strictly follows.
    bool lb = (p.flags & WARP_SNAP_FLAG_LB) != 0;
    bool needs_move = fabs(dst.origin.x - cur.origin.x) > 0.5 ||
                      fabs(dst.origin.y - cur.origin.y) > 0.5;
    if (needs_move || lb) {
        CFTypeRef mtx = SLSTransactionCreate(cid);
        if (mtx) {
            if (needs_move) SLSTransactionMoveWindowWithGroup(mtx, p.wid, dst.origin);
            if (lb) SLSTransactionSetWindowLockedBounds(mtx, p.wid, cur);
            SLSTransactionSetWindowWarp(mtx, p.wid, 4, 4, mesh);
            SLSTransactionCommit(mtx, 1);
            CFRelease(mtx);
        } else {
            lb = false;
            logpf("WARP", "warp_snap: tx create failed at begin — wid=%u covers as bare warp", p.wid);
        }
    }

    double cap = (p.cap_ms > 0) ? (double)p.cap_ms / 1000.0 : WARP_SNAP_CAP_S;
    if (cap < warp_s + 0.100) cap = warp_s + 0.100;    // never deadline mid-tween
    int slot = -1; uint64_t gen = 0;
    double now = (double)mach_absolute_time() * dl_mach_to_s();
    pthread_mutex_lock(&g_warp_snap_lock);
    for (int i = 0; i < WARP_SNAP_MAX; i++)
        if (g_warp_snap[i].active && g_warp_snap[i].wid == p.wid) { slot = i; break; }
    if (slot < 0)
        for (int i = 0; i < WARP_SNAP_MAX; i++)
            if (!g_warp_snap[i].active) { slot = i; break; }
    if (slot >= 0) {
        // NOTE: inherit a superseded cover's live LB pin — mixed-flag supersede would leak it.
        bool inherited_lb = g_warp_snap[slot].active && g_warp_snap[slot].lb;
        g_warp_snap[slot].wid = p.wid;
        g_warp_snap[slot].gen++;                        // orphans any pending chain
        g_warp_snap[slot].cur = cur;
        g_warp_snap[slot].dst = dst;
        g_warp_snap[slot].deadline = now + cap;
        g_warp_snap[slot].t0 = now;
        g_warp_snap[slot].warp_s = warp_s;
        g_warp_snap[slot].lb = lb || inherited_lb;
        g_warp_snap[slot].active = true;
        gen = g_warp_snap[slot].gen;
    }
    pthread_mutex_unlock(&g_warp_snap_lock);
    if (slot < 0) {
        if (lb) {
            CFTypeRef tx = SLSTransactionCreate(cid);
            if (tx) {
                SLSTransactionSetWindowWarp(tx, p.wid, 0, 0, NULL);
                SLSTransactionClearWindowLockedBounds(tx, p.wid);
                SLSTransactionCommit(tx, 0);
                CFRelease(tx);
            }
        }
        SLSSetWindowWarp(cid, p.wid, 0, 0, NULL);
        return;
    }

    lb_set_animating_prop(p.wid, true);
    int s = slot; uint64_t g = gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(WARP_SNAP_TICK_S * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ warp_snap_tick(s, g); });
}
