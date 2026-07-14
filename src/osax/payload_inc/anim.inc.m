// =========================================================================
// anim.inc.m — payload-side LB+T3D+AX animator (CA pump).
// =========================================================================
// Branch B: the payload owns the WHOLE animation — per-VBL clock, lerp, easing,
// LB+T3D commit, AND real AX setFrame — in-process, no daemon sync. AX trust
// comes from Dock's TCC grant.
//
// Per window the T3D bridges from the ANCHOR (= last committed AX position),
// which advances as AX setFrame lands. The AX recipe is ENDPIN (origin-fixed
// resize, the production default): the app's real origin is pinned at
// end_xy for the whole animation, so it never computes an internal move (the
// cause of left/top-edge grow jank); the positional illusion is carried by
// LB_FULL + T3D. Triggers: 1 (t=0) a pure move to end_xy at start size; 2 (mid)
// a PX-threshold resize-only fire at the seated origin; 3 (t>=1) a full end_rect
// commit. Fires are throttled (in-flight + same-PID round-robin) and DISPATCHED
// OFF the CA tick thread (AX is synchronous and can block) — so the pump never
// stalls (jitter stays ~0.01ms). The completion advances the anchor
// (token-guarded against supersede). Finalize is non-blocking: terminal AX +
// EUI-restore go async and the pump keeps ticking + probing the real frame
// until it lands at end, then clears LB/T3D.
//
// USE_AX off ⇒ visual-only behaviour (anchor==start, no AX). apply_easing
// / dl_mach_to_s come in via misc/displaylink.h. Wire unpack MUST mirror the
// daemon packer scripting_addition_anim_ax_begin (sa_experimental.inc.m).
// =========================================================================

#include <CoreGraphics/CGGeometry.h>
#include <dispatch/dispatch.h>

// Geom-probe getters not already externed in payload.m (SLSGetWindowBounds,
// SLSGetScreenRectForWindow, SLSWindowIteratorGetConstraints, the query/iterator
// primitives are there already). Signatures match src/misc/extern.h; the shape
// getter is a *Copy* (+1-retained region → CFRelease).
extern CGError  SLSGetOnscreenWindowBounds(int cid, uint32_t wid, CGRect *out);
extern CGRect   SLSWindowIteratorGetFrameBounds(CFTypeRef iterator);
extern CGRect   SLSWindowIteratorGetBounds(CFTypeRef iterator);
extern CGError  SLSCopyWindowShape(int cid, uint32_t wid, CFTypeRef *out_region);
extern CGError  CGSGetRegionBounds(CFTypeRef region, CGRect *out_bounds);
extern bool     CGSRegionIsEmpty(CFTypeRef region);
extern CGError  SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef key, CFTypeRef *out);  // cross-process title read (kCGSWindowTitle)
extern int      proc_name(int pid, void *buf, uint32_t bufsize);                                // libproc app-name from pid (no AppKit)

#define ANIM_AX_MAX       SA_ANIM_AX_MAX   // per-animation window cap — single-sourced with the daemon packer (common_experimental.h)
#define ANIM_MAX_CTX 16   // concurrent animations
#define WM_AX_TH_NONE_      0u   // mirror of WM_AX_TH_NONE
#define ANIM_SETTLE_MAX_S 0.5  // wall-clock (refresh-independent) hard-stop: clear LB/T3D even if the settle probe never converges
#define GEOM_SETTLE_HOLD_S  0.05 // geom probe only: keep ticking ≥50ms past t=1 so the log captures post-animation settle frames even when the surface lands instantly
#define ANIM_SETTLE_PX    SA_ANIM_SETTLE_PX // per-edge tolerance for "real frame landed at end" — must stay below the daemon AX_DIFF threshold so a settled frame can't trip window_node_flush (single-sourced in common_experimental.h; coupling asserted in window_manager.c)
#define ANIM_COOLDOWN_S   0.1 // wall-clock (refresh-independent) hold on the animating-property flush-gate AFTER LB clears, so trailing terminal-AX MOVED/RESIZED events drain while still suppressed
#define ANIM_CONFORM_MAX_DEV 500.0f // CONFORMANCE CLAMP — the tuning knob (px): max headroom the asked size may lead the app's REAL frame (WindowBounds) while it catches up; ramps to 0 by t=1 via apply_easing(1-t) so the held visual converges to WB → no finalize snap. Sized to the free-window catch-up lag (~270px peak) so lagging windows never clip; the inverse easing holds that headroom through the WB catch-up phase (which lags the ASK motion), then tapers over the last ~30%. Caveat: an UNKNOWN-constrained window (aspect / fixed-axis / lazy-zero — what lb_clamp's shipped min/max DON'T cover) can stretch up to this much mid-flight before the taper.

// Classify-at-settle (single-axis constraint learning). When a window's REAL
// frame (WindowBounds) has LANDED at settle (its screen rect matches the conformed
// end in the settle-judgment loop), the asked-vs-real gap on exactly one axis
// reveals a single-axis min/max constraint. It's persisted on the window's
// property bag (com.koekeishiya.yabai.constraint_class.v1) and read back daemon-
// side in resolve_anim_constraints, so the NEXT animation preshapes (no skew) even
// while the SLS iterator stays lazy-zero.
#define ANIM_CLS_LAND_PX     8.0f   // |asked - WB| under this == the asked size landed on that axis (axis free)
#define ANIM_SEAT_MAX_DISP   8      // display-snapshot capacity for the seat seam-guard (struct anim_ctx)

#include "../../pile_transform.h"  // pile pose math (pure; shared with the daemon)

struct anim_window {
    uint32_t wid, mode; int32_t pid;
    float sx, sy, sw, sh;        // start (VISUAL lerp begin)
    float ex, ey, ew, eh;        // end   (VISUAL lerp end)
    float nx, ny, nw, nh;        // natural surface rect — the visual-only T3D anchor (== start_* on the carve path)
    uint32_t depth;             // stages-only (pile cascade step); inert in carve
    float min_opacity, min_w, min_h, max_w, max_h;
    float aspect;               // inert reserved wire field (SA_ANIM_ROW_FIELDS): daemon ships 0, nothing reads it
    volatile float ax_x, ax_y, ax_w, ax_h;   // anchor = last committed AX pos
    volatile bool  ax_in_flight;
    bool           ax_initial;               // Trigger 1 (t=0) has fired (endpin fires it for resizes too)
    volatile bool  superseded;               // a newer context owns this wid; skip it everywhere
    uint64_t       ax_dispatch_id;
    uint64_t       gen;                       // per-wid generation stamp (AC-5: guards the async animating-prop clear vs a newer begin)
    uint64_t       own_geo;                   // AC-15: anim_owner GEO token (T3D+LB+AX as one channel) — gates every write
    uint64_t       own_alpha;                 // AC-15: ALPHA token when SA_T3D_FLAG_ALPHA; 0 = never claimed
    // Geom probe (SA_T3D_FLAG_GEOM_LOG) — what step_one ASKED for this frame,
    // stashed for the unlocked sampler to log next tick against what the getters
    // report. Written under g_anim_lock in step_one, read (atomically) off-lock
    // in the Pass-1.5 sampler. The one-tick lag aligns ask(N-1) with the read
    // that reflects the pump's commit of tick N-1 — so ask and report line up.
    volatile float glb_x, glb_y, glb_w, glb_h;   // last LB rect asked (lb_x,lb_y,clamped_w,clamped_h)
    volatile float gt;                            // last lerp progress, clamped 0..1
    volatile float wb_w, wb_h;                    // app's REAL frame (WindowBounds) sampled UNLOCKED in the pre-pass; the locked step clamps the asked size to within MAX_DEV of it (conformance clamp). 0 = not yet sampled / probe run → no clamp.
    volatile float wb_x, wb_y;                    // app's REAL on-screen ORIGIN, sampled with wb_w/wb_h in the same pre-pass tick. Seam-held rows anchor their T3D translate on this LIVE origin (not the AX-asked one): the asked anchor leads the server-visible frame by the app's commit lag, and an identity transform in that gap flashes the window at its raw (start) position. wb_w>0 is the "sampled" proxy (a real window's size is never 0).
    bool     seam_hold;              // latched (seam_eval): the endpin seat at START size would occupy a display the end rect doesn't touch → never seat, resize in place, terminal server-side move at the clear, T3D anchored on live WB
    bool     seam_eval;              // seam_hold computed (write-once; START size is constant so the verdict can't flip)
    bool     seam_park;              // straddling-start rescue armed (latch): ONE pure kAXPosition move to park_x/y must fire before any resize; cleared at the dispatch that sends it
    float    park_x, park_y;         // park origin — the real-frame rect clamped inside the end display (moves are never refused; in-place resizes at a straddling origin are)
    float    vis_x, vis_y, vis_w, vis_h;   // last committed VISUAL rect (lerp), stored each locked tick — a superseding begin hands it to the successor row as its lerp start (a seam row's real frame parks at start, so the daemon's captured start is stale mid-flight). g_anim_lock-protected, no atomics.
    bool     vis_set;                // vis_* valid (at least one tick committed)
    // Classify-at-settle (single-axis constraint learning). Pump-thread-only:
    // Pass-1 filters by did so one display's pump owns this context — no atomics.
    bool     cls_done;               // classified this run (write-once verdict guard)
};

struct anim_ctx {
    volatile bool active;        // slot ownership: begin sets last, pump clears on settle
    bool     reported;
    bool     finalizing;         // t>=1 reached: terminal AX + EUI dispatched, now settling
    double   settle_start_s;     // wall-clock (mach→s) when finalize/settle began — bounds the settle wait at ANIM_SETTLE_MAX_S regardless of refresh
    volatile bool settle_ok;     // "real frame landed at end" — probed UNLOCKED in anim_step's pre-pass (AC-4: SLSGetScreenRectForWindow must not run under g_anim_lock or it stalls other displays' pumps); the locked step consumes it round-trip-free
    bool     lb_cleared;         // settle done: LB/T3D dropped, now holding the flush-gate through cooldown
    double   cooldown_start_s;   // wall-clock (mach→s) when LB cleared — bounds the post-clear flush-gate at ANIM_COOLDOWN_S regardless of refresh
    bool     eui_released;       // idempotent guard for the per-pid EUI refcount release
    bool     use_ax;
    bool     notify_done;        // set/clear the daemon-observable animating property even when visual-only (so the daemon's pending-finalize poll fires on completion)
    uint32_t finalize_mode;      // SA_FINALIZE_* — carve always CLEAR (resets LB/T3D to identity at t=1); LEAVE_TERMINAL is stages-only
    bool     pile;               // stages-only (pile pose); always false in carve
    struct pile_xform pile_xf;   // stages-only; unused in carve
    uint32_t pile_pose_easing;   // stages-only; unused in carve
    int      count;
    uint32_t flags, easing, ax_th_mode;
    float    ax_th_val;
    uint32_t did;                // display this animation paces on (per-display CA clock)
    float    refresh_hz;         // that display's panel rate (ProMotion/VRR range)
    double   duration, fade_duration, start_s;
    uint64_t tick_count;
    bool     geom_end_marked;    // geom probe: ANIMATION-END marker already emitted to the log for this context
    // Display snapshot for the endpin seat seam-guard: macOS clamps any AX
    // resize that would vacate a display the window currently occupies (it
    // keeps a ~54px vertical / ~80px horizontal sliver), so the seat move must
    // never drag the start-size frame onto a display the end rect doesn't
    // touch. Snapped per begin (hotplug-safe); empty = guard disabled.
    CGRect   disp[ANIM_SEAT_MAX_DISP];
    int      disp_count;
    struct anim_metrics metrics;
    struct anim_window win[ANIM_AX_MAX];
};

static struct anim_ctx g_anim_ctx[ANIM_MAX_CTX];
static pthread_mutex_t   g_anim_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t          g_lb_ax_dispatch_id;

// ---- Per-frame follower registry (AC-6) ----
// A follower rides the engine's per-VBL transaction: the per-frame loop calls every
// registered fn for every animated wid (the fn self-filters by wid), so features
// (focus ring, icon cards, …) track the interpolated rect in the SAME commit/VBL
// instead of snapping post-animation. The engine names no feature. CONSTRAINTS — a
// follower runs on the pump thread UNDER g_anim_lock, so it may only touch the
// passed tx (client-mirror SLSTransaction* ops): NO blocking SLS round-trips (AC-4 —
// e.g. SLSGetScreenRectForWindow under the lock stalls other displays' pumps) and NO
// call back into lb_follower_register (the mutex is non-recursive → self-deadlock).
typedef void (*lb_follower_fn)(CFTypeRef tx, uint32_t wid, CGRect rect);
#define LB_FOLLOWER_MAX 8
static lb_follower_fn g_lb_followers[LB_FOLLOWER_MAX];
static int            g_lb_follower_count;

// Register a follower (idempotent by fn pointer). Each consumer calls this once from
// its own init, OFF the pump thread; it takes g_anim_lock so it serializes against
// the per-frame iteration. No unregister: the lifetime consumers self-filter when
// torn down, so removal has no caller (YAGNI).
static void lb_follower_register(lb_follower_fn fn)
{
    if (!fn) return;
    bool dup = false, full = false;
    int  count;
    pthread_mutex_lock(&g_anim_lock);
    for (int i = 0; i < g_lb_follower_count; ++i)
        if (g_lb_followers[i] == fn) { dup = true; break; }
    if (!dup) {
        if (g_lb_follower_count >= LB_FOLLOWER_MAX) full = true;
        else g_lb_followers[g_lb_follower_count++] = fn;
    }
    count = g_lb_follower_count;
    pthread_mutex_unlock(&g_anim_lock);

    if (dup)  return;
    if (full) logpf("ANIM", "follower_register DROPPED fn=%p — registry full (%d)", (void *)fn, LB_FOLLOWER_MAX);
    else      logpf("ANIM", "follower_register fn=%p count=%d", (void *)fn, count);
}

