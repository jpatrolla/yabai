// NOTE: payload-side window animator. The payload owns the whole animation
// (per-VBL CA pump, lerp+easing, LB+T3D commit, throttled AX setFrame);
// AX fires are dispatched OFF the tick thread — AX is synchronous and can
// block, and a stalled pump janks every window on the display. Wire unpack
// MUST mirror the daemon packer (scripting_addition_anim_ax_begin).

#include <CoreGraphics/CGGeometry.h>
#include <dispatch/dispatch.h>

extern CGError  SLSGetOnscreenWindowBounds(int cid, uint32_t wid, CGRect *out);
extern CGRect   SLSWindowIteratorGetFrameBounds(CFTypeRef iterator);
extern CGRect   SLSWindowIteratorGetBounds(CFTypeRef iterator);
extern CGError  SLSCopyWindowShape(int cid, uint32_t wid, CFTypeRef *out_region);
extern CGError  CGSGetRegionBounds(CFTypeRef region, CGRect *out_bounds);
extern bool     CGSRegionIsEmpty(CFTypeRef region);
extern CGError  SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef key, CFTypeRef *out);
extern int      proc_name(int pid, void *buf, uint32_t bufsize);

#define ANIM_AX_MAX       SA_ANIM_AX_MAX   // single-sourced with the daemon packer
#define ANIM_MAX_CTX 16   // concurrent animations
#define WM_AX_TH_NONE_      0u   // mirror of WM_AX_TH_NONE
#define ANIM_SETTLE_MAX_S 0.5  // wall-clock settle hard-stop
#define GEOM_SETTLE_HOLD_S  0.05 // geom probe only: keep ticking ≥50ms past t=1 so the log captures post-animation settle frames even when the surface lands instantly
#define ANIM_SETTLE_PX    SA_ANIM_SETTLE_PX // NOTE: must stay < daemon AX_DIFF
                                            // (asserted in window_manager.c)
#define ANIM_COOLDOWN_S   0.1 // wall-clock (refresh-independent) hold on the animating-property flush-gate AFTER LB clears, so trailing terminal-AX MOVED/RESIZED events drain while still suppressed
#define ANIM_CONFORM_MAX_DEV 500.0f // max px the ask may lead the real frame

#define ANIM_CLS_LAND_PX     8.0f   // |asked - WB| under this = axis landed
#define ANIM_SEAT_MAX_DISP   8      // seat seam-guard display capacity

#include "../../pile_transform.h"  // pile pose math (pure; shared with the daemon)

struct anim_window {
    uint32_t wid, mode; int32_t pid;
    float sx, sy, sw, sh;        // start (VISUAL lerp begin)
    float ex, ey, ew, eh;        // end   (VISUAL lerp end)
    float nx, ny, nw, nh;        // natural surface rect — visual-only T3D anchor
    uint32_t depth;             // stages-only; inert in carve
    float min_opacity, min_w, min_h, max_w, max_h;
    float aspect;               // inert reserved wire field
    volatile float ax_x, ax_y, ax_w, ax_h;   // anchor = last committed AX pos
    volatile bool  ax_in_flight;
    bool           ax_initial;               // Trigger 1 (t=0) has fired (endpin fires it for resizes too)
    volatile bool  superseded;               // a newer context owns this wid; skip it everywhere
    uint64_t       ax_dispatch_id;
    uint64_t       gen;                       // guards stale async prop clear
    uint64_t       own_geo;                   // GEO ownership token
    uint64_t       own_alpha;                 // ALPHA ownership token (0 = never claimed)
    // Geom-probe stash: ask(N-1) read next tick so ask and report align
    // (written under g_anim_lock, read atomically off-lock).
    volatile float glb_x, glb_y, glb_w, glb_h;   // last LB rect asked
    volatile float gt;                            // last lerp progress, clamped 0..1
    volatile float wb_w, wb_h;                    // real frame, 0 = unsampled
    volatile float wb_x, wb_y;                    // real on-screen origin (seam T3D anchor)
    bool     seam_hold;              // never-seat latch
    bool     seam_eval;              // seam_hold computed (write-once)
    bool     seam_park;              // straddling-start rescue armed (latch)
    float    park_x, park_y;         // park origin (in-display)
    float    vis_x, vis_y, vis_w, vis_h;   // takeover handoff start (last committed visual)
    bool     vis_set;                // vis_* valid (at least one tick committed)
    bool     cls_done;               // classified this run (write-once verdict guard)
};

