// ===========================================================================
// space_animation.inc.m — space-slide animation subsystem (SA payload side)
// ===========================================================================
// Contains:
//   - payload_space_anim_phase1   (prepare/hold primitive: composite both
//                                  spaces at a static slide fraction)
//   - space_cross_fade_animator   (per-window cross-slide + cross-fade — the
//                                  PRODUCTION animated switch, on the ca_clock pump)
//   - do_space_focus_animated     (SA_OPCODE_SPACE_ANIMATE handler -> cross-fade)
//
// Included from payload.m BEFORE the ca_clock pump and the opcode dispatch,
// which reference these symbols. Depends only on logp.inc.m + the SkyLight/CV
// externs at the top of payload.m.
// ===========================================================================

// Per-space window-set cap — the max wids either side of a slide carries.
// (The name is legacy; the cross-fade animator uses it for its in/out arrays.)
#define SA_WINDOWS_ONLY_MAX_WIDS 256

// SLSTransactionSetSpaceTransform options flag — STATE-CLEAR. Only does
// anything paired with an identity matrix (clears the space's transform state
// rather than applying one; options=0 applies live). Live-verified. Shared
// with the later includes (edge_guard nudge).
#define SLS_SPACE_TRANSFORM_CLEAR_STATE 0x01000000

// Menubar-band SLS window levels (SPA-11 exclusion). Bare ints because the
// payload doesn't pull in the CGWindowLevel headers; values live-verified via
// SLSGetWindowLevel sweeps.
#define SLS_LEVEL_MENUBAR_BACKDROP 24   // kCGMainMenuWindowLevel — per-space Menubar backdrop
#define SLS_LEVEL_STATUS_ITEM      25   // kCGStatusWindowLevel — ControlCenter status items

// Menubar-band SLS tag bits — the DEFINITIVE menubar identity. Either bit
// marks a window as part of the menubar: the backdrop and the status items
// all carry both. Read per wid via SLSGetWindowTags (externed at the top of
// payload.m); preferred over the window-level test because level reads are
// cid-sensitive and can fail open, while the tag read is fresh and Dock's
// cid has full cache coverage.
#define SLS_TAG_MENUBAR_BIT        (1ULL << 45)   // kSLSMenuBarTagBit
#define SLS_TAG_MERGES_MENUBAR_BIT (1ULL << 46)   // kCGSMergesWithMenuBar

// Fallback slide duration when the daemon ships 0 (config unset).
#define SPACE_ANIM_DEFAULT_DURATION_S 0.25

// Wallpaper-window lookup for a space — resolves the desktop-picture window
// SLS reports for that space (exact-level match, lowest-level fallback).
static uint32_t find_wallpaper_wid_for_space(uint64_t sid)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner,
                                                       CFArrayRef spaces, uint32_t options,
                                                       uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);

    int cid = SLSMainConnectionID();

    CFNumberRef sid_num = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    if (!sid_num) return 0;
    CFArrayRef space_list = CFArrayCreate(NULL, (const void **)&sid_num, 1,
                                          &kCFTypeArrayCallBacks);
    CFRelease(sid_num);
    if (!space_list) return 0;

    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef wids = SLSCopyWindowsWithOptionsAndTags(
        cid, 0, space_list, 0x7, &set_tags, &clear_tags);
    CFRelease(space_list);
    if (!wids) return 0;

    // The desktop-picture window Dock creates sits at CGWindowLevelForKey(
    // kCGDesktopWindowLevelKey) - 1 (disasm-verified). On the FIRST/primary
    // space of each display the server also composites an offscreen-transition
    // buffer and the WS backstop BELOW the picture, so "lowest level wins"
    // grabs one of those there — a black window that blacks the slide. Pick
    // the picture by its exact level; fall back to lowest only if nothing
    // matches (never return 0). kCGDesktopWindowLevelKey == 2
    // (CGWindowLevelForKey is linkable in the payload — see do_window_layer
    // in payload.m).
    int picture_level = CGWindowLevelForKey(2) - 1;

    uint32_t picture_wid = 0;          // exact match at the desktop-picture level
    uint32_t lowest_wid  = 0;          // fallback: lowest-level heuristic
    int      lowest_level = INT_MAX;

    CFIndex count = CFArrayGetCount(wids);
    for (CFIndex i = 0; i < count; ++i) {
        uint32_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(wids, i),
                         kCFNumberSInt32Type, &wid);
        if (!wid) continue;

        int level = 0;
        if (SLSGetWindowLevel(cid, wid, &level) != kCGErrorSuccess) continue;
        if (level == picture_level && !picture_wid) picture_wid = wid;
        if (level < lowest_level) { lowest_level = level; lowest_wid = wid; }
    }
    CFRelease(wids);

    uint32_t best_wid = picture_wid ? picture_wid : lowest_wid;

    logpf("SPACE", "wallpaper lookup sid=%llu → wid=%u (picture_lvl=%d picture_wid=%u lowest_wid=%u@%d scanned=%ld)",
          (unsigned long long)sid, best_wid, picture_level, picture_wid,
          lowest_wid, lowest_level == INT_MAX ? 0 : lowest_level, (long)count);
    return best_wid;
}

// AC-7: the per-display ca_clock pump (displaylink_ca.inc.m) is included AFTER
// this file in payload.m, so forward-declare the two entry points the cross-fade
// animator uses as a step client. Signatures must match the definitions exactly.
static int  ca_clock_register(uint32_t did, float refresh_hz, bool (*step)(void *, CFTypeRef, uint32_t), void *ctx);
static void ca_clock_resume(uint32_t did);
static void ca_clock_wait_tick_idle(uint32_t did);
// anim.inc.m is also included AFTER this file — forward-declare
// the in-flight-resize canceller the cross-fade seed calls (AC-8). Returns forced count.
static int anim_skip_all_to_end(void);

// ---------------------------------------------------------------------------
// Native-replica space slide — prepare/hold primitive.
// ---------------------------------------------------------------------------
// Make BOTH spaces composite on the display at once and hold them at a static
// slide position `fraction` ∈ [0,1]. Mirrors the native Dock pipeline's
// prepare stage (disasm-verified): ShowSpace both + IsAnimating flag, then a
// single space-level transform per space.
//
//   direction: +1 prev (slide right), -1 next (slide left) — the cross-fade
//              animator's slide-direction convention.
//   fraction : 0 = incoming parked offscreen, current in place;
//              1 = incoming in place, current pushed offscreen.
//   set_animating: also flip managed-display IsAnimating (the gate that stops
//              the WindowServer auto-hiding the non-current space).
//   reset    : tear down — identity transforms, hide incoming, clear animating.
//
// Geometry (signs live-verified — SLSSetSpaceTransform's tx moves a
// space's content OPPOSITE the on-screen direction, since it transforms the
// coordinate space, so these are flipped from the naive expectation):
//   out_dx = -direction * width * fraction
//   in_dx  =  direction * width * (1 - fraction)
static void payload_space_anim_phase1(int cid, uint64_t out_sid, uint64_t in_sid,
                                      int direction, double width, double gap, double fraction,
                                      bool set_animating, bool reset)
{
    // Park geometry uses the same width+gap stride as the per-frame callback so
    // the seed frame and the first animated frame agree (no gap-sized pop).
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
        SLSTransactionSetSpaceTransform(tx, out_sid, SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
        SLSTransactionSetSpaceTransform(tx, in_sid,  SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
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
        SLSTransactionSetSpaceTransform(tx, out_sid, 0, &out_xf);
        SLSTransactionSetSpaceTransform(tx, in_sid,  0, &in_xf);
    }

    SLSTransactionCommit(tx, 0);
    CFRelease(tx);
    if (uuid) CFRelease(uuid);
}

// Shared viewport-position ease on normalized progress toward `target` from
// `start_p`, using the daemon-selected `easing` curve (space_animation_easing
// config → payload_ease; default ease-out-expo). Single source of truth for
// the slide curve — the cross-fade animator's per-frame step reads through
// here so the curve can't drift. Writes the clamped progress to *out_t when
// non-NULL (the step uses it to detect settle).
static inline double anim_eased_p(double start_p, int target, uint64_t start_t,
                                  double dur, double mach_to_s, double *out_t, int easing)
{
    double elapsed_s = (double)(mach_absolute_time() - start_t) * mach_to_s;
    double t = dur > 0.0 ? elapsed_s / dur : 1.0;
    if (t > 1.0) t = 1.0;
    if (out_t) *out_t = t;
    return start_p + ((double)target - start_p) * payload_ease(easing, t);
}

// === Space animation: per-window cross-slide + cross-fade (PRODUCTION) ===
// The production animated switch. Slides the incoming space's windows in and
// the outgoing space's windows out the opposite side (per-window 3D translate),
// layered with a per-frame manual alpha cross-fade, eased with the configured
// curve (anim_eased_p). Commits the real switch once at settle
// (SetManagedDisplayCurrentSpace + Dock model poke), then resets every
// per-window transform to identity and restores alphas. Interruptible: a seed
// arriving mid-slide takes over via xfade_handoff_no_commit.
// SPA-20: max Dock "Fullscreen Backdrop" windows the slide tracks (one per
// fullscreen space; a handful at most).
#define SA_FS_BACKDROP_MAX 8
// SPA-20: max identical per-space wallpaper windows hidden on one display during a
// fullscreen slide (one per space on that display + the fullscreen child) — generous.
#define SA_FS_MASK_MAX 32

// SPA-20: on a fullscreen enter/exit the normal-space wallpaper recedes into the
// "abyss" — center-scales AND fades together (the Dock backdrop + the other identical
// wallpapers are hidden so the black behind shows through). Visual scale runs 1.0 (full
// presence) → the space_animation_fs_scale lever (0 = shrink to a point, 1 = pure fade);
// the transform floors it at 0.02 so 1/S stays finite. The collapse depth, ramp curve,
// timeline (duration/delay), alpha-fade, and on/off are all config levers shipped per
// switch — see struct fs_min_scale / fs_anim_* and the daemon space_animation_fs_*.

// Dock paints a gray "Fullscreen Backdrop" window over a fullscreen space's
// wallpaper, at CGWindowLevelForKey(2)+1 — one level above the desktop picture
// (live: picture INT_MIN+24, this INT_MIN+26). It is what reads as "black" mid-
// slide when leaving/switching fullscreen. Collect Dock's own windows at that
// level so the cross-fade can fade them out, revealing the wallpaper already
// beneath (on the fullscreen companion space). Queried across ALL spaces — the
// backdrop lives on a fullscreen space's CHILD space, which a single-sid query
// would miss. Returns count, fills out[] (up to max).
static int find_fullscreen_backdrops(int cid, uint32_t *out, int max)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTagsAndSpaceOptions(
        int cid, uint32_t owner, uint32_t space_options, uint32_t options,
        uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);

    int fs_level = CGWindowLevelForKey(2) + 1;   // kCGDesktopWindowLevelKey=2; backdrop = desktop+1
    int n = 0;
    uint64_t set_tags = 0, clear_tags = 0;
    // owner=0 (all owners): the desktop windows are owned by a specific Dock
    // connection that need not equal SLSMainConnectionID(); match purely by the
    // reserved Fullscreen-Backdrop level (no app window lives at desktop+1).
    CFArrayRef all = SLSCopyWindowsWithOptionsAndTagsAndSpaceOptions(
        cid, 0, 0x7, 0x7, &set_tags, &clear_tags);
    if (!all) return 0;
    CFIndex count = CFArrayGetCount(all);
    for (CFIndex i = 0; i < count && n < max; ++i) {
        uint32_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(all, i), kCFNumberSInt32Type, &wid);
        if (!wid) continue;
        int level = 0;
        if (SLSGetWindowLevel(cid, wid, &level) == kCGErrorSuccess && level == fs_level)
            out[n++] = wid;
    }
    CFRelease(all);
    return n;
}