// ---- Per-wid generation guard for the async animating-property clear (AC-5) ----
// The property clear (lb_set_animating_prop(wid,false)) is dispatched OFF the pump
// because SLS writes can block. Between the dispatch and its execution a NEW begin
// for the same wid can land, free+reuse the old slot (so the supersede pass never
// marks the stale row — it only scans ACTIVE contexts), and set the property TRUE
// again — then the in-flight stale clear would flip it false MID-animation, opening
// the daemon flush-gate → the double-animation tail jank the cooldown exists to prevent.
// Guard: begin bumps the wid's generation and stamps it into its context row; the
// async clear only writes when its captured generation still owns the wid.
// Generations are monotonic per wid and never reset (avoids ABA). All access is
// under g_anim_lock (begin holds it; the async clear takes it for the read) — the
// helpers assume the caller holds it. Complements `superseded` (active-context
// overlap); this covers the freed-slot overlap supersede can't see.
struct lb_wid_gen { uint32_t wid; uint64_t gen; };
static struct lb_wid_gen g_lb_wid_gen[ANIM_MAX_CTX * ANIM_AX_MAX];

// Pick a slot to evict when the table is full: prefer a wid no active context still
// animates (its begin is long done, so re-keying the slot can't drop a live guard).
// Falls back to slot 0 — only reachable with >1024 distinct wids tracked at once,
// which the realistic concurrent-animation count (<< table size) never approaches.
static int lb_wid_gen_reclaim_slot(void)
{
    int n = (int)(sizeof(g_lb_wid_gen) / sizeof(g_lb_wid_gen[0]));
    for (int i = 0; i < n; ++i) {
        uint32_t wid = g_lb_wid_gen[i].wid;
        bool active = false;
        for (int k = 0; k < ANIM_MAX_CTX && !active; ++k) {
            if (!__atomic_load_n(&g_anim_ctx[k].active, __ATOMIC_ACQUIRE)) continue;
            for (int j = 0; j < g_anim_ctx[k].count; ++j)
                if (g_anim_ctx[k].win[j].wid == wid) { active = true; break; }
        }
        if (!active) return i;
    }
    return 0;
}

// begin path (caller holds g_anim_lock): bump (or create) the wid's generation.
static uint64_t lb_wid_gen_bump(uint32_t wid)
{
    int n = (int)(sizeof(g_lb_wid_gen) / sizeof(g_lb_wid_gen[0]));
    int free_i = -1;
    for (int i = 0; i < n; ++i) {
        if (g_lb_wid_gen[i].gen != 0 && g_lb_wid_gen[i].wid == wid) return ++g_lb_wid_gen[i].gen;
        if (free_i < 0 && g_lb_wid_gen[i].gen == 0) free_i = i;
    }
    if (free_i < 0) free_i = lb_wid_gen_reclaim_slot();
    g_lb_wid_gen[free_i].wid = wid;
    g_lb_wid_gen[free_i].gen = 1;
    return 1;
}

// clear path (caller holds g_anim_lock): does `gen` still own wid (no newer
// begin)? A missing entry means the slot was reclaimed for an idle wid — treat as
// current so the idle clear still lands the property false (the safe end state when
// nothing is animating; the non-reclaim path always finds its entry).
static bool lb_wid_gen_is_current(uint32_t wid, uint64_t gen)
{
    int n = (int)(sizeof(g_lb_wid_gen) / sizeof(g_lb_wid_gen[0]));
    for (int i = 0; i < n; ++i)
        if (g_lb_wid_gen[i].gen != 0 && g_lb_wid_gen[i].wid == wid) return g_lb_wid_gen[i].gen == gen;
    return true;
}

static inline float lb_lerp(float a, float t, float b) { return a + (b - a) * t; }

// THE constraint clamp. Every size that reaches an SLS/AX write or the settle
// probe goes through these — the per-frame visual lerp, the AX fire rect, the
// skip-to-end terminal commit, and the settle-probe end compare. One definition
// so a retune can't update three sites and silently miss the fourth: if the
// probe ever clamps differently from the writes, the probed frame never matches
// the committed one and settle stalls to the SETTLE_MAX hard-stop.
static inline float lb_clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float lb_clamp_w(const struct anim_window *w, float v) { return lb_clamp(v, w->min_w, w->max_w); }
static inline float lb_clamp_h(const struct anim_window *w, float v) { return lb_clamp(v, w->min_h, w->max_h); }

// Persist a LEARNED single-axis size constraint on the window's server-side
// property bag (written from Dock's cid; the daemon reads it back from
// g_connection — the bag is shared / cross-connection). Blob, space-separated:
//   "<type> <minw> <minh> <maxw> <maxh> <aspect> <confirm>"
// C3a writes only type 1 (single-axis): the free axis carries the daemon's no-op
// sentinels (min 0 / max 1e9). aspect (type 2, 2-run-confirmed) is a later pass.
// resolve_anim_constraints (window_manager.c) is the reader.
static void lb_cls_persist(uint32_t wid, float minw, float minh, float maxw, float maxh)
{
    extern CGError SLSSetWindowProperty(int cid, uint32_t wid, CFStringRef property, CFTypeRef value);
    char buf[96];
    snprintf(buf, sizeof(buf), "1 %.0f %.0f %.0f %.0f 0 1", minw, minh, maxw, maxh);
    CFStringRef val = CFStringCreateWithCString(NULL, buf, kCFStringEncodingUTF8);
    if (val) {
        SLSSetWindowProperty(SLSMainConnectionID(), wid,
                             CFSTR("com.koekeishiya.yabai.constraint_class.v1"), val);
        CFRelease(val);
    }
}

static inline float lb_load_f(volatile float *p)  { float v; __atomic_load(p, &v, __ATOMIC_ACQUIRE); return v; }
static inline void  lb_store_f(volatile float *p, float v) { __atomic_store(p, &v, __ATOMIC_RELEASE); }

// is_animating signal for the daemon (Branch B). Mark/unmark a window animating
// in its shared property bag: Dock's universal-owner cid writes foreign wids,
// the daemon reads it back (prop_scope: writes ownership-gated, reads open).
// Set true at begin (before the first AX fire) / false at settle. This is the
// ground truth the daemon's window_manager_is_animating reads to suppress the
// BSP feedback-flush that would otherwise restart the animation each VBL.
extern CGError SLSSetWindowProperty(int cid, uint32_t wid, CFStringRef property, CFTypeRef value);
static void lb_set_animating_prop(uint32_t wid, bool on) {
    SLSSetWindowProperty(SLSMainConnectionID(), wid,
                         CFSTR("com.koekeishiya.yabai.animating"),
                         on ? (CFTypeRef)kCFBooleanTrue : (CFTypeRef)kCFBooleanFalse);
}

// Per-pid EUI-off refcount across ALL active contexts. Two contexts animating
// windows of the same app must not let the first to finalize flip EUI back on
// while the second is still firing AX (its remaining resizes would reflow).
// EUI goes off on the 0->1 transition and back on only when the last context
// for that pid releases. Mutated only under g_anim_lock (hold at begin,
// release from the pump via anim_step).
// prior / prior_known: the app's EUI value captured at the FIRST hold (count
// 0→1), so release restores it instead of a hardcoded true. Captured once per
// refcount lifetime — nested holds (count++ below) never re-read, so the real
// baseline survives overlapping animations on one pid.
struct lb_eui_hold { int32_t pid; int count; bool prior; bool prior_known; };
static struct lb_eui_hold g_lb_eui[ANIM_MAX_CTX * 4];

static void lb_eui_hold_pid(int32_t pid)
{
    int n = (int)(sizeof(g_lb_eui) / sizeof(g_lb_eui[0]));
    for (int i = 0; i < n; ++i)
        if (g_lb_eui[i].count > 0 && g_lb_eui[i].pid == pid) { g_lb_eui[i].count++; return; }
    for (int i = 0; i < n; ++i)
        if (g_lb_eui[i].count == 0) {
            g_lb_eui[i].pid = pid; g_lb_eui[i].count = 1;
            // Capture the CURRENT EUI before forcing it off, so release restores
            // exactly this (not a hardcoded true). Chrome's baseline is false;
            // forcing true on restore left it permanently AppKit-animating and
            // desynced the daemon's ax_eui_cached.
            bool prior = false;
            g_lb_eui[i].prior_known = payload_ax_get_eui(pid, &prior);
            g_lb_eui[i].prior       = prior;
            payload_ax_set_eui(pid, false);
            return;
        }
}

// Called from the pump (under g_anim_lock). The refcount decrement is cheap
// and stays on the pump; the EUI restore AX call is synchronous (can block) so
// it is dispatched OFF the pump. The async block re-checks the count under the
// lock so a same-pid animation that started in the dispatch gap keeps EUI off.
static void lb_eui_release_pid(int32_t pid)
{
    int n = (int)(sizeof(g_lb_eui) / sizeof(g_lb_eui[0]));
    for (int i = 0; i < n; ++i)
        if (g_lb_eui[i].count > 0 && g_lb_eui[i].pid == pid) {
            if (--g_lb_eui[i].count == 0) {
                bool prior       = g_lb_eui[i].prior;
                bool prior_known = g_lb_eui[i].prior_known;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                    bool still_zero = true;
                    pthread_mutex_lock(&g_anim_lock);
                    for (int k = 0; k < n; ++k)
                        if (g_lb_eui[k].count > 0 && g_lb_eui[k].pid == pid) { still_zero = false; break; }
                    pthread_mutex_unlock(&g_anim_lock);
                    // Restore the captured prior — NOT a hardcoded true. If the
                    // app never exposed EUI (prior_known=false), leave it alone.
                    if (still_zero && prior_known) payload_ax_set_eui(pid, prior);
                });
            }
            return;
        }
}

// Hold / release every unique pid in a context.
static void anim_hold_eui(struct anim_ctx *c)
{
    for (int i = 0; i < c->count; ++i) {
        bool seen = false;
        for (int j = 0; j < i; ++j) if (c->win[j].pid == c->win[i].pid) { seen = true; break; }
        if (!seen) lb_eui_hold_pid(c->win[i].pid);
    }
}

static void anim_release_eui(struct anim_ctx *c)
{
    if (c->eui_released) return;     // idempotent
    c->eui_released = true;
    for (int i = 0; i < c->count; ++i) {
        bool seen = false;
        for (int j = 0; j < i; ++j) if (c->win[j].pid == c->win[i].pid) { seen = true; break; }
        if (!seen) lb_eui_release_pid(c->win[i].pid);
    }
}

// Wake each unique pid's lazy AX tree at begin (SA_T3D_FLAG_AX_WAKE, daemon
// config window_animation_ax_wake, default on). Sets AXManualAccessibility so a
// Chromium/Electron app builds its tree — else AXWindows is empty and the
// animator's AX setFrame no-ops. No refcount/restore (unlike EUI): enabling
// a11y is sticky and harmless to leave on, and there's nothing to undo. Same
// dedup-by-pid + synchronous-at-begin shape as anim_hold_eui, so the tree has
// the whole animation to finish building before the terminal fire. Caller gates
// on use_ax (no AX → nothing to wake) AND the flag.
static void anim_wake_ax(struct anim_ctx *c)
{
    for (int i = 0; i < c->count; ++i) {
        bool seen = false;
        for (int j = 0; j < i; ++j) if (c->win[j].pid == c->win[i].pid) { seen = true; break; }
        if (!seen) payload_ax_enable_manual_a11y(c->win[i].pid);
    }
}

