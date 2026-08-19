#define SA_WINDOWS_ONLY_MAX_WIDS 256

// NOTE: state-clear flag — only does anything paired with an identity
// matrix; options=0 applies a transform live.
#define SLS_SPACE_TRANSFORM_CLEAR_STATE 0x01000000

extern CGError SLSTransactionSetSpaceOrderingWeight(CFTypeRef tx, uint64_t sid, int weight);
extern CGError SLSTransactionSetSpaceAlpha(CFTypeRef tx, uint64_t sid, float alpha);

#define SLS_LEVEL_MENUBAR_BACKDROP 24   // kCGMainMenuWindowLevel — per-space Menubar backdrop
#define SLS_LEVEL_STATUS_ITEM      25   // kCGStatusWindowLevel — ControlCenter status items

// NOTE: bit 45 is a reserved slot that above-normal panels carry too, so
// this pair over-matches; bit 46 is the real kSLSMenuBarTagBit.
#define SLS_TAG_MENUBAR_BIT        (1ULL << 45)   // reserved slot, NOT kSLSMenuBarTagBit
#define SLS_TAG_MERGES_MENUBAR_BIT (1ULL << 46)   // kSLSMenuBarTagBit

#define SPACE_ANIM_DEFAULT_DURATION_S 0.25

// NOTE: defined in wallpaper_floor.inc.m, which payload.m includes AFTER this
// file — the type has to be declared here or the seed cannot name it.
#define SA_WP_OFF_MAX 8

struct wallpaper_space_set {
    uint32_t picture;
    uint32_t offscreen[SA_WP_OFF_MAX];
    int      off_n;
};

// NOTE: displaylink_ca.inc.m and anim.inc.m are included AFTER this file in
// payload.m — these forward decls must match their definitions exactly.
static int  ca_clock_register(uint32_t did, float refresh_hz, bool (*step)(void *, CFTypeRef, uint32_t), void *ctx);
static void ca_clock_resume(uint32_t did);
static void ca_clock_wait_tick_idle(uint32_t did);
static int anim_skip_all_to_end(void);

#define SA_CHILD_SPACE_MAX 8

// NOTE: SLSSpaceCopyTileSpaces is NOT this list — a container's tile list names
// only the app's tile space, omitting the type-6 content host that Dock's
// Fullscreen Backdrop lives on. Parent-id is the only link that reaches both.
static int find_child_spaces(int cid, uint64_t sid, uint64_t *out, int max)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces,
                                                       uint32_t options, uint64_t *set_tags,
                                                       uint64_t *clear_tags);
    extern CFTypeRef  SLSWindowQueryWindows(int cid, CFArrayRef wids, int count);
    extern int        SLSWindowQueryResultGetSpaceCount(CFTypeRef query);
    extern CFTypeRef  SLSWindowQueryResultCopySpaces(CFTypeRef query);
    extern bool       SLSSpaceIteratorAdvance(CFTypeRef it);
    extern int        SLSSpaceIteratorGetCount(CFTypeRef it);
    extern uint64_t   SLSSpaceIteratorGetSpaceID(CFTypeRef it);
    extern uint64_t   SLSSpaceIteratorGetParentSpaceID(CFTypeRef it);

    if (!sid || !out || max <= 0) return 0;

    CFArrayRef space_list = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
    if (!space_list) return 0;
    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef wids = SLSCopyWindowsWithOptionsAndTags(cid, 0, space_list, 0x7, &set_tags, &clear_tags);
    CFRelease(space_list);
    if (!wids) return 0;

    CFIndex base = CFArrayGetCount(wids);
    if (base == 0) { CFRelease(wids); return 0; }

    // NOTE: SLSWindowQueryWindows can reply valid-but-empty for some input
    // lengths; padding the wid list with zeros until the space count is
    // non-empty is the known recovery (documentation/sls/windows/iterator.md).
    CFTypeRef query = NULL;
    for (int pad = 0; pad <= 8 && !query; pad++) {
        CFArrayRef padded = wids;
        CFMutableArrayRef tmp = NULL;
        if (pad > 0) {
            tmp = CFArrayCreateMutableCopy(NULL, base + pad, wids);
            if (!tmp) break;
            uint32_t zero = 0;
            CFNumberRef zero_ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &zero);
            if (!zero_ref) { CFRelease(tmp); break; }
            for (int i = 0; i < pad; i++) CFArrayAppendValue(tmp, zero_ref);
            CFRelease(zero_ref);
            padded = tmp;
        }
        CFTypeRef q = SLSWindowQueryWindows(cid, padded, (int)base + pad);
        if (tmp) CFRelease(tmp);
        if (q && SLSWindowQueryResultGetSpaceCount(q) > 0) query = q;
        else if (q) CFRelease(q);
    }
    CFRelease(wids);
    if (!query) return 0;

    CFTypeRef it = SLSWindowQueryResultCopySpaces(query);
    CFRelease(query);
    if (!it) return 0;
    (void)SLSSpaceIteratorGetCount(it);

    int n = 0;
    while (n < max && SLSSpaceIteratorAdvance(it)) {
        uint64_t child = SLSSpaceIteratorGetSpaceID(it);
        if (child && child != sid && SLSSpaceIteratorGetParentSpaceID(it) == sid) out[n++] = child;
    }
    CFRelease(it);
    return n;
}