// SPA-20: collect every desktop-PICTURE window that shares `frame` (the animated
// display's full-display rect), EXCLUDING keep_wid. These are the byte-identical
// per-space wallpapers — including a fullscreen space's CHILD-space wallpaper — that
// otherwise mask the one we animate. Hidden for the slide, restored at settle/handoff.
// Picture level is desktop-1 (one below the Fullscreen Backdrop). Display-scoped by
// exact rect match so OTHER displays' wallpapers are never touched (no cross-display
// blackout). Returns count, fills out[] up to max.
static int find_wallpaper_maskers(int cid, CGRect frame, uint32_t keep_wid, uint32_t *out, int max)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTagsAndSpaceOptions(
        int cid, uint32_t owner, uint32_t space_options, uint32_t options,
        uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);

    int pic_level = CGWindowLevelForKey(2) - 1;   // desktop picture = desktop-1
    int n = 0;
    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef all = SLSCopyWindowsWithOptionsAndTagsAndSpaceOptions(cid, 0, 0x7, 0x7, &set_tags, &clear_tags);
    if (!all) return 0;
    CFIndex count = CFArrayGetCount(all);
    for (CFIndex i = 0; i < count && n < max; ++i) {
        uint32_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(all, i), kCFNumberSInt32Type, &wid);
        if (!wid || wid == keep_wid) continue;
        int level = 0;
        if (SLSGetWindowLevel(cid, wid, &level) != kCGErrorSuccess || level != pic_level) continue;
        CGRect b;
        if (SLSGetWindowBounds(cid, wid, &b) != kCGErrorSuccess) continue;
        if (fabs(b.origin.x - frame.origin.x) < 1.0 && fabs(b.origin.y - frame.origin.y) < 1.0 &&
            fabs(b.size.width - frame.size.width) < 1.0 && fabs(b.size.height - frame.size.height) < 1.0)
            out[n++] = wid;
    }
    CFRelease(all);
    return n;
}

// SPA-20: build the 2D window transform that displays a wallpaper at visual scale S
// (1.0 = natural) about its CENTER, in the screen→local convention the desktop picture
// already uses (observed live: identity + (-origin)). Same shape as
// do_window_scale_custom: scale(1/S) ∘ translate(-target_origin), where the target is
// the S-scaled rect centered on the window. At S=1 it reduces to translate(-ox,-oy) =
// natural, so it composes cleanly with the picture's existing transform and is correct
// on any display (the origin is baked in — that's why the bare 3D scale slid off D2).
extern CGError SLSTransactionSetWindowTransform(CFTypeRef tx, uint32_t wid, int u0, int u1, CGAffineTransform t);
static inline CGAffineTransform fs_abyss_xform(double ox, double oy, double w, double h, double S)
{
    double si = 1.0 / S;                              // screen→local is the inverse scale
    double target_x = ox + (1.0 - S) * w * 0.5;       // S-scaled rect, centered
    double target_y = oy + (1.0 - S) * h * 0.5;
    return (CGAffineTransform){ .a = si, .b = 0, .c = 0, .d = si, .tx = -target_x * si, .ty = -target_y * si };
}

struct space_cross_fade_animator {
    int       cid;
    uint64_t  out_sid, in_sid;
    int       direction;
    double    width, duration, mach_to_s;
    uint64_t  start_mach_time;
    bool      wallpaper;                              // wallpapers ride the slide with their spaces
    uint32_t  in_wp, out_wp;
    uint32_t  in_wids[SA_WINDOWS_ONLY_MAX_WIDS];  int in_n;
    uint32_t  out_wids[SA_WINDOWS_ONLY_MAX_WIDS]; int out_n;
    // AC-15: anim_owner tokens, parallel to the wid arrays. Claimed at collect
    // (seed, SA thread), presented on every per-frame write AND every settle/
    // handoff reset, released at settle/handoff. A token going stale mid-slide
    // (an anim begin re-claimed the wid for a resize) makes the slide drop
    // that window cleanly — no last-writer-wins per frame, no identity/
    // alpha-1.0 stomp at settle.
    uint64_t  in_geo[SA_WINDOWS_ONLY_MAX_WIDS],  in_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t  out_geo[SA_WINDOWS_ONLY_MAX_WIDS], out_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t  in_wp_alpha, out_wp_alpha;          // wallpaper ALPHA tokens (0 = no wallpaper)
    uint64_t  in_wp_geo, out_wp_geo;              // wallpaper GEO tokens (0 = ride disabled: lever off, unresolved, or a shared picture)
    // SPA-9: per-wid steady-state alpha (anim_baseline_capture at seed). The
    // cross-fade runs 0<->baseline instead of 0<->1, and settle/handoff restore
    // the baseline — a --opacity 0.5 window survives the switch at 0.5.
    float     in_base[SA_WINDOWS_ONLY_MAX_WIDS], out_base[SA_WINDOWS_ONLY_MAX_WIDS];
    float     in_wp_base, out_wp_base;
    // SPA-11: fade-only rows (menubar backdrops) cross-fade in place — alpha
    // writes as normal, no transform writes anywhere (per-frame or terminal).
    bool      in_fade_only[SA_WINDOWS_ONLY_MAX_WIDS], out_fade_only[SA_WINDOWS_ONLY_MAX_WIDS];
    // SPA-17: geo-only rows (the focus-ring overlay) ride the slide's Transform3D
    // but the slide NEVER writes their alpha mid-slide — the focus_ring fade owns
    // ANIM_CH_ALPHA. The inverse of fade_only; the two are mutually exclusive per
    // row. The entering side parks a ring on the destination window (SPA-17); the
    // exiting side adopts the outgoing space's live ring (SPA-21) so it slides
    // off with its windows, and settle/handoff park it dark (one-shot alpha 0).
    bool      in_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];
    bool      out_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];
    // SPA-20: Dock's black "Fullscreen Backdrop" covers (find_fullscreen_backdrops).
    // HIDDEN (alpha 0) for the slide so the scaling wallpaper shows over the exposed
    // black, then restored to 1.0 at settle/handoff. Always opaque (baseline 1.0) and
    // not contended by any other animator, so no per-wid baseline capture or AC-15 token.
    uint32_t  fs_wids[SA_FS_BACKDROP_MAX];  int fs_n;   // Dock "Fullscreen Backdrop" covers — HIDDEN for the slide so the scaling wallpaper shows over the black
    bool      fs_entering;  // true = entering a fullscreen space (in_sid fullscreen); picks scale/fade direction
    uint32_t  fs_scale_wid; // SPA-20: normal-space wallpaper that scales+fades into the abyss (out_wp on enter, in_wp on exit); 0 = none
    double    fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h; // its display rect (captured at seed) — origin baked into the 2D center-scale; scopes the masker hunt; guards the effect
    uint32_t  fs_mask_wids[SA_FS_MASK_MAX]; int fs_mask_n; // SPA-20: the OTHER identical wallpapers on this display — HIDDEN for the slide so only fs_scale_wid shows
    float     fs_min_scale;   // SPA-20 lever: collapse target (0 = point, 1 = no shrink)
    int       fs_anim_easing; // SPA-20 lever: presence-ramp curve (enum focus_ring_easing)
    double    fs_anim_dur;    // SPA-20 lever: abyss duration seconds (<=0 = track slide)
    double    fs_anim_delay;  // SPA-20 lever: seconds after slide start before the abyss begins
    bool      fs_anim_fade;   // SPA-20 lever: fade alpha with the scale
    _Atomic bool active;
    bool      committed;
    pthread_mutex_t lock;
    uint32_t  did;            // AC-7: ca_clock display this slide registered on (stale-clock guard)
    float     refresh_hz;     // panel rate shipped on the wire (ProMotion/VRR range)
    uint64_t  gen;            // AC-7: bumped per seed; the step's settle re-checks it to
                              // replace CVDisplayLinkStop's blocking interrupt guarantee
    int       easing;         // SPA: curve mode (enum focus_ring_easing) shipped per seed; payload_ease
    uint8_t   fade;           // SPACE_FADE_EXIT|SPACE_FADE_ENTER bitmask (per-side); 0 = slide only, no cross-fade
    float     enter_delay;    // SPA slide stagger (s): delay before the incoming windows start sliding in (0 = no delay)
    float     exit_delay;     // SPA slide stagger (s): delay before the outgoing windows start sliding out (0 = no delay)
    float     fade_enter_delay; // SPA fade sub-timeline (s): incoming fade delay; <0 = auto (track slide)
    float     fade_exit_delay;  // outgoing fade delay; <0 = auto (track slide)
    float     fade_enter_dur;   // incoming fade duration; <=0 = auto (ramp to slide end)
    float     fade_exit_dur;    // outgoing fade duration; <=0 = auto (ramp to slide end)
};
static struct space_cross_fade_animator g_xfade = { .lock = PTHREAD_MUTEX_INITIALIZER };

// Slide z-order (SetWindowSystemLevel, opcode 0x52 family). A per-side slide delay
// leaves both spaces co-visible — the incoming slides in while the outgoing is
// still on screen — so the incoming must render ABOVE the outgoing. We sink the
// OUTGOING windows one band BELOW normal (negative = the proven "sink below normal"
// direction; window_manager.c uses -(rank+1) for inactive windows). A positive
// level would risk punching above the menubar. Incoming windows stay at their
// natural plane (cleared each frame so a reversed retarget can't strand a window
// sunk), and the outgoing level is cleared at settle. Buffered into the pump's
// shared tx so the z-promotion lands in the same frame as the slide motion.
#define SPACE_SLIDE_OUT_SYSTEM_LEVEL (-1)
extern CGError SLSTransactionSetWindowSystemLevel(CFTypeRef transaction, uint32_t wid, int level);
extern CGError SLSTransactionClearWindowSystemLevel(CFTypeRef transaction, uint32_t wid);