struct anim_ctx {
    volatile bool active;        // slot ownership: begin sets last, pump clears on settle
    bool     reported;
    bool     finalizing;         // t>=1 reached: terminal AX + EUI dispatched, now settling
    double   settle_start_s;     // settle wall-clock start (bounds wait at SETTLE_MAX_S)
    volatile bool settle_ok;     // "real frame landed at end"; probed unlocked in pre-pass
    bool     lb_cleared;         // settle done: LB/T3D dropped, now holding the flush-gate through cooldown
    double   cooldown_start_s;   // cooldown wall-clock start (bounds gate at COOLDOWN_S)
    bool     eui_released;       // idempotent guard for the per-pid EUI refcount release
    bool     use_ax;
    bool     notify_done;        // daemon-observable animating prop even when visual-only
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
    CGRect   disp[ANIM_SEAT_MAX_DISP];   // seat seam-guard snapshot; empty = guard off
    int      disp_count;
    struct anim_metrics metrics;
    struct anim_window win[ANIM_AX_MAX];
};

static struct anim_ctx g_anim_ctx[ANIM_MAX_CTX];
static pthread_mutex_t   g_anim_lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t          g_lb_ax_dispatch_id;

// NOTE: followers run on the pump thread UNDER g_anim_lock: only touch the
// passed tx — no blocking SLS round-trips, and never call back into
// lb_follower_register (non-recursive mutex → self-deadlock).
typedef void (*lb_follower_fn)(CFTypeRef tx, uint32_t wid, CGRect rect);
#define LB_FOLLOWER_MAX 8
static lb_follower_fn g_lb_followers[LB_FOLLOWER_MAX];
static int            g_lb_follower_count;

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

// NOTE: the async animating-prop clear must stay gen-guarded: a newer begin
// can reuse the freed slot before the clear runs, and a stale clear opens
// the daemon flush-gate mid-animation. Helpers assume g_anim_lock held;
// a reclaimed (missing) entry reads as current so idle clears still land.
struct lb_wid_gen { uint32_t wid; uint64_t gen; };
static struct lb_wid_gen g_lb_wid_gen[ANIM_MAX_CTX * ANIM_AX_MAX];

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

static bool lb_wid_gen_is_current(uint32_t wid, uint64_t gen)
{
    int n = (int)(sizeof(g_lb_wid_gen) / sizeof(g_lb_wid_gen[0]));
    for (int i = 0; i < n; ++i)
        if (g_lb_wid_gen[i].gen != 0 && g_lb_wid_gen[i].wid == wid) return g_lb_wid_gen[i].gen == gen;
    return true;
}

static inline float lb_lerp(float a, float t, float b) { return a + (b - a) * t; }

// NOTE: every written/probed size goes through these — visual lerp, AX fire,
// terminal commit, settle probe. Clamp differently anywhere and the probe
// never matches the commit → settle stalls to the hard-stop.
static inline float lb_clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float lb_clamp_w(const struct anim_window *w, float v) { return lb_clamp(v, w->min_w, w->max_w); }
static inline float lb_clamp_h(const struct anim_window *w, float v) { return lb_clamp(v, w->min_h, w->max_h); }

// NOTE: blob "<type> <minw> <minh> <maxw> <maxh> <aspect> <confirm>" —
// parsed by resolve_anim_constraints (window_manager.c); free axis carries
// the daemon's no-op sentinels (min 0 / max 1e9).
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

// NOTE: ground truth for the daemon's window_manager_is_animating — set at
// begin / cleared after cooldown; suppresses the BSP feedback-flush.
extern CGError SLSSetWindowProperty(int cid, uint32_t wid, CFStringRef property, CFTypeRef value);
static void lb_set_animating_prop(uint32_t wid, bool on) {
    SLSSetWindowProperty(SLSMainConnectionID(), wid,
                         CFSTR("com.koekeishiya.yabai.animating"),
                         on ? (CFTypeRef)kCFBooleanTrue : (CFTypeRef)kCFBooleanFalse);
}

// NOTE: EUI is refcounted per pid across contexts — the first context to
// finalize must not re-enable it while another still fires AX. Restore the
// value captured at 0->1 (some apps baseline false), and only after settle:
// an early restore lets AppKit animate the terminal resize.
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
            bool prior = false;
            g_lb_eui[i].prior_known = payload_ax_get_eui(pid, &prior);
            g_lb_eui[i].prior       = prior;
            payload_ax_set_eui(pid, false);
            return;
        }
}

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
                    if (still_zero && prior_known) payload_ax_set_eui(pid, prior);
                });
            }
            return;
        }
}

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