// NOTE: a type-4 container has no windows of its own — its type-5 chrome and
// type-6 content children carry them, and Dock's Fullscreen Backdrop sits on a
// child. Transforming the parent alone strands every one of them on screen.
static void space_tree_xform(CFTypeRef tx, uint64_t sid, const uint64_t *kids, int kid_n,
                             uint64_t options, CGAffineTransform *xf)
{
    SLSTransactionSetSpaceTransform(tx, sid, options, xf);
    for (int i = 0; i < kid_n; i++) SLSTransactionSetSpaceTransform(tx, kids[i], options, xf);
}

static void space_set_transform_tree(CFTypeRef tx, int cid, uint64_t sid,
                                     uint64_t options, CGAffineTransform *xf)
{
    extern int SLSSpaceGetType(int cid, uint64_t sid);

    if (SLSSpaceGetType(cid, sid) != 4) {
        SLSTransactionSetSpaceTransform(tx, sid, options, xf);
        return;
    }

    uint64_t kids[SA_CHILD_SPACE_MAX];
    int n = find_child_spaces(cid, sid, kids, SA_CHILD_SPACE_MAX);
    space_tree_xform(tx, sid, kids, n, options, xf);
    if (n) logpf("SPACE_ANIM", "space xform sid=%llu + %d child space(s) child0=%llu",
                 sid, n, kids[0]);
}

static bool space_contains_wid(int cid, uint64_t sid, uint32_t wid)
{
    extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);

    CFArrayRef wl = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    if (!wl) return false;
    CFArrayRef spaces = SLSCopySpacesForWindows(cid, 0x7, wl);
    CFRelease(wl);
    if (!spaces) return false;

    bool hit = false;
    for (CFIndex i = 0; i < CFArrayGetCount(spaces) && !hit; ++i) {
        uint64_t s = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(spaces, i), kCFNumberSInt64Type, &s);
        hit = (s == sid);
    }
    CFRelease(spaces);
    return hit;
}