// Collect the wids that ride a slide for `sid`. With animate_menubar off, the
// menubar band is special-cased (identified by tag bits 45/46 OR'd with the
// legacy window-level test 24/25, so the check fails closed): the per-space
// backdrop rides as a fade-only row — alpha cross-fades in place, never
// translated — and the global status items are excluded outright, since the
// native switch keeps the menubar geometrically fixed. Details at the band
// check in the body.
static int xfade_collect_wids(int cid, uint64_t sid, uint32_t skip_wid, uint32_t *out, bool *fade_only, int max,
                              bool animate_menubar, int active_stage)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner,
                                                       CFArrayRef spaces, uint32_t options,
                                                       uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
    extern CGError SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef key, CFTypeRef *out);
    // Stage-membership property the daemon persists per window (window.c
    // YABAI_WS_PROP_STAGE_ID). Reads are open to any connection (shared bag);
    // duplicated here because the payload is a separate translation unit.
    CFStringRef stage_prop = CFSTR("com.koekeishiya.yabai.stage_id.v1");
    int stage_excluded_n = 0;
    int count = 0;
    CFNumberRef sid_num = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    CFArrayRef space_list = sid_num ? CFArrayCreate(NULL, (const void **)&sid_num, 1, &kCFTypeArrayCallBacks) : NULL;
    if (sid_num) CFRelease(sid_num);
    if (space_list) {
        uint64_t set_tags = 0, clear_tags = 0;
        // options=0 narrows the query to the windows that should actually slide,
        // excluding the desktop furniture (NotificationCenter WidgetKit widgets,
        // etc.) that 0x7 pulls in. 0x7 = 0x1|0x2|0x4 (the broad "+minimized/desktop"
        // set the daemon uses only for include_minimized); the slide wants the
        // composited app windows, not desktop-level widgets that slid before.
        CFArrayRef w = SLSCopyWindowsWithOptionsAndTags(cid, 0, space_list, 0, &set_tags, &clear_tags);
        if (w) {
            CFIndex n = CFArrayGetCount(w);
            uint32_t excluded[8]; int excluded_n = 0;
            for (CFIndex i = 0; i < n && count < max; ++i) {
                uint32_t wid = 0;
                CFNumberGetValue(CFArrayGetValueAtIndex(w, i), kCFNumberSInt32Type, &wid);
                if (!wid || wid == skip_wid) continue;
                // AC-15: exclude windows OUR connection owns. cid here is
                // Dock's cid (the payload's), so this drops every payload
                // overlay (focus ring, GBOs, icon cards) and Dock's own sticky
                // furniture — riders that would be double-written against
                // g_focus_fade and snap back at settle. One quick SLS read per
                // wid, seed path only.
                int owner = 0;
                if (SLSGetWindowOwner(cid, wid, &owner) == kCGErrorSuccess && owner == cid) {
                    if (excluded_n < 8) excluded[excluded_n] = wid;
                    excluded_n++;
                    continue;
                }
                // Stage filter: drop windows the daemon parked on a DIFFERENT
                // stage. Without this an off-stage thumbnail rides the slide and
                // gets transformed back to identity — i.e. "revealed full-size
                // on space return" even though its stage is inactive. We only
                // exclude on a POSITIVE mismatch (property present + valid 0..15
                // + != active_stage); a window with no/invalid stage property is
                // kept (slid), so non-stage windows and unassigned (-1) windows
                // behave exactly as before. active_stage < 0 disables the filter
                // entirely (stages off / no view).
                if (active_stage >= 0) {
                    CFNumberRef sv = NULL;
                    int wstage = -1;
                    if (SLSCopyWindowProperty(cid, wid, stage_prop, (CFTypeRef *)&sv) == kCGErrorSuccess &&
                        sv && CFGetTypeID(sv) == CFNumberGetTypeID()) {
                        CFNumberGetValue(sv, kCFNumberIntType, &wstage);
                    }
                    if (sv) CFRelease(sv);
                    if (wstage >= 0 && wstage < 16 && wstage != active_stage) {
                        stage_excluded_n++;
                        continue;
                    }
                }
                // SPA-11/SPA-14 menubar band (animate_menubar on => the whole
                // band slides, no special case). Identify the band FAIL-CLOSED:
                // tag bits 45/46, read fresh per wid via SLSGetWindowTags
                // (Dock's cid has full cache coverage), OR'd with the legacy
                // window-level test (24 backdrop / 25 status item —
                // ControlCenter-owned, so the self-owned check above can't
                // catch them); if either signal is unavailable the other still
                // catches it. Within the band the LEVEL discriminates: the
                // per-space backdrop (level 24, kCGMainMenuWindowLevel) rides
                // as a fade-only row — alpha cross-fades 0<->baseline in place,
                // never translated; the global status items (level 25) are
                // excluded outright, as is any menubar window whose level read
                // FAILS (can't prove it's the backdrop). Known strand risk: an
                // interrupted slide can leave the fade-only backdrop at alpha 0
                // (invisible menubar).
                bool fade = false;
                if (!animate_menubar) {
                    uint64_t tags = 0;
                    bool is_menubar = (SLSGetWindowTags(cid, wid, &tags, 64) == kCGErrorSuccess) &&
                                      (tags & (SLS_TAG_MENUBAR_BIT | SLS_TAG_MERGES_MENUBAR_BIT));
                    int level = 0;
                    bool have_level = (SLSGetWindowLevel(cid, wid, &level) == kCGErrorSuccess);
                    if (!is_menubar && have_level)
                        is_menubar = (level == SLS_LEVEL_MENUBAR_BACKDROP ||
                                      level == SLS_LEVEL_STATUS_ITEM);
                    if (is_menubar) {
                        if (have_level && level == SLS_LEVEL_MENUBAR_BACKDROP) {
                            fade = true;   // backdrop → fade-only row (alpha in place)
                        } else {
                            if (excluded_n < 8) excluded[excluded_n] = wid;
                            excluded_n++;
                            continue;       // status items / unprovable → excluded
                        }
                    }
                }
                fade_only[count] = fade;
                out[count++] = wid;
            }
            if (excluded_n) {
                char ex[128]; size_t off = 0;
                int shown = excluded_n < 8 ? excluded_n : 8;
                for (int i = 0; i < shown && off < sizeof(ex) - 2; ++i) {
                    int k = snprintf(ex + off, sizeof(ex) - off, "%s%u", i ? "," : "", excluded[i]);
                    if (k <= 0) break;
                    off += (size_t)k;
                }
                logpf("SPACE_ANIM", "xfade collect sid=%llu excluded %d self-owned/menubar wid(s) [%s%s]",
                      sid, excluded_n, ex, excluded_n > shown ? ",..." : "");
            }
            if (stage_excluded_n) logpf("SPACE_ANIM", "xfade collect sid=%llu excluded %d off-stage wid(s) (active_stage=%d)", sid, stage_excluded_n, active_stage);
            if (n > max) logpf("SPACE_ANIM", "xfade wid cap hit on sid=%llu (%ld > %d) — overflow hard-cuts", sid, (long)n, max);
            CFRelease(w);
        }
        CFRelease(space_list);
    }
    return count;
}

// Dump the collected wid list per side at seed. One line per side per seed —
// slides are user-paced, so this is not log-hot.
static void xfade_log_collected(const char *side, uint64_t sid, uint32_t *wids, int n)
{
    char list[640]; size_t off = 0;
    int shown = n < 48 ? n : 48;
    for (int i = 0; i < shown && off < sizeof(list) - 2; ++i) {
        int w = snprintf(list + off, sizeof(list) - off, "%s%u", i ? "," : "", wids[i]);
        if (w <= 0) break;
        off += (size_t)w;
    }
    list[off < sizeof(list) ? off : sizeof(list) - 1] = '\0';
    logpf("SPACE_ANIM", "xfade collect %s sid=%llu n=%d wids=[%s%s]",
          side, sid, n, list, n > shown ? ",..." : "");
}