// Force every in-flight RESIZE/MOVE context to its terminal state RIGHT NOW.
// Called at the top of a space switch (space_cross_fade_animator_start) so no
// window is left mid-animation when the slide takes over the same wids (AC-8:
// xfade-vs-LB+T3D cross-animator stomp, the "floating window").
//
// What actually floats: the cross-fade REPLACES each window's Transform3D with
// its slide matrix, so a residual T3D is harmless. The hazards are (1) the
// LockedBounds pin — still pinning the window at its interpolated mid-resize
// size, which survives after the cross-fade clears the (replaced) transform at
// settle → window stuck at the wrong size; and (2) the un-committed end AX frame
// — the real resize never finished. So we finish the resize (commit the end AX
// frame), then clear LB + T3D and drop the slot.
//
// LEAVE_TERMINAL contexts (stage thumbnails) are left running untouched: they
// intentionally persist their last transform and aren't the resize-vs-slide
// hazard — force-ending one would freeze a stages animation mid-flight.
//
// AC-4: snapshot + deactivate under g_anim_lock; do the AX round-trips and the
// SLS commit OUTSIDE it. AC-5: the animating-property clear is gen-guarded, the
// same idiom as the natural settle/cooldown path.
//
// Also reachable as SA_OPCODE_ANIM_SKIP_ALL (daemon-initiated cancel before
// instant/MC space transitions — same SA handler thread, same inline contract).
// Returns the number of window rows forced to terminal (0 = nothing in flight;
// rows past the SKIP cap are dropped, not counted — they settle via own pump).
#define ANIM_SKIP_MAX 128   // bounded bridge buffer (realistic concurrent-resize count is 1-4)
static int anim_skip_all_to_end(void)
{
    struct skip_item { uint32_t wid; int32_t pid; CGRect end; uint64_t gen;
                       uint64_t own_geo, own_alpha;
                       bool do_t3, do_lb, use_ax, seam; };
    struct skip_item items[ANIM_SKIP_MAX];
    int n = 0, dropped = 0;

    pthread_mutex_lock(&g_anim_lock);
    for (int k = 0; k < ANIM_MAX_CTX; ++k) {
        struct anim_ctx *c = &g_anim_ctx[k];
        if (!__atomic_load_n(&c->active, __ATOMIC_ACQUIRE)) continue;
        if (c->finalize_mode == SA_FINALIZE_LEAVE_TERMINAL) continue;   // leave stages running
        bool do_t3 = (c->flags & SA_T3D_FLAG_T3) != 0;
        bool do_lb = (c->flags & SA_T3D_FLAG_LB) != 0;
        for (int i = 0; i < c->count; ++i) {
            struct anim_window *w = &c->win[i];
            if (__atomic_load_n(&w->superseded, __ATOMIC_ACQUIRE)) continue;
            // AC-15: a wid some later claim already owns is not ours to force
            // to terminal — its new owner is responsible. (At the xfade-seed
            // call site this can't fire — the seed claims AFTER this courtesy —
            // it guards other/future callers.) Stale token => release no-ops,
            // so dropping the row here leaks nothing.
            if (!anim_owns(w->wid, ANIM_CH_GEO, w->own_geo)) continue;
            if (n >= ANIM_SKIP_MAX) { dropped++; continue; }
            float ew = lb_clamp_w(w, w->ew);
            float eh = lb_clamp_h(w, w->eh);
            // Seat at the centered end (mirror the per-frame AX commit): a
            // sub-slot window lands centered in its slack, an over-slot window
            // anchors left/top. Without this, an interrupted/space-switched
            // animation snaps the surface to the slot's top-left.
            float esx = w->ew - ew, esy = w->eh - eh;
            float ex_c = w->ex + (esx > 0.0f ? esx * 0.5f : 0.0f);
            float ey_c = w->ey + (esy > 0.0f ? esy * 0.5f : 0.0f);
            items[n].wid       = w->wid;
            items[n].pid       = w->pid;
            items[n].end       = CGRectMake(ex_c, ey_c, ew, eh);
            items[n].gen       = w->gen;
            items[n].own_geo   = w->own_geo;
            items[n].own_alpha = w->own_alpha;
            items[n].do_t3     = do_t3 && w->mode != SA_T3D_ROW_MODE_LB_ONLY;
            items[n].do_lb     = do_lb && w->mode != SA_T3D_ROW_MODE_T3D_ONLY;
            items[n].use_ax    = c->use_ax;
            items[n].seam      = w->seam_hold;
            n++;
        }
        if (c->use_ax) anim_release_eui(c);   // pump-context EUI restore (lock-safe: blocking AX call dispatches off-lock)
        __atomic_store_n(&c->active, false, __ATOMIC_RELEASE);
    }
    pthread_mutex_unlock(&g_anim_lock);
    if (n == 0) return 0;

    int cid = SLSMainConnectionID();
    double ident[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
    CFTypeRef tx = SLSTransactionCreate(cid);
    for (int i = 0; i < n; ++i) {
        if (items[i].use_ax) payload_ax_set_frame(items[i].pid, items[i].wid, items[i].end);   // finish the real resize
        if (tx) {
            // Seam-held rows: their real frame sat at the park the whole
            // flight, and the set_frame above lands app-side a frame+ AFTER
            // the masks drop below — the window would pop at the park for
            // that gap (the space-switch pop). Land the origin server-side
            // in this SAME commit (the finalize-clear recipe); the app's own
            // AX move then arrives idempotent.
            if (items[i].seam) SLSTransactionMoveWindowWithGroup(tx, items[i].wid, items[i].end.origin);
            if (items[i].do_t3) SLSTransactionSetWindowTransform3D(tx, items[i].wid, ident);
            if (items[i].do_lb) SLSTransactionClearWindowLockedBounds(tx, items[i].wid);
            // Jello: unconditional warp clear at every terminal site — cheaper
            // than tracking warp rows across supersede handoffs, and a leaked
            // mesh is the worst possible artifact (it overpowers everything).
            SLSTransactionSetWindowWarp(tx, items[i].wid, 0, 0, NULL);
        }
    }
    if (tx) { SLSTransactionCommit(tx, 0); CFRelease(tx); }

    for (int i = 0; i < n; ++i) {
        uint32_t wid = items[i].wid; uint64_t gen = items[i].gen;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            pthread_mutex_lock(&g_anim_lock);
            bool current = lb_wid_gen_is_current(wid, gen);
            pthread_mutex_unlock(&g_anim_lock);
            if (current) lb_set_animating_prop(wid, false);
        });
        // AC-15: cede ownership inline (SA handler thread). At the xfade-seed
        // call site the seed claims these wids right after, so releasing here
        // hands them over with accurate owner tags. Rows past the SKIP cap keep
        // their claim until the next takeover bumps it — accepted with the
        // existing dropped-rows compromise.
        anim_release(items[i].wid, ANIM_CH_GEO, items[i].own_geo);
        if (items[i].own_alpha) anim_release(items[i].wid, ANIM_CH_ALPHA, items[i].own_alpha);
    }

    if (dropped) logpf("ANIM", "skip_all_to_end: forced %d to terminal, DROPPED %d (>%d cap) — they settle via own pump",
                       n, dropped, ANIM_SKIP_MAX);
    else         logpf("ANIM", "skip_all_to_end forced %d window(s) to terminal (space switch)", n);
    return n;
}

// SA_OPCODE_ANIM_SKIP_ALL — daemon-initiated "cancel all window animations".
// Forces every in-flight RESIZE/MOVE context to terminal (the same AC-8
// primitive the xfade seed calls) and replies with the forced-row count
// (uint32). Fired by the daemon before space transitions that never reach the
// slide seed (instant switches, in-MC navigation), so no window is left
// holding a LockedBounds pin + an uncommitted end AX frame. A live cross-fade
// slide is logged but deliberately NOT touched: xfade_handoff_no_commit is
// retarget-only (it needs a follow-up seed to re-establish the current space)
// and the slide self-settles at t>=1 on its own pump. Runs inline on the SA
// handler thread; the daemon's send blocks until this returns, so the caller
// observes a fully committed terminal state.
static void do_anim_skip_all(int sockfd, char *message)
{
    (void)message;
    uint32_t forced = (uint32_t)anim_skip_all_to_end();
    if (atomic_load(&g_xfade.active))
        logpf("ANIM", "skip_all opcode: slide live (left to self-settle) forced=%u", forced);
    send(sockfd, &forced, sizeof(forced), 0);
}