// NOTE: SLSSetSpaceTransform transforms the coordinate space, so tx moves a
// space's content OPPOSITE the on-screen direction — the dx signs below are
// flipped from the naive expectation.
static void payload_space_anim_phase1(int cid, uint64_t out_sid, uint64_t in_sid,
                                      int direction, double width, double gap, double fraction,
                                      bool set_animating, bool reset,
                                      uint32_t freeze_wid, double freeze_k)
{
    double stride = width + gap;
    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    CFTypeRef tx = SLSTransactionCreate(cid);
    if (!tx) {
        logpf("SPACE_ANIM", "phase1: SLSTransactionCreate FAIL out=%llu in=%llu", out_sid, in_sid);
        if (uuid) CFRelease(uuid);
        return;
    }

    if (reset) {
        CGAffineTransform identity = CGAffineTransformIdentity;
        space_set_transform_tree(tx, cid, out_sid, SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
        space_set_transform_tree(tx, cid, in_sid,  SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
        if (freeze_wid) {
            double I[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
            SLSTransactionSetWindowTransform3D(tx, freeze_wid, I);
        }
        SLSTransactionHideSpace(tx, in_sid);
        if (set_animating && uuid) SLSTransactionSetManagedDisplayIsAnimating(tx, uuid, false);
    } else {
        SLSTransactionShowSpace(tx, out_sid);
        SLSTransactionShowSpace(tx, in_sid);
        if (set_animating && uuid) SLSTransactionSetManagedDisplayIsAnimating(tx, uuid, true);

        double out_dx = -(double)direction * stride * fraction;
        double in_dx  =  (double)direction * stride * (1.0 - fraction);
        CGAffineTransform out_xf = CGAffineTransformMakeTranslation(out_dx, 0.0);
        CGAffineTransform in_xf  = CGAffineTransformMakeTranslation(in_dx,  0.0);
        space_set_transform_tree(tx, cid, out_sid, 0, &out_xf);
        space_set_transform_tree(tx, cid, in_sid,  0, &in_xf);

        if (freeze_wid) {
            bool   on_in = space_contains_wid(cid, in_sid, freeze_wid);
            double sdx   = on_in ? in_dx : out_dx;
            double fdx   = freeze_k * sdx;
            double F[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, fdx,0,0,1 };
            SLSTransactionSetWindowTransform3D(tx, freeze_wid, F);
            logpf("SPACE_ANIM", "phase1 freeze: wid=%u side=%s space_dx=%.1f k=%.2f win_dx=%.1f",
                  freeze_wid, on_in ? "in" : "out", sdx, freeze_k, fdx);
        }
    }

    SLSTransactionCommit(tx, 0);
    CFRelease(tx);
    if (uuid) CFRelease(uuid);
}

static inline double anim_eased_p(double start_p, int target, uint64_t start_t,
                                  double dur, double mach_to_s, double *out_t, int easing)
{
    double elapsed_s = (double)(mach_absolute_time() - start_t) * mach_to_s;
    double t = dur > 0.0 ? elapsed_s / dur : 1.0;
    if (t > 1.0) t = 1.0;
    if (out_t) *out_t = t;
    return start_p + ((double)target - start_p) * payload_ease(easing, t);
}

// NOTE: the animator never touches a wallpaper. animate_wallpaper on leaves each
// picture unhandled so it rides its own space transform; off means the floor is up
// and has already blanked them, so there is nothing here to pin, hide or restore.
struct space_slide_animator {
    int       cid;
    uint64_t  out_sid, in_sid;
    // NOTE: resolved ONCE at seed — find_child_spaces runs a window query, far
    // too costly for the per-frame path.
    uint64_t  in_kids[SA_CHILD_SPACE_MAX];  int in_kid_n;
    uint64_t  out_kids[SA_CHILD_SPACE_MAX]; int out_kid_n;
    int       direction;
    // NOTE: gap widens the per-side stride, so mid-slide neither space covers a
    // gap-wide strip and whatever sits under them shows through.
    double    width, gap, duration, mach_to_s;
    uint64_t  start_mach_time;
    _Atomic bool active;
    bool      committed;
    pthread_mutex_t lock;
    uint32_t  did;            // ca_clock display this slide registered on (stale-clock guard)
    float     refresh_hz;     // panel rate shipped on the wire (ProMotion/VRR range)
    uint64_t  gen;            // bumped per seed; the step's settle re-checks it
    int       easing;         // curve mode (enum focus_ring_easing)
    float     enter_delay;    // slide stagger (s); 0 = no delay
    float     exit_delay;     // slide stagger (s); 0 = no delay
};
static struct space_slide_animator g_slide = { .lock = PTHREAD_MUTEX_INITIALIZER };

// NOTE: sink the OUTGOING space one band BELOW normal — a positive weight
// would risk punching above the menubar.
#define SPACE_SLIDE_OUT_SYSTEM_LEVEL (-1)

// NOTE: returns true once settled (or inactive / on a stale clock) so the pump
// deactivates this client. No blocking SLS round-trip belongs here — the step
// runs on the pump thread under clients_lock.
static bool space_slide_animator_ca_step(void *ctx, CFTypeRef pump_tx, uint32_t pump_did)
{
    struct space_slide_animator *a = (struct space_slide_animator *)ctx;
    if (!atomic_load(&a->active)) return true;

    pthread_mutex_lock(&a->lock);
    int      cid = a->cid;
    uint64_t out_sid = a->out_sid, in_sid = a->in_sid;
    int      in_kid_n = a->in_kid_n, out_kid_n = a->out_kid_n;
    uint64_t in_kids[SA_CHILD_SPACE_MAX], out_kids[SA_CHILD_SPACE_MAX];
    memcpy(in_kids,  a->in_kids,  sizeof(uint64_t) * (size_t)in_kid_n);
    memcpy(out_kids, a->out_kids, sizeof(uint64_t) * (size_t)out_kid_n);
    int      direction = a->direction;
    double   stride = a->width + a->gap, dur = a->duration, mach_to_s = a->mach_to_s;
    int      easing = a->easing;
    double   enter_delay = (double)a->enter_delay, exit_delay = (double)a->exit_delay;   // slide stagger (s)
    uint64_t start_t = a->start_mach_time;
    uint64_t snap_gen  = a->gen;     // the seed bumps a->gen
    uint32_t adid      = a->did;
    pthread_mutex_unlock(&a->lock);

    // NOTE: re-seeded on a different display — release this clock's slot.
    if (pump_did != adid) return true;

    double t = 0.0;
    (void)anim_eased_p(0.0, 1, start_t, dur, mach_to_s, &t, easing);
    bool settled = (t >= 1.0);

    double edf = dur > 0.0 ? enter_delay / dur : 0.0;   // enter delay as a slide fraction
    double xdf = dur > 0.0 ? exit_delay  / dur : 0.0;   // exit  delay as a slide fraction
    double es  = 1.0 - edf, xs = 1.0 - xdf;             // span left after the delay
    double er  = es > 1e-6 ? (t - edf) / es : (t >= edf ? 1.0 : 0.0);
    double xr  = xs > 1e-6 ? (t - xdf) / xs : (t >= xdf ? 1.0 : 0.0);
    er = er < 0.0 ? 0.0 : (er > 1.0 ? 1.0 : er);
    xr = xr < 0.0 ? 0.0 : (xr > 1.0 ? 1.0 : xr);
    double e_enter = payload_ease(easing, er);   // incoming slide progress (delayed)
    double e_exit  = payload_ease(easing, xr);   // outgoing slide progress (delayed)
    double entering_dx =  (double)direction * stride * (1.0 - e_enter);
    double leaving_dx  = -(double)direction * stride * e_exit;

    // NOTE: ShowSpace/IsAnimating are asserted ONCE at seed — never re-assert per
    // frame. Cost here is per-SPACE, not per-window: keep it that way.
    if (pump_tx) {
        CGAffineTransform xf_in = CGAffineTransformMakeTranslation(entering_dx, 0.0);
        space_tree_xform(pump_tx, in_sid, in_kids, in_kid_n, 0, &xf_in);
        CGAffineTransform xf_out = CGAffineTransformMakeTranslation(leaving_dx, 0.0);
        space_tree_xform(pump_tx, out_sid, out_kids, out_kid_n, 0, &xf_out);
        SLSTransactionSetSpaceOrderingWeight(pump_tx, in_sid, 0);
        SLSTransactionSetSpaceOrderingWeight(pump_tx, out_sid, SPACE_SLIDE_OUT_SYSTEM_LEVEL);
    }

    pthread_mutex_lock(&a->lock);
    // NOTE: a new seed bumps a->gen and clears committed, so the committed-only
    // check is insufficient — a step holding the OLD gen must not settle-commit.
    bool do_settle = settled && pump_tx && !a->committed && (a->gen == snap_gen);
    if (do_settle) {
        a->committed = true;
        atomic_store(&a->active, false);
    }
    pthread_mutex_unlock(&a->lock);

    if (!do_settle) return false;

    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    uint64_t target_sid = in_sid, src_sid = out_sid;

    // NOTE: ONE atomic cut, IN the pump's SHARED transaction — a separate tx can
    // commit before this tick's buffered frame writes and strand the outgoing side.
    // NOTE: a space transform outlives the animator — a side left un-cleared strands
    // that space offset for good, so this is unconditional (no token gate).
    CGAffineTransform SI = CGAffineTransformIdentity;
    space_tree_xform(pump_tx, in_sid,  in_kids,  in_kid_n,  SLS_SPACE_TRANSFORM_CLEAR_STATE, &SI);
    space_tree_xform(pump_tx, out_sid, out_kids, out_kid_n, SLS_SPACE_TRANSFORM_CLEAR_STATE, &SI);
    SLSTransactionSetSpaceOrderingWeight(pump_tx, in_sid,  0);
    SLSTransactionSetSpaceOrderingWeight(pump_tx, out_sid, 0);
    if (uuid) SLSTransactionSetManagedDisplayCurrentSpace(pump_tx, uuid, target_sid);
    SLSTransactionHideSpace(pump_tx, src_sid);
    if (uuid) SLSTransactionSetManagedDisplayIsAnimating(pump_tx, uuid, false);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (uuid && dock_spaces != nil) {
            id dest_space    = space_for_display_with_id(uuid, target_sid);
            id display_space = display_space_for_display_uuid(uuid);
            if (dest_space != nil && display_space != nil)
                set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
        }
        if (uuid) {
            uint64_t mc_current = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), uuid);
            logpf("SPACE_ANIM", "slide settle COMMIT target=%llu mc_current=%llu%s",
                  target_sid, mc_current, mc_current == target_sid ? "" : " (MISMATCH)");
            CFRelease(uuid);
        }
    });
    return true;   // settled & committed → pump deactivates this client
}

