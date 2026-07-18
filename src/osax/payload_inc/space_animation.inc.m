// space_animation.inc.m — space-slide animation (SA payload side): per-window
// cross-slide/cross-fade animator + the SA_OPCODE_SPACE_ANIMATE handler.
// Included from payload.m BEFORE the ca_clock pump and opcode dispatch, which
// reference these symbols.

// per-side cap on the wids a slide carries (name is legacy)
#define SA_WINDOWS_ONLY_MAX_WIDS 256

// NOTE: STATE-CLEAR — only does anything paired with an identity matrix
// (clears the space's transform state; options=0 applies live).
#define SLS_SPACE_TRANSFORM_CLEAR_STATE 0x01000000

#define SLS_LEVEL_MENUBAR_BACKDROP 24   // kCGMainMenuWindowLevel — per-space Menubar backdrop
#define SLS_LEVEL_STATUS_ITEM      25   // kCGStatusWindowLevel — ControlCenter status items

#define SLS_TAG_MENUBAR_BIT        (1ULL << 45)   // kSLSMenuBarTagBit
#define SLS_TAG_MERGES_MENUBAR_BIT (1ULL << 46)   // kCGSMergesWithMenuBar

// Fallback slide duration when the daemon ships 0 (config unset).
#define SPACE_ANIM_DEFAULT_DURATION_S 0.25

// Resolve a space's desktop-picture window: exact match at desktop-1, lowest-level
// fallback. NOTE: never "lowest level wins" alone — the primary space also
// composites the offscreen-transition buffer and WS backstop BELOW the picture.
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

    int picture_level = CGWindowLevelForKey(2) - 1;

    uint32_t picture_wid = 0;
    uint32_t lowest_wid  = 0;
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

// displaylink_ca.inc.m and anim.inc.m are included after this file — forward
// declarations must match their definitions exactly.
static int  ca_clock_register(uint32_t did, float refresh_hz, bool (*step)(void *, CFTypeRef, uint32_t), void *ctx);
static void ca_clock_resume(uint32_t did);
static void ca_clock_wait_tick_idle(uint32_t did);
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

static inline double anim_eased_p(double start_p, int target, uint64_t start_t,
                                  double dur, double mach_to_s, double *out_t, int easing)
{
    double elapsed_s = (double)(mach_absolute_time() - start_t) * mach_to_s;
    double t = dur > 0.0 ? elapsed_s / dur : 1.0;
    if (t > 1.0) t = 1.0;
    if (out_t) *out_t = t;
    return start_p + ((double)target - start_p) * payload_ease(easing, t);
}

// === Per-window cross-slide + cross-fade — the production animated switch ===
// Commits the real switch ONCE at settle; a seed arriving mid-slide takes over
// via xfade_handoff_no_commit.
// one Dock "Fullscreen Backdrop" per fullscreen space
#define SA_FS_BACKDROP_MAX 8
// identical per-space wallpapers hidden on one display during a fullscreen slide
#define SA_FS_MASK_MAX 32

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
    double si = 1.0 / S;
    double target_x = ox + (1.0 - S) * w * 0.5;
    double target_y = oy + (1.0 - S) * h * 0.5;
    return (CGAffineTransform){ .a = si, .b = 0, .c = 0, .d = si, .tx = -target_x * si, .ty = -target_y * si };
}

