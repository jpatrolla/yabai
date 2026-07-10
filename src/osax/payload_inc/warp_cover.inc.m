// payload_inc/warp_cover.inc.m
//
// WM-9 phase-2: 9-slice warp snap cover for duration==0 placements.
// The daemon sends SA_OPCODE_WARP_SNAP before its AX commit; we set a
// chrome-pinned SLSSetWindowWarp mesh mapping the CURRENT backing onto the
// target rect (the window is visually AT the target from this frame), arm
// the animating property (BSP re-flush gate), then poll the real frame on a
// generation-guarded 16ms dispatch chain and clear the warp at settle or the
// hard cap. rc!=0 from SLSSetWindowWarp = no cover (bare-AX behavior), never
// an error to the daemon.
//
// lb_warp: WARP_SNAP_FLAG_LB additionally pins LockedBounds at the CURRENT
// rect for the cover's lifetime. The pin does two jobs a bare warp cannot:
// (1) it freezes the warp's SOURCE space — the mesh is built against
// cur, and without the pin the AX resize drags the backing size out from
// under it mid-flight; (2) it turns the mid-cover content commit into a
// near-identity — the app's dst-sized commit is squeezed into LB(cur) and
// then warped cur->dst, so uniform-in composed with 9-slice-out roughly
// cancels (chrome bands excepted). Release is ATOMIC: one transaction clears
// warp + LockedBounds in the same server commit — clearing LB first would
// show a frame of the dst-sized surface through the cur-sized mesh, clearing
// the warp first would snap the presentation back to LB(cur).
//
// Animated transition (warp_ms, daemon lever window_animation_warp_min_ms):
// warp_ms > 0 tweens the mesh TARGET cur->dst over warp_ms (ease-out expo,
// payload_ease mode 3) on the tick chain instead of snapping it. Settle is
// not consulted until the tween completes (warp_min_ms is a floor).
// warp_ms == 0 = the instant snap.
//
// Source tracking: a mesh's target coords are global but its SOURCE coords
// are backing-local, so a mesh built against cur goes stale the moment the
// AX resize mutates the frame under it (live: out-of-sync distortion).
// Every tick therefore re-reads the REAL frame and rebuilds the mesh with
// source = the real dims and target = the FIXED cur0->dst trajectory
// (re-anchoring the trajectory too would double-ease). Before the AX lands
// this is a forward warp over the cur-sized backing; the landing flips it
// into the genie idiom — a reverse envelope over the now-static dst
// backing — continuously, no special case. At tween-end + settle the mesh
// converges to the identity mapping, so the clear in finish is a visual
// no-op by construction (no release pop, no atomicity needed).
//
// Move-first: begin seats the ORIGIN at dst server-side
// (SLSTransactionMoveWindowWithGroup, sync commit) before the daemon's AX
// fire. The server move bypasses AppKit's constraint entirely and lands in
// ONE commit — no sweep — so the app's own resize is evaluated at the END
// origin, never against the stale one (the AX size clamp misbehaves at a
// stale origin). The app adopts the position via kCGSWindowDidMove; AX
// keeps the size. FUSED with the pin mesh in ONE transaction: committed
// apart, the move presents at least one unwarped frame at dst — the
// pre-move mesh is cur->cur (identity, nothing for the server to hold) and
// the first tick only re-pins ~16ms later (live: snap-to-dst then
// bounce-back). Same-commit move+warp leaves no in-between frame: the frame
// teleports under a mesh that is non-identity the instant it matters.
//
// LB fused: WARP_SNAP_FLAG_LB pins LockedBounds(cur) as a THIRD op in the
// begin transaction — move, pin, warp, one commit. The warp still owns the
// presentation (live-verified: the warp overpowers LB), so the glide is
// unchanged; the pin does its two lb_warp jobs underneath — freeze the
// mesh's source space against the mid-flight AX resize and squeeze the
// app's dst-sized content commit back into cur — without a release pop,
// because source tracking walks the mesh to identity before finish's
// atomic warp+LB clear.
//
// Live-verified foundation:
// immediate-path warp works on foreign windows from this cid; non-uniform
// src grids honored; hit-test follows the warp; kCGSMeshedWindowTagBit is
// NOT a signal (rc + geometry only). Drag/resize regions and the shadow do
// NOT follow the warp — acceptable because covers are transient; that is
// WHY the clear must be reliable (generation guard, hard cap).
//
// Orphan safety net (live-verified via kill -9 Dock with a live mesh):
// WindowServer WIPES cid-owned warps when the owning connection dies — the
// window snaps back instantly. A Dock crash mid-cover therefore self-heals
// server-side; no daemon-side recovery sweep is needed. The guards above
// are for the LIVE payload's lifecycle, not crash recovery.

// The transactional-warp extern, the WARP_SNAP_BAND_* chrome bands, and the
// warp_mesh_9slice builder live in warp_mesh.inc.m (shared with the
// jello-policy animator in anim.inc.m — included earlier in the TU).

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