// NOTE: deliberately does NOT touch SetManagedDisplayCurrentSpace, IsAnimating or
// Dock's _currentSpace — those three race Dock's bookkeeping when spammed and
// must fire exactly once, at the real settle. HideSpace is visibility-only.
static void slide_handoff_no_commit(struct space_slide_animator *a)
{
    pthread_mutex_lock(&a->lock);
    if (!atomic_load(&a->active)) { pthread_mutex_unlock(&a->lock); return; }
    int      cid = a->cid;
    uint32_t hdid = a->did;
    uint64_t src_sid = a->out_sid;
    int      in_kid_n = a->in_kid_n, out_kid_n = a->out_kid_n;
    uint64_t in_kids[SA_CHILD_SPACE_MAX], out_kids[SA_CHILD_SPACE_MAX];
    memcpy(in_kids,  a->in_kids,  sizeof(uint64_t) * (size_t)in_kid_n);
    memcpy(out_kids, a->out_kids, sizeof(uint64_t) * (size_t)out_kid_n);
    // NOTE: committed MUST be cleared here — a settle queued in the same instant
    // guards on it and would otherwise commit the OLD target mid-new-slide.
    a->committed = false;
    atomic_store(&a->active, false);
    // NOTE: bump gen HERE, not only at seed — a step mid-flight on the old hop
    // would otherwise stray-commit it through the cleared `committed` flag.
    a->gen++;
    pthread_mutex_unlock(&a->lock);

    // NOTE: a pump tick may already have this hop's mid-slide frame BUFFERED and the
    // gen bump cannot recall it — without this wait the stale frame commits last.
    ca_clock_wait_tick_idle(hdid);

    CFTypeRef tx = SLSTransactionCreate(cid);
    if (tx) {
        CGAffineTransform SI = CGAffineTransformIdentity;
        space_tree_xform(tx, a->in_sid,  in_kids,  in_kid_n,  SLS_SPACE_TRANSFORM_CLEAR_STATE, &SI);
        space_tree_xform(tx, a->out_sid, out_kids, out_kid_n, SLS_SPACE_TRANSFORM_CLEAR_STATE, &SI);
        SLSTransactionSetSpaceOrderingWeight(tx, a->in_sid,  0);
        SLSTransactionSetSpaceOrderingWeight(tx, a->out_sid, 0);
        SLSTransactionHideSpace(tx, src_sid);
        SLSTransactionCommit(tx, 0);
        CFRelease(tx);
    } else {
        logpf("SPACE_ANIM", "slide handoff: SLSTransactionCreate FAIL — terminal restore lost src=%llu", src_sid);
    }

    logpf("SPACE_ANIM", "slide handoff (no commit) leaving src=%llu", src_sid);
}