// Heap snapshot the settle block owns (blocks can't capture C arrays by value):
// wid lists + their AC-15 ownership tokens. The terminal SLS resets ride the
// pump's shared transaction synchronously in the step (AC-18); the deferred
// main-queue block only releases tokens (anim_release is barred from the pump
// hot path) and pokes Dock's model.
struct xfade_settle_snap {
    uint32_t in_wids[SA_WINDOWS_ONLY_MAX_WIDS],  out_wids[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t in_geo[SA_WINDOWS_ONLY_MAX_WIDS],   in_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t out_geo[SA_WINDOWS_ONLY_MAX_WIDS],  out_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t in_wp_alpha, out_wp_alpha;
    uint64_t in_wp_geo, out_wp_geo;
};

// Cede one side's claims (stale tokens no-op). Shared by the settle block and
// the handoff.
static void xfade_release_side(const uint32_t *wids, const uint64_t *geo, const uint64_t *alpha, int n)
{
    for (int i = 0; i < n; i++) {
        anim_release(wids[i], ANIM_CH_GEO,   geo[i]);
        anim_release(wids[i], ANIM_CH_ALPHA, alpha[i]);
    }
}

// AC-7 ca_clock step. Buffers each frame's transforms/alphas into the pump's
// SHARED per-VBL transaction so the slide commits in the same frame as any
// focus-ring fade riding the same clock. SLSCopyManagedDisplayForSpace happens
// only in the settle branch — per frame it would be a blocking SLS round-trip
// on the pump thread under clients_lock (the AC-4 hazard). Returns true once
// it has committed the settle (or is inactive / on a stale clock) so the pump
// deactivates it.
static bool space_cross_fade_animator_ca_step(void *ctx, CFTypeRef pump_tx, uint32_t pump_did)
{
    struct space_cross_fade_animator *a = (struct space_cross_fade_animator *)ctx;
    if (!atomic_load(&a->active)) return true;   // post-settle / post-handoff → settle

    pthread_mutex_lock(&a->lock);
    int      cid = a->cid;
    uint64_t out_sid = a->out_sid, in_sid = a->in_sid;
    int      direction = a->direction;
    double   width = a->width, dur = a->duration, mach_to_s = a->mach_to_s;
    int      easing = a->easing;
    bool     fade_enter = (a->fade & SPACE_FADE_ENTER) != 0;   // incoming windows fade in  (gates win_ae)
    bool     fade_exit  = (a->fade & SPACE_FADE_EXIT)  != 0;   // outgoing windows fade out (gates win_aeo)
    double   enter_delay = (double)a->enter_delay, exit_delay = (double)a->exit_delay;   // SPA slide stagger (s)
    double   fade_enter_delay = (double)a->fade_enter_delay, fade_exit_delay = (double)a->fade_exit_delay;   // SPA fade sub-timeline (s)
    double   fade_enter_dur   = (double)a->fade_enter_dur,   fade_exit_dur   = (double)a->fade_exit_dur;
    uint64_t start_t = a->start_mach_time;
    int      in_n = a->in_n, out_n = a->out_n;
    uint32_t in_wids[SA_WINDOWS_ONLY_MAX_WIDS], out_wids[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_wids,  a->in_wids,  sizeof(uint32_t) * in_n);
    memcpy(out_wids, a->out_wids, sizeof(uint32_t) * out_n);
    uint64_t in_geo[SA_WINDOWS_ONLY_MAX_WIDS],  in_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t out_geo[SA_WINDOWS_ONLY_MAX_WIDS], out_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_geo,    a->in_geo,    sizeof(uint64_t) * in_n);
    memcpy(in_alpha,  a->in_alpha,  sizeof(uint64_t) * in_n);
    memcpy(out_geo,   a->out_geo,   sizeof(uint64_t) * out_n);
    memcpy(out_alpha, a->out_alpha, sizeof(uint64_t) * out_n);
    float in_base[SA_WINDOWS_ONLY_MAX_WIDS], out_base[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_base,  a->in_base,  sizeof(float) * in_n);
    memcpy(out_base, a->out_base, sizeof(float) * out_n);
    bool in_fade_only[SA_WINDOWS_ONLY_MAX_WIDS], out_fade_only[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_fade_only,  a->in_fade_only,  sizeof(bool) * in_n);
    memcpy(out_fade_only, a->out_fade_only, sizeof(bool) * out_n);
    bool in_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];        // SPA-17: ring rider — transform yes, alpha no
    memcpy(in_geo_only,   a->in_geo_only,   sizeof(bool) * in_n);
    bool out_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];       // SPA-21: exit ring rider
    memcpy(out_geo_only,  a->out_geo_only,  sizeof(bool) * out_n);
    float    in_wp_base = a->in_wp_base, out_wp_base = a->out_wp_base;
    uint64_t in_wp_alpha = a->in_wp_alpha, out_wp_alpha = a->out_wp_alpha;
    uint64_t in_wp_geo = a->in_wp_geo, out_wp_geo = a->out_wp_geo;
    uint32_t in_wp = a->in_wp, out_wp = a->out_wp;
    bool     wallpaper = a->wallpaper;
    int      fs_n = a->fs_n;
    uint32_t fs_wids[SA_FS_BACKDROP_MAX];
    memcpy(fs_wids, a->fs_wids, sizeof(uint32_t) * fs_n);
    bool     fs_entering = a->fs_entering;
    uint32_t fs_scale_wid = a->fs_scale_wid;
    double   fs_wp_x = a->fs_wp_x, fs_wp_y = a->fs_wp_y, fs_wp_w = a->fs_wp_w, fs_wp_h = a->fs_wp_h;
    int      fs_mask_n = a->fs_mask_n;
    uint32_t fs_mask_wids[SA_FS_MASK_MAX];
    memcpy(fs_mask_wids, a->fs_mask_wids, sizeof(uint32_t) * fs_mask_n);
    float    fs_min_scale = a->fs_min_scale;
    int      fs_anim_easing = a->fs_anim_easing;
    double   fs_anim_dur = a->fs_anim_dur, fs_anim_delay = a->fs_anim_delay;
    bool     fs_anim_fade = a->fs_anim_fade;
    uint64_t snap_gen  = a->gen;     // AC-5-style guard: the seed bumps a->gen
    uint32_t adid      = a->did;
    pthread_mutex_unlock(&a->lock);

    // Stale-clock guard: slide re-seeded on a different display → release
    // this clock's slot; the current clock keeps driving it.
    if (pump_did != adid) return true;

    double t = 0.0;
    double e = anim_eased_p(0.0, 1, start_t, dur, mach_to_s, &t, easing);
    bool settled = (t >= 1.0);

    // Per-side SLIDE stagger: each space's windows slide on their OWN sub-timeline —
    // delayed start, ramping to the slide end with the slide curve — so one space can
    // lead and the other trail (a geometric hand-off). delay(s) -> slide fraction;
    // zero delay => payload_ease(easing, t) == e => an exact no-op. This offsets the
    // WINDOWS (Transform3D), NOT their opacity: the alpha below stays on the shared
    // timeline (the fade lever), and the wallpaper ride keeps the shared timeline too.
    double edf = dur > 0.0 ? enter_delay / dur : 0.0;   // enter delay as a slide fraction
    double xdf = dur > 0.0 ? exit_delay  / dur : 0.0;   // exit  delay as a slide fraction
    double es  = 1.0 - edf, xs = 1.0 - xdf;             // span left after the delay
    double er  = es > 1e-6 ? (t - edf) / es : (t >= edf ? 1.0 : 0.0);
    double xr  = xs > 1e-6 ? (t - xdf) / xs : (t >= xdf ? 1.0 : 0.0);
    er = er < 0.0 ? 0.0 : (er > 1.0 ? 1.0 : er);
    xr = xr < 0.0 ? 0.0 : (xr > 1.0 ? 1.0 : xr);
    double e_enter = payload_ease(easing, er);   // incoming slide progress (delayed)
    double e_exit  = payload_ease(easing, xr);   // outgoing slide progress (delayed)
    double entering_dx =  (double)direction * width * (1.0 - e_enter);
    double leaving_dx  = -(double)direction * width * e_exit;
    double Min[16]  = { 1,0,0,0, 0,1,0,0, 0,0,1,0, entering_dx,0,0,1 };
    double Mout[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, leaving_dx, 0,0,1 };

    // Cross-fade alpha is driven MANUALLY per frame with instant SLSTransactionSetWindowAlpha
    // (entering 0->1, leaving 1->0) — same idiom as focus_ring. We deliberately do NOT use
    // SLSTransactionSetWindowAlphaAnimated: its server-side fade completion (CGXWindow::fade_finish)
    // crashed WindowServer when a later alpha op finalized the in-flight fade.
    // SPA-9: these are fade FRACTIONS — each write scales by the wid's captured
    // steady-state alpha (entering 0->baseline, leaving baseline->0), so a
    // 0.5-opacity window never overshoots to 1.0 mid-slide.
    float ae  = (float)(e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e));   // entering fade fraction
    float aeo = 1.0f - ae;                                       // leaving fade fraction
    // SPA: `fade` off → windows ride the slide at full baseline opacity (no
    // cross-fade). The fade-only menubar rows (see the (fade_only ? ae : win_ae)
    // splits below) deliberately keep using the raw ae/aeo so they cross-fade over
    // the slide duration INDEPENDENT of this window-only lever — the menubar fades
    // even when window `fade` is off (menubar decouple).
    // Window fade runs on its OWN per-side sub-timeline (delay + duration),
    // decoupled from the slide. Each knob AUTO-tracks the slide when unset:
    // fade delay < 0 → the side's slide delay; fade dur <= 0 → ramp to the slide
    // end. All-auto ⇒ fer/fxr == the slide's er/xr ⇒ the fade exactly tracks the
    // Transform3D (an exact no-op). (The fade-only menubar rows keep the raw
    // shared ae/aeo above — full-duration cross-fade regardless.)
    double fade_now_s = t * dur;
    double fed = fade_enter_delay >= 0.0 ? fade_enter_delay : enter_delay;   // auto delay = the side's slide delay
    double fxd = fade_exit_delay  >= 0.0 ? fade_exit_delay  : exit_delay;
    double fedur = fade_enter_dur > 0.0 ? fade_enter_dur : (dur - fed);      // auto dur = ramp to the slide end
    double fxdur = fade_exit_dur  > 0.0 ? fade_exit_dur  : (dur - fxd);
    double fer = fedur > 1e-6 ? (fade_now_s - fed) / fedur : (fade_now_s >= fed ? 1.0 : 0.0);
    double fxr = fxdur > 1e-6 ? (fade_now_s - fxd) / fxdur : (fade_now_s >= fxd ? 1.0 : 0.0);
    fer = fer < 0.0 ? 0.0 : (fer > 1.0 ? 1.0 : fer);
    fxr = fxr < 0.0 ? 0.0 : (fxr > 1.0 ? 1.0 : fxr);
    float win_ae  = fade_enter ? (float)payload_ease(easing, fer)         : 1.0f;   // incoming fade-in on its own timeline
    float win_aeo = fade_exit  ? (float)(1.0 - payload_ease(easing, fxr)) : 1.0f;   // outgoing fade-out on its own timeline

    // Buffer the frame into the pump's SHARED tx (ShowSpace/IsAnimating were asserted
    // ONCE at seed — never re-assert per frame). pump_tx is NULL when the pump's
    // create failed this tick: skip the frame writes (one dropped slide frame;
    // the settle below also requires pump_tx) and retry next VBL.
    // AC-15: every write presents its ownership token. anim_owns is lock-free
    // (safe on the pump); a wid whose token went stale (an anim resize began
    // mid-slide and re-claimed it) is simply no longer carried by the slide —
    // the resize animator owns its geometry/alpha now.
    if (pump_tx) {
        for (int i = 0; i < in_n;  i++) {
            if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, in_wids[i],  Min);
            if (!in_geo_only[i] && anim_owns(in_wids[i],  ANIM_CH_ALPHA, in_alpha[i]))  SLSTransactionSetWindowSystemAlpha(pump_tx, in_wids[i],  (in_fade_only[i] ? ae : win_ae) * in_base[i]);
            if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionClearWindowSystemLevel(pump_tx, in_wids[i]);   // z: keep incoming at its natural plane (self-corrects a reversed retarget)
        }
        for (int i = 0; i < out_n; i++) {
            if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, out_wids[i], Mout);
            if (anim_owns(out_wids[i], ANIM_CH_ALPHA, out_alpha[i])) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wids[i], (out_fade_only[i] ? aeo : win_aeo) * out_base[i]);
            if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowSystemLevel(pump_tx, out_wids[i], SPACE_SLIDE_OUT_SYSTEM_LEVEL);   // z: sink outgoing below the incoming
        }
        if (wallpaper) {   // wallpapers ride the slide with their spaces, native-style (off path
            // leaves both as a static backdrop). Driven by the SHARED slide progress `e`,
            // NOT the per-side staggered Min/Mout — the same fraction on both sides keeps
            // the two pictures seamlessly adjacent while staggered windows move over them.
            // Token 0 (ride disabled at seed) skips the writes; skip fs_scale_wid too — on
            // a fullscreen transition the abyss block below owns it.
            double Win[16]  = { 1,0,0,0, 0,1,0,0, 0,0,1,0,  (double)direction * width * (1.0 - e),0,0,1 };
            double Wout[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, -(double)direction * width * e,        0,0,1 };
            if (in_wp  && in_wp  != fs_scale_wid && anim_owns(in_wp,  ANIM_CH_GEO, in_wp_geo))  SLSTransactionSetWindowTransform3D(pump_tx, in_wp,  Win);
            if (out_wp && out_wp != fs_scale_wid && anim_owns(out_wp, ANIM_CH_GEO, out_wp_geo)) SLSTransactionSetWindowTransform3D(pump_tx, out_wp, Wout);
        }
        // SPA-20: fullscreen enter/exit — the normal-space wallpaper "recedes into the
        // abyss". The Dock backdrop AND every other identical wallpaper on this display
        // are hidden at seed (restored at settle/handoff), so ONLY this wid shows over
        // the exposed black. It center-scales AND fades on one presence ramp: shrink+fade
        // into black on enter, zoom+fade up on exit. p_wp = presence (1 full → 0 gone).
        // Uses the picture's native 2D screen→local transform (origin baked in via
        // fs_abyss_xform) — a bare 3D scale slid the D2 picture off because it ignored
        // the wallpaper's existing translate(-origin). S floored so 1/S stays finite.
        if (fs_scale_wid && fs_wp_w > 0.0 && fs_wp_h > 0.0) {
            // Abyss progress on its OWN timeline (lever duration + delay), independent of
            // the slide's eased position; eased through the lever curve. presence: 1 full
            // → 0 gone. The wid is the OUTGOING wallpaper on enter (so a settle-reset to
            // natural is invisible) and the INCOMING one on exit (ends at presence 1).
            double   elapsed_s = (double)(mach_absolute_time() - start_t) * mach_to_s;
            double   ad = fs_anim_dur > 0.0 ? fs_anim_dur : dur;   // <=0 → track slide
            double   ap = ad > 0.0 ? (elapsed_s - fs_anim_delay) / ad : 1.0;
            if (ap < 0.0) ap = 0.0; if (ap > 1.0) ap = 1.0;
            double   eased = payload_ease(fs_anim_easing, ap);
            float    p_wp  = fs_entering ? (float)(1.0 - eased) : (float)eased;
            double   S     = fmax((double)fs_min_scale + (1.0 - (double)fs_min_scale) * (double)p_wp, 0.02);
            SLSTransactionSetWindowTransform(pump_tx, fs_scale_wid, 0, 0, fs_abyss_xform(fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h, S));
            uint64_t fs_alpha = fs_entering ? out_wp_alpha : in_wp_alpha;
            float    fs_base  = fs_entering ? out_wp_base  : in_wp_base;
            float    a_frac   = fs_anim_fade ? p_wp : 1.0f;   // fade lever off → scale only, full alpha
            if (anim_owns(fs_scale_wid, ANIM_CH_ALPHA, fs_alpha)) SLSTransactionSetWindowSystemAlpha(pump_tx, fs_scale_wid, a_frac * fs_base);
        }
    }

    pthread_mutex_lock(&a->lock);
    // Gen guard: a new seed (interrupt) bumps a->gen and resets committed=false, so
    // an in-flight step that snapshotted the OLD hop must NOT settle-commit it — the
    // committed-only check is insufficient (the seed cleared committed). Stale gen =>
    // no settle. This replaces CVDisplayLinkStop's blocking "no callback after stop".
    // AC-18: settling also requires pump_tx — the terminal cut rides the SHARED
    // per-VBL transaction below. No tx this tick → keep ticking, settle next VBL.
    bool do_settle = settled && pump_tx && !a->committed && (a->gen == snap_gen);
    if (do_settle) {
        a->committed = true;
        atomic_store(&a->active, false);
    }
    pthread_mutex_unlock(&a->lock);

    // Not settled, or superseded by a newer hop (which re-registered/re-activated
    // this client) → keep the slot ticking. A genuinely inactive client is caught by
    // the !active check at the top of the next tick.
    if (!do_settle) return false;

    // Settle-only: the managed-display UUID round-trip happens here, not per frame.
    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    uint64_t target_sid = in_sid, src_sid = out_sid;

    // ONE atomic cut, IN the pump's shared transaction: identity transforms, baseline
    // alphas (SPA-9: each wid's captured steady state, not 1.0), both wallpapers,
    // current-space switch, hide the outgoing space, clear IsAnimating. Single-tx
    // keeps the anti-flash atomicity (split commits show the new space for a frame
    // before the alphas land). Riding pump_tx — rather than a separate main-queue
    // tx — is the stale-frame fix: this tick's frame writes were buffered above and
    // these later writes override them in the SAME commit, so the settle can never
    // lose a commit race against its own final frame and strand the outgoing side
    // at alpha≈0.
    // AC-15 gates: per-wid resets present their tokens; the hop-level ops
    // (current-space switch, HideSpace, IsAnimating) are not per-wid and stay
    // unconditional. A takeover landing between these checks and the pump's commit
    // still stomps for one frame — accepted transient.
    double I[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
    for (int i = 0; i < in_n;  i++) {
        if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, in_wids[i],  I);
        if (!in_geo_only[i] && anim_owns(in_wids[i],  ANIM_CH_ALPHA, in_alpha[i]))  SLSTransactionSetWindowSystemAlpha(pump_tx, in_wids[i],  in_base[i]);
    }
    for (int i = 0; i < out_n; i++) {
        if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, out_wids[i], I);
        if (anim_owns(out_wids[i], ANIM_CH_ALPHA, out_alpha[i])) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wids[i], out_base[i]);
        if (out_geo_only[i]) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wids[i], 0.0f);   // SPA-21: park the exit-ridden ring dark at slide end
        if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionClearWindowSystemLevel(pump_tx, out_wids[i]);   // z: restore outgoing to its natural plane
    }
    if (in_wp  && anim_owns(in_wp,  ANIM_CH_ALPHA, in_wp_alpha))  SLSTransactionSetWindowSystemAlpha(pump_tx, in_wp,  in_wp_base);
    if (out_wp && anim_owns(out_wp, ANIM_CH_ALPHA, out_wp_alpha)) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wp, out_wp_base);
    // Riding wallpapers land at identity T3D with their windows (token 0 = ride
    // disabled → no-op; fs_scale_wid's 2D transform is restored separately below).
    if (in_wp  && in_wp  != fs_scale_wid && anim_owns(in_wp,  ANIM_CH_GEO, in_wp_geo))  SLSTransactionSetWindowTransform3D(pump_tx, in_wp,  I);
    if (out_wp && out_wp != fs_scale_wid && anim_owns(out_wp, ANIM_CH_GEO, out_wp_geo)) SLSTransactionSetWindowTransform3D(pump_tx, out_wp, I);
    // SPA-20: restore Dock's Fullscreen Backdrop to opaque (it's the fullscreen
    // presentation's backdrop for next time; invisible now on the background space).
    for (int i = 0; i < fs_n; i++)
        SLSTransactionSetWindowSystemAlpha(pump_tx, fs_wids[i], 1.0f);
    for (int i = 0; i < fs_mask_n; i++)
        SLSTransactionSetWindowSystemAlpha(pump_tx, fs_mask_wids[i], 1.0f);   // SPA-20: un-hide the masked wallpapers
    // SPA-20: restore the picture's NATURAL 2D transform (translate(-origin)), NOT 3D
    // identity — a bare identity would drop the -origin and park the D2 picture on D1.
    if (fs_scale_wid) SLSTransactionSetWindowTransform(pump_tx, fs_scale_wid, 0, 0, fs_abyss_xform(fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h, 1.0));
    if (uuid) SLSTransactionSetManagedDisplayCurrentSpace(pump_tx, uuid, target_sid);
    SLSTransactionHideSpace(pump_tx, src_sid);
    if (uuid) SLSTransactionSetManagedDisplayIsAnimating(pump_tx, uuid, false);

    // Deferred main-queue work: token release (anim_release is barred from the
    // pump hot path), the Dock model poke, and logging. malloc failure leaks
    // the tokens until the next claim bumps them — no visual reset is skipped.
    struct xfade_settle_snap *snap = malloc(sizeof(*snap));
    if (snap) {
        memcpy(snap->in_wids,   in_wids,   sizeof(uint32_t) * in_n);
        memcpy(snap->out_wids,  out_wids,  sizeof(uint32_t) * out_n);
        memcpy(snap->in_geo,    in_geo,    sizeof(uint64_t) * in_n);
        memcpy(snap->in_alpha,  in_alpha,  sizeof(uint64_t) * in_n);
        memcpy(snap->out_geo,   out_geo,   sizeof(uint64_t) * out_n);
        memcpy(snap->out_alpha, out_alpha, sizeof(uint64_t) * out_n);
        snap->in_wp_alpha  = in_wp_alpha;
        snap->out_wp_alpha = out_wp_alpha;
        snap->in_wp_geo    = in_wp_geo;
        snap->out_wp_geo   = out_wp_geo;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        // No superseded-guard needed: the settle's SLS state was committed
        // synchronously in the pump's transaction above, so there is no deferred
        // visual work a newer seed could resurrect — a seed landing after
        // do_settle starts from the committed state and re-claims forward (these
        // releases then go stale and no-op).
        if (snap) {
            xfade_release_side(snap->in_wids,  snap->in_geo,  snap->in_alpha,  in_n);
            xfade_release_side(snap->out_wids, snap->out_geo, snap->out_alpha, out_n);
            if (in_wp  && snap->in_wp_alpha)  anim_release(in_wp,  ANIM_CH_ALPHA, snap->in_wp_alpha);
            if (out_wp && snap->out_wp_alpha) anim_release(out_wp, ANIM_CH_ALPHA, snap->out_wp_alpha);
            if (in_wp  && snap->in_wp_geo)    anim_release(in_wp,  ANIM_CH_GEO,   snap->in_wp_geo);
            if (out_wp && snap->out_wp_geo)   anim_release(out_wp, ANIM_CH_GEO,   snap->out_wp_geo);
        }

        // Repaint Dock's model so the MC strip thumbnail tracks the switch
        // (resolve container by display UUID — the native settle idiom).
        if (uuid && dock_spaces != nil) {
            id dest_space    = space_for_display_with_id(uuid, target_sid);
            id display_space = display_space_for_display_uuid(uuid);
            if (dest_space != nil && display_space != nil)
                set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
        }
        if (uuid) {
            uint64_t mc_current = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), uuid);
            logpf("SPACE_ANIM", "xfade settle COMMIT target=%llu mc_current=%llu%s",
                  target_sid, mc_current, mc_current == target_sid ? "" : " (MISMATCH)");
            CFRelease(uuid);
        }
        free(snap);
    });
    return true;   // settled & committed → pump deactivates this client
}