struct space_cross_fade_animator {
    int       cid;
    uint64_t  out_sid, in_sid;
    int       direction;
    double    width, duration, mach_to_s;
    uint64_t  start_mach_time;
    bool      wallpaper;
    uint32_t  in_wp, out_wp;
    uint32_t  in_wids[SA_WINDOWS_ONLY_MAX_WIDS];  int in_n;
    uint32_t  out_wids[SA_WINDOWS_ONLY_MAX_WIDS]; int out_n;
    // anim_owner tokens, parallel to the wid arrays; presented on every per-frame
    // write and terminal reset. A token going stale mid-slide drops that window cleanly.
    uint64_t  in_geo[SA_WINDOWS_ONLY_MAX_WIDS],  in_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t  out_geo[SA_WINDOWS_ONLY_MAX_WIDS], out_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t  in_wp_alpha, out_wp_alpha;          // wallpaper ALPHA tokens (0 = no wallpaper)
    uint64_t  in_wp_geo, out_wp_geo;              // wallpaper GEO tokens (0 = ride disabled: lever off, unresolved, or a shared picture)
    // steady-state alpha per wid: fades run 0<->baseline and settle restores it
    float     in_base[SA_WINDOWS_ONLY_MAX_WIDS], out_base[SA_WINDOWS_ONLY_MAX_WIDS];
    float     in_wp_base, out_wp_base;
    // Row modes (mutually exclusive): fade_only = alpha only, never translated
    // (menubar backdrop); geo_only = transform only — the focus-ring fade owns the
    // ring rider's alpha, the slide must never write it.
    bool      in_fade_only[SA_WINDOWS_ONLY_MAX_WIDS], out_fade_only[SA_WINDOWS_ONLY_MAX_WIDS];
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
    float     fs_min_scale;   // collapse target (0 = point, 1 = no shrink)
    int       fs_anim_easing; // presence-ramp curve (enum focus_ring_easing)
    double    fs_anim_dur;    // abyss duration seconds (<=0 = track slide)
    double    fs_anim_delay;  // seconds after slide start before the abyss begins
    bool      fs_anim_fade;   // fade alpha with the scale
    _Atomic bool active;
    bool      committed;
    pthread_mutex_t lock;
    uint32_t  did;            // ca_clock display this slide registered on (stale-clock guard)
    float     refresh_hz;     // panel rate shipped on the wire (ProMotion/VRR range)
    uint64_t  gen;            // bumped per seed/handoff; settle re-checks it
    int       easing;         // curve mode (enum focus_ring_easing) shipped per seed; payload_ease
    uint8_t   fade;           // SPACE_FADE_EXIT|SPACE_FADE_ENTER bitmask (per-side); 0 = slide only, no cross-fade
    float     enter_delay;    // slide stagger (s): delay before the incoming windows start sliding in (0 = no delay)
    float     exit_delay;     // slide stagger (s): delay before the outgoing windows start sliding out (0 = no delay)
    float     fade_enter_delay; // fade sub-timeline (s): incoming fade delay; <0 = auto (track slide)
    float     fade_exit_delay;  // outgoing fade delay; <0 = auto (track slide)
    float     fade_enter_dur;   // incoming fade duration; <=0 = auto (ramp to slide end)
    float     fade_exit_dur;    // outgoing fade duration; <=0 = auto (ramp to slide end)
};
static struct space_cross_fade_animator g_xfade = { .lock = PTHREAD_MUTEX_INITIALIZER };

// NOTE: staggered slides leave both spaces co-visible, so the incoming must
// render ABOVE the outgoing: sink OUTGOING one band below normal (negative;
// positive would punch above the menubar), clear incoming each frame so a
// reversed retarget can't strand a window sunk, clear outgoing at settle.
#define SPACE_SLIDE_OUT_SYSTEM_LEVEL (-1)
extern CGError SLSTransactionSetWindowSystemLevel(CFTypeRef transaction, uint32_t wid, int level);
extern CGError SLSTransactionClearWindowSystemLevel(CFTypeRef transaction, uint32_t wid);