static void space_slide_animator_start(int cid, uint64_t out_sid, uint64_t in_sid,
                                       int direction, double width, double gap, double duration,
                                       uint32_t did, float refresh_hz,
                                       int easing,
                                       uint32_t ring_wid, CGRect ring_rect, float ring_radius,
                                       float enter_delay, float exit_delay)
{
    struct space_slide_animator *a = &g_slide;

    // NOTE: force in-flight LB+T3D resizes to their terminal state BEFORE the slide
    // takes those wids — one still pinned by LockedBounds keeps its mid-resize size.
    anim_skip_all_to_end();

    uint32_t prev_did = a->did;   // previous hop's clock (0 before the first seed)
    if (atomic_load(&a->active)) {
        slide_handoff_no_commit(a);
        logpf("SPACE_ANIM", "slide retarget in=%llu (handed off prior slide, no commit)", in_sid);
    }

    // NOTE: fence the previous hop's clock even with no handoff — a settle tick
    // mid-commit would otherwise land after this hop's seed.
    ca_clock_wait_tick_idle(prev_did);

    pthread_mutex_lock(&a->lock);
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    a->cid = cid; a->out_sid = out_sid; a->in_sid = in_sid; a->direction = direction;
    a->width = width; a->gap = gap;
    a->duration = duration > 0.0 ? duration : SPACE_ANIM_DEFAULT_DURATION_S;
    a->mach_to_s = (double)tb.numer / ((double)tb.denom * 1e9);
    a->committed = false;
    a->did = did; a->refresh_hz = refresh_hz; a->easing = easing;
    a->enter_delay = enter_delay; a->exit_delay = exit_delay;
    a->gen++;   // new hop generation — the step's settle re-checks this
    pthread_mutex_unlock(&a->lock);

    // NOTE: a type-4 container owns no windows — its type-5 chrome and type-6
    // content children carry them, so only a type-4 side has kids to move.
    extern int SLSSpaceGetType(int cid, uint64_t sid);
    a->in_kid_n  = SLSSpaceGetType(cid, in_sid)  == 4 ? find_child_spaces(cid, in_sid,  a->in_kids,  SA_CHILD_SPACE_MAX) : 0;
    a->out_kid_n = SLSSpaceGetType(cid, out_sid) == 4 ? find_child_spaces(cid, out_sid, a->out_kids, SA_CHILD_SPACE_MAX) : 0;

    // NOTE: the ring is bound to its space, so the slide already carries it — it
    // only has to EXIST in the incoming space before the transform starts.
    if (ring_wid != 0) payload_focus_ring_park_for_slide(cid, ring_wid, ring_rect, ring_radius, in_sid);

    // NOTE: ShowSpace, IsAnimating and the entering space's t=0 offset must land in
    // ONE transaction — showing it before the offset is applied presents it
    // untranslated, i.e. squarely on top of the outgoing space, for a frame.
    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    CFTypeRef show = SLSTransactionCreate(cid);
    if (show) {
        CGAffineTransform xf0 = CGAffineTransformMakeTranslation((double)direction * (width + gap), 0.0);
        space_tree_xform(show, in_sid, a->in_kids, a->in_kid_n, 0, &xf0);
        SLSTransactionShowSpace(show, in_sid);
        if (uuid) SLSTransactionSetManagedDisplayIsAnimating(show, uuid, true);
        SLSTransactionCommit(show, 0);
        CFRelease(show);
    } else {
        logpf("SPACE_ANIM", "slide seed: SLSTransactionCreate FAIL in=%llu", in_sid);
    }
    if (uuid) CFRelease(uuid);

    pthread_mutex_lock(&a->lock);
    a->start_mach_time = mach_absolute_time();
    atomic_store(&a->active, true);
    pthread_mutex_unlock(&a->lock);

    // NOTE: register AFTER releasing a->lock — lock order vs the pump's
    // clients_lock. Idempotent by ctx; a retarget re-activates the same client.
    ca_clock_register(did, refresh_hz, space_slide_animator_ca_step, a);
    ca_clock_resume(did);
    logpf("SPACE_ANIM", "slide seed out=%llu in=%llu dir=%d width=%.0f gap=%.0f dur=%.3f in_kids=%d out_kids=%d did=0x%x hz=%.0f",
          out_sid, in_sid, direction, width, gap, a->duration, a->in_kid_n, a->out_kid_n, did, refresh_hz);
}