// Hand an in-flight cross-fade off to the NEXT hop WITHOUT committing the space
// change. Lands the current hop's windows visually (reset to identity+opaque so
// the target snaps into place — this is the "flick") and hides the space we're
// leaving, but deliberately does NOT touch SetManagedDisplayCurrentSpace,
// IsAnimating, or Dock's _currentSpace ivar. Those three are the per-switch Dock
// MUTATION that races Dock's bookkeeping when you spam; firing them on every
// interrupt was the instability. They now happen exactly ONCE, at the real settle
// (callback t>=1, the last hop with no follow-up press). HideSpace is visibility-
// only (not a model mutation) so it's safe per-hop and keeps shown spaces from
// piling up. Runs inline on the SA handler thread; after it returns the animator
// is idle (active=false) and the caller seeds the next hop. No-op if not active.
static void xfade_handoff_no_commit(struct space_cross_fade_animator *a)
{
    pthread_mutex_lock(&a->lock);
    if (!atomic_load(&a->active)) { pthread_mutex_unlock(&a->lock); return; }
    int      cid = a->cid;
    uint32_t hdid = a->did;
    uint64_t src_sid = a->out_sid;
    int      in_n = a->in_n, out_n = a->out_n;
    uint32_t in_wids[SA_WINDOWS_ONLY_MAX_WIDS], out_wids[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_wids,  a->in_wids,  sizeof(uint32_t) * in_n);
    memcpy(out_wids, a->out_wids, sizeof(uint32_t) * out_n);
    uint64_t in_geo[SA_WINDOWS_ONLY_MAX_WIDS],  in_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t out_geo[SA_WINDOWS_ONLY_MAX_WIDS], out_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_geo,    a->in_geo,    sizeof(uint64_t) * in_n);
    memcpy(in_alpha,  a->in_alpha,  sizeof(uint64_t) * in_n);
    memcpy(out_geo,   a->out_geo,   sizeof(uint64_t) * out_n);
    memcpy(out_alpha, a->out_alpha, sizeof(uint64_t) * out_n);
    float in_base[SA_WINDOWS_ONLY_MAX_WIDS], out_base[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_base,  a->in_base,  sizeof(float) * in_n);
    memcpy(out_base, a->out_base, sizeof(float) * out_n);
    bool in_fade_only[SA_WINDOWS_ONLY_MAX_WIDS], out_fade_only[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_fade_only,  a->in_fade_only,  sizeof(bool) * in_n);
    memcpy(out_fade_only, a->out_fade_only, sizeof(bool) * out_n);
    bool in_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];        // SPA-17: ring rider — transform yes, alpha no
    memcpy(in_geo_only,   a->in_geo_only,   sizeof(bool) * in_n);
    bool out_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];       // SPA-21: exit ring rider
    memcpy(out_geo_only,  a->out_geo_only,  sizeof(bool) * out_n);
    float    in_wp_base = a->in_wp_base, out_wp_base = a->out_wp_base;
    uint64_t in_wp_alpha = a->in_wp_alpha, out_wp_alpha = a->out_wp_alpha;
    uint64_t in_wp_geo = a->in_wp_geo, out_wp_geo = a->out_wp_geo;
    uint32_t in_wp = a->in_wp, out_wp = a->out_wp;
    int      fs_n = a->fs_n;
    uint32_t fs_wids[SA_FS_BACKDROP_MAX];
    memcpy(fs_wids, a->fs_wids, sizeof(uint32_t) * fs_n);
    uint32_t fs_scale_wid = a->fs_scale_wid;
    double   fs_wp_x = a->fs_wp_x, fs_wp_y = a->fs_wp_y, fs_wp_w = a->fs_wp_w, fs_wp_h = a->fs_wp_h;
    int      fs_mask_n = a->fs_mask_n;
    uint32_t fs_mask_wids[SA_FS_MASK_MAX];
    memcpy(fs_mask_wids, a->fs_mask_wids, sizeof(uint32_t) * fs_mask_n);
    // A slide can hit t>=1 at the same instant a new press takes this handoff;
    // committed must be cleared (and gen bumped, below) so the old hop cannot
    // stray-commit — committing the OLD target and resetting its windows
    // mid-new-slide would strand a window off-screen. The seed about to run
    // re-arms committed=false for the new hop.
    a->committed = false;
    atomic_store(&a->active, false);
    // AC-7: bump gen HERE (not only at seed). A pump step mid-flight on the OLD
    // hop can reach its settle check between this handoff (committed=false) and
    // the seed's gen bump — and with committed cleared it would stray-commit the
    // old hop. The step snapshotted the pre-handoff gen, so bumping now makes its
    // `a->gen == snap_gen` settle guard fail immediately. The step is a ca_clock
    // client: active=false settles it out at the next tick's top check, and the
    // seed re-registers (idempotent) for the new hop.
    a->gen++;
    pthread_mutex_unlock(&a->lock);

    // AC-18: a pump tick may be mid-flight with this hop's mid-fade frame already
    // BUFFERED into the shared transaction — anim_owns gated those writes at buffer
    // time, and the gen bump above cannot recall them. Wait (bounded) for that tick
    // to finish committing so the restore below lands after it; otherwise the stale
    // frame commits LAST and re-strands the abandoned side at mid-fade alpha.
    ca_clock_wait_tick_idle(hdid);

    double I[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
    CFTypeRef tx = SLSTransactionCreate(cid);
    // The arriving target's windows land at identity+opaque (they become the next
    // hop's leaving set); the leaving space's windows are cleaned then its space
    // hidden. No managed-display current-space / IsAnimating / Dock poke here.
    // AC-15: each per-wid reset gated on its token (an anim takeover keeps
    // its geometry/alpha); HideSpace stays unconditional (hop-level).
    // NULL tx: terminal restore is lost (nothing to fall back to) — log loudly,
    // but the token releases below MUST still run or the next hop can't claim.
    if (tx) {
        for (int i = 0; i < in_n;  i++) {
            if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionSetWindowTransform3D(tx, in_wids[i],  I);
            if (!in_geo_only[i] && anim_owns(in_wids[i],  ANIM_CH_ALPHA, in_alpha[i]))  SLSTransactionSetWindowSystemAlpha(tx, in_wids[i],  in_base[i]);   // SPA-9: land at baseline, not 1.0
        }
        for (int i = 0; i < out_n; i++) {
            if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowTransform3D(tx, out_wids[i], I);
            if (anim_owns(out_wids[i], ANIM_CH_ALPHA, out_alpha[i])) SLSTransactionSetWindowSystemAlpha(tx, out_wids[i], out_base[i]);
            if (out_geo_only[i]) SLSTransactionSetWindowSystemAlpha(tx, out_wids[i], 0.0f);   // SPA-21: park the exit-ridden ring dark
        }
        if (in_wp  && anim_owns(in_wp,  ANIM_CH_ALPHA, in_wp_alpha))  SLSTransactionSetWindowSystemAlpha(tx, in_wp,  in_wp_base);
        if (out_wp && anim_owns(out_wp, ANIM_CH_ALPHA, out_wp_alpha)) SLSTransactionSetWindowSystemAlpha(tx, out_wp, out_wp_base);
        // Riding wallpapers land at identity — the arriving picture becomes the next
        // hop's leaving one and must start from natural placement (token 0 no-ops).
        if (in_wp  && in_wp  != fs_scale_wid && anim_owns(in_wp,  ANIM_CH_GEO, in_wp_geo))  SLSTransactionSetWindowTransform3D(tx, in_wp,  I);
        if (out_wp && out_wp != fs_scale_wid && anim_owns(out_wp, ANIM_CH_GEO, out_wp_geo)) SLSTransactionSetWindowTransform3D(tx, out_wp, I);
        for (int i = 0; i < fs_n; i++) SLSTransactionSetWindowSystemAlpha(tx, fs_wids[i], 1.0f);   // SPA-20: restore on interrupt
        for (int i = 0; i < fs_mask_n; i++) SLSTransactionSetWindowSystemAlpha(tx, fs_mask_wids[i], 1.0f);   // SPA-20: un-hide masked wallpapers
        if (fs_scale_wid) SLSTransactionSetWindowTransform(tx, fs_scale_wid, 0, 0, fs_abyss_xform(fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h, 1.0));   // SPA-20: restore natural 2D transform
        SLSTransactionHideSpace(tx, src_sid);
        SLSTransactionCommit(tx, 0);
        CFRelease(tx);
    } else {
        logpf("SPACE_ANIM", "xfade handoff: SLSTransactionCreate FAIL — terminal restore lost src=%llu", src_sid);
    }

    // Cede every claim this hop held (SA handler thread — inline is fine).
    // The seed about to run re-claims fresh tokens for the next hop; stale
    // (taken-over) tokens no-op.
    xfade_release_side(in_wids,  in_geo,  in_alpha,  in_n);
    xfade_release_side(out_wids, out_geo, out_alpha, out_n);
    if (in_wp  && in_wp_alpha)  anim_release(in_wp,  ANIM_CH_ALPHA, in_wp_alpha);
    if (out_wp && out_wp_alpha) anim_release(out_wp, ANIM_CH_ALPHA, out_wp_alpha);
    if (in_wp  && in_wp_geo)    anim_release(in_wp,  ANIM_CH_GEO,   in_wp_geo);
    if (out_wp && out_wp_geo)   anim_release(out_wp, ANIM_CH_GEO,   out_wp_geo);
    logpf("SPACE_ANIM", "xfade handoff (no commit) leaving src=%llu", src_sid);
}