// Step ONE context into the caller's SHARED per-VBL transaction `tx` (committed
// once by anim_step across every context on the display — atomic
// same-frame commit, no per-context commit storm). Drives throttled AX.
static bool anim_ctx_step_one(struct anim_ctx *c, CFTypeRef tx)
{
    // Cooldown phase: LB/T3D were already dropped at settle (window at
    // rest, unpinned, draggable) but the context stays ACTIVE so the daemon's
    // window_manager_is_animating keeps returning true. That holds the BSP
    // feedback-flush gate closed for a few extra ticks while the trailing
    // MOVED/RESIZED events from the terminal AX setFrames drain through the
    // daemon event loop — otherwise one lands with is_animating already false,
    // diverges from node->area, and trips window_node_flush → a second (jank)
    // animation at the tail. Commit NOTHING here (don't re-pin LB); just count
    // down, then clear the animating property and free the slot. Set in the
    // landed block below.
    if (c->lb_cleared) {
        double cd_now = (double)mach_absolute_time() * dl_mach_to_s();
        if (cd_now - c->cooldown_start_s < ANIM_COOLDOWN_S) return false;
        for (int i = 0; i < c->count; ++i) {
            if (c->win[i].superseded) continue;   // the new owner clears it
            uint32_t wid = c->win[i].wid;
            uint64_t gen = c->win[i].gen;         // AC-5: stale-clear guard
            uint64_t own_geo = c->win[i].own_geo, own_alpha = c->win[i].own_alpha;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                // Skip if a newer begin took this wid (and re-set the property
                // true) after this clear was dispatched but before it ran.
                pthread_mutex_lock(&g_anim_lock);
                bool current = lb_wid_gen_is_current(wid, gen);
                pthread_mutex_unlock(&g_anim_lock);
                if (current) lb_set_animating_prop(wid, false);
                // AC-15: cede ownership off-pump (release never runs on the
                // pump hot path); stale (taken-over) tokens no-op.
                anim_release(wid, ANIM_CH_GEO, own_geo);
                if (own_alpha) anim_release(wid, ANIM_CH_ALPHA, own_alpha);
            });
        }
        return true;
    }

    anim_metrics_tick(&c->metrics);
    double now = (double)mach_absolute_time() * dl_mach_to_s();
    double t = c->duration > 0.0 ? (now - c->start_s) / c->duration : 1.0;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    float mt = apply_easing((float)t, (int)c->easing);

    bool do_lb    = (c->flags & SA_T3D_FLAG_LB)      != 0;
    bool do_t3    = (c->flags & SA_T3D_FLAG_T3)      != 0;
    bool t3_full  = (c->flags & SA_T3D_FLAG_T3_FULL) != 0;
    bool lb_full  = (c->flags & SA_T3D_FLAG_LB_FULL) != 0;
    bool do_alpha = (c->flags & SA_T3D_FLAG_ALPHA)   != 0;
    bool use_ax   = c->use_ax;

    c->tick_count++;

    for (int i = 0; i < c->count; ++i) {
        struct anim_window *w = &c->win[i];
        if (__atomic_load_n(&w->superseded, __ATOMIC_ACQUIRE)) continue;   // a newer context owns this wid
        // AC-15: cross-animator gate — a later GEO claim (xfade seed, another
        // animator) owns this wid now; skip the whole row (AX fire, LB/T3D,
        // followers). GEO is T3D+LB+AX as one non-substitutable channel. An
        // ALPHA-only claim elsewhere does NOT keep our alpha drive alive on a
        // GEO-lost row — accepted simplification (the taker claims both in
        // practice). Intra-anim supersede still uses `superseded` until
        // AC-16 folds it in.
        if (!anim_owns(w->wid, ANIM_CH_GEO, w->own_geo)) continue;
        float lerp_x = lb_lerp(w->sx, mt, w->ex);
        float lerp_y = lb_lerp(w->sy, mt, w->ey);
        float lerp_w = lb_lerp(w->sw, mt, w->ew);
        float lerp_h = lb_lerp(w->sh, mt, w->eh);
        float clamped_w = lb_clamp_w(w, lerp_w);
        float clamped_h = lb_clamp_h(w, lerp_h);
        // Conformance clamp: never let the asked size lead the app's REAL
        // frame (WindowBounds, sampled UNLOCKED in the pre-pass → wb_w/wb_h) by more
        // than MAX_DEV. Bounds the frame-vs-content stretch to MAX_DEV for ANY reason
        // the window won't follow the ask — aspect / min / max / fixed-axis — with no
        // per-constraint logic and no cache to go stale. The slack-centering just below
        // re-anchors the (now smaller) rect in its slot for free. wb==0 (first tick or
        // a GEOM_LOG probe run) → no-op, the raw ask passes through.
        {
            float wbw = lb_load_f(&w->wb_w), wbh = lb_load_f(&w->wb_h);
            // DEV ramps DOWN over the animation via the INVERSE of the motion easing:
            // apply_easing(1-t) holds ~MAX early (full headroom while the app's WB lags —
            // its catch-up extends PAST the ASK motion) then tapers to 0 at t=1 so the
            // held visual converges to WB → no finalize snap. (1-t into the SAME easing
            // IS the time-mirror — ease_out becomes an ease_in-shaped descent — no
            // separate ease_in fn. Matched (1-easing) would instead collapse DEV exactly
            // when an ease_out window's lag is biggest → clip free windows.)
            float dev = ANIM_CONFORM_MAX_DEV * apply_easing(1.0f - (float)t, (int)c->easing);
            if (wbw > 0.0f) clamped_w = lb_clamp(clamped_w, wbw - dev, wbw + dev);
            if (wbh > 0.0f) clamped_h = lb_clamp(clamped_h, wbh - dev, wbh + dev);
        }

        // Center the constraint-limited window into its slot's *available* slack.
        // lerp_w/h is the node rect the BSP assigned; clamped_w/h is what the
        // window's min/max actually allow. When the window is smaller than its
        // slot, distribute the leftover space so it sits centered. When a
        // min-constraint makes it LARGER than the slot, slack is negative → clamp
        // to 0 so the overflow anchors at the slot's left/top edge instead of
        // straddling both. Per-axis, so a window that's too narrow but too tall
        // centers in X and anchors at the top. cx/cy is the centered VISUAL
        // origin; lerp_x/y stays the raw slot origin for the slack math.
        float slack_x = lerp_w - clamped_w;
        float slack_y = lerp_h - clamped_h;
        float cx = lerp_x + (slack_x > 0.0f ? slack_x * 0.5f : 0.0f);
        float cy = lerp_y + (slack_y > 0.0f ? slack_y * 0.5f : 0.0f);
        // Stash the committed visual rect for takeover handoff (see vis_* in
        // struct anim_window). Under g_anim_lock — begin serializes with us.
        w->vis_x = cx; w->vis_y = cy; w->vis_w = clamped_w; w->vis_h = clamped_h;
        w->vis_set = true;

        // Anchor = last committed AX (use_ax) or the natural surface rect
        // (visual-only). For visual-only T3D the app's surface stays at its natural
        // frame the whole animation; the matrix must scale/translate FROM there to
        // the visual lerp rect. Anchoring on start_* only works when start==natural
        // (stages OUT); stages IN starts at the thumb rect, so anchoring on start
        // collapses the t=0 matrix to identity and the window never grows from the
        // thumbnail (it sits at natural). nx/ny/nw/nh carry the real surface rect.
        float ax, ay, aw, ah;
        if (use_ax) { ax = lb_load_f(&w->ax_x); ay = lb_load_f(&w->ax_y); aw = lb_load_f(&w->ax_w); ah = lb_load_f(&w->ax_h); }
        else        { ax = w->nx; ay = w->ny; aw = w->nw; ah = w->nh; }
        // Seam-held rows anchor the translate on the LIVE server origin
        // instead: the asked anchor leads the real frame by the app's commit
        // lag, and with a large terminal move that gap composites the surface
        // at its raw start position for a frame or two (the end-of-animation
        // flash). Live-WB anchoring keeps the visual pinned on the lerp rect
        // through the catch-up, and identity lands exactly when the server
        // frame does. Origin only — sizes converge progressively, so the
        // asked sizes are already within a few px of WB here. Also makes the
        // Trigger-3 landed-compare WB-driven (re-fires until the server sees
        // the end rect), the same recipe as the WIP tree's instant-snap rows.
        if (use_ax && w->seam_hold && lb_load_f(&w->wb_w) > 0.0f) {
            ax = lb_load_f(&w->wb_x); ay = lb_load_f(&w->wb_y);
        }

        // -------- AX fire decision (use_ax only) — endpin recipe --------
        // Endpin (the production default): the app's real origin is pinned at
        // end_xy for the whole animation, so it only ever does an origin-fixed
        // resize (no internal-move reflow — the left/top-edge grow jank). LB_FULL
        // + T3D carry the visual position. Three triggers mirror window_manager.c.
        if (use_ax) {
            // Jello AX choreography (warp rows): genie-style — ONE pure move
            // (Trigger 1, endpin forced below) then ONE full end-size resize
            // (the warp arm below), no progressive Trigger-2 fires. Each mid
            // resize is an app repaint + a mesh-source desync window, and
            // SLSGetWindowBounds reads the wrong clock to close it (frame
            // geometry, not the app's content commit) — so the backing goes
            // static at end size early and the mesh carries the whole glide.
            bool warp_ax   = (c->flags & SA_T3D_FLAG_WARP) && !c->pile
                          && w->mode != SA_T3D_ROW_MODE_LB_ONLY
                          && (fabsf(w->sw - w->ew) > 0.5f || fabsf(w->sh - w->eh) > 0.5f);
            bool endpin    = ((c->flags & SA_T3D_FLAG_ENDPIN) != 0) || warp_ax;   // warp rows: move-first is mandatory
            bool endpin_ro = (c->flags & SA_T3D_FLAG_ENDPIN_RESIZE_ONLY) != 0;
            bool pure_move = (w->sw == w->ew) && (w->sh == w->eh);
            bool fire = false, terminal = false, resize_only = false, move_only = false, park_fire = false;
            // Centered AX end-origin — same available-slack rule as the visual
            // (cx/cy above), but against the *end* slot so the real surface
            // settles centered. Without this the AX commit pins the surface to
            // the slot top-left and it snaps there the instant LB/T3D clear at
            // finalize, undoing the centered visual.
            float end_cw = lb_clamp_w(w, w->ew);
            float end_ch = lb_clamp_h(w, w->eh);
            float end_sx = w->ew - end_cw;
            float end_sy = w->eh - end_ch;
            float end_cx = w->ex + (end_sx > 0.0f ? end_sx * 0.5f : 0.0f);
            float end_cy = w->ey + (end_sy > 0.0f ? end_sy * 0.5f : 0.0f);
            float fx = endpin ? end_cx : cx;   // endpin: AX origin pinned at centered end
            float fy = endpin ? end_cy : cy;
            float fw = clamped_w, fh = clamped_h;

            // Seat seam-guard: the seat move plants the frame at end_xy at
            // START size — that rect must not occupy a display the end rect
            // doesn't touch. AppKit's edge-resize logic refuses shrinks around
            // a seam shared with another display: a straddling window can't
            // shrink off the neighbor (clamped at a ~54px vertical / ~80px
            // horizontal sliver), and even a CLEAR window can't land its edge
            // near the seam (a 17px shrink 3px clear of the neighbor is
            // refused) — so a premature seat both wedges mid-flight shrinks
            // AND strands the final padding gap. Flagged rows never seat:
            // Trigger 2 shrinks in place at the start origin (far from the
            // seam every ask lands) and Trigger 3's terminal setFrame — size
            // at the start origin FIRST, then the move — lands the end rect,
            // the same recipe the daemon's non-animated sandwich uses. The
            // test uses START size (constant) so the verdict can't flip
            // mid-flight. Void overhang stays legal (occupancy, not
            // containment).
            if (!w->seam_eval && endpin && !pure_move) {
                w->seam_eval = true;
                CGRect sg_seat = CGRectMake(end_cx, end_cy, w->sw, w->sh);
                CGRect sg_end  = CGRectMake(end_cx, end_cy, end_cw, end_ch);
                for (int sg = 0; sg < c->disp_count; ++sg) {
                    if (CGRectIntersectsRect(sg_seat, c->disp[sg]) &&
                        !CGRectIntersectsRect(sg_end, c->disp[sg])) { w->seam_hold = true; break; }
                }
                // Straddling-START rescue: when the REAL frame itself occupies
                // the foreign display, even the in-place shrinks are refused
                // (the ~54/80px sliver clamp) — holding at the start origin
                // wedges the whole resize. Arm ONE pure move (never refused)
                // to the real-frame rect clamped inside the end display; the
                // hold recipe then runs from that park. Real frame = the
                // anchor (== start for fresh rows; a takeover row inherits the
                // donor's committed frame, not its stale daemon-captured one).
                if (w->seam_hold) {
                    CGRect sg_real = CGRectMake(ax, ay, aw, ah);
                    for (int sg = 0; sg < c->disp_count; ++sg) {
                        if (!CGRectIntersectsRect(sg_real, c->disp[sg]) ||
                            CGRectIntersectsRect(sg_end, c->disp[sg])) continue;
                        int end_di = -1; float best_ov = 0.0f;   // park display = biggest end-rect overlap
                        for (int sd = 0; sd < c->disp_count; ++sd) {
                            CGRect ov = CGRectIntersection(sg_end, c->disp[sd]);
                            float ova = (float)(ov.size.width * ov.size.height);
                            if (ova > best_ov) { best_ov = ova; end_di = sd; }
                        }
                        if (end_di >= 0) {
                            float dx = (float)c->disp[end_di].origin.x, dw = (float)c->disp[end_di].size.width;
                            float dy = (float)c->disp[end_di].origin.y, dh = (float)c->disp[end_di].size.height;
                            w->park_x = (dw < aw) ? dx : lb_clamp(ax, dx, dx + dw - aw);
                            w->park_y = (dh < ah) ? dy : lb_clamp(ay, dy, dy + dh - ah);
                            w->seam_park = true;
                        }
                        break;
                    }
                }
            }
            bool seat_safe = !w->seam_hold;

            if (!w->ax_initial && (pure_move || endpin) && seat_safe) {
                // Trigger 1 (t=0): endpin → pure MOVE to end_xy at the last
                // COMMITTED size (defer the resize → no re-raster flicker; a
                // seam-deferred seat continues from the in-place shrinks, so
                // start size would re-grow the frame). Non-endpin pure moves
                // commit the full end_rect.
                fire = terminal = true;
                fx = end_cx; fy = end_cy;
                if (endpin && !pure_move) { fw = aw;  fh = ah;
                                            if (warp_ax) move_only = true; }   // jello: PURE kAXPosition move (no redundant AXSize touch)
                else                      { fw = w->ew;  fh = w->eh; }
            } else if (w->seam_park) {
                // Straddling-start park (armed at the latch above): ONE pure
                // kAXPosition move to the in-display park — this branch owns
                // the fire slot until it dispatches, so no resize can execute
                // at the still-straddling origin. Sizes stay the committed
                // anchor's; the T3D anchor rides the live WB origin, so the
                // visual never leaves the lerp rect while the frame relocates.
                fire = true; move_only = true; park_fire = true;
                fx = w->park_x; fy = w->park_y; fw = aw; fh = ah;
            } else if (t >= 1.0f && (w->seam_hold ? (aw != w->ew || ah != w->eh)
                                                  : (ax != end_cx || ay != end_cy || aw != w->ew || ah != w->eh))) {
                // Trigger 3 (t>=1): full end_rect terminal safety fire (also the
                // settle-phase driver — round-robin throttled for same-PID).
                // Seam-held rows fire SIZE only: their position lands
                // SERVER-SIDE in the finalize-clear transaction (same commit
                // that drops LB/T3D) — an AX move's app-side apply can't be
                // made atomic with the clear, and composites one raw frame at
                // the start origin (the end-of-animation flash).
                fire = terminal = true;
                if (w->seam_hold) { fx = ax; fy = ay; fw = w->ew; fh = w->eh; resize_only = true; }
                else              { fx = end_cx; fy = end_cy; fw = w->ew; fh = w->eh; }
            } else if (warp_ax && t < 1.0f) {
                // Jello single end-resize: Trigger 1 seated the origin (pure
                // move); commit the FULL end size once, immediately — kAXSize
                // only at the seated origin (move first, then resize). The
                // anchor stores the asked rect at completion, so this arm
                // self-extinguishes after one fire; Trigger 3 stays the
                // terminal safety net. Swallows Trigger 2 for warp rows.
                if (aw != end_cw || ah != end_ch) {
                    fire = true; resize_only = true;
                    // Seam-deferred seat: the origin is still the start rect —
                    // the anchor must record the REAL origin (kAXSize doesn't
                    // move) or Trigger 1/3's landed-compares go stale; and the
                    // in-place fire caps each axis at start size (a pre-seat
                    // GROW could overhang a neighbor display — the capped axis
                    // catches up right here once the seat lands).
                    if (w->ax_initial) { fx = end_cx; fy = end_cy; fw = end_cw; fh = end_ch; }
                    else               { fx = ax;     fy = ay;
                                         fw = fminf(end_cw, w->sw); fh = fminf(end_ch, w->sh); }
                }
            } else if (t < 1.0f && c->ax_th_mode != WM_AX_TH_NONE_ && c->ax_th_val > 0.0f) {
                // Trigger 2 (mid): PX threshold on resize delta from anchor.
                float dmax = fmaxf(fabsf(lerp_w - aw), fabsf(lerp_h - ah));
                if (dmax >= c->ax_th_val) {
                    fire = true;
                    if (endpin && !w->ax_initial) {
                        // Seam-deferred seat (above): shrink in place at the
                        // committed origin. kAXSize only — and the anchor must
                        // record the REAL origin or Trigger 3's landed-compare
                        // reads "already at end" and skips the terminal move.
                        // Cap each axis at start size: an in-place GROW (mixed
                        // resize) could overhang a neighbor display from the
                        // start origin — the growing axis catches up post-seat.
                        fx = ax; fy = ay;
                        resize_only = true;
                        fw = fminf(clamped_w, w->sw); fh = fminf(clamped_h, w->sh);
                    } else {
                        fx = endpin ? end_cx : cx;
                        fy = endpin ? end_cy : cy;
                        resize_only = endpin && endpin_ro;   // kAXSize-only fast path (origin held)
                        fw = clamped_w; fh = clamped_h;
                    }
                }
            }

            // Clamp the AX fire size to the wire SLS constraints — the same clamp
            // the LB/T3D visual uses. Trigger 1/3 set raw end (w->ew/eh); without
            // this the terminal commit drives the real surface sub-min/over-max
            // and it snaps past the constraint the instant LB/T3D clear at
            // finalize. No-op for unconstrained rows (min 0 / max 1e9).
            fw = lb_clamp_w(w, fw);
            fh = lb_clamp_h(w, fh);

            if (fire && !__atomic_load_n(&w->ax_in_flight, __ATOMIC_ACQUIRE)) {
                int group = 1, rank = 0;             // same-PID round-robin
                for (int j = 0; j < c->count; ++j) {
                    if (j == i || c->win[j].pid != w->pid) continue;
                    group++; if (j < i) rank++;
                }
                if (group <= 1 || (c->tick_count % (uint64_t)group) == (uint64_t)rank) {
                    __atomic_store_n(&w->ax_in_flight, true, __ATOMIC_RELEASE);
                    uint64_t did = __atomic_add_fetch(&g_lb_ax_dispatch_id, 1, __ATOMIC_RELAXED);
                    __atomic_store_n(&w->ax_dispatch_id, did, __ATOMIC_RELEASE);
                    if (terminal) w->ax_initial = true;
                    if (park_fire) w->seam_park = false;   // one-shot: the park move is on its way
                    int32_t pid = w->pid; uint32_t wid = w->wid;
                    CGRect rr = CGRectMake(fx, fy, fw, fh);
                    bool ro = resize_only;
                    bool mo = move_only;
                    struct anim_window *wp = w;
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                        if (mo)      payload_ax_set_position(pid, wid, rr.origin.x, rr.origin.y);
                        else if (ro) payload_ax_set_size(pid, wid, rr.size.width, rr.size.height);
                        else         payload_ax_set_frame(pid, wid, rr);
                        if (__atomic_load_n(&wp->ax_dispatch_id, __ATOMIC_ACQUIRE) == did) {   // not superseded
                            // Anchor = the rect committed (origin seated at end for resize-only).
                            lb_store_f(&wp->ax_x, rr.origin.x);   lb_store_f(&wp->ax_y, rr.origin.y);
                            lb_store_f(&wp->ax_w, rr.size.width);  lb_store_f(&wp->ax_h, rr.size.height);
                            __atomic_store_n(&wp->ax_in_flight, false, __ATOMIC_RELEASE);
                        }
                    });
                }
            }
        }

        // -------- LB + T3D / warp commit (anchor-relative) --------
        // Jello policy (SA_T3D_FLAG_WARP): a size-animating row carries its
        // per-frame presentation as a chrome-pinned 9-slice mesh instead of
        // LB+T3D — the uniform T3D stretch smears the traffic lights, and
        // LockedBounds does not play well with a live mesh, so warp rows
        // skip BOTH. Mesh source = anchor dims
        // (re-bases on every AX landing — the warp cover's source-tracking
        // for free), target = the eased visual rect (global). At t=1 the
        // mesh converges to identity, so the terminal clear is a visual
        // no-op by construction. Pure-move rows (and pile rows) keep the
        // true_resize recipe: the shadow follows T3D but NOT the warp, and
        // a detached shadow on a full-window glide would show.
        bool warp_row = (c->flags & SA_T3D_FLAG_WARP) && !c->pile
                     && w->mode != SA_T3D_ROW_MODE_LB_ONLY
                     && (fabsf(w->sw - w->ew) > 0.5f || fabsf(w->sh - w->eh) > 0.5f);
        if (warp_row) {
            float mesh[4 * 4 * 4];
            warp_mesh_9slice((double)aw, (double)ah,
                             CGRectMake(cx, cy, clamped_w, clamped_h),
                             WARP_SNAP_BAND_L, WARP_SNAP_BAND_R,
                             WARP_SNAP_BAND_T, WARP_SNAP_BAND_B, mesh);
            SLSTransactionSetWindowWarp(tx, w->wid, 4, 4, mesh);
        }
        if (!warp_row && do_t3 && w->mode != SA_T3D_ROW_MODE_LB_ONLY) {
            if (c->pile) {
                // Pile pose-tween (SA_T3D_FLAG_PILE): rebuild the posed CATransform3D
                // per frame from the RAW (unclamped) lerp rect natural→thumb, ramping
                // the pose by the shrink progress, perspective held constant (the
                // native-SM signature). pose strength is direction-agnostic — 1 at the
                // thumb (small) end, 0 at the natural (full) end — so stages IN (which
                // lerps thumb→natural) tweens the pose back to identity for free. At
                // p=1 this lands byte-equal to the settled pile (no snap).
                double pnw = (double)w->nw, pnh = (double)w->nh;
                double fit_now = (pnw > 0.0 && pnh > 0.0)
                               ? fmin((double)lerp_w / pnw, (double)lerp_h / pnh) : 1.0;
                double f_s = (pnw > 0.0 && pnh > 0.0)
                           ? fmin((double)w->sw / pnw, (double)w->sh / pnh) : 1.0;
                double f_e = (pnw > 0.0 && pnh > 0.0)
                           ? fmin((double)w->ew / pnw, (double)w->eh / pnh) : 1.0;
                // Pose strength is measured against NATURAL (fit==1.0), NOT the
                // animation's own endpoints. For IN/OUT one endpoint IS natural so
                // fmax(f_s,f_e) was already 1.0 here => no change; but a SAME-SIZE
                // slide (the strip repack, thumb->thumb) makes fmax==thumb and
                // den==0 => pp collapses to 0 (flat — the STG-30 flicker). Pinning
                // f_full=1.0 holds full pose through a slide; cards (natural==slot)
                // still get den==0 => pp=0 => flat fit. (STG-33)
                double f_full = 1.0, f_thumb = fmin(f_s, f_e);
                double den = f_full - f_thumb;
                double pp_raw = den > 1e-6 ? (f_full - fit_now) / den : 0.0;
                // Pose-ramp easing (config stage_animation_easing): re-shape the
                // pose strength so the yaw/perspective LAGS the shrink — native SM
                // holds the card flat and swings it into the posed flag only near
                // the end. pp_raw is the SIZE fraction (0 at natural, 1 at thumb),
                // so an ease_in curve == the "distance-based" late pose. Maps 0->0
                // and 1->1, so the settled pose at the thumb end is unchanged (no
                // end-snap); direction-agnostic (stages IN un-poses for free).
                double pp = (double)apply_easing((float)pp_raw, (int)c->pile_pose_easing);
                double m[16];
                pile_build_tween((double)lerp_x, (double)lerp_y, (double)lerp_w, (double)lerp_h,
                                 (double)w->nx, (double)w->ny, pnw, pnh,
                                 (int)w->depth, &c->pile_xf, pp, m);
                SLSTransactionSetWindowTransform3D(tx, w->wid, m);
            } else {
                double xs = 1.0, ys = 1.0;
                if (t3_full && clamped_w > 0.0f && clamped_h > 0.0f) {
                    xs = (double)aw / (double)clamped_w;
                    ys = (double)ah / (double)clamped_h;
                }
                double dx = (double)cx - (double)ax;
                double dy = (double)cy - (double)ay;
                double m[16] = { xs, 0, 0, 0,  0, ys, 0, 0,  0, 0, 1, 0,  -xs * dx, -ys * dy, 0, 1 };
                SLSTransactionSetWindowTransform3D(tx, w->wid, m);
            }
        }
        if (!warp_row && do_lb && w->mode != SA_T3D_ROW_MODE_T3D_ONLY) {
            float lb_x = lb_full ? cx : ax;
            float lb_y = lb_full ? cy : ay;
            SLSTransactionSetWindowLockedBounds(tx, w->wid, CGRectMake(lb_x, lb_y, clamped_w, clamped_h));
        }
        if (do_alpha && anim_owns(w->wid, ANIM_CH_ALPHA, w->own_alpha)) {
            float opacity = 1.0f - ((1.0f - w->min_opacity) * (1.0f - fabsf(mt - 0.5f) * 2.0f));
            SLSTransactionSetWindowAlpha(tx, w->wid, opacity);
        }

        // Per-frame followers (AC-6): each rides this window's interpolated VISUAL
        // rect (lerp pos + clamped size, what LB_FULL+T3D paint) on THIS transaction,
        // so it tracks the motion in the same commit/VBL. Each self-filters by wid.
        // Iteration is safe here — we hold g_anim_lock (see anim_step).
        CGRect follow_rect = CGRectMake(cx, cy, clamped_w, clamped_h);
        for (int f = 0; f < g_lb_follower_count; ++f)
            g_lb_followers[f](tx, w->wid, follow_rect);

        // Stash the asked VISUAL rect (= follow_rect; equals the LB rect under
        // LB_FULL) + progress for the unlocked pre-pass samplers (the geom probe,
        // Pass 1.5) to compare against what the app reports next tick. Plain
        // stores under the lock — no round-trip (AC-4 safe).
        lb_store_f(&w->glb_x, cx);        lb_store_f(&w->glb_y, cy);
        lb_store_f(&w->glb_w, clamped_w); lb_store_f(&w->glb_h, clamped_h);
        lb_store_f(&w->gt, t);
    }
    // (no commit here — the caller commits the shared per-VBL tx once.)

    if (t >= 1.0) {
        // Non-blocking settle. Latch once: report metrics. The per-window
        // Trigger 3 above already drives the terminal end_rect AX (round-robin
        // throttled), so finalize only PROBES the real on-screen frame and clears
        // LB/T3D once it has landed — nothing here blocks the pump.
        //
        // EUI is deliberately NOT restored here: it must stay OFF until the
        // surface actually lands, otherwise the EUI-on restore races ahead of the
        // still-settling terminal AX setFrames and AppKit animates the final
        // resize (end-of-animation motion). Restored in the Landed block below.
        if (!c->finalizing) {
            c->finalizing      = true;
            c->settle_start_s  = now;   // `now` = mach→s captured at the top of this tick
            if (!c->reported) { anim_metrics_report(&c->metrics, "anim", c->use_ax ? "CA+AX" : "CA"); c->reported = true; }
        }

        // Geom probe: hold the context active for ≥GEOM_SETTLE_HOLD_S past t=1 so
        // the Pass-1.5 sampler captures post-animation settle frames even when the
        // surface lands instantly. Probe-only (gated on GEOM_LOG); the per-frame
        // LB/T3D commit above keeps holding the window at end during the wait, and
        // EUI stays off — it never touches production timing.
        if ((c->flags & SA_T3D_FLAG_GEOM_LOG) && (now - c->settle_start_s) < GEOM_SETTLE_HOLD_S)
            return false;

        // Settle verdict: did every live (non-superseded) window's REAL frame land
        // at end? Probed via SLSGetScreenRectForWindow in anim_step's
        // UNLOCKED pre-pass (AC-4) — those synchronous SLS round-trips must NOT run
        // under g_anim_lock or they stall every other display's pump at the mutex.
        // Here we just read the verdict (no round-trip). Visual-only contexts never
        // probe → treated as settled immediately.
        bool settled = c->use_ax ? __atomic_load_n(&c->settle_ok, __ATOMIC_ACQUIRE) : true;

        // Keep ticking until the surface lands (or the hard-stop bounds it). The
        // per-window LB/T3D commit above runs at mt==1 (lerp==end) every settle
        // tick, so the visual holds at end while AX catches up.
        if (!settled && (now - c->settle_start_s) < ANIM_SETTLE_MAX_S) return false;

        // Landed (or hard-stop): the terminal AX surface has arrived, so restore
        // EUI now (idempotent). Doing it here — not at the finalizing latch above
        // — guarantees every terminal setFrame committed with EUI still OFF, so
        // AppKit never animates the final resize.
        if (c->use_ax) anim_release_eui(c);

        // Finalize policy (mirrors Branch A). CLEAR (default — production resize,
        // stages IN): drop the transform AND the LockedBounds pin (else drag-locked)
        // for the windows this context still owns, so the AX-committed end_rect
        // becomes the steady visual. LEAVE_TERMINAL (stages OUT): leave the
        // last-frame LB/T3D applied — the per-frame loop above committed the
        // terminal (thumb) transform this same tick — so the window persists at
        // its terminal transform until a follow-up animation/clear. The identity/
        // clear writes are the LATER writes for these wids in the SHARED tx, so
        // they win at commit; redundant-safe (the window is already at end via AX).
        if (c->finalize_mode != SA_FINALIZE_LEAVE_TERMINAL) {
            double ident[16] = { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1 };
            for (int i = 0; i < c->count; ++i) {
                if (c->win[i].superseded) continue;   // the new owner clears it
                if (!anim_owns(c->win[i].wid, ANIM_CH_GEO, c->win[i].own_geo)) continue;   // AC-15: ditto, cross-animator
                // Seam-held rows: land the origin SERVER-SIDE in this same
                // transaction — the masks drop in the exact commit that
                // materializes the window at end, so no frame ever composites
                // the raw window at its start origin (the AX-move recipe's
                // 1-frame flash). Sizes were AX-committed in place; the app
                // adopts the new origin via kCGSWindowDidMove. Centered origin
                // mirrors the step's available-slack rule.
                if (c->win[i].seam_hold) {
                    float mw = lb_clamp_w(&c->win[i], c->win[i].ew);
                    float mh = lb_clamp_h(&c->win[i], c->win[i].eh);
                    float gw = lb_load_f(&c->win[i].wb_w);
                    float gh = lb_load_f(&c->win[i].wb_h);
                    // Stomp gate: land the origin only when OUR terminal size
                    // actually arrived (live WB ≈ clamped end — trivially true
                    // on the settled path, whose verdict IS this compare). On
                    // the SETTLE_MAX hard-stop the window may sit wherever a
                    // FOREIGN op re-placed it mid-settle; moving it to this
                    // animation's end origin would stomp that placement.
                    if (gw > 0.0f && fabsf(gw - mw) <= ANIM_SETTLE_PX
                                  && fabsf(gh - mh) <= ANIM_SETTLE_PX) {
                        CGPoint mo = CGPointMake(
                            c->win[i].ex + (c->win[i].ew > mw ? (c->win[i].ew - mw) * 0.5f : 0.0f),
                            c->win[i].ey + (c->win[i].eh > mh ? (c->win[i].eh - mh) * 0.5f : 0.0f));
                        SLSTransactionMoveWindowWithGroup(tx, c->win[i].wid, mo);
                    }
                }
                if (do_t3) SLSTransactionSetWindowTransform3D(tx, c->win[i].wid, ident);
                if (do_lb) SLSTransactionClearWindowLockedBounds(tx, c->win[i].wid);
                // Jello: unconditional warp clear (identity at settle → visual no-op)
                SLSTransactionSetWindowWarp(tx, c->win[i].wid, 0, 0, NULL);
            }
        }
        // The animating property is deliberately NOT cleared here. LB/T3D
        // are down (window at rest and draggable), but the daemon flush-gate must
        // stay closed for a short cooldown so the terminal AX setFrames' trailing
        // MOVED/RESIZED events drain while still suppressed — otherwise one trips
        // window_node_flush → a second animation at the tail. Enter the cooldown:
        // keep the context active (is_animating stays true via the property) and
        // let the top-of-function cooldown block count down, then clear the
        // property + free the slot. Visual-only contexts have no property/flush
        // concern → done immediately.
        if (c->use_ax) {
            c->lb_cleared       = true;
            c->cooldown_start_s = now;   // `now` = mach→s captured at the top of this tick
            return false;   // stay active for the flush-gate cooldown (clears the property after cooldown)
        }
        // Visual-only: no AX → no trailing MOVED/RESIZED events → no flush-gate
        // cooldown, so we deactivate this tick. If the daemon is waiting on a
        // completion signal (notify_done — it wired a finalize_callback), clear
        // the animating property now so its pending-finalize poll observes the
        // batch as done and fires the callback (which frees its user_data).
        // AC-15: every non-superseded row also cedes its ownership tokens here
        // (off-pump, stale-safe) — including LEAVE_TERMINAL contexts, whose
        // persisted matrix is AC-17's business, not the registry owner's.
        bool notify = c->notify_done;
        for (int i = 0; i < c->count; ++i) {
            if (c->win[i].superseded) continue;   // the new owner owns the property now
            uint32_t wid = c->win[i].wid;
            uint64_t gen = c->win[i].gen;         // AC-5: stale-clear guard
            uint64_t own_geo = c->win[i].own_geo, own_alpha = c->win[i].own_alpha;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                if (notify) {
                    pthread_mutex_lock(&g_anim_lock);
                    bool current = lb_wid_gen_is_current(wid, gen);
                    pthread_mutex_unlock(&g_anim_lock);
                    if (current) lb_set_animating_prop(wid, false);
                }
                anim_release(wid, ANIM_CH_GEO, own_geo);
                if (own_alpha) anim_release(wid, ANIM_CH_ALPHA, own_alpha);
            });
        }
        return true;
    }
    return false;
}