// NOTE: AXManualAccessibility wakes lazy Chromium/Electron AX trees (else
// AXWindows is empty and setFrame no-ops). Sticky — no restore needed.
static void anim_wake_ax(struct anim_ctx *c)
{
    for (int i = 0; i < c->count; ++i) {
        bool seen = false;
        for (int j = 0; j < i; ++j) if (c->win[j].pid == c->win[i].pid) { seen = true; break; }
        if (!seen) payload_ax_enable_manual_a11y(c->win[i].pid);
    }
}

// NOTE: called before a cross-animator takeover (space slide) — the hazards
// are the surviving LockedBounds pin and the uncommitted end AX frame, so
// finish the resize, then clear LB/T3D. LEAVE_TERMINAL contexts are left
// running. Snapshot under g_anim_lock; AX + commit outside it.
#define ANIM_SKIP_MAX 128
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
            if (!anim_owns(w->wid, ANIM_CH_GEO, w->own_geo)) continue;
            if (n >= ANIM_SKIP_MAX) { dropped++; continue; }
            float ew = lb_clamp_w(w, w->ew);
            float eh = lb_clamp_h(w, w->eh);
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
        if (c->use_ax) anim_release_eui(c);
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
            if (items[i].seam) SLSTransactionMoveWindowWithGroup(tx, items[i].wid, items[i].end.origin);
            if (items[i].do_t3) SLSTransactionSetWindowTransform3D(tx, items[i].wid, ident);
            if (items[i].do_lb) SLSTransactionClearWindowLockedBounds(tx, items[i].wid);
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
        anim_release(items[i].wid, ANIM_CH_GEO, items[i].own_geo);
        if (items[i].own_alpha) anim_release(items[i].wid, ANIM_CH_ALPHA, items[i].own_alpha);
    }

    if (dropped) logpf("ANIM", "skip_all_to_end: forced %d to terminal, DROPPED %d (>%d cap) — they settle via own pump",
                       n, dropped, ANIM_SKIP_MAX);
    else         logpf("ANIM", "skip_all_to_end forced %d window(s) to terminal (space switch)", n);
    return n;
}

// NOTE: runs inline on the SA handler thread — the daemon's send blocks
// until return, so the caller observes a committed terminal state. A live
// cross-fade slide is left to self-settle.
static void do_anim_skip_all(int sockfd, char *message)
{
    (void)message;
    uint32_t forced = (uint32_t)anim_skip_all_to_end();
    if (atomic_load(&g_xfade.active))
        logpf("ANIM", "skip_all opcode: slide live (left to self-settle) forced=%u", forced);
    send(sockfd, &forced, sizeof(forced), 0);
}