// Collect the wids that ride a slide for `sid`. NOTE: options=0 keeps desktop
// furniture (widgets) out of the set; wids owned by our own cid (payload
// overlays) are excluded; the stage filter drops only on a POSITIVE stage
// mismatch (absent/invalid property rides; active_stage < 0 disables). With
// animate_menubar off the band is identified fail-closed (tag bits 45/46 OR
// levels 24/25): backdrop rides as fade-only, status items are excluded.
static int xfade_collect_wids(int cid, uint64_t sid, uint32_t skip_wid, uint32_t *out, bool *fade_only, int max,
                              bool animate_menubar, int active_stage)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner,
                                                       CFArrayRef spaces, uint32_t options,
                                                       uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
    extern CGError SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef key, CFTypeRef *out);
    CFStringRef stage_prop = CFSTR("com.koekeishiya.yabai.stage_id.v1");
    int stage_excluded_n = 0;
    int count = 0;
    CFNumberRef sid_num = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    CFArrayRef space_list = sid_num ? CFArrayCreate(NULL, (const void **)&sid_num, 1, &kCFTypeArrayCallBacks) : NULL;
    if (sid_num) CFRelease(sid_num);
    if (space_list) {
        uint64_t set_tags = 0, clear_tags = 0;
        CFArrayRef w = SLSCopyWindowsWithOptionsAndTags(cid, 0, space_list, 0, &set_tags, &clear_tags);
        if (w) {
            CFIndex n = CFArrayGetCount(w);
            uint32_t excluded[8]; int excluded_n = 0;
            for (CFIndex i = 0; i < n && count < max; ++i) {
                uint32_t wid = 0;
                CFNumberGetValue(CFArrayGetValueAtIndex(w, i), kCFNumberSInt32Type, &wid);
                if (!wid || wid == skip_wid) continue;
                int owner = 0;
                if (SLSGetWindowOwner(cid, wid, &owner) == kCGErrorSuccess && owner == cid) {
                    if (excluded_n < 8) excluded[excluded_n] = wid;
                    excluded_n++;
                    continue;
                }
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
                            fade = true;
                        } else {
                            if (excluded_n < 8) excluded[excluded_n] = wid;
                            excluded_n++;
                            continue;
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

struct xfade_settle_snap {
    uint32_t in_wids[SA_WINDOWS_ONLY_MAX_WIDS],  out_wids[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t in_geo[SA_WINDOWS_ONLY_MAX_WIDS],   in_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t out_geo[SA_WINDOWS_ONLY_MAX_WIDS],  out_alpha[SA_WINDOWS_ONLY_MAX_WIDS];
    uint64_t in_wp_alpha, out_wp_alpha;
    uint64_t in_wp_geo, out_wp_geo;
};

static void xfade_release_side(const uint32_t *wids, const uint64_t *geo, const uint64_t *alpha, int n)
{
    for (int i = 0; i < n; i++) {
        anim_release(wids[i], ANIM_CH_GEO,   geo[i]);
        anim_release(wids[i], ANIM_CH_ALPHA, alpha[i]);
    }
}

// ca_clock step: buffer each frame into the pump's SHARED per-VBL transaction.
// NOTE: no blocking SLS round-trips on the pump thread — the managed-display
// lookup happens only in the settle branch. Returns true when done/stale.
static bool space_cross_fade_animator_ca_step(void *ctx, CFTypeRef pump_tx, uint32_t pump_did)
{
    struct space_cross_fade_animator *a = (struct space_cross_fade_animator *)ctx;
    if (!atomic_load(&a->active)) return true;

    pthread_mutex_lock(&a->lock);
    int      cid = a->cid;
    uint64_t out_sid = a->out_sid, in_sid = a->in_sid;
    int      direction = a->direction;
    double   width = a->width, dur = a->duration, mach_to_s = a->mach_to_s;
    int      easing = a->easing;
    bool     fade_enter = (a->fade & SPACE_FADE_ENTER) != 0;
    bool     fade_exit  = (a->fade & SPACE_FADE_EXIT)  != 0;
    double   enter_delay = (double)a->enter_delay, exit_delay = (double)a->exit_delay;
    double   fade_enter_delay = (double)a->fade_enter_delay, fade_exit_delay = (double)a->fade_exit_delay;
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
    bool in_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_geo_only,   a->in_geo_only,   sizeof(bool) * in_n);
    bool out_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];
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
    uint64_t snap_gen  = a->gen;
    uint32_t adid      = a->did;
    pthread_mutex_unlock(&a->lock);

    if (pump_did != adid) return true;

    double t = 0.0;
    double e = anim_eased_p(0.0, 1, start_t, dur, mach_to_s, &t, easing);
    bool settled = (t >= 1.0);

    double edf = dur > 0.0 ? enter_delay / dur : 0.0;
    double xdf = dur > 0.0 ? exit_delay  / dur : 0.0;
    double es  = 1.0 - edf, xs = 1.0 - xdf;             // span left after the delay
    double er  = es > 1e-6 ? (t - edf) / es : (t >= edf ? 1.0 : 0.0);
    double xr  = xs > 1e-6 ? (t - xdf) / xs : (t >= xdf ? 1.0 : 0.0);
    er = er < 0.0 ? 0.0 : (er > 1.0 ? 1.0 : er);
    xr = xr < 0.0 ? 0.0 : (xr > 1.0 ? 1.0 : xr);
    double e_enter = payload_ease(easing, er);
    double e_exit  = payload_ease(easing, xr);
    double entering_dx =  (double)direction * width * (1.0 - e_enter);
    double leaving_dx  = -(double)direction * width * e_exit;
    double Min[16]  = { 1,0,0,0, 0,1,0,0, 0,0,1,0, entering_dx,0,0,1 };
    double Mout[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, leaving_dx, 0,0,1 };

    // NOTE: alpha is driven manually per frame with instant writes — never
    // SLSTransactionSetWindowAlphaAnimated (its server-side fade completion can
    // crash WindowServer). Writes scale by the captured baseline, not 1.0.
    float ae  = (float)(e < 0.0 ? 0.0 : (e > 1.0 ? 1.0 : e));
    float aeo = 1.0f - ae;
    double fade_now_s = t * dur;
    double fed = fade_enter_delay >= 0.0 ? fade_enter_delay : enter_delay;
    double fxd = fade_exit_delay  >= 0.0 ? fade_exit_delay  : exit_delay;
    double fedur = fade_enter_dur > 0.0 ? fade_enter_dur : (dur - fed);
    double fxdur = fade_exit_dur  > 0.0 ? fade_exit_dur  : (dur - fxd);
    double fer = fedur > 1e-6 ? (fade_now_s - fed) / fedur : (fade_now_s >= fed ? 1.0 : 0.0);
    double fxr = fxdur > 1e-6 ? (fade_now_s - fxd) / fxdur : (fade_now_s >= fxd ? 1.0 : 0.0);
    fer = fer < 0.0 ? 0.0 : (fer > 1.0 ? 1.0 : fer);
    fxr = fxr < 0.0 ? 0.0 : (fxr > 1.0 ? 1.0 : fxr);
    float win_ae  = fade_enter ? (float)payload_ease(easing, fer)         : 1.0f;
    float win_aeo = fade_exit  ? (float)(1.0 - payload_ease(easing, fxr)) : 1.0f;

    if (pump_tx) {
        for (int i = 0; i < in_n;  i++) {
            if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, in_wids[i],  Min);
            if (!in_geo_only[i] && anim_owns(in_wids[i],  ANIM_CH_ALPHA, in_alpha[i]))  SLSTransactionSetWindowSystemAlpha(pump_tx, in_wids[i],  (in_fade_only[i] ? ae : win_ae) * in_base[i]);
            if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionClearWindowSystemLevel(pump_tx, in_wids[i]);
        }
        for (int i = 0; i < out_n; i++) {
            if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, out_wids[i], Mout);
            if (anim_owns(out_wids[i], ANIM_CH_ALPHA, out_alpha[i])) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wids[i], (out_fade_only[i] ? aeo : win_aeo) * out_base[i]);
            if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowSystemLevel(pump_tx, out_wids[i], SPACE_SLIDE_OUT_SYSTEM_LEVEL);
        }
        if (wallpaper) {
            double Win[16]  = { 1,0,0,0, 0,1,0,0, 0,0,1,0,  (double)direction * width * (1.0 - e),0,0,1 };
            double Wout[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, -(double)direction * width * e,        0,0,1 };
            if (in_wp  && in_wp  != fs_scale_wid && anim_owns(in_wp,  ANIM_CH_GEO, in_wp_geo))  SLSTransactionSetWindowTransform3D(pump_tx, in_wp,  Win);
            if (out_wp && out_wp != fs_scale_wid && anim_owns(out_wp, ANIM_CH_GEO, out_wp_geo)) SLSTransactionSetWindowTransform3D(pump_tx, out_wp, Wout);
        }
        if (fs_scale_wid && fs_wp_w > 0.0 && fs_wp_h > 0.0) {
            double   elapsed_s = (double)(mach_absolute_time() - start_t) * mach_to_s;
            double   ad = fs_anim_dur > 0.0 ? fs_anim_dur : dur;
            double   ap = ad > 0.0 ? (elapsed_s - fs_anim_delay) / ad : 1.0;
            if (ap < 0.0) ap = 0.0; if (ap > 1.0) ap = 1.0;
            double   eased = payload_ease(fs_anim_easing, ap);
            float    p_wp  = fs_entering ? (float)(1.0 - eased) : (float)eased;
            double   S     = fmax((double)fs_min_scale + (1.0 - (double)fs_min_scale) * (double)p_wp, 0.02);
            SLSTransactionSetWindowTransform(pump_tx, fs_scale_wid, 0, 0, fs_abyss_xform(fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h, S));
            uint64_t fs_alpha = fs_entering ? out_wp_alpha : in_wp_alpha;
            float    fs_base  = fs_entering ? out_wp_base  : in_wp_base;
            float    a_frac   = fs_anim_fade ? p_wp : 1.0f;
            if (anim_owns(fs_scale_wid, ANIM_CH_ALPHA, fs_alpha)) SLSTransactionSetWindowSystemAlpha(pump_tx, fs_scale_wid, a_frac * fs_base);
        }
    }

    pthread_mutex_lock(&a->lock);
    // NOTE: settle requires the gen snapshot to still match (a re-seed bumps gen,
    // so a stale in-flight step can't commit the old hop) AND pump_tx (the terminal
    // cut rides the shared transaction — no tx this tick, settle next VBL).
    bool do_settle = settled && pump_tx && !a->committed && (a->gen == snap_gen);
    if (do_settle) {
        a->committed = true;
        atomic_store(&a->active, false);
    }
    pthread_mutex_unlock(&a->lock);

    if (!do_settle) return false;

    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    uint64_t target_sid = in_sid, src_sid = out_sid;

    // NOTE: the terminal cut (identity, baseline alphas, space switch, HideSpace,
    // IsAnimating off) rides the SAME shared tx as this tick's frame writes — split
    // commits flash the new space or lose the race and strand alpha≈0. Per-wid
    // resets are token-gated; hop-level ops stay unconditional.
    double I[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
    for (int i = 0; i < in_n;  i++) {
        if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, in_wids[i],  I);
        if (!in_geo_only[i] && anim_owns(in_wids[i],  ANIM_CH_ALPHA, in_alpha[i]))  SLSTransactionSetWindowSystemAlpha(pump_tx, in_wids[i],  in_base[i]);
    }
    for (int i = 0; i < out_n; i++) {
        if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowTransform3D(pump_tx, out_wids[i], I);
        if (anim_owns(out_wids[i], ANIM_CH_ALPHA, out_alpha[i])) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wids[i], out_base[i]);
        if (out_geo_only[i]) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wids[i], 0.0f);
        if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionClearWindowSystemLevel(pump_tx, out_wids[i]);
    }
    if (in_wp  && anim_owns(in_wp,  ANIM_CH_ALPHA, in_wp_alpha))  SLSTransactionSetWindowSystemAlpha(pump_tx, in_wp,  in_wp_base);
    if (out_wp && anim_owns(out_wp, ANIM_CH_ALPHA, out_wp_alpha)) SLSTransactionSetWindowSystemAlpha(pump_tx, out_wp, out_wp_base);
    if (in_wp  && in_wp  != fs_scale_wid && anim_owns(in_wp,  ANIM_CH_GEO, in_wp_geo))  SLSTransactionSetWindowTransform3D(pump_tx, in_wp,  I);
    if (out_wp && out_wp != fs_scale_wid && anim_owns(out_wp, ANIM_CH_GEO, out_wp_geo)) SLSTransactionSetWindowTransform3D(pump_tx, out_wp, I);
    for (int i = 0; i < fs_n; i++)
        SLSTransactionSetWindowSystemAlpha(pump_tx, fs_wids[i], 1.0f);
    for (int i = 0; i < fs_mask_n; i++)
        SLSTransactionSetWindowSystemAlpha(pump_tx, fs_mask_wids[i], 1.0f);
    // SPA-20: restore the picture's NATURAL 2D transform (translate(-origin)), NOT 3D
    // identity — a bare identity would drop the -origin and park the D2 picture on D1.
    if (fs_scale_wid) SLSTransactionSetWindowTransform(pump_tx, fs_scale_wid, 0, 0, fs_abyss_xform(fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h, 1.0));
    if (uuid) SLSTransactionSetManagedDisplayCurrentSpace(pump_tx, uuid, target_sid);
    SLSTransactionHideSpace(pump_tx, src_sid);
    if (uuid) SLSTransactionSetManagedDisplayIsAnimating(pump_tx, uuid, false);

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
        if (snap) {
            xfade_release_side(snap->in_wids,  snap->in_geo,  snap->in_alpha,  in_n);
            xfade_release_side(snap->out_wids, snap->out_geo, snap->out_alpha, out_n);
            if (in_wp  && snap->in_wp_alpha)  anim_release(in_wp,  ANIM_CH_ALPHA, snap->in_wp_alpha);
            if (out_wp && snap->out_wp_alpha) anim_release(out_wp, ANIM_CH_ALPHA, snap->out_wp_alpha);
            if (in_wp  && snap->in_wp_geo)    anim_release(in_wp,  ANIM_CH_GEO,   snap->in_wp_geo);
            if (out_wp && snap->out_wp_geo)   anim_release(out_wp, ANIM_CH_GEO,   snap->out_wp_geo);
        }

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
    return true;
}