// ====================== Geom probe (SA_T3D_FLAG_GEOM_LOG) ======================
// Per frame, UNLOCKED (AC-4): for each geom-logging context on this display,
// sample every window-geometry getter for each window and append a column-
// aligned row to GEOM_LOG_PATH, beside the rect step_one ASKED for last tick.
// The daemon ships WIDE constraints for this batch (window_manager.c), so the
// animator drives PAST the window's real min/max — the gap between the asked
// size and what GetWindowBounds / Onscreen / ScreenRect / FrameBounds / Shape /
// Constraints report IS the app/server push-back. With SA_T3D_FLAG_GEOM_AX a
// payload AX read (payload_ax_get_frame) is added + timed, to (a) disambiguate
// stale AX (Chromium/Electron trees go stale) from a real clamp and (b) test
// whether a per-frame AX read contends with the AX setFrame the animator fires.
//
// Every getter is a synchronous SLS/AX round-trip → this MUST stay outside
// g_anim_lock. Safe: the context is owned by THIS display's pump for the whole
// walk (begin only reuses inactive slots; no other pump touches a did≠this row),
// and `superseded` only ever flips true (a harmless skip). The per-tick fopen is
// itself overhead, but it lands on the pump thread (NOT the AX-setFrame queue)
// and is constant across frames, so it perturbs cadence uniformly.
#define GEOM_LOG_PATH "/tmp/yabai_anim_probe.log"