// Steps one context into the shared per-VBL tx (committed once by the pump).
static bool anim_ctx_step_one(struct anim_ctx *c, CFTypeRef tx)
{
    // NOTE: cooldown — LB/T3D already dropped; commit nothing (don't re-pin),
    // just hold the animating property until trailing AX events drain.
    if (c->lb_cleared) {
        double cd_now = (double)mach_absolute_time() * dl_mach_to_s();
        if (cd_now - c->cooldown_start_s < ANIM_COOLDOWN_S) return false;
        for (int i = 0; i < c->count; ++i) {
            if (c->win[i].superseded) continue;   // the new owner clears it
            uint32_t wid = c->win[i].wid;
            uint64_t gen = c->win[i].gen;         // AC-5: stale-clear guard
            uint64_t own_geo = c->win[i].own_geo, own_alpha = c->win[i].own_alpha;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
                pthread_mutex_lock(&g_anim_lock);
                bool current = lb_wid_gen_is_current(wid, gen);
                pthread_mutex_unlock(&g_anim_lock);
                if (current) lb_set_animating_prop(wid, false);
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
        if (!anim_owns(w->wid, ANIM_CH_GEO, w->own_geo)) continue;
        float lerp_x = lb_lerp(w->sx, mt, w->ex);
        float lerp_y = lb_lerp(w->sy, mt, w->ey);
        float lerp_w = lb_lerp(w->sw, mt, w->ew);
        float lerp_h = lb_lerp(w->sh, mt, w->eh);
        float clamped_w = lb_clamp_w(w, lerp_w);
        float clamped_h = lb_clamp_h(w, lerp_h);
        // NOTE: conformance clamp — the ask may lead the real frame (WindowBounds,
        // sampled unlocked every tick INCLUDING settle) by at most DEV; DEV ramps to
        // 0 by t=1 via apply_easing(1-t) so the held visual converges to WB (no
        // finalize snap). The 1-t time-mirror is deliberate: matched (1-easing)
        // collapses DEV exactly when an ease-out window's lag peaks.
        {
            float wbw = lb_load_f(&w->wb_w), wbh = lb_load_f(&w->wb_h);
            float dev = ANIM_CONFORM_MAX_DEV * apply_easing(1.0f - (float)t, (int)c->easing);
            if (wbw > 0.0f) clamped_w = lb_clamp(clamped_w, wbw - dev, wbw + dev);
            if (wbh > 0.0f) clamped_h = lb_clamp(clamped_h, wbh - dev, wbh + dev);
        }

        // NOTE: per-axis slack centering; every site that computes the end rect
        // (AX fire, skip-to-end, settle probe, degrade) must mirror this exactly
        // or the settle probe never matches and stalls to the hard-stop.
        float slack_x = lerp_w - clamped_w;
        float slack_y = lerp_h - clamped_h;
        float cx = lerp_x + (slack_x > 0.0f ? slack_x * 0.5f : 0.0f);
        float cy = lerp_y + (slack_y > 0.0f ? slack_y * 0.5f : 0.0f);
        w->vis_x = cx; w->vis_y = cy; w->vis_w = clamped_w; w->vis_h = clamped_h;
        w->vis_set = true;

        // NOTE: visual-only T3D anchors on the NATURAL surface rect — anchoring on
        // start collapses the t=0 matrix to identity whenever start != natural.
        float ax, ay, aw, ah;
        if (use_ax) { ax = lb_load_f(&w->ax_x); ay = lb_load_f(&w->ax_y); aw = lb_load_f(&w->ax_w); ah = lb_load_f(&w->ax_h); }
        else        { ax = w->nx; ay = w->ny; aw = w->nw; ah = w->nh; }
        if (use_ax && w->seam_hold && lb_load_f(&w->wb_w) > 0.0f) {
            ax = lb_load_f(&w->wb_x); ay = lb_load_f(&w->wb_y);
        }

        // NOTE: endpin — the real origin stays pinned at end_xy so the app never
        // computes an internal move (left/top-edge grow reflow); LB_FULL+T3D carry
        // the position. Triggers: 1 seat move at t=0, 2 threshold resize, 3 terminal.
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
            float end_cw = lb_clamp_w(w, w->ew);
            float end_ch = lb_clamp_h(w, w->eh);
            float end_sx = w->ew - end_cw;
            float end_sy = w->eh - end_ch;
            float end_cx = w->ex + (end_sx > 0.0f ? end_sx * 0.5f : 0.0f);
            float end_cy = w->ey + (end_sy > 0.0f ? end_sy * 0.5f : 0.0f);
            float fx = endpin ? end_cx : cx;   // endpin: AX origin pinned at centered end
            float fy = endpin ? end_cy : cy;
            float fw = clamped_w, fh = clamped_h;

            // NOTE: AppKit refuses AX resizes that would vacate a display the frame
            // occupies. Rows whose START-size seat would occupy a display the end rect
            // doesn't touch never seat: shrink in place (grow capped at start size,
            // anchor records the REAL origin), park straddling-start frames with one
            // pure move, and land the terminal origin SERVER-SIDE in the finalize
            // commit — size-only settle verdict; on hard-stop never move (foreign op).
            if (!w->seam_eval && endpin && !pure_move) {
                w->seam_eval = true;
                CGRect sg_seat = CGRectMake(end_cx, end_cy, w->sw, w->sh);
                CGRect sg_end  = CGRectMake(end_cx, end_cy, end_cw, end_ch);
                for (int sg = 0; sg < c->disp_count; ++sg) {
                    if (CGRectIntersectsRect(sg_seat, c->disp[sg]) &&
                        !CGRectIntersectsRect(sg_end, c->disp[sg])) { w->seam_hold = true; break; }
                }
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
                // Trigger 1 (t=0): seat move to end_xy at committed size.
                fire = terminal = true;
                fx = end_cx; fy = end_cy;
                if (endpin && !pure_move) { fw = aw;  fh = ah;
                                            if (warp_ax) move_only = true; }   // jello: PURE kAXPosition move (no redundant AXSize touch)
                else                      { fw = w->ew;  fh = w->eh; }
            } else if (w->seam_park) {
                // Straddling-start park: one pure move to the in-display park.
                fire = true; move_only = true; park_fire = true;
                fx = w->park_x; fy = w->park_y; fw = aw; fh = ah;
            } else if (t >= 1.0f && (w->seam_hold ? (aw != w->ew || ah != w->eh)
                                                  : (ax != end_cx || ay != end_cy || aw != w->ew || ah != w->eh))) {
                // Trigger 3 (t>=1): full end_rect terminal fire (seam rows: size only).
                fire = terminal = true;
                if (w->seam_hold) { fx = ax; fy = ay; fw = w->ew; fh = w->eh; resize_only = true; }
                else              { fx = end_cx; fy = end_cy; fw = w->ew; fh = w->eh; }
            } else if (warp_ax && t < 1.0f) {
                if (aw != end_cw || ah != end_ch) {
                    fire = true; resize_only = true;
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
                double pnw = (double)w->nw, pnh = (double)w->nh;
                double fit_now = (pnw > 0.0 && pnh > 0.0)
                               ? fmin((double)lerp_w / pnw, (double)lerp_h / pnh) : 1.0;
                double f_s = (pnw > 0.0 && pnh > 0.0)
                           ? fmin((double)w->sw / pnw, (double)w->sh / pnh) : 1.0;
                double f_e = (pnw > 0.0 && pnh > 0.0)
                           ? fmin((double)w->ew / pnw, (double)w->eh / pnh) : 1.0;
                double f_full = 1.0, f_thumb = fmin(f_s, f_e);
                double den = f_full - f_thumb;
                double pp_raw = den > 1e-6 ? (f_full - fit_now) / den : 0.0;
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

        CGRect follow_rect = CGRectMake(cx, cy, clamped_w, clamped_h);
        for (int f = 0; f < g_lb_follower_count; ++f)
            g_lb_followers[f](tx, w->wid, follow_rect);

        lb_store_f(&w->glb_x, cx);        lb_store_f(&w->glb_y, cy);
        lb_store_f(&w->glb_w, clamped_w); lb_store_f(&w->glb_h, clamped_h);
        lb_store_f(&w->gt, t);
    }

    if (t >= 1.0) {
        // NOTE: settle only probes — nothing here blocks the pump. EUI restore
        // waits for the landed block: restoring early animates the final resize.
        if (!c->finalizing) {
            c->finalizing      = true;
            c->settle_start_s  = now;   // `now` = mach→s captured at the top of this tick
            if (!c->reported) { anim_metrics_report(&c->metrics, "anim", c->use_ax ? "CA+AX" : "CA"); c->reported = true; }
        }

        if ((c->flags & SA_T3D_FLAG_GEOM_LOG) && (now - c->settle_start_s) < GEOM_SETTLE_HOLD_S)
            return false;

        bool settled = c->use_ax ? __atomic_load_n(&c->settle_ok, __ATOMIC_ACQUIRE) : true;

        if (!settled && (now - c->settle_start_s) < ANIM_SETTLE_MAX_S) return false;

        if (c->use_ax) anim_release_eui(c);

        // NOTE: CLEAR drops T3D+LB; LEAVE_TERMINAL persists the last frame. These
        // are the LATER writes for the wids in the shared tx, so they win at commit.
        if (c->finalize_mode != SA_FINALIZE_LEAVE_TERMINAL) {
            double ident[16] = { 1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1 };
            for (int i = 0; i < c->count; ++i) {
                if (c->win[i].superseded) continue;   // the new owner clears it
                if (!anim_owns(c->win[i].wid, ANIM_CH_GEO, c->win[i].own_geo)) continue;   // AC-15: ditto, cross-animator
                if (c->win[i].seam_hold) {
                    float mw = lb_clamp_w(&c->win[i], c->win[i].ew);
                    float mh = lb_clamp_h(&c->win[i], c->win[i].eh);
                    float gw = lb_load_f(&c->win[i].wb_w);
                    float gh = lb_load_f(&c->win[i].wb_h);
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
                SLSTransactionSetWindowWarp(tx, c->win[i].wid, 0, 0, NULL);
            }
        }
        if (c->use_ax) {
            c->lb_cleared       = true;
            c->cooldown_start_s = now;   // `now` = mach→s captured at the top of this tick
            return false;   // stay active for the flush-gate cooldown (clears the property after cooldown)
        }
        // Visual-only: no cooldown; clear the property now if a finalize callback waits.
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

// NOTE: debug probe (SA_T3D_FLAG_GEOM_LOG): sample every geometry getter per
// frame — synchronous SLS/AX round-trips, so it MUST stay off g_anim_lock.
// Wide-shipped constraints make ASK-vs-WindowBounds the app/server push-back.
#define GEOM_LOG_PATH "/tmp/yabai_anim_probe.log"

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

static void geom_log_targets(struct anim_ctx *c)
{
    FILE *f = fopen(GEOM_LOG_PATH, "a");
    if (!f) return;
    int cid = SLSMainConnectionID();
    fprintf(f, "== targets (before t=0.0) — START = where the surface is, TARGET = end rect asked ==\n");
    for (int k = 0; k < c->count; ++k) {
        struct anim_window *w = &c->win[k];
        if (!w->wid) continue;

        char app[256] = {0};
        if (w->pid <= 0 || proc_name((int)w->pid, app, sizeof(app)) <= 0) snprintf(app, sizeof(app), "?");
        char title[256] = "?";
        CFTypeRef tv = NULL;
        if (SLSCopyWindowProperty(cid, w->wid, CFSTR("kCGSWindowTitle"), &tv) == kCGErrorSuccess && tv) {
            if (CFGetTypeID(tv) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)tv, title, sizeof(title), kCFStringEncodingUTF8);
            CFRelease(tv);
        }

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

        if (c->finalizing && !c->geom_end_marked) {
            fprintf(f, "========================= ANIMATION END (t=1.0, ts=%.1fms) — settle frames below =========================\n", ts_ms);
            c->geom_end_marked = true;
        }

        for (int k = 0; k < c->count; ++k) {
            struct anim_window *w = &c->win[k];
            if (__atomic_load_n(&w->superseded, __ATOMIC_ACQUIRE)) continue;
            uint32_t wid = w->wid;

            CGRect ask = CGRectMake(lb_load_f(&w->glb_x), lb_load_f(&w->glb_y),
                                    lb_load_f(&w->glb_w), lb_load_f(&w->glb_h));
            float t = lb_load_f(&w->gt);

            CGRect wb = CGRectZero, ob = CGRectZero, sr = CGRectZero;
            bool wb_ok = SLSGetWindowBounds(cid, wid, &wb)         == kCGErrorSuccess;
            bool ob_ok = SLSGetOnscreenWindowBounds(cid, wid, &ob) == kCGErrorSuccess;
            bool sr_ok = SLSGetScreenRectForWindow(cid, wid, &sr)  == kCGErrorSuccess;

            CGRect fb = CGRectZero; bool fb_ok = false;
            CGSize cmin = {0}, cmax = {0}, ccur = {0}, cp4 = {0}; bool cn_ok = false;
            CFArrayRef arr = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
            CFTypeRef query = arr ? SLSWindowQueryWindows(cid, arr, 0x0) : NULL;
            CFTypeRef iter  = query ? SLSWindowQueryResultCopyWindows(query) : NULL;
            if (iter && SLSWindowIteratorAdvance(iter)) {
                fb = SLSWindowIteratorGetFrameBounds(iter); fb_ok = true;
                SLSWindowIteratorGetConstraints(iter, &cmin, &cmax, &ccur, &cp4);
                cn_ok = true;
            }
            if (iter)  CFRelease(iter);
            if (query) CFRelease(query);
            if (arr)   CFRelease(arr);

            CGRect shape = CGRectZero; bool shape_ok = false;
            CFTypeRef region = NULL;
            if (SLSCopyWindowShape(cid, wid, &region) == kCGErrorSuccess && region) {
                if (!CGSRegionIsEmpty(region) && CGSGetRegionBounds(region, &shape) == kCGErrorSuccess)
                    shape_ok = true;
                CFRelease(region);
            }

            CGRect axr = CGRectZero; bool ax_ok = false; double ax_us = 0.0;
            if (with_ax) {
                double t0 = (double)mach_absolute_time() * dl_mach_to_s();
                ax_ok = payload_ax_get_frame(w->pid, wid, &axr);
                ax_us = ((double)mach_absolute_time() * dl_mach_to_s() - t0) * 1.0e6;
            }

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

// Per-display pump client (ctx == did): each panel's vblank advances only
// its own contexts.
static bool anim_step(void *ctx_did, CFTypeRef pump_tx, uint32_t pump_did)
{
    (void)pump_did;
    uint32_t did = (uint32_t)(uintptr_t)ctx_did;
    int cid = SLSMainConnectionID();

    // NOTE: synchronous SLS round-trips (settle probe, WB sampling) must not
    // run under g_anim_lock — they stall every other display's pump. Safe
    // unlocked: this display's pump owns its contexts; `superseded` only ever
    // flips true. The locked pass consumes stashed verdicts round-trip-free.
    for (int i = 0; i < ANIM_MAX_CTX; ++i) {
        struct anim_ctx *c = &g_anim_ctx[i];
        if (!__atomic_load_n(&c->active, __ATOMIC_ACQUIRE)) continue;
        if (c->did != did) continue;
        if (c->lb_cleared || !c->use_ax) continue;   // cooldown / visual-only: nothing to probe
        double pnow = (double)mach_absolute_time() * dl_mach_to_s();
        double pt   = c->duration > 0.0 ? (pnow - c->start_s) / c->duration : 1.0;
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
            if (!anim_owns(c->win[k].wid, ANIM_CH_GEO, c->win[k].own_geo)) continue;
            CGRect sr = CGRectZero;
            if (SLSGetScreenRectForWindow(cid, c->win[k].wid, &sr) != kCGErrorSuccess) continue;
            float ew_c = lb_clamp_w(&c->win[k], c->win[k].ew);
            float eh_c = lb_clamp_h(&c->win[k], c->win[k].eh);
            float sdev = ANIM_CONFORM_MAX_DEV * apply_easing(1.0f - fminf((float)pt, 1.0f), (int)c->easing);
            float cwbw = lb_load_f(&c->win[k].wb_w), cwbh = lb_load_f(&c->win[k].wb_h);
            if (!c->win[k].seam_hold) {
                if (cwbw > 0.0f) ew_c = lb_clamp(ew_c, cwbw - sdev, cwbw + sdev);
                if (cwbh > 0.0f) eh_c = lb_clamp(eh_c, cwbh - sdev, cwbh + sdev);
            }
            float esx  = c->win[k].ew - ew_c;
            float esy  = c->win[k].eh - eh_c;
            float ex_c = c->win[k].ex + (esx > 0.0f ? esx * 0.5f : 0.0f);
            float ey_c = c->win[k].ey + (esy > 0.0f ? esy * 0.5f : 0.0f);
            bool match = fabsf((float)sr.size.width  - ew_c) <= ANIM_SETTLE_PX &&
                         fabsf((float)sr.size.height - eh_c) <= ANIM_SETTLE_PX &&
                         (c->win[k].seam_hold ||
                          (fabsf((float)sr.origin.x - ex_c) <= ANIM_SETTLE_PX &&
                           fabsf((float)sr.origin.y - ey_c) <= ANIM_SETTLE_PX));
            if (!match) { settled = false; continue; }  // keep walking so every landed row can classify

            // NOTE: landed row => WB is its final size; a single-axis gap learns a
            // min/max, persisted only when the daemon shipped wide-open (lazy-zero) —
            // the only case it reads back.
            struct anim_window *cw = &c->win[k];
            if (!cw->cls_done && cw->mode != SA_T3D_ROW_MODE_T3D_ONLY &&
                !(c->flags & SA_T3D_FLAG_GEOM_LOG) &&
                cwbw > 0.0f && cwbh > 0.0f && cw->ew > 0.0f && cw->eh > 0.0f) {
                cw->cls_done = true;
                bool w_off = fabsf(cw->ew - cwbw) > ANIM_CLS_LAND_PX;
                bool h_off = fabsf(cw->eh - cwbh) > ANIM_CLS_LAND_PX;

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

    // Pass 1.5 (unlocked): geom probe sampling.
    geom_log_sample(did, cid);

    // NOTE: Pass 2 buffers into the pump's ONE shared per-VBL tx (atomic
    // same-frame commit); pump_tx NULL => skip setters, retry next VBL.
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

    return !any_active;
}

static void do_anim_ax_begin(char *message)
{
    // NOTE: header/rows decode via the shared SA_ANIM_*_FIELDS X-macros
    // (common_experimental.h) — the packer's exact order; both unpack copies
    // (main + degrade) must consume the identical byte stream.
#define X(t, dn, pn) t pn;
    SA_ANIM_HDR_FIELDS(X)
#undef X
#define X(t, dn, pn) unpack(pn);
    SA_ANIM_HDR_FIELDS(X)
#undef X
    if (count == 0 || count > ANIM_AX_MAX) return;

    // Pile block: read on EVERY path so the wire cursor always advances.
    bool pile = (flags & SA_T3D_FLAG_PILE) != 0;
    struct pile_xform pile_xf = {0};
    uint32_t pile_pose_easing = 0;   // linear fallback (enum animation_easing_type)
    if (pile) {
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
        pile_xf.cx=pcx; pile_xf.cy=pcy;
        pile_xf.max_step=(int)pmstep;
        pile_pose_easing=peasing;
    }

    if (flags & SA_T3D_FLAG_GEOM_LOG) geom_log_begin((flags & SA_T3D_FLAG_GEOM_AX) != 0);

    pthread_mutex_lock(&g_anim_lock);
    struct anim_ctx *c = NULL;
    for (int i = 0; i < ANIM_MAX_CTX; ++i) {
        if (!g_anim_ctx[i].active) { c = &g_anim_ctx[i]; break; }
    }
    if (!c) {
        pthread_mutex_unlock(&g_anim_lock);
        // NOTE: table full => snap every row to terminal — the daemon already
        // gated on this animation, so a silent drop leaves the layout diverged.
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
#define X(t, dn, pn) unpack(wp->pn);
            SA_ANIM_ROW_FIELDS(X)
#undef X
            if (pile) { unpack(wp->depth); }  // advance cursor (degrade path snaps flat)
            if (!w.wid) continue;
            float ew = w.ew < w.min_w ? w.min_w : (w.ew > w.max_w ? w.max_w : w.ew);
            float eh = w.eh < w.min_h ? w.min_h : (w.eh > w.max_h ? w.max_h : w.eh);
            float esx = w.ew - ew, esy = w.eh - eh;
            float ex_c = w.ex + (esx > 0.0f ? esx * 0.5f : 0.0f);
            float ey_c = w.ey + (esy > 0.0f ? esy * 0.5f : 0.0f);
            if (sk_use_ax) payload_ax_set_frame(w.pid, w.wid, CGRectMake(ex_c, ey_c, ew, eh));
            if (!sk_tx) continue;
            if (sk_leave && !sk_use_ax) {
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
                SLSTransactionSetWindowTransform3D(sk_tx, w.wid, ident);
                SLSTransactionClearWindowLockedBounds(sk_tx, w.wid);
                SLSTransactionSetWindowWarp(sk_tx, w.wid, 0, 0, NULL);
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
    // Seat seam-guard snapshot (AX contexts only).
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
#define X(t, dn, pn) unpack(w->pn);
        SA_ANIM_ROW_FIELDS(X)
#undef X
        if (pile) { unpack(w->depth); }
        // Anchor starts at start_* (where the surface actually is).
        w->ax_x = w->sx; w->ax_y = w->sy; w->ax_w = w->sw; w->ax_h = w->sh;
        w->gen = lb_wid_gen_bump(w->wid);
        // NOTE: claim GEO/ALPHA ownership (stales other animators' tokens).
        // anim_claim is a leaf lock, safe under g_anim_lock — keep it that way.
        w->own_geo   = anim_claim(w->wid, ANIM_CH_GEO, ANIM_OWNER_LB_T3D);
        w->own_alpha = (flags & SA_T3D_FLAG_ALPHA) ? anim_claim(w->wid, ANIM_CH_ALPHA, ANIM_OWNER_LB_T3D) : 0;
    }

    // Supersede still-active contexts holding our wids.
    for (int i = 0; i < c->count; ++i) {
        uint32_t wid = c->win[i].wid;
        for (int k = 0; k < ANIM_MAX_CTX; ++k) {
            struct anim_ctx *o = &g_anim_ctx[k];
            if (o == c || !__atomic_load_n(&o->active, __ATOMIC_ACQUIRE)) continue;
            for (int j = 0; j < o->count; ++j) {
                if (o->win[j].wid != wid) continue;
                // NOTE: a seam-held donor's real frame sat parked, so the daemon-captured
                // start is stale — inherit its last VISUAL rect as lerp start + its anchor.
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

    if (c->use_ax) anim_hold_eui(c);

    if (c->use_ax && (c->flags & SA_T3D_FLAG_AX_WAKE)) anim_wake_ax(c);

    __atomic_store_n(&c->active, true, __ATOMIC_RELEASE);   // activate LAST
    pthread_mutex_unlock(&g_anim_lock);

    if (c->flags & SA_T3D_FLAG_GEOM_LOG) geom_log_targets(c);

    // Property true after the lock, BEFORE the clock resumes (first AX fire).
    if (c->use_ax || c->notify_done)
        for (int i = 0; i < (int)count; ++i) lb_set_animating_prop(c->win[i].wid, true);

    // Register on the display clock AFTER releasing g_anim_lock (lock order).
    ca_clock_register(did, refresh_hz, anim_step, (void *)(uintptr_t)did);
    ca_clock_resume(did);
}