// Clear the warp (+ LockedBounds pin) + drop the animating property for slot
// i IF gen still matches (a newer cover for the same wid invalidates us).
// Takes g_warp_snap_lock for the slot mutation; SLS calls made outside the
// lock.
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
    // Non-LB path clear; for LB it is insurance for the tx-encoded warp
    // clear (server-side decode of the empty tx mesh is unverified live) —
    // a no-op when the tx clear worked.
    SLSSetWindowWarp(cid, wid, 0, 0, NULL);

    // animating=FALSE after the cooldown — but only if no NEWER cover for
    // this wid is live by then (a begin during the cooldown re-arms the
    // property, possibly in a different slot). Scan-under-lock is the
    // slot-table analogue of anim.inc.m's wid+gen currency check.
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

// Source-tracking tween + settle poll: reschedules itself every
// WARP_SNAP_TICK_S until finish. Every tick reads the REAL frame once
// (settle oracle AND mesh source) and rebuilds the mesh: source = the real
// backing's dims (cur0 until the read says otherwise), target = the fixed
// cur0->dst trajectory, eased while the tween runs, dst after. The AX
// landing flips the forward warp into the genie-style reverse envelope
// continuously; at tween-end + settle the mesh is the identity mapping, so
// finish's clear is a visual no-op. Settle is not consulted until the
// tween completes (warp_min_ms is a floor). gen captured by value — a
// superseding cover orphan-kills this chain.
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
    if (!wid) return;                                  // superseded/finished

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

// Wire handler. Struct must stay byte-identical with the daemon packer
// scripting_addition_warp_snap in sa_inc/sa_experimental.inc.m.
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
    // Instant snap: full cur->dst mesh now. Tween: frame 0 is an identity
    // mesh (cur->cur) — visually nothing yet — and the tick chain drives the
    // target toward dst. Either way this first set is the rc gate.
    float mesh[4 * 4 * 4];
    warp_mesh_9slice(cur.size.width, cur.size.height,
                     (warp_s > 0.0) ? cur : dst,
                     WARP_SNAP_BAND_L, WARP_SNAP_BAND_R,
                     WARP_SNAP_BAND_T, WARP_SNAP_BAND_B, mesh);
    CGError rc = SLSSetWindowWarp(cid, p.wid, 4, 4, mesh);
    if (rc != kCGErrorSuccess) {
        // No cover — behavior degrades to today's bare AX. Log once-ish.
        logpf("WARP", "warp_snap: SLSSetWindowWarp wid=%u rc=%d (no cover)", p.wid, rc);
        return;
    }

    // Move-first, fused with the LB pin and the pin mesh (see header:
    // "double animation" fix + fused-LB experiment). ONE transaction, buffer
    // order move -> LockedBounds(cur) -> warp: even if a geometry op
    // invalidates a standing mesh, the warp op (last) re-establishes it in
    // the same server frame; there is no presentable state where the window
    // sits at dst unwarped or unpinned. The re-set mesh is the SAME initial
    // mesh: after the move it is non-identity (frame at dst.origin,
    // presented on the cur0->dst trajectory), so the server can't drop it
    // as a no-op. sync=1 so everything is server-applied before our
    // connection closes — the daemon's AX fire strictly follows.
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
            // No tx = no move and no pin went out; finish must not try to
            // clear a pin that was never applied. Bare warp still covers.
            lb = false;
            logpf("WARP", "warp_snap: tx create failed at begin — wid=%u covers as bare warp", p.wid);
        }
    }

    double cap = (p.cap_ms > 0) ? (double)p.cap_ms / 1000.0 : WARP_SNAP_CAP_S;
    if (cap < warp_s + 0.100) cap = warp_s + 0.100;    // never deadline mid-tween
    int slot = -1; uint64_t gen = 0;
    double now = (double)mach_absolute_time() * dl_mach_to_s();
    pthread_mutex_lock(&g_warp_snap_lock);
    for (int i = 0; i < WARP_SNAP_MAX; i++)            // reuse wid slot (supersede)
        if (g_warp_snap[i].active && g_warp_snap[i].wid == p.wid) { slot = i; break; }
    if (slot < 0)
        for (int i = 0; i < WARP_SNAP_MAX; i++)
            if (!g_warp_snap[i].active) { slot = i; break; }
    if (slot >= 0) {
        // Inherit a superseded cover's live LB pin: our finish must clear it
        // even if THIS cover didn't ask for one (mixed-flag supersede would
        // otherwise leak the pin).
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
    if (slot < 0) {                                     // table full: no watcher
        // Never leave an unwatched warp/pin behind. The pin (if any) went
        // out in the begin tx above, so mirror finish's atomic clear idiom.
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

    // arm the animating property — mirrors lb_set_animating_prop(wid, true)
    // from anim.inc.m (same property string, same value type).
    lb_set_animating_prop(p.wid, true);
    int s = slot; uint64_t g = gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(WARP_SNAP_TICK_S * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ warp_snap_tick(s, g); });
}