static void space_cross_fade_animator_start(int cid, uint64_t out_sid, uint64_t in_sid,
                                            int direction, double width, double duration, bool wallpaper,
                                            bool animate_menubar, uint32_t did, float refresh_hz,
                                            int out_active_stage, int in_active_stage, int easing, uint8_t fade,
                                            uint32_t ring_wid, CGRect ring_rect, float ring_radius,
                                            bool fs_enabled, float fs_scale, int fs_easing,
                                            double fs_duration, double fs_delay, bool fs_fade,
                                            float enter_delay, float exit_delay,
                                            float fade_enter_delay, float fade_exit_delay,
                                            float fade_enter_dur, float fade_exit_dur)
{
    struct space_cross_fade_animator *a = &g_xfade;

    // AC-8: force any in-flight LB+T3D window resize to its terminal state BEFORE
    // the slide takes over those wids. A window still pinned by SLSTransactionSet-
    // WindowLockedBounds at its mid-resize size keeps that size after the cross-fade
    // clears its (replaced) transform at settle → it lands floating at the wrong
    // size. skip_all_to_end finishes the resize (commits end AX frame) and clears
    // LB/T3D, so the slide starts from clean, settled windows.
    anim_skip_all_to_end();

    // Interruptible: if a slide is already running, snap it to its committed end
    // (instant) and take over — a mid-slide press cuts the current slide short
    // and advances immediately, instead of being dropped. Spam => fast cuts
    // through intermediates; the last press (no follow-up) plays its full slide.
    uint32_t prev_did = a->did;   // previous hop's clock (0 before the first seed)
    if (atomic_load(&a->active)) {
        xfade_handoff_no_commit(a);
        logpf("SPACE_ANIM", "xfade retarget in=%llu (handed off prior slide, no commit)", in_sid);
    }

    // AC-18: fence the previous hop's clock even when NO handoff ran — a hop that
    // just settled (active already false) may still have its settle tick mid-commit,
    // and its token release on the main queue can land before that commit. Capturing
    // baselines through that window reads the leaving side's pre-terminal alpha (≈0)
    // and poisons the restore target. Post-fence, the terminal state is on the
    // server and the captures below read steady state. (After a handoff this
    // re-checks an already-idle clock — effectively free.)
    ca_clock_wait_tick_idle(prev_did);

    pthread_mutex_lock(&a->lock);
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    a->cid = cid; a->out_sid = out_sid; a->in_sid = in_sid; a->direction = direction;
    a->width = width; a->duration = duration > 0.0 ? duration : SPACE_ANIM_DEFAULT_DURATION_S;
    a->mach_to_s = (double)tb.numer / ((double)tb.denom * 1e9);
    a->wallpaper = wallpaper; a->committed = false;
    a->did = did; a->refresh_hz = refresh_hz; a->easing = easing; a->fade = fade;
    a->enter_delay = enter_delay; a->exit_delay = exit_delay;
    a->fade_enter_delay = fade_enter_delay; a->fade_exit_delay = fade_exit_delay;
    a->fade_enter_dur = fade_enter_dur; a->fade_exit_dur = fade_exit_dur;
    a->fs_min_scale = fs_scale; a->fs_anim_easing = fs_easing;
    a->fs_anim_dur = fs_duration; a->fs_anim_delay = fs_delay; a->fs_anim_fade = fs_fade;
    a->gen++;   // new hop generation — the step's settle re-checks this (AC-5-style guard)
    pthread_mutex_unlock(&a->lock);

    // Collect wids BEFORE ShowSpace — SLSCopyWindowsWithOptionsAndTags keys off the
    // sid and does NOT require the space to be composited, so there's no reason to
    // pay these round-trips after revealing the space.
    a->in_wp  = find_wallpaper_wid_for_space(in_sid);
    a->out_wp = find_wallpaper_wid_for_space(out_sid);
    a->in_n  = xfade_collect_wids(cid, in_sid,  a->in_wp,  a->in_wids,  a->in_fade_only,  SA_WINDOWS_ONLY_MAX_WIDS, animate_menubar, in_active_stage);
    a->out_n = xfade_collect_wids(cid, out_sid, a->out_wp, a->out_wids, a->out_fade_only, SA_WINDOWS_ONLY_MAX_WIDS, animate_menubar, out_active_stage);

    // SPA-17: collected windows are full riders (transform + alpha); clear geo_only
    // for all, then inject the focus-ring overlay as a geo-only rider on the
    // entering side. Parked on the destination's focused window at its natural rect
    // (ring_rect), the ring rides the uniform entering Min translate in lockstep —
    // the slide drives only its Transform3D, the focus_ring fade owns its alpha.
    for (int i = 0; i < a->in_n; i++) a->in_geo_only[i] = false;
    if (ring_wid != 0 && a->in_n < SA_WINDOWS_ONLY_MAX_WIDS) {
        uint32_t ring_overlay = payload_focus_ring_park_for_slide(cid, ring_wid, ring_rect, ring_radius, in_sid);
        if (ring_overlay != 0) {
            int idx = a->in_n;
            a->in_wids[idx]      = ring_overlay;
            a->in_fade_only[idx] = false;
            a->in_geo_only[idx]  = true;
            a->in_n++;
            logpf("SPACE_ANIM", "xfade geo-rider: ring overlay=%u on target=%u", ring_overlay, ring_wid);
        }
    }

    // SPA-21 exit-ride: adopt the outgoing space's live ring as a geo-only rider
    // so it slides OFF with the exiting windows instead of vanishing at slide
    // start. GEO claimed below; its alpha is untouched mid-slide (token 0 skips
    // every alpha write) — settle/handoff park it dark at the slide's end. Runs
    // AFTER the in-side park above: a full pool's LRU acquire can evict the
    // outgoing entry, and this post-park lookup reflects that.
    for (int i = 0; i < a->out_n; i++) a->out_geo_only[i] = false;
    if (a->out_n < SA_WINDOWS_ONLY_MAX_WIDS) {
        uint32_t exit_ring = payload_focus_ring_adopt_for_exit(out_sid);
        if (exit_ring != 0) {
            int idx = a->out_n;
            a->out_wids[idx]      = exit_ring;
            a->out_fade_only[idx] = false;
            a->out_geo_only[idx]  = true;
            a->out_n++;
            logpf("SPACE_ANIM", "xfade exit-rider: ring overlay=%u out_sid=%llu", exit_ring, (unsigned long long)out_sid);
        }
    }

    xfade_log_collected("in",  in_sid,  a->in_wids,  a->in_n);
    xfade_log_collected("out", out_sid, a->out_wids, a->out_n);

    // AC-15: claim both channels of every collected wid (and the wallpapers'
    // ALPHA — the settle/handoff restores touch them unconditionally — plus
    // their GEO when the wallpaper ride below is engaged). Claims
    // come AFTER skip_all_to_end above: eviction courtesy first (finish the
    // in-flight resizes), then take ownership. From here every per-frame write
    // and terminal reset presents these tokens; an anim begin landing
    // mid-slide re-claims its wids and this slide stops carrying them.
    // SPA-9: capture each wid's steady-state alpha BEFORE claiming its ALPHA
    // channel (capture trusts the live alpha only while the channel is
    // unowned) and before the seed transaction below zeroes the entering
    // windows. On a mid-chain re-seed the handoff above already restored
    // baselines and released, so the re-read returns the same values.
    for (int i = 0; i < a->in_n; i++) {
        a->in_geo[i]   = anim_claim(a->in_wids[i],  ANIM_CH_GEO,   ANIM_OWNER_XFADE);
        if (a->in_geo_only[i]) {
            // SPA-17: ring rider — claim GEO only; the focus_ring fade owns ALPHA.
            // base unused; in_alpha=0 makes every slide alpha write/reset skip it.
            a->in_base[i]  = 1.0f;
            a->in_alpha[i] = 0;
        } else {
            a->in_base[i]  = anim_baseline_capture(a->in_wids[i]);
            a->in_alpha[i] = anim_claim(a->in_wids[i],  ANIM_CH_ALPHA, ANIM_OWNER_XFADE);
        }
    }
    for (int i = 0; i < a->out_n; i++) {
        if (a->out_geo_only[i]) {
            // SPA-21: exit ring — GEO only. base/alpha-token unused: token 0 skips
            // every per-frame fade write; settle/handoff write the one-shot
            // alpha-0 park unconditionally.
            a->out_base[i]  = 0.0f;
            a->out_geo[i]   = anim_claim(a->out_wids[i], ANIM_CH_GEO, ANIM_OWNER_XFADE);
            a->out_alpha[i] = 0;
            continue;
        }
        a->out_base[i]  = anim_baseline_capture(a->out_wids[i]);
        a->out_geo[i]   = anim_claim(a->out_wids[i], ANIM_CH_GEO,   ANIM_OWNER_XFADE);
        a->out_alpha[i] = anim_claim(a->out_wids[i], ANIM_CH_ALPHA, ANIM_OWNER_XFADE);
    }
    a->in_wp_base   = a->in_wp  ? anim_baseline_capture(a->in_wp)  : 1.0f;
    a->out_wp_base  = a->out_wp ? anim_baseline_capture(a->out_wp) : 1.0f;
    a->in_wp_alpha  = a->in_wp  ? anim_claim(a->in_wp,  ANIM_CH_ALPHA, ANIM_OWNER_XFADE) : 0;
    a->out_wp_alpha = a->out_wp ? anim_claim(a->out_wp, ANIM_CH_ALPHA, ANIM_OWNER_XFADE) : 0;
    // Wallpaper ride gate: both pictures must resolve and be DISTINCT windows. A
    // shared/sticky picture (or a failed resolve) falls back to the static-backdrop
    // path — sliding a shared picture with one side would strand the other side on
    // black. GEO token 0 disables every ride write (seed, per-frame, terminal).
    bool wp_ride = wallpaper && a->in_wp && a->out_wp && a->in_wp != a->out_wp;
    a->in_wp_geo    = wp_ride ? anim_claim(a->in_wp,  ANIM_CH_GEO, ANIM_OWNER_XFADE) : 0;
    a->out_wp_geo   = wp_ride ? anim_claim(a->out_wp, ANIM_CH_GEO, ANIM_OWNER_XFADE) : 0;

    // SPA-20: only engage the fullscreen "abyss" effect when THIS transition actually
    // enters or leaves a fullscreen space. The Dock "Fullscreen Backdrop" window is
    // persistent and queryable from any space, so an unguarded find_* matched it on
    // every normal slide (and scaled the wallpaper on every space change) — gate on
    // the space types. fs_entering picks direction; backdrops are collected only when
    // involved (they get HIDDEN, not faded, so the scaling wallpaper shows).
    extern int SLSSpaceGetType(int cid, uint64_t sid);
    int  in_type  = SLSSpaceGetType(cid, in_sid);
    int  out_type = SLSSpaceGetType(cid, out_sid);
    bool fs_involved = fs_enabled && ((in_type == 4) || (out_type == 4));   // 4 = SLS_SPACE_FULLSCREEN; lever off → no abyss
    a->fs_entering = (in_type == 4);
    a->fs_n = fs_involved ? find_fullscreen_backdrops(cid, a->fs_wids, SA_FS_BACKDROP_MAX) : 0;
    if (a->fs_n) logpf("SPACE_ANIM", "xfade fullscreen: n=%d wid0=%u entering=%d", a->fs_n, a->fs_wids[0], a->fs_entering);

    // SPA-20: pick the NORMAL-space wallpaper that recedes into the abyss. The
    // fullscreen side has no picture wid, so it's out_wp on enter (in_sid fullscreen)
    // and in_wp on exit. Capture its display rect, then hunt the OTHER identical
    // wallpapers on the same display (incl. the fullscreen child-space wallpaper) so
    // they can be hidden — without that, the masker shows full-size and the effect is
    // invisible. 0 (→ skipped) when neither side has a picture (fullscreen↔fullscreen).
    a->fs_scale_wid = 0;
    a->fs_wp_x = a->fs_wp_y = a->fs_wp_w = a->fs_wp_h = 0.0;
    a->fs_mask_n = 0;
    if (a->fs_n) {
        uint32_t cand = a->fs_entering ? a->out_wp : a->in_wp;
        CGRect wpb;
        if (cand && SLSGetWindowBounds(cid, cand, &wpb) == kCGErrorSuccess &&
            wpb.size.width > 0.0 && wpb.size.height > 0.0) {
            a->fs_scale_wid = cand;
            a->fs_wp_x = wpb.origin.x; a->fs_wp_y = wpb.origin.y;
            a->fs_wp_w = wpb.size.width; a->fs_wp_h = wpb.size.height;
            a->fs_mask_n = find_wallpaper_maskers(cid, wpb, cand, a->fs_mask_wids, SA_FS_MASK_MAX);
            logpf("SPACE_ANIM", "xfade fs-abyss: wid=%u rect=%.0f,%.0f %.0fx%.0f maskers=%d min=%.2f ease=%d dur=%.2f delay=%.2f fade=%d",
                  cand, a->fs_wp_x, a->fs_wp_y, a->fs_wp_w, a->fs_wp_h, a->fs_mask_n,
                  (double)a->fs_min_scale, a->fs_anim_easing, a->fs_anim_dur, a->fs_anim_delay, a->fs_anim_fade);
        }
    }

    // Seed the initial state ATOMICALLY with ShowSpace. ShowSpace composites the
    // incoming space at full alpha and natural placement; if the alpha=0 clamp (or the
    // riding wallpaper's start translate) lands in a LATER commit, the compositor can
    // present the space unseeded for the intervening frame — the cold-start flash.
    // Folding ShowSpace + IsAnimating + every entering-window alpha=0 + the wallpaper's
    // start translate into ONE transaction means the space is already staged the
    // instant it's revealed. The per-frame callback drives all alpha from here
    // (entering 0->1, leaving 1->0) using instant SLSTransactionSetWindowAlpha —
    // never the animated SPI (it crashed WindowServer).
    //
    // Wallpaper OFF: keep BOTH wallpapers visible (static, opaque) as the backdrop. Both
    // are excluded from the moving sets, so two full-screen wallpapers sit behind the
    // sliding windows — whatever the WindowServer's space z-order does at the edges (which
    // single-wallpaper rules couldn't satisfy: out_wp blacked on `prev`, the lower-wp rule
    // blacked on `next`->last), one of the two always covers the screen, so black is
    // impossible.
    // ON (wp_ride): each wallpaper rides the slide's Transform3D with its space,
    // native-style — the incoming one enters pre-translated a full width offscreen
    // (below), and the seam between the two pictures stays exact because both ride
    // the SHARED slide progress.
    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    CFTypeRef show = SLSTransactionCreate(cid);
    if (show) {
        SLSTransactionShowSpace(show, in_sid);
        if (uuid) SLSTransactionSetManagedDisplayIsAnimating(show, uuid, true);
        // Wallpaper ride: pre-translate the incoming picture a full width offscreen,
        // atomically with ShowSpace — it enters VISIBLE (alpha untouched), so a late
        // transform would flash it over the outgoing picture for a frame. Guarded by
        // the ride token (0 = lever off / shared picture); skip fs_scale_wid (the
        // abyss seeds its own 2D transform below).
        if (a->in_wp_geo && a->in_wp != a->fs_scale_wid) {
            double W0[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, (double)direction * width,0,0,1 };
            SLSTransactionSetWindowTransform3D(show, a->in_wp, W0);
        }
        // SPA-20: HIDE the Dock "Fullscreen Backdrop" AND every other identical wallpaper
        // on this display (the maskers — incl. the fullscreen child-space wallpaper) for
        // the whole slide, exposing the black behind so the one wallpaper we animate reads
        // as receding into the abyss. All restored at settle/handoff.
        for (int i = 0; i < a->fs_n; i++)      SLSTransactionSetWindowSystemAlpha(show, a->fs_wids[i], 0.0f);
        for (int i = 0; i < a->fs_mask_n; i++) SLSTransactionSetWindowSystemAlpha(show, a->fs_mask_wids[i], 0.0f);
        // SPA-20: seed the wallpaper's start scale+alpha atomically with ShowSpace so it
        // doesn't flash full-size/opaque for a frame before the first step. On exit it
        // must START collapsed+transparent (presence 0) and zoom/fade up; on enter it
        // starts at natural (presence 1). 2D center-scale (origin baked in).
        if (a->fs_scale_wid) {
            double p0 = a->fs_entering ? 1.0 : 0.0;   // presence at t=0 (delay/easing both map 0→p0)
            double S0 = fmax((double)a->fs_min_scale + (1.0 - (double)a->fs_min_scale) * p0, 0.02);
            SLSTransactionSetWindowTransform(show, a->fs_scale_wid, 0, 0, fs_abyss_xform(a->fs_wp_x, a->fs_wp_y, a->fs_wp_w, a->fs_wp_h, S0));
            float fs_base = a->fs_entering ? a->out_wp_base : a->in_wp_base;
            float a0 = a->fs_anim_fade ? (float)p0 : 1.0f;
            SLSTransactionSetWindowSystemAlpha(show, a->fs_scale_wid, a0 * fs_base);
        }
        // fade on: entering windows start hidden (alpha 0) and fade up per frame.
        // fade off: start at baseline so they slide in already opaque (no fade-in pop).
        // SPA-17: skip geo-only riders (the focus ring) — the slide never touches
        // their alpha; the focus_ring fade reveals the ring independently.
        for (int i = 0; i < a->in_n; i++) {
            if (a->in_geo_only[i]) continue;
            // fade-only menubar rows always start hidden so they cross-fade up over
            // the slide (menubar decouple) — independent of the window `fade` lever.
            SLSTransactionSetWindowSystemAlpha(show, a->in_wids[i], (fade || a->in_fade_only[i]) ? 0.0f : a->in_base[i]);
        }
        SLSTransactionCommit(show, 0);
        CFRelease(show);
    } else {
        // Degraded seed: incoming space not pre-shown/pre-hidden (one-frame pop);
        // the per-frame step still drives all alpha from here.
        logpf("SPACE_ANIM", "xfade seed: SLSTransactionCreate FAIL in=%llu", in_sid);
    }
    if (uuid) CFRelease(uuid);

    pthread_mutex_lock(&a->lock);
    a->start_mach_time = mach_absolute_time();
    atomic_store(&a->active, true);
    pthread_mutex_unlock(&a->lock);

    // AC-7: drive from the per-display ca_clock pump instead of an own CVDisplayLink.
    // Register AFTER releasing a->lock (lock order vs the pump's clients_lock).
    // Idempotent by ctx — a retarget re-activates the same client; the gen bump above
    // keeps any in-flight old-hop step from committing a stale settle.
    ca_clock_register(did, refresh_hz, space_cross_fade_animator_ca_step, a);
    ca_clock_resume(did);
    logpf("SPACE_ANIM", "xfade seed out=%llu in=%llu dir=%d width=%.0f dur=%.3f wp=%d in_n=%d out_n=%d did=0x%x hz=%.0f",
          out_sid, in_sid, direction, width, a->duration, wallpaper, a->in_n, a->out_n, did, refresh_hz);
}