static void do_space_focus_animated(char *message)
{
    // NOTE: the unpack order is the wire contract — it must mirror
    // scripting_addition_animate_space's packer exactly.
    uint64_t out_sid;   unpack(out_sid);
    uint64_t in_sid;    unpack(in_sid);
    int32_t  direction; unpack(direction);
    float    duration;  unpack(duration);
    double   width;     unpack(width);
    double   gap;       unpack(gap);      // extra stride between the two sides
    uint32_t did;       unpack(did);      // per-display ca_clock cadence
    float    refresh_hz; unpack(refresh_hz);
    uint8_t  easing;    unpack(easing);   // curve mode (enum focus_ring_easing)
    uint32_t ring_wid;  unpack(ring_wid);   // destination focused window; 0 = no rider
    float    ring_x;    unpack(ring_x);
    float    ring_y;    unpack(ring_y);
    float    ring_w;    unpack(ring_w);
    float    ring_h;    unpack(ring_h);
    float    ring_radius; unpack(ring_radius);   // corner radius
    float    enter_delay; unpack(enter_delay);    // slide stagger (s)
    float    exit_delay;  unpack(exit_delay);     // slide stagger (s)

    int cid = SLSMainConnectionID();
    space_slide_animator_start(cid, out_sid, in_sid, direction, width, gap,
                               duration > 0.0f ? (double)duration : SPACE_ANIM_DEFAULT_DURATION_S,
                               did, refresh_hz, (int)easing,
                               ring_wid, CGRectMake(ring_x, ring_y, ring_w, ring_h), ring_radius,
                               enter_delay, exit_delay);
}