// One labeled rect row: "  <label>      x      y      w      h [ DEV_W DEV_H ]".
// Getters are stacked vertically (one per line) so a frame is a short block.
// !ok → dashes (read failed). When with_dev is set (every per-frame getter row
// EXCEPT ASK), two extra columns report this SPI's w/h MINUS the ASK w/h — i.e.
// the per-axis push-back: + means the SPI reports bigger than asked (clamp held
// it above a shrink target), − means smaller. ASK itself and the targets-block
// rows pass with_dev=false (no reference to deviate from).
static void geom_row(FILE *f, const char *label, bool ok, CGRect r, bool with_dev, double ask_w, double ask_h)
{
    if (ok) fprintf(f, "  %-15s %8.1f %8.1f %8.1f %8.1f", label,
                    (double)r.origin.x, (double)r.origin.y,
                    (double)r.size.width, (double)r.size.height);
    else    fprintf(f, "  %-15s %8s %8s %8s %8s", label, "-", "-", "-", "-");
    if (with_dev) {
        if (ok) fprintf(f, " %+8.1f %+8.1f", (double)r.size.width - ask_w, (double)r.size.height - ask_h);
        else    fprintf(f, " %8s %8s", "-", "-");
    }
    fprintf(f, "\n");
}

// APPEND a run banner + legend. Called from do_anim_ax_begin when a geom batch
// begins. Runs accumulate in the file (no truncate) so successive probes can be
// compared; the banner separates them.
static void geom_log_begin(bool with_ax)
{
    FILE *f = fopen(GEOM_LOG_PATH, "a");
    if (!f) return;
    fprintf(f, "\n\n############################## NEW anim_probe RUN ##############################\n");
    fprintf(f, "# one block per frame; getters stacked as rows (narrow, terminal-friendly).\n");
    fprintf(f, "# Each row is 'label  x  y  w  h  DEV_W DEV_H'. ASK = what step_one drove this window to (the LB/AX target).\n");
    fprintf(f, "# DEV_W/DEV_H (every row but ASK) = that SPI's w/h MINUS ASK's — the per-axis push-back (+ = bigger than asked).\n");
    fprintf(f, "# The daemon ships WIDE constraints so the animator asks PAST the real min/max — the gap between\n");
    fprintf(f, "# ASK and WindowBounds/ShapeBBox/AX (the app's REAL size) is the constraint push-back. ScreenRect\n");
    fprintf(f, "# and Onscreen reflect the LB/T3D-composited rect (can exceed the clamp; snaps back at finalize).\n");
    fprintf(f, "# CONSTR is min/max/cur sizes (w h). Rows after the ANIMATION-END marker are settle frames. AX row%s.\n",
            with_ax ? " adds (read_us ok) — the payload-side AX read + its latency" : " absent (ax:0)");
    fclose(f);
}

// Append a START + TARGET block for each window BEFORE the first t=0.0 frame, so
// the log opens with where the animator was asked to drive FROM and TO. START is
// the captured surface rect (t=0); TARGET is the raw end rect; TARGET(clamp) is
// the clamped+centered end the per-frame commit settles to (== the t=1 ASK the
// getters below are compared against — in geom_wide runs the wire clamp is a
// no-op so it equals TARGET). Called from do_anim_ax_begin AFTER the windows
// are unpacked into the context but BEFORE the clock resumes, so it always
// precedes Pass-1.5 rows. Off the lock (file I/O only).
static void geom_log_targets(struct anim_ctx *c)
{
    FILE *f = fopen(GEOM_LOG_PATH, "a");
    if (!f) return;
    int cid = SLSMainConnectionID();
    fprintf(f, "== targets (before t=0.0) — START = where the surface is, TARGET = end rect asked ==\n");
    for (int k = 0; k < c->count; ++k) {
        struct anim_window *w = &c->win[k];
        if (!w->wid) continue;

        // App name from pid (libproc, no AppKit) + title (cross-process server read).
        char app[256] = {0};
        if (w->pid <= 0 || proc_name((int)w->pid, app, sizeof(app)) <= 0) snprintf(app, sizeof(app), "?");
        char title[256] = "?";
        CFTypeRef tv = NULL;
        if (SLSCopyWindowProperty(cid, w->wid, CFSTR("kCGSWindowTitle"), &tv) == kCGErrorSuccess && tv) {
            if (CFGetTypeID(tv) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)tv, title, sizeof(title), kCFStringEncodingUTF8);
            CFRelease(tv);
        }

        // Real constraints (min/max/cur) — same iterator path as the per-frame
        // sampler; lazy-populated (zero until the window's first mouse-grab).
        CGSize cmin = {0}, cmax = {0}, ccur = {0}, cp4 = {0}; bool cn_ok = false;
        CFArrayRef arr = cfarray_of_cfnumbers(&w->wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        CFTypeRef query = arr ? SLSWindowQueryWindows(cid, arr, 0x0) : NULL;
        CFTypeRef iter  = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
        if (iter && SLSWindowIteratorAdvance(iter)) {
            SLSWindowIteratorGetConstraints(iter, &cmin, &cmax, &ccur, &cp4);
            cn_ok = true;
        }
        if (iter)  CFRelease(iter);
        if (query) CFRelease(query);
        if (arr)   CFRelease(arr);

        // Mirror the per-frame commit's clamp+center so TARGET(clamp) is exactly
        // the t=1 ASK (clamped end, sub-slot centered in its slack).
        float ew  = lb_clamp_w(w, w->ew);
        float eh  = lb_clamp_h(w, w->eh);
        float esx = w->ew - ew, esy = w->eh - eh;
        float ex  = w->ex + (esx > 0.0f ? esx * 0.5f : 0.0f);
        float ey  = w->ey + (esy > 0.0f ? esy * 0.5f : 0.0f);
        fprintf(f, "-- wid=%u pid=%d  app=\"%s\"  title=\"%s\" %s\n", w->wid, (int)w->pid, app, title,
                "--------------------");
        if (cn_ok)
            fprintf(f, "  %-15s min %.0fx%.0f  max %.0fx%.0f  cur %.0fx%.0f\n", "CONSTR",
                    (double)cmin.width, (double)cmin.height,
                    (double)cmax.width, (double)cmax.height,
                    (double)ccur.width, (double)ccur.height);
        else
            fprintf(f, "  %-15s (unread — needs a prior manual grab)\n", "CONSTR");
        fprintf(f, "  %-15s %8s %8s %8s %8s\n", "(label)", "x", "y", "w", "h");
        geom_row(f, "START",         true, CGRectMake(w->sx, w->sy, w->sw, w->sh), false, 0, 0);
        geom_row(f, "TARGET",        true, CGRectMake(w->ex, w->ey, w->ew, w->eh), false, 0, 0);
        geom_row(f, "TARGET(clamp)", true, CGRectMake(ex,    ey,    ew,    eh),    false, 0, 0);
    }
    fclose(f);
}

static void geom_log_sample(uint32_t did, int cid)
{
    // Anything to log on this display this tick?
    bool any = false;
    for (int i = 0; i < ANIM_MAX_CTX && !any; ++i) {
        struct anim_ctx *c = &g_anim_ctx[i];
        if (!__atomic_load_n(&c->active, __ATOMIC_ACQUIRE)) continue;
        if (c->did != did) continue;
        if (c->flags & SA_T3D_FLAG_GEOM_LOG) any = true;
    }
    if (!any) return;

    FILE *f = fopen(GEOM_LOG_PATH, "a");
    if (!f) return;
    double now = (double)mach_absolute_time() * dl_mach_to_s();

    for (int i = 0; i < ANIM_MAX_CTX; ++i) {
        struct anim_ctx *c = &g_anim_ctx[i];
        if (!__atomic_load_n(&c->active, __ATOMIC_ACQUIRE)) continue;
        if (c->did != did) continue;
        if (!(c->flags & SA_T3D_FLAG_GEOM_LOG)) continue;
        bool   with_ax = (c->flags & SA_T3D_FLAG_GEOM_AX) != 0;
        double ts_ms   = (now - c->start_s) * 1000.0;

        // ANIMATION-END marker: the first sampled tick after t=1 reached (the
        // finalizing latch). Everything below it is a settle frame. Emitted once
        // per context (geom_end_marked); the sampler owns this did's contexts on
        // the pump thread, so the off-lock read/set of finalizing/geom_end_marked
        // is race-free.
        if (c->finalizing && !c->geom_end_marked) {
            fprintf(f, "========================= ANIMATION END (t=1.0, ts=%.1fms) — settle frames below =========================\n", ts_ms);
            c->geom_end_marked = true;
        }

        for (int k = 0; k < c->count; ++k) {
            struct anim_window *w = &c->win[k];
            if (__atomic_load_n(&w->superseded, __ATOMIC_ACQUIRE)) continue;
            uint32_t wid = w->wid;

            // ASK — stashed by step_one on the previous tick (aligns with the
            // commit the getters below now observe).
            CGRect ask = CGRectMake(lb_load_f(&w->glb_x), lb_load_f(&w->glb_y),
                                    lb_load_f(&w->glb_w), lb_load_f(&w->glb_h));
            float t = lb_load_f(&w->gt);

            // Direct SLS getters.
            CGRect wb = CGRectZero, ob = CGRectZero, sr = CGRectZero;
            bool wb_ok = SLSGetWindowBounds(cid, wid, &wb)         == kCGErrorSuccess;
            bool ob_ok = SLSGetOnscreenWindowBounds(cid, wid, &ob) == kCGErrorSuccess;
            bool sr_ok = SLSGetScreenRectForWindow(cid, wid, &sr)  == kCGErrorSuccess;

            // Iterator getters — frame-bounds + constraints (cur/min/max). Built
            // per-wid; geometry/constraints decode regardless of the title flag.
            CGRect fb = CGRectZero; bool fb_ok = false;
            CGSize cmin = {0}, cmax = {0}, ccur = {0}, cp4 = {0}; bool cn_ok = false;
            CFArrayRef arr = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
            CFTypeRef query = arr ? SLSWindowQueryWindows(cid, arr, 0x0) : NULL;
            CFTypeRef iter  = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
            if (iter && SLSWindowIteratorAdvance(iter)) {
                fb = SLSWindowIteratorGetFrameBounds(iter); fb_ok = true;
                // 4th out-param (cp4) confirmed to return 0x0 — not the resize
                // increment; discarded.
                SLSWindowIteratorGetConstraints(iter, &cmin, &cmax, &ccur, &cp4);
                cn_ok = true;   // values may be zero until the window's first mouse-grab (lazy-populate)
            }
            if (iter)  CFRelease(iter);
            if (query) CFRelease(query);
            if (arr)   CFRelease(arr);

            // Visible shape bbox.
            CGRect shape = CGRectZero; bool shape_ok = false;
            CFTypeRef region = NULL;
            if (SLSCopyWindowShape(cid, wid, &region) == kCGErrorSuccess && region) {
                if (!CGSRegionIsEmpty(region) && CGSGetRegionBounds(region, &shape) == kCGErrorSuccess)
                    shape_ok = true;
                CFRelease(region);
            }

            // Optional payload AX read — timed (the contention test).
            CGRect axr = CGRectZero; bool ax_ok = false; double ax_us = 0.0;
            if (with_ax) {
                double t0 = (double)mach_absolute_time() * dl_mach_to_s();
                ax_ok = payload_ax_get_frame(w->pid, wid, &axr);
                ax_us = ((double)mach_absolute_time() * dl_mach_to_s() - t0) * 1.0e6;
            }

            // Block header for this frame, then each getter on its own row.
            fprintf(f, "-- t=%.2f  ts=%.1fms  wid=%u %s\n",
                    (double)t, ts_ms, wid,
                    "----------------------------------------");
            double aw = (double)ask.size.width, ah = (double)ask.size.height;
            fprintf(f, "  %-15s %8s %8s %8s %8s %8s %8s\n", "(label)", "x", "y", "w", "h", "DEV_W", "DEV_H");
            geom_row(f, "ASK",            true,     ask,   false, 0,  0);
            geom_row(f, "WindowBounds",   wb_ok,    wb,    true,  aw, ah);
            // geom_row(f, "OnscreenBounds", ob_ok,    ob,    true,  aw, ah);
            geom_row(f, "ScreenRect",     sr_ok,    sr,    true,  aw, ah);
            // geom_row(f, "FrameBounds",    fb_ok,    fb,    true,  aw, ah);
            // geom_row(f, "ShapeBBox",      shape_ok, shape, true,  aw, ah);
            if (cn_ok)
                fprintf(f, "  %-15s min %.0fx%.0f  max %.0fx%.0f  cur %.0fx%.0f\n", "CONSTR",
                        (double)cmin.width, (double)cmin.height,
                        (double)cmax.width, (double)cmax.height,
                        (double)ccur.width, (double)ccur.height);
            else
                fprintf(f, "  %-15s (unread)\n", "CONSTR");
            if (with_ax) {
                if (ax_ok)
                    fprintf(f, "  %-15s %8.1f %8.1f %8.1f %8.1f %+8.1f %+8.1f   (%.0fus ok)\n", "AX read",
                            (double)axr.origin.x, (double)axr.origin.y,
                            (double)axr.size.width, (double)axr.size.height,
                            (double)axr.size.width - aw, (double)axr.size.height - ah, ax_us);
                else
                    fprintf(f, "  %-15s %8s %8s %8s %8s %8s %8s   (%.0fus FAIL)\n", "AX read",
                            "-", "-", "-", "-", "-", "-", ax_us);
            }
        }
    }
    fclose(f);
}