// === Space animation: production animated switch ===
// SA_OPCODE_SPACE_ANIMATE handler. Delegates to space_cross_fade_animator_start
// (above): per-window cross-slide + cross-fade, with the wallpapers riding the
// slide when the `wallpaper` lever is on (off = static backdrop), committing
// the real switch via SetManagedDisplayCurrentSpace + Dock model poke ONCE at settle.
static void do_space_focus_animated(char *message)
{
    uint64_t out_sid;   unpack(out_sid);
    uint64_t in_sid;    unpack(in_sid);
    int32_t  direction; unpack(direction);
    float    duration;  unpack(duration);
    double   width;     unpack(width);
    double   gap;       unpack(gap);   // wire order matches scripting_addition_animate_space
    uint8_t  wallpaper; unpack(wallpaper);
    uint8_t  animate_menubar; unpack(animate_menubar);   // SPA-11 (must mirror the packer order)
    uint32_t did;       unpack(did);          // AC-7: per-display ca_clock cadence (must mirror the packer order)
    float    refresh_hz; unpack(refresh_hz);
    int32_t  out_active_stage; unpack(out_active_stage);  // stage filter (must mirror the packer order)
    int32_t  in_active_stage;  unpack(in_active_stage);   // -1 = no filtering
    uint8_t  easing;    unpack(easing);   // curve mode (enum focus_ring_easing); mirror the packer order
    uint8_t  fade;      unpack(fade);     // SPA: cross-fade windows during slide; mirror the packer order
    // SPA-17: focus-ring geo-rider. ring_wid=0 → no rider (anticipate off / no dest).
    uint32_t ring_wid;  unpack(ring_wid);   // destination focused window (ring parks here); mirror packer
    float    ring_x;    unpack(ring_x);
    float    ring_y;    unpack(ring_y);
    float    ring_w;    unpack(ring_w);
    float    ring_h;    unpack(ring_h);
    float    ring_radius; unpack(ring_radius);   // corner radius; mirror the packer order
    uint8_t  fs_enabled;  unpack(fs_enabled);    // SPA-20 fullscreen-abyss levers (mirror the packer order)
    float    fs_scale;    unpack(fs_scale);
    uint8_t  fs_easing;   unpack(fs_easing);
    float    fs_duration; unpack(fs_duration);
    float    fs_delay;    unpack(fs_delay);
    uint8_t  fs_fade;     unpack(fs_fade);        // mirror the packer order
    float    enter_delay; unpack(enter_delay);    // SPA slide stagger (s); mirror the packer order
    float    exit_delay;  unpack(exit_delay);     // slide stagger (s); mirror the packer order
    float    fade_enter_delay; unpack(fade_enter_delay);   // fade sub-timeline (s); mirror the packer order
    float    fade_exit_delay;  unpack(fade_exit_delay);
    float    fade_enter_dur;   unpack(fade_enter_dur);
    float    fade_exit_dur;    unpack(fade_exit_dur);       // mirror the packer order (last)

    int cid = SLSMainConnectionID();
    (void)gap;
    logpf("SPACE_ANIM", "do_space_focus_animated -> cross_fade wallpaper=%u fs_en=%u fs_scale=%.2f", wallpaper, fs_enabled, fs_scale);
    // Transparent per-window cross-fade (windows slide+fade; the wallpapers ride
    // along when the lever is on). Interruptible: a press mid-slide hands off to the next hop
    // WITHOUT committing the space change — the dangerous Dock commit
    // (SetManagedDisplayCurrentSpace + _currentSpace poke) fires ONCE at settle,
    // so spamming can't race Dock's per-switch bookkeeping.
    space_cross_fade_animator_start(cid, out_sid, in_sid, direction, width,
                                    duration > 0.0f ? (double)duration : SPACE_ANIM_DEFAULT_DURATION_S,
                                    wallpaper != 0, animate_menubar != 0, did, refresh_hz,
                                    out_active_stage, in_active_stage, (int)easing, fade,
                                    ring_wid, CGRectMake(ring_x, ring_y, ring_w, ring_h), ring_radius,
                                    fs_enabled != 0, fs_scale, (int)fs_easing,
                                    (double)fs_duration, (double)fs_delay, fs_fade != 0,
                                    enter_delay, exit_delay,
                                    fade_enter_delay, fade_exit_delay, fade_enter_dur, fade_exit_dur);
}