// Hand an in-flight slide to the next hop WITHOUT committing the space change.
// NOTE: SetManagedDisplayCurrentSpace, IsAnimating and the Dock _currentSpace
// poke fire exactly ONCE, at the real settle — per-hop commits race Dock's
// bookkeeping (HideSpace is visibility-only, safe per hop). Clear committed AND
// bump gen here so a mid-flight step can't stray-commit the old hop, then wait
// out the in-flight tick so its buffered frame can't commit after the restore.
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
    bool in_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];
    memcpy(in_geo_only,   a->in_geo_only,   sizeof(bool) * in_n);
    bool out_geo_only[SA_WINDOWS_ONLY_MAX_WIDS];
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
    a->committed = false;
    atomic_store(&a->active, false);
    a->gen++;
    pthread_mutex_unlock(&a->lock);

    ca_clock_wait_tick_idle(hdid);

    double I[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
    CFTypeRef tx = SLSTransactionCreate(cid);
    if (tx) {
        for (int i = 0; i < in_n;  i++) {
            if (!in_fade_only[i] && anim_owns(in_wids[i], ANIM_CH_GEO, in_geo[i])) SLSTransactionSetWindowTransform3D(tx, in_wids[i],  I);
            if (!in_geo_only[i] && anim_owns(in_wids[i],  ANIM_CH_ALPHA, in_alpha[i]))  SLSTransactionSetWindowSystemAlpha(tx, in_wids[i],  in_base[i]);
        }
        for (int i = 0; i < out_n; i++) {
            if (!out_fade_only[i] && anim_owns(out_wids[i], ANIM_CH_GEO, out_geo[i])) SLSTransactionSetWindowTransform3D(tx, out_wids[i], I);
            if (anim_owns(out_wids[i], ANIM_CH_ALPHA, out_alpha[i])) SLSTransactionSetWindowSystemAlpha(tx, out_wids[i], out_base[i]);
            if (out_geo_only[i]) SLSTransactionSetWindowSystemAlpha(tx, out_wids[i], 0.0f);
        }
        if (in_wp  && anim_owns(in_wp,  ANIM_CH_ALPHA, in_wp_alpha))  SLSTransactionSetWindowSystemAlpha(tx, in_wp,  in_wp_base);
        if (out_wp && anim_owns(out_wp, ANIM_CH_ALPHA, out_wp_alpha)) SLSTransactionSetWindowSystemAlpha(tx, out_wp, out_wp_base);
        if (in_wp  && in_wp  != fs_scale_wid && anim_owns(in_wp,  ANIM_CH_GEO, in_wp_geo))  SLSTransactionSetWindowTransform3D(tx, in_wp,  I);
        if (out_wp && out_wp != fs_scale_wid && anim_owns(out_wp, ANIM_CH_GEO, out_wp_geo)) SLSTransactionSetWindowTransform3D(tx, out_wp, I);
        for (int i = 0; i < fs_n; i++) SLSTransactionSetWindowSystemAlpha(tx, fs_wids[i], 1.0f);
        for (int i = 0; i < fs_mask_n; i++) SLSTransactionSetWindowSystemAlpha(tx, fs_mask_wids[i], 1.0f);
        if (fs_scale_wid) SLSTransactionSetWindowTransform(tx, fs_scale_wid, 0, 0, fs_abyss_xform(fs_wp_x, fs_wp_y, fs_wp_w, fs_wp_h, 1.0));
        SLSTransactionHideSpace(tx, src_sid);
        SLSTransactionCommit(tx, 0);
        CFRelease(tx);
    } else {
        logpf("SPACE_ANIM", "xfade handoff: SLSTransactionCreate FAIL — terminal restore lost src=%llu", src_sid);
    }

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

    // Seed ordering: (1) force in-flight resizes to their end state before taking
    // their wids (a LockedBounds pin survives the slide's transform reset);
    // (2) fence the previous hop's clock BEFORE capturing baselines — a settle
    // mid-commit reads alpha≈0 and poisons the restore target; (3) capture each
    // baseline BEFORE claiming its ALPHA channel and before the seed zeroes the
    // entering windows; (4) adopt the exit ring after the in-side park (LRU evicts).
    anim_skip_all_to_end();

    uint32_t prev_did = a->did;
    if (atomic_load(&a->active)) {
        xfade_handoff_no_commit(a);
        logpf("SPACE_ANIM", "xfade retarget in=%llu (handed off prior slide, no commit)", in_sid);
    }

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
    a->gen++;
    pthread_mutex_unlock(&a->lock);

    a->in_wp  = find_wallpaper_wid_for_space(in_sid);
    a->out_wp = find_wallpaper_wid_for_space(out_sid);
    a->in_n  = xfade_collect_wids(cid, in_sid,  a->in_wp,  a->in_wids,  a->in_fade_only,  SA_WINDOWS_ONLY_MAX_WIDS, animate_menubar, in_active_stage);
    a->out_n = xfade_collect_wids(cid, out_sid, a->out_wp, a->out_wids, a->out_fade_only, SA_WINDOWS_ONLY_MAX_WIDS, animate_menubar, out_active_stage);

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

    for (int i = 0; i < a->in_n; i++) {
        a->in_geo[i]   = anim_claim(a->in_wids[i],  ANIM_CH_GEO,   ANIM_OWNER_XFADE);
        if (a->in_geo_only[i]) {
            a->in_base[i]  = 1.0f;
            a->in_alpha[i] = 0;
        } else {
            a->in_base[i]  = anim_baseline_capture(a->in_wids[i]);
            a->in_alpha[i] = anim_claim(a->in_wids[i],  ANIM_CH_ALPHA, ANIM_OWNER_XFADE);
        }
    }
    for (int i = 0; i < a->out_n; i++) {
        if (a->out_geo_only[i]) {
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
    // NOTE: ride requires two DISTINCT resolved pictures — sliding a shared/sticky
    // picture with one side strands the other on black. GEO token 0 disables it.
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

    // NOTE: seed atomically WITH ShowSpace — entering alphas, the riding
    // wallpaper's start translate and the abyss start state must land in the same
    // commit, or the compositor can present the space unseeded for a frame.
    // Wallpaper off: BOTH pictures stay visible as the static backdrop so no
    // space z-order at the edges can expose black.
    CFStringRef uuid = SLSCopyManagedDisplayForSpace(cid, out_sid);
    CFTypeRef show = SLSTransactionCreate(cid);
    if (show) {
        SLSTransactionShowSpace(show, in_sid);
        if (uuid) SLSTransactionSetManagedDisplayIsAnimating(show, uuid, true);
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
        if (a->fs_scale_wid) {
            double p0 = a->fs_entering ? 1.0 : 0.0;
            double S0 = fmax((double)a->fs_min_scale + (1.0 - (double)a->fs_min_scale) * p0, 0.02);
            SLSTransactionSetWindowTransform(show, a->fs_scale_wid, 0, 0, fs_abyss_xform(a->fs_wp_x, a->fs_wp_y, a->fs_wp_w, a->fs_wp_h, S0));
            float fs_base = a->fs_entering ? a->out_wp_base : a->in_wp_base;
            float a0 = a->fs_anim_fade ? (float)p0 : 1.0f;
            SLSTransactionSetWindowSystemAlpha(show, a->fs_scale_wid, a0 * fs_base);
        }
        for (int i = 0; i < a->in_n; i++) {
            if (a->in_geo_only[i]) continue;
            SLSTransactionSetWindowSystemAlpha(show, a->in_wids[i], (fade || a->in_fade_only[i]) ? 0.0f : a->in_base[i]);
        }
        SLSTransactionCommit(show, 0);
        CFRelease(show);
    } else {
        logpf("SPACE_ANIM", "xfade seed: SLSTransactionCreate FAIL in=%llu", in_sid);
    }
    if (uuid) CFRelease(uuid);

    pthread_mutex_lock(&a->lock);
    a->start_mach_time = mach_absolute_time();
    atomic_store(&a->active, true);
    pthread_mutex_unlock(&a->lock);

    // NOTE: register after dropping a->lock (lock order vs the pump's
    // clients_lock); registration is idempotent by ctx.
    ca_clock_register(did, refresh_hz, space_cross_fade_animator_ca_step, a);
    ca_clock_resume(did);
    logpf("SPACE_ANIM", "xfade seed out=%llu in=%llu dir=%d width=%.0f dur=%.3f wp=%d in_n=%d out_n=%d did=0x%x hz=%.0f",
          out_sid, in_sid, direction, width, a->duration, wallpaper, a->in_n, a->out_n, did, refresh_hz);
}

static void do_space_focus_animated(char *message)
{
    // NOTE: unpack order mirrors scripting_addition_animate_space's pack order.
    uint64_t out_sid;   unpack(out_sid);
    uint64_t in_sid;    unpack(in_sid);
    int32_t  direction; unpack(direction);
    float    duration;  unpack(duration);
    double   width;     unpack(width);
    double   gap;       unpack(gap);
    uint8_t  wallpaper; unpack(wallpaper);
    uint8_t  animate_menubar; unpack(animate_menubar);
    uint32_t did;       unpack(did);
    float    refresh_hz; unpack(refresh_hz);
    int32_t  out_active_stage; unpack(out_active_stage);
    int32_t  in_active_stage;  unpack(in_active_stage);   // -1 = no filtering
    uint8_t  easing;    unpack(easing);
    uint8_t  fade;      unpack(fade);
    // SPA-17: focus-ring geo-rider. ring_wid=0 → no rider (anticipate off / no dest).
    uint32_t ring_wid;  unpack(ring_wid);
    float    ring_x;    unpack(ring_x);
    float    ring_y;    unpack(ring_y);
    float    ring_w;    unpack(ring_w);
    float    ring_h;    unpack(ring_h);
    float    ring_radius; unpack(ring_radius);
    uint8_t  fs_enabled;  unpack(fs_enabled);
    float    fs_scale;    unpack(fs_scale);
    uint8_t  fs_easing;   unpack(fs_easing);
    float    fs_duration; unpack(fs_duration);
    float    fs_delay;    unpack(fs_delay);
    uint8_t  fs_fade;     unpack(fs_fade);
    float    enter_delay; unpack(enter_delay);
    float    exit_delay;  unpack(exit_delay);
    float    fade_enter_delay; unpack(fade_enter_delay);
    float    fade_exit_delay;  unpack(fade_exit_delay);
    float    fade_enter_dur;   unpack(fade_enter_dur);
    float    fade_exit_dur;    unpack(fade_exit_dur);

    int cid = SLSMainConnectionID();
    (void)gap;
    logpf("SPACE_ANIM", "do_space_focus_animated -> cross_fade wallpaper=%u fs_en=%u fs_scale=%.2f", wallpaper, fs_enabled, fs_scale);
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