// Per-display pump client: walk the registry, step every active context ON THIS
// display. ctx carries the did (one client per display clock), so each panel's
// vblank only advances the animations that live on it. Returns true (this
// display's pump pauses) only when no context on it remains active.
static bool anim_step(void *ctx_did, CFTypeRef pump_tx, uint32_t pump_did)
{
    (void)pump_did;   // this client is per-display (ctx == its did); pump_did is the same value — ignore.
    uint32_t did = (uint32_t)(uintptr_t)ctx_did;
    int cid = SLSMainConnectionID();

    // -------- Pass 1 (UNLOCKED): settle probe (AC-4) --------
    // SLSGetScreenRectForWindow is a synchronous SLS round-trip, per window, per
    // settle tick. Run under g_anim_lock it would block every OTHER display's
    // pump thread at the mutex — the cross-display tick jitter the per-display CA
    // clock design exists to avoid. So probe here, outside the lock, against a
    // stable snapshot: this context stays active and owned by THIS pump for the
    // whole walk (begin only reuses inactive slots; another display's pump never
    // touches a did≠this row), and `superseded` only ever flips true → a harmless
    // skip. The verdict is stashed on the context; the locked pass below consumes
    // it with no round-trip. Cooldown rows and visual-only rows never probe.
    for (int i = 0; i < ANIM_MAX_CTX; ++i) {
        struct anim_ctx *c = &g_anim_ctx[i];
        if (!__atomic_load_n(&c->active, __ATOMIC_ACQUIRE)) continue;
        if (c->did != did) continue;
        if (c->lb_cleared || !c->use_ax) continue;   // cooldown / visual-only: nothing to probe
        double pnow = (double)mach_absolute_time() * dl_mach_to_s();
        double pt   = c->duration > 0.0 ? (pnow - c->start_s) / c->duration : 1.0;
        // ---- conformance-clamp WB sampling (production), AC-4 unlocked ----
        // Read each window's REAL frame (WindowBounds) and stash w/h so the locked
        // per-frame step can cap the asked size to within MAX_DEV of it. Bounds the
        // frame-vs-content stretch for ANY reason the window won't follow the ask
        // (aspect / min / max / fixed-axis) — no classification, no cache, self-
        // correcting. Runs every tick INCLUDING settle
        // so the verdict target below matches the held visual (else a constraint-bound
        // window never matches → 0.5s hard-stop). GEOM_LOG probe runs skip it → wb
        // stays 0 → conformance no-op → they keep measuring raw push-back.
        if (!(c->flags & SA_T3D_FLAG_GEOM_LOG)) {
            for (int k = 0; k < c->count; ++k) {
                struct anim_window *w = &c->win[k];
                if (__atomic_load_n(&w->superseded, __ATOMIC_ACQUIRE)) continue;
                if (!anim_owns(w->wid, ANIM_CH_GEO, w->own_geo)) continue;
                CGRect wb;
                if (SLSGetWindowBounds(cid, w->wid, &wb) == kCGErrorSuccess &&
                    wb.size.width > 0.0f && wb.size.height > 0.0f) {
                    lb_store_f(&w->wb_w, (float)wb.size.width);
                    lb_store_f(&w->wb_h, (float)wb.size.height);
                    lb_store_f(&w->wb_x, (float)wb.origin.x);
                    lb_store_f(&w->wb_y, (float)wb.origin.y);
                }
            }
        }
        if (pt < 1.0) continue;                       // not in settle phase yet

        bool settled = true;
        for (int k = 0; k < c->count; ++k) {
            if (__atomic_load_n(&c->win[k].superseded, __ATOMIC_ACQUIRE)) continue;
            // AC-15: a taken-over wid (stale GEO token) will never land at OUR
            // end rect — don't let it veto settle and stall finalize to the
            // SETTLE_MAX hard-stop. own_geo is stable after begin (written
            // before the active=true release-store).
            if (!anim_owns(c->win[k].wid, ANIM_CH_GEO, c->win[k].own_geo)) continue;
            CGRect sr = CGRectZero;
            if (SLSGetScreenRectForWindow(cid, c->win[k].wid, &sr) != kCGErrorSuccess) continue;
            // Compare against the CLAMPED, CENTERED end: the app holds at its
            // min/max (so probing the raw end — e.g. 200 when min is 500 — would
            // never match), and a sub-slot window is seated centered in its slack
            // (so probing the raw slot origin would never match either). Both
            // would stall finalize to the SETTLE_MAX hard-stop. Mirror the AX
            // commit's available-slack centering exactly.
            float ew_c = lb_clamp_w(&c->win[k], c->win[k].ew);
            float eh_c = lb_clamp_h(&c->win[k], c->win[k].eh);
            // Match the step's conformance clamp (incl. its inverse-easing DEV ramp)
            // so the settle target == the visual actually held. At settle pt≥1 the
            // ramp → 0, so the target == WB exactly (matches the held visual → the
            // finalize clear snaps nothing). Same wb_w/wb_h the step consumed.
            float sdev = ANIM_CONFORM_MAX_DEV * apply_easing(1.0f - fminf((float)pt, 1.0f), (int)c->easing);
            float cwbw = lb_load_f(&c->win[k].wb_w), cwbh = lb_load_f(&c->win[k].wb_h);
            // Seam-held rows skip the conformance fold: with sdev→0 at settle
            // it collapses the target to WB itself, and with their origin
            // exempt below the whole verdict would be vacuously true — they
            // need the REAL landed check (WB == clamped end) so finalize's
            // server-side move fires only once the terminal size arrived, and
            // classify never reads a mid-catch-up WB as the final size.
            if (!c->win[k].seam_hold) {
                if (cwbw > 0.0f) ew_c = lb_clamp(ew_c, cwbw - sdev, cwbw + sdev);
                if (cwbh > 0.0f) eh_c = lb_clamp(eh_c, cwbh - sdev, cwbh + sdev);
            }
            float esx  = c->win[k].ew - ew_c;
            float esy  = c->win[k].eh - eh_c;
            float ex_c = c->win[k].ex + (esx > 0.0f ? esx * 0.5f : 0.0f);
            float ey_c = c->win[k].ey + (esy > 0.0f ? esy * 0.5f : 0.0f);
            // Seam-held rows never AX-move — their origin lands server-side in
            // the finalize-clear transaction — so the verdict is SIZE-only
            // (waiting on the origin would stall every seam row to the
            // hard-stop and re-introduce the raw-frame flash it exists to fix).
            bool match = fabsf((float)sr.size.width  - ew_c) <= ANIM_SETTLE_PX &&
                         fabsf((float)sr.size.height - eh_c) <= ANIM_SETTLE_PX &&
                         (c->win[k].seam_hold ||
                          (fabsf((float)sr.origin.x - ex_c) <= ANIM_SETTLE_PX &&
                           fabsf((float)sr.origin.y - ey_c) <= ANIM_SETTLE_PX));
            if (!match) { settled = false; continue; }  // keep walking so every landed row can classify

            // ---- Classify-at-settle ----
            // This row's REAL frame has LANDED (screen rect == conformed/centered
            // end), so cwbw/cwbh (its WB sampled this tick) is its final size. Two
            // verdicts from the start/asked/landed rects we already hold:
            //   1. ASPECT (start-ratio rule): the landed ratio tracked the window's
            //      OWN start ratio instead of the asked slot ratio → an aspect lock,
            //      whichever axis the app honored (catches VLC, which honors width and
            //      so reads as only "one axis off"). Free windows adopt the asked ratio
            //      → excluded. Single-shot.
            //   2. SINGLE-AXIS min/max: exactly one axis short. Persist ONLY when the
            //      daemon shipped WIDE-OPEN (lazy-zero — the only case it reads back).
            struct anim_window *cw = &c->win[k];
            if (!cw->cls_done && cw->mode != SA_T3D_ROW_MODE_T3D_ONLY &&
                !(c->flags & SA_T3D_FLAG_GEOM_LOG) &&
                cwbw > 0.0f && cwbh > 0.0f && cw->ew > 0.0f && cw->eh > 0.0f) {
                cw->cls_done = true;
                bool w_off = fabsf(cw->ew - cwbw) > ANIM_CLS_LAND_PX;
                bool h_off = fabsf(cw->eh - cwbh) > ANIM_CLS_LAND_PX;

                // --- Single-axis min/max: a window pinned on exactly one axis
                //     (w_off != h_off) gets that axis's limit persisted (type-1 blob). ---
                if (w_off != h_off) {
                    float lmnw = 0.0f, lmnh = 0.0f, lmxw = 1.0e9f, lmxh = 1.0e9f;
                    if (w_off) { if (cw->ew > cwbw) lmxw = cwbw; else lmnw = cwbw; }   // width pinned
                    else       { if (cw->eh > cwbh) lmxh = cwbh; else lmnh = cwbh; }   // height pinned
                    bool shipped_wide = cw->min_w < 1.0f && cw->min_h < 1.0f &&
                                        cw->max_w > 1.0e8f && cw->max_h > 1.0e8f;
                    if (shipped_wide) {
                        lb_cls_persist(cw->wid, lmnw, lmnh, lmxw, lmxh);
                        logpf("ANIM", "cls: wid=%u single-axis ask=(%.0f,%.0f) wb=(%.0f,%.0f) learn min=(%.0f,%.0f) max=(%.0f,%.0f) [persisted]",
                              cw->wid, cw->ew, cw->eh, cwbw, cwbh, lmnw, lmnh, lmxw, lmxh);
                    } else {
                        logpf("ANIM", "cls: wid=%u single-axis ask=(%.0f,%.0f) wb=(%.0f,%.0f) [daemon-known]",
                              cw->wid, cw->ew, cw->eh, cwbw, cwbh);
                    }
                }
            }
        }
        __atomic_store_n(&c->settle_ok, settled, __ATOMIC_RELEASE);
    }

    // -------- Pass 1.5 (UNLOCKED): geom probe getter sampling (AC-4) --------
    // No-op unless a context on this display set SA_T3D_FLAG_GEOM_LOG. Runs EVERY
    // tick (not just settle) so it captures the resize crossing the constraint.
    geom_log_sample(did, cid);

    // -------- Pass 2 (LOCKED): buffer into the pump's SHARED per-VBL transaction --
    // AC-7: the pump now owns ONE transaction per VBL and commits it after the
    // client walk, so every context on this display still commits atomically in the
    // same frame (no per-context commit storm, no sub-frame skew) AND now shares the
    // frame with the clock's other clients (fade/mirror/xfade). Only buffered
    // transaction setters run under the lock; no SLS round-trips (AC-4). pump_tx is
    // NULL when the pump's create failed — skip this tick's setters, stay active so
    // the pump retries next VBL.
    bool any_active = false;
    pthread_mutex_lock(&g_anim_lock);
    for (int i = 0; i < ANIM_MAX_CTX; ++i) {
        struct anim_ctx *c = &g_anim_ctx[i];
        if (!__atomic_load_n(&c->active, __ATOMIC_ACQUIRE)) continue;
        if (c->did != did) continue;     // another display's clock owns this one
        if (pump_tx && anim_ctx_step_one(c, pump_tx)) __atomic_store_n(&c->active, false, __ATOMIC_RELEASE);
        else                                            any_active = true;
    }
    pthread_mutex_unlock(&g_anim_lock);

    // No commit here — the pump commits the shared tx outside clients_lock.
    return !any_active;
}

static void do_anim_ax_begin(char *message)
{
    // AC-9: header decoded from the SA_ANIM_HDR_FIELDS list (common_experimental.h)
    // — the first expansion declares the locals (count, flags, … finalize_mode), the
    // second unpacks them in the packer's exact order. Validate count after; reading
    // the fixed-size header first on the rare bad-count path is harmless.
#define X(t, dn, pn) t pn;
    SA_ANIM_HDR_FIELDS(X)
#undef X
#define X(t, dn, pn) unpack(pn);
    SA_ANIM_HDR_FIELDS(X)
#undef X
    if (count == 0 || count > ANIM_AX_MAX) return;

    // Pile pose block (SA_T3D_FLAG_PILE) — MUST mirror the packer order in
    // scripting_addition_anim_ax_begin. Read here, before the ctx branch, so the
    // wire cursor advances on EVERY path (main + ctx-FULL degrade). Float wire →
    // double pile_xform.
    bool pile = (flags & SA_T3D_FLAG_PILE) != 0;
    struct pile_xform pile_xf = {0};
    uint32_t pile_pose_easing = 0;   // linear fallback (enum animation_easing_type)
    if (pile) {
        // AC-9: declare + unpack the pile locals from SA_ANIM_PILE_FIELDS in the
        // packer's order, then widen them into the double-precision pile_xform
        // (off-wire assembly — the wire contract is the unpack order above).
#define X(t, dn, pn) t pn;
        SA_ANIM_PILE_FIELDS(X)
#undef X
#define X(t, dn, pn) unpack(pn);
        SA_ANIM_PILE_FIELDS(X)
#undef X
        pile_xf.perspective=persp; pile_xf.tx=ptx; pile_xf.ty=pty; pile_xf.tz=ptz;
        pile_xf.ry=pry; pile_xf.rx=prx; pile_xf.rz=prz;
        pile_xf.sc=psc; pile_xf.skx=pskx; pile_xf.sky=psky;
        pile_xf.origin_x=pox; pile_xf.origin_y=poy; pile_xf.overflow_z=povz;
        pile_xf.cx=pcx; pile_xf.cy=pcy;   // global-perspective principal (display centre)
        pile_xf.max_step=(int)pmstep;
        pile_pose_easing=peasing;
    }

    // Geom probe: append the run banner before taking the lock (file I/O off
    // the lock). The per-frame rows come from Pass 1.5.
    if (flags & SA_T3D_FLAG_GEOM_LOG) geom_log_begin((flags & SA_T3D_FLAG_GEOM_AX) != 0);

    pthread_mutex_lock(&g_anim_lock);
    struct anim_ctx *c = NULL;
    for (int i = 0; i < ANIM_MAX_CTX; ++i) {
        if (!g_anim_ctx[i].active) { c = &g_anim_ctx[i]; break; }
    }
    if (!c) {
        pthread_mutex_unlock(&g_anim_lock);
        // AC-10: all slots busy. The daemon has already gated on this animation,
        // so a silent drop leaves the layout diverged until gate expiry. Degrade:
        // land every row at its terminal state in one shot — the animation
        // skipped straight to t=1 — instead of freezing windows in place.
        logpf("ANIM", "ERROR: ctx table FULL (%d) — snap-committing %u rows to terminal (flags=0x%x finalize=%u)",
              ANIM_MAX_CTX, count, flags, finalize_mode);
        bool sk_use_ax  = (flags & SA_T3D_FLAG_AX)      != 0;
        bool sk_do_t3   = (flags & SA_T3D_FLAG_T3)      != 0;
        bool sk_do_lb   = (flags & SA_T3D_FLAG_LB)      != 0;
        bool sk_t3_full = (flags & SA_T3D_FLAG_T3_FULL) != 0;
        bool sk_lb_full = (flags & SA_T3D_FLAG_LB_FULL) != 0;
        bool sk_leave   = finalize_mode == SA_FINALIZE_LEAVE_TERMINAL;
        double ident[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
        CFTypeRef sk_tx = SLSTransactionCreate(SLSMainConnectionID());
        for (uint32_t i = 0; i < count; ++i) {
            struct anim_window w = {0};
            struct anim_window *wp = &w;
            // AC-9: same SA_ANIM_ROW_FIELDS list as the main path, so the two
            // unpack copies cannot drift.
#define X(t, dn, pn) unpack(wp->pn);
            SA_ANIM_ROW_FIELDS(X)
#undef X
            if (pile) { unpack(wp->depth); }  // advance cursor (degrade path snaps flat)
            if (!w.wid) continue;
            float ew = w.ew < w.min_w ? w.min_w : (w.ew > w.max_w ? w.max_w : w.ew);
            float eh = w.eh < w.min_h ? w.min_h : (w.eh > w.max_h ? w.max_h : w.eh);
            // Centered end (mirror the per-frame commit): sub-slot centers in
            // its slack, over-slot anchors left/top.
            float esx = w.ew - ew, esy = w.eh - eh;
            float ex_c = w.ex + (esx > 0.0f ? esx * 0.5f : 0.0f);
            float ey_c = w.ey + (esy > 0.0f ? esy * 0.5f : 0.0f);
            if (sk_use_ax) payload_ax_set_frame(w.pid, w.wid, CGRectMake(ex_c, ey_c, ew, eh));
            if (!sk_tx) continue;
            if (sk_leave && !sk_use_ax) {
                // Visual-only LEAVE_TERMINAL (stages): write the t=1 frame the
                // step would have left applied — anchored on the natural rect,
                // same matrix convention as the per-frame commit above.
                if (sk_do_t3 && w.mode != SA_T3D_ROW_MODE_LB_ONLY) {
                    double xs = 1.0, ys = 1.0;
                    if (sk_t3_full && ew > 0.0f && eh > 0.0f) {
                        xs = (double)w.nw / (double)ew;
                        ys = (double)w.nh / (double)eh;
                    }
                    double dx = (double)ex_c - (double)w.nx;
                    double dy = (double)ey_c - (double)w.ny;
                    double m[16] = { xs, 0, 0, 0,  0, ys, 0, 0,  0, 0, 1, 0,  -xs * dx, -ys * dy, 0, 1 };
                    SLSTransactionSetWindowTransform3D(sk_tx, w.wid, m);
                }
                if (sk_do_lb && w.mode != SA_T3D_ROW_MODE_T3D_ONLY) {
                    float lb_x = sk_lb_full ? ex_c : w.nx;
                    float lb_y = sk_lb_full ? ey_c : w.ny;
                    SLSTransactionSetWindowLockedBounds(sk_tx, w.wid, CGRectMake(lb_x, lb_y, ew, eh));
                }
            } else {
                // CLEAR (or AX-driven) terminal: identity + unlocked, the same
                // end state the settle/skip paths commit.
                SLSTransactionSetWindowTransform3D(sk_tx, w.wid, ident);
                SLSTransactionClearWindowLockedBounds(sk_tx, w.wid);
                SLSTransactionSetWindowWarp(sk_tx, w.wid, 0, 0, NULL);   // jello: unconditional warp clear
            }
        }
        if (sk_tx) { SLSTransactionCommit(sk_tx, 0); CFRelease(sk_tx); }
        return;
    }

    memset(c, 0, sizeof(*c));
    c->count         = (int)count;
    c->flags         = flags;
    c->easing        = easing;
    c->duration      = (double)duration;
    c->fade_duration = (double)fade_duration;
    c->ax_th_mode    = ax_th_mode;
    c->ax_th_val     = ax_th_val;
    c->did           = did;
    c->refresh_hz    = refresh_hz;
    c->finalize_mode = finalize_mode;
    c->pile          = pile;
    c->pile_xf       = pile_xf;
    c->pile_pose_easing = pile_pose_easing;
    c->use_ax        = (flags & SA_T3D_FLAG_AX) != 0;
    c->notify_done   = (flags & SA_T3D_FLAG_NOTIFY_DONE) != 0;
    // Seat seam-guard snapshot (cheap; AX contexts only — visual-only rows
    // never commit real frames, so they can't trip the vacate clamp).
    if (c->use_ax) {
        CGDirectDisplayID sg_dl[ANIM_SEAT_MAX_DISP]; uint32_t sg_dn = 0;
        if (CGGetActiveDisplayList(ANIM_SEAT_MAX_DISP, sg_dl, &sg_dn) == kCGErrorSuccess) {
            for (uint32_t sg_i = 0; sg_i < sg_dn; ++sg_i) {
                c->disp[c->disp_count++] = CGDisplayBounds(sg_dl[sg_i]);
            }
        }
    }
    for (int i = 0; i < c->count; ++i) {
        struct anim_window *w = &c->win[i];
        // AC-9: row decoded from SA_ANIM_ROW_FIELDS (common_experimental.h) — the
        // canonical order shared with the daemon packer and the degrade path above.
#define X(t, dn, pn) unpack(w->pn);
        SA_ANIM_ROW_FIELDS(X)
#undef X
        if (pile) { unpack(w->depth); }
        // Anchor starts at start_* (where the surface actually is).
        w->ax_x = w->sx; w->ax_y = w->sy; w->ax_w = w->sw; w->ax_h = w->sh;
        // AC-5: claim this wid's latest generation so any earlier context's
        // in-flight async clear (dispatched after its slot freed) is now stale.
        w->gen = lb_wid_gen_bump(w->wid);
        // AC-15: claim cross-animator ownership — a resize begun mid-slide
        // stales g_xfade's tokens for these wids, so the slide's per-frame
        // writes AND its settle/handoff identity+alpha resets skip them.
        // anim_claim is a pure table op (leaf lock, no SLS), safe under
        // g_anim_lock.
        w->own_geo   = anim_claim(w->wid, ANIM_CH_GEO, ANIM_OWNER_LB_T3D);
        w->own_alpha = (flags & SA_T3D_FLAG_ALPHA) ? anim_claim(w->wid, ANIM_CH_ALPHA, ANIM_OWNER_LB_T3D) : 0;
    }

    // Supersede: any still-active context animating one of our wids must release
    // it — this new context owns it now (its start_* was captured live by the
    // daemon, so the handoff is seamless). Mark the OLD row; that context then
    // skips the wid in commit/AX/finalize-clear. Under g_anim_lock (held).
    for (int i = 0; i < c->count; ++i) {
        uint32_t wid = c->win[i].wid;
        for (int k = 0; k < ANIM_MAX_CTX; ++k) {
            struct anim_ctx *o = &g_anim_ctx[k];
            if (o == c || !__atomic_load_n(&o->active, __ATOMIC_ACQUIRE)) continue;
            for (int j = 0; j < o->count; ++j) {
                if (o->win[j].wid != wid) continue;
                // Seam-held takeover handoff: a seam row's REAL frame parks at
                // its start origin for the whole flight, so the daemon's
                // captured start (an AX read) is the park — a superseding
                // animation would visually restart from there. Hand the old
                // row's last committed VISUAL rect to the new row as its lerp
                // start, and its real anchor as the new anchor (the wire
                // start==anchor assumption breaks when start is overridden).
                // Both rows are under g_anim_lock here.
                // (donor must be the LIVE owner — an already-superseded row's
                // stash is frozen at ITS takeover tick)
                if (!__atomic_load_n(&o->win[j].superseded, __ATOMIC_ACQUIRE) &&
                    o->win[j].seam_hold && o->win[j].vis_set) {
                    c->win[i].sx = o->win[j].vis_x; c->win[i].sy = o->win[j].vis_y;
                    c->win[i].sw = o->win[j].vis_w; c->win[i].sh = o->win[j].vis_h;
                    c->win[i].ax_x = o->win[j].ax_x; c->win[i].ax_y = o->win[j].ax_y;
                    c->win[i].ax_w = o->win[j].ax_w; c->win[i].ax_h = o->win[j].ax_h;
                }
                __atomic_store_n(&o->win[j].superseded, true, __ATOMIC_RELEASE);
                __atomic_store_n(&o->win[j].ax_dispatch_id, 0, __ATOMIC_RELEASE);   // invalidate any in-flight AX completion (token 0 is never live)
            }
        }
    }

    anim_metrics_reset(&c->metrics, dl_mach_to_s());
    c->start_s  = (double)mach_absolute_time() * dl_mach_to_s();
    c->reported = false;

    // EUI off (refcounted per pid across all contexts) → atomic, non-reflowing
    // AX resizes during the anim; restored when the LAST context for the pid
    // settles. Synchronous here (begin runs on the SA handler thread, not the
    // pump) so EUI is guaranteed off before the first AX fire.
    if (c->use_ax) anim_hold_eui(c);

    // Wake lazy Chromium/Electron AX trees so the AX setFrame lands (config
    // window_animation_ax_wake, default on). Synchronous here like the EUI hold
    // → the attribute is set before the first pump-tick AX fire, giving the
    // async tree-build the whole animation to complete.
    if (c->use_ax && (c->flags & SA_T3D_FLAG_AX_WAKE)) anim_wake_ax(c);

    __atomic_store_n(&c->active, true, __ATOMIC_RELEASE);   // activate LAST
    pthread_mutex_unlock(&g_anim_lock);

    // Geom probe: write the START/TARGET block now — off the lock, and before the
    // clock resumes below, so it lands at the very top of the log ahead of the
    // first t=0.0 Pass-1.5 frame.
    if (c->flags & SA_T3D_FLAG_GEOM_LOG) geom_log_targets(c);

    // Mark each window animating (daemon is_animating ground truth + the
    // pending-finalize completion signal) AFTER the lock (SLS writes shouldn't
    // stall the pump) but BEFORE resuming the clock, so the property is true
    // before the first AX fire on the next pump tick. notify_done extends this
    // to visual-only batches (no AX) whose daemon caller wired a finalize_callback
    // — begin is synchronous, so the property is true before the daemon registers.
    if (c->use_ax || c->notify_done)
        for (int i = 0; i < (int)count; ++i) lb_set_animating_prop(c->win[i].wid, true);

    // Register the pump client on the animation's OWN display clock (its panel
    // rate), keyed by did, AFTER releasing g_anim_lock (lock order).
    ca_clock_register(did, refresh_hz, anim_step, (void *)(uintptr_t)did);
    ca_clock_resume(did);
}
