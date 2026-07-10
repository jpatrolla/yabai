// payload_inc/focus_ring.inc.m
//
// Payload-side focus_ring overlay — Dock-cid-owned, display-sized CA window
// (one per managed space, FR-9 pool) that follows the focused target. Every
// ring renders through ONE CA tree (FR-24): a CABackdropLayer frost band when
// blur_radius > 0, a solid CAShapeLayer band when blur_radius == 0. Moves and
// resizes are per-frame band-path updates inside the pinned surface; the CA
// flush lands microseconds before the t3d batch commit so the ring tracks the
// target's LB+T3D motion in the same compositor frame.
//
// Driven by:
//   - SA opcodes  SA_OPCODE_FOCUS_RING_{SHOW,HIDE,SET_VISIBLE}
//   - The LB+T3D engine's per-frame follower registry (AC-6): payload_focus_ring_follower
//     is registered via lb_follower_register at stroke init, and the engine calls it
//     for every animated wid each tick (it self-filters). The debug-only translate3d
//     batch path (do_window_lockedbounds_translate3d_batch) calls the same follower
//     directly by name (it's included before the engine, so can't see the registry).
//
// Forward declarations for the public entry points live in payload.m: their
// callers (the opcode dispatch switch, the t3d batch hook, the deathwatch
// teardown) appear earlier in the TU than this include.

// Forward decl — body lower in this file. Declared here so the registration call
// at stroke init (above the definition) and the debug-only translate3d batch path
// (window_transform.inc.m, included earlier) both resolve it. (AC-6)
static void payload_focus_ring_follower(CFTypeRef tx, uint32_t wid, CGRect rect);

// =========================================================================
// Style — runtime-mutable. Stamped on every SHOW from the daemon's
// `yabai -m config focus_ring_width/_opacity` values; the macro names below
// redirect to these file-static floats.
// =========================================================================
static float g_focus_ring_stroke_width = 7.0f;
static float g_focus_ring_stroke_alpha = 0.05f;
static float g_focus_ring_stroke_r     = 1.00f;
static float g_focus_ring_stroke_g     = 1.00f;
static float g_focus_ring_stroke_b     = 1.00f;

// Background-blur (vibrancy) radius for the band. Stamped on every SHOW from
// the daemon's `focus_ring blur` config. Just one filter knob on the always-on
// backdrop pipeline (FR-24): 0 = unblurred band (tint at full alpha = the
// classic solid ring), > 0 = frosted.
static int   g_focus_ring_blur_radius  = 0;

// Inner bleed (px) — how far the frosted band's INNER edge is pushed INWARD past
// the focused window's edge so the band overlaps a strip of the window. Stamped on
// every SHOW from `focus_ring_blur_bleed`. Any radius. When > 0 the band's
// cutout (the sharp hole) shrinks by this much and the overlap strip samples the
// window's own edge pixels via the backdrop's behind-window capture — which only
// works with the ring ordered ABOVE the target (below it, the window occludes
// the strip instead of feeding it).
static float g_focus_ring_blur_bleed   = 0.0f;

// FR-24: ONE rendering path for every ring. The overlay is always the type-5
// layer-backed SLS window hosting the CA tree built in
// payload_focus_surface_create:
//   root -> CABackdropLayer (masked rounded band; behind-window sampling)
//             -> tint CALayer (band color @ blur_opacity, compositingFilter = blend)
//        -> ca_stroke / ca_xray overlays
// The backdrop pipeline ALWAYS renders; blur is just the gaussian filter knob
// on it (radius 0 = unblurred band). So tint/blend_mode/saturation/brightness/
// contrast/feather/bleed apply at ANY radius, and the classic solid ring is
// simply tint at full alpha over an unblurred sample. Changing any knob —
// including blur 0<->N — is a live layer/filter update, never a window
// recreate. The server-side SLSSetWindowBackgroundBlurRadius is deliberately
// NOT used: it frosts the window's whole region and can't be masked (hollow
// shape blacks out, content clear still frosts) — the maskable client
// CABackdropLayer is the only way to get a band + sharp center.

// Backdrop color adjustment + tint blend mode (applies at any radius). Stamped on
// every SHOW from the daemon's focus_ring_blur_saturation / _blur_brightness /
// _blend_mode config. saturation/brightness are CAFilter colorSaturate/
// colorBrightness inputAmounts applied to the sampled frosted content (defaults
// 1.0/0.0 = identity, so an unconfigured blur ring is unchanged); blend_mode is
// the tint sublayer's compositingFilter (0 = none / default source-over).
static float g_focus_ring_blur_saturation = 1.0f;
static float g_focus_ring_blur_brightness = 0.0f;
static float g_focus_ring_blur_contrast   = 1.0f;   // colorContrast inputAmount; 1.0 = identity
static float g_focus_ring_blur_hue        = 0.0f;   // colorHueRotate angle (degrees); 0.0 = identity
static int   g_focus_ring_blend_mode      = 0;   // enum focus_ring_blend_mode ordinal

// Hard stroke overlaid on the BLUR ring (focus_ring_blur_stroke{,_position,_width}).
// Stamped on every SHOW. A CAShapeLayer sublayer of the backdrop window's root
// (built in payload_focus_surface_create, configured in payload_focus_surface_sync); the
// position is the layer's zPosition vs the frosted band (0 = above, 1 = below).
static bool  g_focus_ring_blur_stroke          = false;
static int   g_focus_ring_blur_stroke_position = 0;     // 0 = above band, 1 = below band
static float g_focus_ring_blur_stroke_width    = 2.0f;

// Final per-layer RGBA for the BLUR ring, resolved daemon-side from the
// focus_ring_blur_{,stroke_}{opacity,color} overrides (each inherits the base
// focus_ring_color/opacity when unset). _tint_ = the frosted color wash, _strokeclr_
// = the hard stroke overlay. Stamped on every SHOW; applied verbatim (no inherit
// logic here). Defaults mirror the base ring color/opacity.
static float g_focus_ring_blur_tint_r = 1.00f, g_focus_ring_blur_tint_g = 1.00f,
             g_focus_ring_blur_tint_b = 1.00f, g_focus_ring_blur_tint_a = 0.05f;
static float g_focus_ring_blur_strokeclr_r = 1.00f, g_focus_ring_blur_strokeclr_g = 1.00f,
             g_focus_ring_blur_strokeclr_b = 1.00f, g_focus_ring_blur_strokeclr_a = 0.05f;
// Edge feather (focus_ring_blur_feather) — gaussianBlur radius applied to the band's
// alpha mask so its edges soften. 0 = off (sharp band).
static float g_focus_ring_blur_feather = 0.0f;

// Per-KIND style banks. The daemon resolves the desktop_* overrides into the
// SAME wire fields as the main ring, so the shared g_focus_ring_* globals above
// always hold whichever SHOW landed LAST — a desktop show would leak its style
// into any window-ring redraw that happens WITHOUT a fresh SHOW (the FR-9 park
// before a space switch, fade/space reveals, the t3d follower), and vice versa.
// Every SHOW stamps the bank for its ring kind (req.wid == 0 = desktop);
// payload_focus_surface_sync reads the bank matching the slot it's drawing.
// Defaults mirror the daemon's FOCUS_RING_DEFAULT_* / payload globals so a
// pre-first-SHOW park still renders sanely.
struct fr_style_bank {
    float band_width;
    int   blur;
    float sat, bri, con, hue;
    float feather;
    int   blend;
    float tint_r, tint_g, tint_b, tint_a;
    float strokeclr_r, strokeclr_g, strokeclr_b, strokeclr_a;
};
#define FR_STYLE_BANK_DEFAULTS {                          \
    .band_width = 7.0f, .blur = 1,                        \
    .sat = 0.40f, .bri = 0.40f, .con = 2.0f, .hue = 5.0f, \
    .feather = 0.0f, .blend = 0,                          \
    .tint_r = 1.0f, .tint_g = 1.0f, .tint_b = 1.0f, .tint_a = 0.05f, \
    .strokeclr_r = 1.0f, .strokeclr_g = 1.0f, .strokeclr_b = 1.0f, .strokeclr_a = 0.05f, \
}
static struct fr_style_bank g_fr_style_main    = FR_STYLE_BANK_DEFAULTS;
static struct fr_style_bank g_fr_style_desktop = FR_STYLE_BANK_DEFAULTS;
// Discrete-transition animation (focus_ring_animate{,_duration}) — when set, the BLUR
// band's mask mutations on a SHOW are wrapped in an animated CATransaction; live-drag
// tracking always passes animated=false so the band stays glued to the window.
static bool  g_focus_ring_animate          = true;
static float g_focus_ring_animate_duration = 0.25f;
// Crossfade-between-windows duration (focus_ring_fade_duration). On a focus change
// the outgoing ring window fades 1->0 while the incoming fades 0->1 over this, both
// driven by the g_focus_fade animator. 0 (or animate off) => instant snap, no fade.
static float g_focus_ring_fade_duration    = 0.15f;
// Whole-window translucency (focus_ring `alpha` knob) — the window's NORMAL alpha
// slot, stamped on every SHOW. Show/hide + fades live on the SYSTEM alpha slot
// (the compositor multiplies the two), so visibility never clobbers this value.
static float g_focus_ring_window_alpha     = 1.0f;

// FR-21 xray (focus_ring_xray{,_color}) — recolor the band segments that overlap
// another window's frame. Stamped on every SHOW: flag + RGBA from config, plus the
// overlapping windows' SCREEN-SPACE frames resolved daemon-side. Full frames, not
// precomputed intersections — the clipped re-stroke recomputes the visible overlap
// on every redraw, so the per-frame follower tracks an animated target for free.
// Renders on the sharp (blur=0) band directly, and on the frosted ring's
// stroke overlay (focus_ring_blur_stroke / inner_stroke). Rects go stale until
// the next SHOW when a FOREIGN window moves — a documented prototype limit.
static bool   g_focus_ring_xray       = false;
static float  g_focus_ring_xray_r     = 0.25f, g_focus_ring_xray_g = 0.78f,
              g_focus_ring_xray_b     = 1.00f, g_focus_ring_xray_a = 1.00f;
static int    g_focus_ring_xray_count = 0;
static CGRect g_focus_ring_xray_rects[SA_FOCUS_RING_XRAY_MAX_RECTS];

// Outset (px) applied to each shipped frame before clipping. The stroke band
// sits entirely OUTSIDE the target rect (inner edge flush with the window
// bounds), so a window at the exact same rect as the target — or sharing an
// edge — would meet the band edge-on with zero-area overlap and never recolor.
// The outset lets such windows reach this many px into the band.
#define FOCUS_RING_XRAY_TOLERANCE 2.0f

// blend_mode ordinal -> CAFilter compositingFilter type. Index 0 (NORMAL) is nil
// (no filter). Order MUST match enum focus_ring_blend_mode in focus_ring.h — the
// ordinal is the SHOW wire contract, so append, never reorder.
static NSString * const g_focus_ring_blend_filter_types[] = {
    nil,                    //  0 NORMAL (no compositing filter)
    @"multiplyBlendMode",   //  1 MULTIPLY
    @"screenBlendMode",     //  2 SCREEN
    @"overlayBlendMode",    //  3 OVERLAY
    @"darkenBlendMode",     //  4 DARKEN
    @"lightenBlendMode",    //  5 LIGHTEN
    @"colorDodgeBlendMode", //  6 COLOR_DODGE
    @"colorBurnBlendMode",  //  7 COLOR_BURN
    @"softLightBlendMode",  //  8 SOFT_LIGHT
    @"hardLightBlendMode",  //  9 HARD_LIGHT
    @"differenceBlendMode", // 10 DIFFERENCE
    @"exclusionBlendMode",  // 11 EXCLUSION
    @"hueBlendMode",        // 12 HUE
    @"saturationBlendMode", // 13 SATURATION
    @"colorBlendMode",      // 14 COLOR
    @"luminosityBlendMode", // 15 LUMINOSITY
};
#define FOCUS_RING_BLEND_COUNT \
    ((int)(sizeof(g_focus_ring_blend_filter_types) / sizeof(g_focus_ring_blend_filter_types[0])))

#define FOCUS_RING_STROKE_WIDTH  (g_focus_ring_stroke_width)
#define FOCUS_RING_R             (g_focus_ring_stroke_r)
#define FOCUS_RING_G             (g_focus_ring_stroke_g)
#define FOCUS_RING_B             (g_focus_ring_stroke_b)
#define FOCUS_RING_A             (g_focus_ring_stroke_alpha)
#define FOCUS_RING_LEVEL         19
#define FOCUS_RING_DEFAULT_RGBA  0x00000000  // fully transparent overlay fill

// Ring visibility/fade writes — the window's SYSTEM alpha slot (txn op 0x0e), a
// second alpha the compositor multiplies with the normal slot. The normal slot
// belongs to the user's `alpha` config knob (g_focus_ring_window_alpha), so
// show/hide and fades can never clobber it and need no save/restore. The slot is
// privileged (universal-owner gate) and the instant singular SPI isn't exported
// on Tahoe, so writes go through a transaction on Dock's main cid — the shared
// per-VBL tx when the caller has one, else a one-shot. Owner-cid threading is
// unnecessary here: the universal-owner connection passes the gate for any wid.
static void fr_stroke_note_alpha(uint32_t wid, float a);   // defined after the stroke pool below

static void payload_focus_set_system_alpha(CFTypeRef tx, uint32_t wid, float a)
{
    if (!wid) return;
    fr_stroke_note_alpha(wid, a);
    if (tx) { SLSTransactionSetWindowSystemAlpha(tx, wid, a); return; }
    CFTypeRef t = SLSTransactionCreate(SLSMainConnectionID());
    if (!t) return;
    SLSTransactionSetWindowSystemAlpha(t, wid, a);
    SLSTransactionCommit(t, 0);
    CFRelease(t);
}

// =========================================================================
// MC-thumbnail occlusion knobs. They PERSIST across stroke-window
// destroy/create cycles
// (file-static, NOT part of g_payload_focus_stroke, which is zeroed on
// destroy); the wid itself is ephemeral, so any per-wid SLS state that must
// survive a focus change is RE-APPLIED from these globals at create time.
//
// Defaults are BELOW-target at level 0: MC thumbnail compositing does not
// honor the overlay's transparency, so a topmost ring blanks the target's
// thumbnail. Ordering below (effective only when ring and target share a
// level) lets the window render into its thumbnail.
// =========================================================================
static uint64_t g_payload_focus_ring_extra_tags    = 0;    // debug bookkeeping only, never applied at create
static int      g_payload_focus_ring_level          = 0;    // SLS window level
static bool     g_payload_focus_ring_order_below    = true; // order below target wid
static bool     g_payload_focus_ring_color_override = false;// once set, rgba knob owns alpha (SHOW won't restamp from config)

// Overlay model: ONE DISPLAY-SIZED transparent surface per focused display,
// pinned at the display origin and never moved or resized. The band is placed
// at the target's display-relative position by the CA layer paths; a window
// move OR resize is just a path update at the new local rect — no SLS
// move/shape op, no per-target surface, no recreate-on-grow (the window can't
// exceed its display). The CA flush lands on this payload thread microseconds
// before the t3d batch commit, so it composites on the same refresh.

// =========================================================================
// payload_focus_ring_log — file log (PAYLOAD_FR_LOG_PATH) shared with the
// daemon's stream so the two interleave by timestamp. Atomic single-write
// (write() to an O_APPEND fd, under PIPE_BUF) so lines don't tear under load.
// =========================================================================
static int g_payload_focus_ring_log_fd = -1;
static pthread_once_t g_payload_focus_ring_log_once = PTHREAD_ONCE_INIT;

#ifndef YB_LOG_TREE
#define YB_LOG_TREE "unknown"
#endif
#define PAYLOAD_FR_LOG_DIR  "/tmp/logs/yabai/" YB_LOG_TREE
#define PAYLOAD_FR_LOG_PATH PAYLOAD_FR_LOG_DIR "/focus_ring.log"

static void payload_focus_ring_log_open(void)
{
    mkdir("/tmp/logs", 0755);
    mkdir("/tmp/logs/yabai", 0755);
    mkdir(PAYLOAD_FR_LOG_DIR, 0755);
    g_payload_focus_ring_log_fd = open(PAYLOAD_FR_LOG_PATH,
                                        O_WRONLY | O_CREAT | O_APPEND,
                                        0644);
}

static void payload_focus_ring_log(const char *source, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static void payload_focus_ring_log(const char *source, const char *fmt, ...)
{
#if !YB_PAYLOAD_LOG
    // Dev-only file log, compiled out with logpf (see logp.inc.m).
    (void)source; (void)fmt;
    return;
#endif
    pthread_once(&g_payload_focus_ring_log_once, payload_focus_ring_log_open);
    if (g_payload_focus_ring_log_fd < 0) return;

    char buf[512];
    int off = 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    int n = snprintf(buf + off, sizeof(buf) - off,
                     "[%ld.%09ld] [payload] [%s] ",
                     (long)ts.tv_sec, (long)ts.tv_nsec, source);
    if (n < 0 || (size_t)n >= sizeof(buf) - off) return;
    off += n;

    va_list ap;
    va_start(ap, fmt);
    n = vsnprintf(buf + off, sizeof(buf) - off, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof(buf) - off) n = (int)(sizeof(buf) - off - 1);
    off += n;

    if (off < (int)sizeof(buf) - 1) buf[off++] = '\n';
    (void)write(g_payload_focus_ring_log_fd, buf, (size_t)off);
}

// =========================================================================
// State — two structs split by lifetime:
//   g_payload_focus_ring   — config-level: SET_VISIBLE flag + last-focus
//                            shadow the t3d batch hook reads ("is the wid
//                            being animated the focused one?"). Persists
//                            across stroke-window destroy/create cycles.
//   g_payload_focus_stroke — instance-level: the Dock-cid SLS window, its
//                            CA tree, geometry, and the managed sid it's
//                            attached to. Lives from first SHOW to HIDE /
//                            focus-loss.
// =========================================================================

static struct {
    bool     visible;       // SET_VISIBLE: true => alpha 1, false => alpha 0
    uint32_t target_wid;    // last SHOW target — t3d hook's filter key
    float    target_radius;
} g_payload_focus_ring;

// FR-9: per-space ring pool. One overlay per managed space, each parked on that
// space's last-focused window and held as a genuine SLSMoveWindowsToManagedSpace
// member of the space — so on a space switch it rides the slide transform for
// free (no per-frame mirroring). g_active_stroke points at the entry for the
// currently-focused space; single-overlay code paths operate on it via the
// g_payload_focus_stroke macro below.
struct focus_stroke {
    bool            initialized;    // true once the SLS window is alive
    uint32_t        wid;            // our stroke window (Dock-cid owned)
    int             owner_cid;      // Dock cid that owns wid
    uint32_t        target_wid;     // target we're tracking
    float           target_radius;
    CGRect          target_rect;    // last target rect in screen coords
    CGPoint         surface_origin; // surface's screen origin (= display origin)
    CGSize          surface_size;   // surface dimensions (= display size)
    uint64_t        attached_sid;   // managed space the window is attached to
    uint64_t        last_used_mach; // LRU stamp (mach_absolute_time at last SHOW)
    float           last_alpha;     // last SYSTEM alpha written for wid (advisory —
                                    // see fr_stroke_note_alpha; consulted by the
                                    // space-switch reveal's already-lit skip)
    // The CA tree (type-5 layer-backed window, all rings). The retained
    // CAContext owns the layer tree; the layer refs are retained references we
    // re-touch each SHOW in payload_focus_surface_sync.
    id              ca_ctx;         // CAContext
    id              ca_backdrop;    // CABackdropLayer (behind-window blur; hidden at blur=0)
    id              ca_mask;        // CAShapeLayer (rounded band mask on the backdrop)
    id              ca_tint;        // CALayer color wash over the sampled band (band color/opacity + blend)
    id              ca_stroke;      // CAShapeLayer hard stroke overlay (focus_ring inner_stroke)
    id              ca_xray;        // CAShapeLayer xray recolor over ca_stroke, masked to the
                                    // overlap rects (FR-21; its mask layer is owned via setMask:)
    pthread_mutex_t ctx_lock;       // serializes sync/draw vs destroy across threads
};

#define FR_MAX_SPACES 16
static struct focus_stroke g_focus_stroke_pool[FR_MAX_SPACES] = {
    [0 ... FR_MAX_SPACES - 1] = { .ctx_lock = PTHREAD_MUTEX_INITIALIZER }
};
static struct focus_stroke *g_active_stroke = &g_focus_stroke_pool[0];

// All legacy single-overlay code reads/writes "the active space's overlay".
#define g_payload_focus_stroke (*g_active_stroke)

// Note the last SYSTEM alpha written for a ring wid on its pool entry. Advisory
// state for the space-switch reveal ("already lit → don't re-fade"): every ring
// alpha write funnels through payload_focus_set_system_alpha, EXCEPT the space
// slide's exit-ride settle (a pump-tx write inside the animator) — for that,
// payload_focus_ring_adopt_for_exit pre-stamps 0. Cross-thread races are benign:
// wrong by at most one write, and the predicate then degrades to a redundant
// fade or a skipped one, never a stuck ring.
static void fr_stroke_note_alpha(uint32_t wid, float a)
{
    if (!wid) return;
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (g_focus_stroke_pool[i].wid == wid) { g_focus_stroke_pool[i].last_alpha = a; return; }
    }
}

// Forward decl: draw is defined below the lifecycle helpers.
static void payload_focus_stroke_draw(float radius, bool animated);

// Display id whose bounds contain `r`'s center (falls back to main). The fade /
// mirror animators resolve their ca_clock did from the ring's rect with this so
// they pace on the panel the ring lives on (AC-7).
static uint32_t payload_focus_display_id_for(CGRect r)
{
    extern CGError CGGetDisplaysWithPoint(CGPoint point, uint32_t max_displays,
                                          CGDirectDisplayID *displays, uint32_t *count);
    CGPoint c = { r.origin.x + r.size.width  / 2.0f,
                  r.origin.y + r.size.height / 2.0f };
    CGDirectDisplayID did = 0;
    uint32_t count = 0;
    if (CGGetDisplaysWithPoint(c, 1, &did, &count) != kCGErrorSuccess || count == 0) {
        did = CGMainDisplayID();
    }
    return did;
}

// Screen rect of the display containing `r`'s center (falls back to main).
static CGRect payload_focus_display_rect_for(CGRect r)
{
    return CGDisplayBounds(payload_focus_display_id_for(r));
}

// Effective background-blur radius (px). 0 = unblurred band; > 0 = frosted.
// The daemon infers its style enum from this same radius (FR-22). Only the
// gaussian filter and the xray seam shape key off it — every other knob
// applies at any radius.
static int payload_focus_blur_effective(void)
{
    return g_focus_ring_blur_radius;
}

// Width (px) of the FROSTED border band. Tracks focus_ring_width raw — no
// floor/clamp, same as the sharp (blur=0) band (at small widths the vibrancy
// just gets faint).
static float payload_focus_blur_band_width(void)
{
    return FOCUS_RING_STROKE_WIDTH;
}

// =========================================================================
// The ring surface = type-5 layer-backed window + CA tree (ALL rings).
// Frosted band recipe matches AppKit's
// +[CABackdropLayer(NSBehindWindowLayer) behindWindowLayer]:
//   type-5 layer-backed SLS window -> CAContext -> root CALayer
//     -> CABackdropLayer (KVC groupName/scale/windowServerAware + a gaussianBlur
//        CAFilter) masked by a CAShapeLayer (rounded outer+inner band).
// The mask confines the frost to the band; the rounded cutout reads SHARP.
// Runs on Dock's MAIN cid — the behind-window blur composites there, no
// dedicated connection needed. At blur=0 the same pipeline renders unblurred
// (no gaussian filter, sampling scale 1.0); the classic solid ring is the
// tint wash at full alpha.
// =========================================================================

// Create the type-5 layer-backed window + the CA tree, retaining the layers we
// re-touch each SHOW (payload_focus_surface_sync). Returns false (and releases
// the window) on any failure; *out_wid set on success.
static bool payload_focus_surface_create(int cid, CGRect surface_rect, uint32_t *out_wid)
{
    extern int     SLSNewWindow(int cid, int type, float x, float y, CFTypeRef region, uint32_t *wid);
    extern CGError SLSReleaseWindow(int cid, uint32_t wid);
    extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
    extern void    SLSSetWindowOpacity(int cid, uint32_t wid, bool isOpaque);
    extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
    extern CGError SLSSetWindowResolution(int cid, uint32_t wid, double res);
    extern void    SLSWindowSetShadowProperties(uint32_t wid, CFDictionaryRef properties);
    extern CGError SLSSetWindowLayerContext(int cid, uint32_t wid, CGContextRef context);
    extern CGError SLSSetWindowTitle(int cid, uint32_t wid, CFStringRef title);

    *out_wid = 0;

    // type-5 (unbuffered, layer-backed) window; region carries SHAPE only at (0,0),
    // screen position goes in the x/y args (created directly at its final spot).
    CGRect shape = CGRectMake(0.0, 0.0, surface_rect.size.width, surface_rect.size.height);
    CGSRegionRef region = NULL;
    if (CGSNewRegionWithRect(&shape, &region) != kCGErrorSuccess || !region) return false;
    uint32_t wid = 0;
    int rc = SLSNewWindow(cid, 5, surface_rect.origin.x, surface_rect.origin.y, region, &wid);
    CFRelease(region);
    if (rc != 0 || !wid) return false;

    uint64_t tags = (1ULL << 46 | 1ULL << 9);   // kCGSMergesWithMenuBar + kCGSIgnoreForEventsTagBit (click-through)
    SLSSetWindowTags(cid, wid, &tags, 64);
    // WindowServer auto-applies bit 45 (kSLSMenuBarTagBit) + bit 46 (MergesWithMenuBar)
    // to windows created on Dock's MAIN connection. Bit 45 pins us to the menu-bar
    // origin (0,0) regardless of our move and breaks blur compositing, so clear it on
    // every (re)create; bit 46 we keep as a default tag (set above).
    extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
    uint64_t clear_menubar = (1ULL << 45);
    SLSClearWindowTags(cid, wid, &clear_menubar, 64);
    SLSSetWindowResolution(cid, wid, 2.0);
    SLSSetWindowOpacity(cid, wid, 0);
    SLSSetWindowLevel(cid, wid, g_payload_focus_ring_level);
    SLSSetWindowTitle(cid, wid, CFSTR("Focus Ring Quartz"));

    CFIndex shadow_density = 0;
    CFNumberRef dens = CFNumberCreate(NULL, kCFNumberCFIndexType, &shadow_density);
    CFDictionaryRef shadow_props = CFDictionaryCreate(NULL,
        (const void *[]){CFSTR("com.apple.WindowShadowDensity")},
        (const void *[]){dens}, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SLSWindowSetShadowProperties(wid, shadow_props);
    CFRelease(dens);
    CFRelease(shadow_props);

    // Build the CA tree inside a scoped pool (the SA handler thread has no ambient
    // autorelease pool); RETAIN the three objects we keep so they survive the drain.
    bool ok = false;
    uint32_t dbg_ctx_id  = 0;              // DIAG: CAContext slot id (0 = never registered with render server)
    CGError  dbg_bind_rc = (CGError)-999;  // DIAG: SLSSetWindowLayerContext result
    @autoreleasepool {
        Class CAContextCls  = NSClassFromString(@"CAContext");
        Class CALayerCls    = NSClassFromString(@"CALayer");
        Class CABackdropCls = NSClassFromString(@"CABackdropLayer");
        Class CAShapeCls    = NSClassFromString(@"CAShapeLayer");
        Class CATxCls       = NSClassFromString(@"CATransaction");
        if (CAContextCls && CALayerCls && CABackdropCls && CAShapeCls) {
            CGRect bounds = CGRectMake(0.0, 0.0, surface_rect.size.width, surface_rect.size.height);

            id ctx  = ((id (*)(id, SEL, id)) objc_msgSend)(CAContextCls, @selector(remoteContextWithOptions:), @{});
            id root = ((id (*)(id, SEL)) objc_msgSend)(CALayerCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(root, @selector(setFrame:), bounds);
            // y-DOWN geometry so the sampled backdrop displays right-side-up
            // (matches the screen + our y-down mask path).
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(root, @selector(setGeometryFlipped:), YES);

            // CABackdropLayer configured for behind-window sampling exactly as
            // AppKit's behindWindowLayer (KVC defaults dict).
            id bd = ((id (*)(id, SEL)) objc_msgSend)(CABackdropCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(bd, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, id, id)) objc_msgSend)(bd, @selector(setValue:forKey:),
                @"NSCGSWindowBehindWindowCaptureBackdropGroup", @"groupName");
            ((void (*)(id, SEL, id, id)) objc_msgSend)(bd, @selector(setValue:forKey:), @(0.25), @"scale");
            ((void (*)(id, SEL, id, id)) objc_msgSend)(bd, @selector(setValue:forKey:), @YES, @"windowServerAware");

            // Mask = even-odd rounded band (opaque in the band, alpha-0 cutout).
            // Path is set per-SHOW in payload_focus_surface_sync.
            id mask = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(mask, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, id)) objc_msgSend)(mask, @selector(setFillRule:), @"even-odd");
            CGColorRef blk = CGColorCreateGenericRGB(0, 0, 0, 1);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(mask, @selector(setFillColor:), blk);
            if (blk) CGColorRelease(blk);
            ((void (*)(id, SEL, id)) objc_msgSend)(bd, @selector(setMask:), mask);

            // Color wash over the blur — a SUBLAYER of the backdrop, so the band mask
            // clips it too. Its backgroundColor (ring color @ focus_ring_opacity) is
            // (re)set each SHOW in payload_focus_surface_sync.
            id tint = ((id (*)(id, SEL)) objc_msgSend)(CALayerCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(tint, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, id)) objc_msgSend)(bd, @selector(addSublayer:), tint);

            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), bd);

            // Hard stroke overlay (focus_ring_blur_stroke). A SIBLING of the backdrop
            // under root (NOT a sublayer of bd, so the band mask doesn't clip it — its
            // own path bounds the draw). fillColor=clear; strokeColor/lineWidth/path and
            // the above/below zPosition are (re)set each SHOW in payload_focus_surface_sync.
            // Created unconditionally so the blur_stroke knob is a live toggle (no window
            // recreate); hidden when disabled.
            id stroke = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(stroke, @selector(setFrame:), bounds);
            CGColorRef clear = CGColorCreateGenericRGB(0, 0, 0, 0);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(stroke, @selector(setFillColor:), clear);
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(stroke, @selector(setHidden:), YES);
            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), stroke);

            // FR-21 xray recolor over the stroke overlay: same seam path stroked in
            // the xray color, MASKED to the overlap rects so only the segments over
            // another window recolor. The mask CAShapeLayer is owned by the layer
            // (setMask: retains); its rect-union path is (re)set each SHOW in
            // payload_focus_surface_sync. Created unconditionally + hidden, like the
            // stroke, so the knobs stay live toggles (no window recreate).
            id xray = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(xray, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(xray, @selector(setFillColor:), clear);
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(xray, @selector(setHidden:), YES);
            id xmask = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(xmask, @selector(setFrame:), bounds);
            CGColorRef xopaque = CGColorCreateGenericRGB(0, 0, 0, 1);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(xmask, @selector(setFillColor:), xopaque);
            if (xopaque) CGColorRelease(xopaque);
            ((void (*)(id, SEL, id)) objc_msgSend)(xray, @selector(setMask:), xmask);
            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), xray);
            if (clear) CGColorRelease(clear);

            ((void (*)(id, SEL, id)) objc_msgSend)(ctx, @selector(setLayer:), root);

            g_payload_focus_stroke.ca_ctx      = ((id (*)(id, SEL)) objc_msgSend)(ctx,    @selector(retain));
            g_payload_focus_stroke.ca_backdrop = ((id (*)(id, SEL)) objc_msgSend)(bd,     @selector(retain));
            g_payload_focus_stroke.ca_mask     = ((id (*)(id, SEL)) objc_msgSend)(mask,   @selector(retain));
            g_payload_focus_stroke.ca_tint     = ((id (*)(id, SEL)) objc_msgSend)(tint,   @selector(retain));
            g_payload_focus_stroke.ca_stroke   = ((id (*)(id, SEL)) objc_msgSend)(stroke, @selector(retain));
            g_payload_focus_stroke.ca_xray     = ((id (*)(id, SEL)) objc_msgSend)(xray,   @selector(retain));

            dbg_bind_rc = SLSSetWindowLayerContext(cid, wid, (CGContextRef)ctx);
            dbg_ctx_id  = (uint32_t)((unsigned int (*)(id, SEL)) objc_msgSend)(ctx, sel_registerName("contextId"));
            if (CATxCls) ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(flush));
            ok = true;
        }
    }

    if (!ok) {
        SLSReleaseWindow(cid, wid);
        payload_focus_ring_log("blur_create_fail", "reason=ca_tree wid=%u", wid);
        return false;
    }

    SLSOrderWindow(cid, wid, 1, 0);
    payload_focus_ring_log("surface_bind", "wid=%u ctxId=%u bind_rc=%d", wid, dbg_ctx_id, (int)dbg_bind_rc);
    *out_wid = wid;
    return true;
}

// ---------------------------------------------------------------------------
// Feathered-band mask image (focus_ring_blur_feather).
//
// Filtering a CALayer used as a *mask* breaks the masking — CA fills/ignores
// the shape and the hole collapses (both even-odd fills and strokes). So the
// feather is NOT a live filter on the mask layer; the band's alpha is
// pre-rendered into a CGImage handed to the mask as `contents`.
//
// Order matters: blur the FILLED outer shape FIRST, then cut the hole SHARP.
// That keeps the window center clear and the inner edge crisp against the
// window — only the OUTER edge feathers into the desktop. The blur is the
// CoreGraphics shadow trick (draw the shape far offscreen, keep only its
// blurred shadow) — pure CG, no CALayer filter.
//
// Cached by geometry so a pure-move drag reuses the image (only a resize /
// param change re-renders). The band is symmetric on both axes, so the
// CGImage's y-up origin vs the layer's y-down geometry needs no flip.
static CGImageRef s_fm_img      = NULL;
static float      s_fm_w        = -1, s_fm_h = -1, s_fm_corner = -1,
                  s_fm_bw       = -1, s_fm_bleed = -1, s_fm_feather = -1;
static bool       s_fm_inset    = false;
static CGSize     s_fm_img_size = { 0, 0 };   // image extent in points

static void payload_focus_feather_mask_refresh(float w, float h, float corner,
                                               float bw, float bleed, float feather,
                                               bool inset)
{
    if (s_fm_img && s_fm_w == w && s_fm_h == h && s_fm_corner == corner &&
        s_fm_bw == bw && s_fm_bleed == bleed && s_fm_feather == feather &&
        s_fm_inset == inset) {
        return;   // cache hit — geometry unchanged
    }
    if (s_fm_img) { CGImageRelease(s_fm_img); s_fm_img = NULL; }

    float  pad   = feather + 2.0f;
    // LOCAL geometry: window placed so `outer` starts at (pad,pad); image extent =
    // outer size + 2*pad (room for the blurred outer edge on every side). INSET
    // (desktop ring): outer IS the target rect — band grows inward — so the target
    // sits at (pad,pad) directly and the hole eats the band width as well.
    CGRect inner   = CGRectMake(pad + (inset ? 0.0f : bw), pad + (inset ? 0.0f : bw), w, h);
    CGRect outer   = inset ? inner : CGRectInset(inner, -bw, -bw);
    float  outer_r = inset ? 0.0f : corner + bw; if (outer_r < 0.0f) outer_r = 0.0f;
    // Radius lives on the seam in both modes (see payload_focus_surface_sync):
    // the hole keeps the configured corner even though it moves inward by bw.
    float  hole_in = bleed + (inset ? bw : 0.0f);
    CGRect hole    = CGRectInset(inner, hole_in, hole_in);
    float  hole_r  = corner - bleed; if (hole_r < 0.0f) hole_r = 0.0f;
    float  img_w   = outer.size.width  + 2.0f * pad;
    float  img_h   = outer.size.height + 2.0f * pad;

    size_t pxw = (size_t)(img_w + 0.999f);
    size_t pxh = (size_t)(img_h + 0.999f);
    if (pxw == 0 || pxh == 0) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, pxw, pxh, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return;

    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    float OFF = img_w + 1000.0f;

    if (inset) {
        // INSET (desktop ring): the OUTER edge hugs the display boundary, so a
        // feather there is invisible (it ramps off the screen edge) — the soft
        // edge belongs on the HOLE, the band's on-screen inner edge. Fill the
        // outer shape SHARP first, then knock the hole out with a BLURRED alpha:
        // render the hole's blurred mass into its own bitmap (same offscreen-
        // shadow trick) and erase it via destination-out. Outer edge stays
        // crisp/flush; only the inner edge ramps into the band.
        CGContextSetFillColorWithColor(c, white);
        CGMutablePathRef op = CGPathCreateMutable();
        CGPathAddRoundedRect(op, NULL, outer, outer_r, outer_r);
        CGContextAddPath(c, op);
        CGContextFillPath(c);
        CGPathRelease(op);

        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        CGContextRef hctx = CGBitmapContextCreate(NULL, pxw, pxh, 8, 0, cs2, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs2);
        if (hctx) {
            CGContextSetShadowWithColor(hctx, CGSizeMake(OFF, 0), feather, white);
            CGContextSetFillColorWithColor(hctx, white);
            CGMutablePathRef hp = CGPathCreateMutable();
            CGPathAddRoundedRect(hp, NULL, CGRectOffset(hole, -OFF, 0), hole_r, hole_r);
            CGContextAddPath(hctx, hp);
            CGContextFillPath(hctx);
            CGPathRelease(hp);
            CGImageRef himg = CGBitmapContextCreateImage(hctx);
            CGContextRelease(hctx);
            if (himg) {
                // Both bitmaps share extent + origin, so a full-rect draw aligns 1:1.
                CGContextSetBlendMode(c, kCGBlendModeDestinationOut);
                CGContextDrawImage(c, CGRectMake(0, 0, (CGFloat)pxw, (CGFloat)pxh), himg);
                CGImageRelease(himg);
            }
        }
    } else {
        // OUTSET (window ring): blur the filled OUTER shape via the shadow-offset
        // trick — draw it OFF px to the left (offscreen) so only its blurred
        // shadow lands at the real outer position — then cut the hole SHARP
        // (shadow off, clear blend). Clear center, crisp inner edge against the
        // window; the outer edge feathers out into the desktop.
        CGContextSetShadowWithColor(c, CGSizeMake(OFF, 0), feather, white);
        CGContextSetFillColorWithColor(c, white);
        CGMutablePathRef op = CGPathCreateMutable();
        CGPathAddRoundedRect(op, NULL, CGRectOffset(outer, -OFF, 0), outer_r, outer_r);
        CGContextAddPath(c, op);
        CGContextFillPath(c);
        CGPathRelease(op);

        CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
        CGContextSetBlendMode(c, kCGBlendModeClear);
        CGMutablePathRef hp = CGPathCreateMutable();
        CGPathAddRoundedRect(hp, NULL, hole, hole_r, hole_r);
        CGContextAddPath(c, hp);
        CGContextFillPath(c);
        CGPathRelease(hp);
    }

    CGColorRelease(white);
    s_fm_img      = CGBitmapContextCreateImage(c);
    s_fm_img_size = CGSizeMake(img_w, img_h);
    CGContextRelease(c);

    s_fm_w = w; s_fm_h = h; s_fm_corner = corner;
    s_fm_bw = bw; s_fm_bleed = bleed; s_fm_feather = feather;
    s_fm_inset = inset;
}

// Update the live overlay each SHOW (every ring, FR-24): the band ALWAYS
// renders through the backdrop pipeline — blur is just one filter knob on it
// (radius 0 = unblurred band), so tint/blend/saturation/brightness/contrast/
// feather apply at ANY radius. Set the filter chain + the rounded band mask
// path (outer-minus-inner around the target, surface-local), then flush the
// CA transaction (no runloop in the SA handler). `corner` = target corner radius.
static void payload_focus_surface_sync(float corner, bool animated)
{
    if (!g_payload_focus_stroke.ca_backdrop || !g_payload_focus_stroke.ca_mask) return;

    @autoreleasepool {
        Class CAFilterCls = NSClassFromString(@"CAFilter");
        Class CATxCls     = NSClassFromString(@"CATransaction");

        // Gate Core Animation's implicit actions: on a DISCRETE transition (animated)
        // the band's mask move/crossfade eases over animate_duration; during live
        // tracking (animated=false) actions are disabled so the band glues to the
        // window (an implicit animation there would make it trail). The whole mutation
        // body runs inside this one transaction.
        if (CATxCls) {
            ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(begin));
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(CATxCls, @selector(setDisableActions:), animated ? NO : YES);
            if (animated) {
                ((void (*)(id, SEL, CFTimeInterval)) objc_msgSend)(CATxCls, @selector(setAnimationDuration:),
                                                                   (CFTimeInterval)g_focus_ring_animate_duration);
            }
        }

        // Style comes from the per-KIND bank (see fr_style_bank), NOT the shared
        // globals — this sync may be a park/reveal/follower redraw long after a
        // SHOW for the OTHER ring kind re-stamped the globals.
        const struct fr_style_bank *stb = (g_payload_focus_stroke.target_wid == 0)
                                        ? &g_fr_style_desktop : &g_fr_style_main;
        int  radius  = stb->blur;
        bool frosted = radius > 0;

        // The backdrop samples behind-window content at quarter resolution by
        // default (invisible under blur, AppKit's perf choice). Unblurred
        // (radius 0) the pixelation would show wherever tint alpha < 1, so
        // sample at full resolution there.
        ((void (*)(id, SEL, id, id)) objc_msgSend)(g_payload_focus_stroke.ca_backdrop,
            @selector(setValue:forKey:), frosted ? @(0.25) : @(1.0), @"scale");

        if (CAFilterCls) {
            // Backdrop filter chain: gaussianBlur only when radius > 0, plus
            // colorSaturate / colorBrightness / colorContrast appended ONLY
            // when non-identity (an unconfigured band carries no extra
            // filters). These adjust the sampled behind-window content — at
            // ANY radius (FR-24: blur is just one knob, not a mode).
            NSMutableArray *filters = [NSMutableArray array];
            if (frosted) {
                id blur = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"gaussianBlur");
                if (blur) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(blur, @selector(setValue:forKey:), @(radius), @"inputRadius");
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(blur, @selector(setValue:forKey:), @YES, @"inputNormalizeEdges");
                    [filters addObject:blur];
                }
            }
            if (stb->sat != 1.0f) {
                id sat = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorSaturate");
                if (sat) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(sat, @selector(setValue:forKey:), @(stb->sat), @"inputAmount");
                    [filters addObject:sat];
                }
            }
            if (stb->bri != 0.0f) {
                id bright = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorBrightness");
                if (bright) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(bright, @selector(setValue:forKey:), @(stb->bri), @"inputAmount");
                    [filters addObject:bright];
                }
            }
            if (stb->con != 1.0f) {
                id contrast = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorContrast");
                if (contrast) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(contrast, @selector(setValue:forKey:), @(stb->con), @"inputAmount");
                    [filters addObject:contrast];
                }
            }
            // colorHueRotate rotates the sampled frost's hue around the wheel.
            // inputAngle is RADIANS; the daemon knob is degrees, converted here.
            if (stb->hue != 0.0f) {
                id hue = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorHueRotate");
                if (hue) {
                    double angle = (double)stb->hue * (M_PI / 180.0);
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(hue, @selector(setValue:forKey:), @(angle), @"inputAngle");
                    [filters addObject:hue];
                }
            }
            ((void (*)(id, SEL, id)) objc_msgSend)(g_payload_focus_stroke.ca_backdrop, @selector(setFilters:), filters);
        }

        // Color wash over the sampled band: the band color at focus_ring_blur_opacity
        // (alpha 0 = pure sampled content, 1 = solid color — the "sharp ring" look).
        // Independent of the stroke overlay's color/alpha — both resolved daemon-side.
        // The backdrop's band mask clips it to the ring. Applies at any radius.
        if (g_payload_focus_stroke.ca_tint) {
            CGColorRef c = CGColorCreateGenericRGB(stb->tint_r, stb->tint_g,
                                                   stb->tint_b, stb->tint_a);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(g_payload_focus_stroke.ca_tint,
                                                           @selector(setBackgroundColor:), c);
            if (c) CGColorRelease(c);

            // Blend mode: the compositingFilter governing how the color wash blends
            // over the frosted blur beneath it. NORMAL (0) sets nil — clearing any
            // prior filter so toggling back to normal reverts to default source-over.
            id comp = nil;
            int bm = stb->blend;
            if (CAFilterCls && bm > 0 && bm < FOCUS_RING_BLEND_COUNT) {
                NSString *type = g_focus_ring_blend_filter_types[bm];
                if (type) comp = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), type);
            }
            ((void (*)(id, SEL, id)) objc_msgSend)(g_payload_focus_stroke.ca_tint,
                                                   @selector(setCompositingFilter:), comp);
        }

        // Rounded band in surface-LOCAL coords (screen rect minus surface_origin).
        // inner = the window cutout, outer = inner + band width.
        CGPoint o  = g_payload_focus_stroke.surface_origin;
        CGRect  t  = g_payload_focus_stroke.target_rect;
        float   bw = stb->band_width;
        // Desktop ring (target_wid == 0) renders INSET: its SHOW rect is the
        // desktop config's bounds, so an outward band would hang past the display
        // edge — flip the whole band inward instead. outer = the rect itself,
        // hole = rect − band width. Every seam-derived feature below (bleed,
        // inner_stroke, feather, xray) composes off the flipped hole, so the full
        // style stack inverts with it. Window rings keep the outward band.
        //
        // The configured radius always describes the SEAM (the hole edge) in both
        // modes: outset hole = the window rect at its own corner radius; inset the
        // radius rides the seam inward with the band, so desktop_radius rounds the
        // band's INNER edge while the outer edge stays square, flush against the
        // display boundary (rounding it would carve a gap at the screen corners).
        bool   inset = (g_payload_focus_stroke.target_wid == 0);
        CGRect inner = CGRectMake(t.origin.x - o.x, t.origin.y - o.y, t.size.width, t.size.height);
        CGRect outer = inset ? inner : CGRectInset(inner, -bw, -bw);
        float  outer_r = inset ? 0.0f : corner + bw; if (outer_r < 0.0f) outer_r = 0.0f;

        // Inner bleed: push the band's cutout INWARD past the window edge by
        // `bleed` so the frosted band overlaps a strip of the window itself. With
        // the ring ordered above the target (forced in do_focus_ring_show when
        // bleed > 0), the backdrop's behind-window capture samples that strip — the
        // window's own edge pixels frost outward into the halo, then this (smaller)
        // cutout keeps the center sharp. Clamp so the hole stays positive on small
        // windows (leave a few px of sharp center); bleed <= 0 reduces to the
        // original window-edge cutout.
        float  bleed = g_focus_ring_blur_bleed;
        // INSET mode the band width itself comes out of the hole too, so the
        // positive-hole cap applies to band + bleed combined.
        float  band_in = inset ? bw : 0.0f;
        float  bleed_cap = 0.5f * fminf(inner.size.width, inner.size.height) - 2.0f - band_in;
        if (bleed_cap < 0.0f) bleed_cap = 0.0f;
        if (bleed > bleed_cap) bleed = bleed_cap;
        if (bleed < 0.0f)      bleed = 0.0f;
        // hole_r = corner − bleed in BOTH modes: the radius lives on the seam, so
        // the band width never subtracts from it (inset mode the hole moves inward
        // by bw but keeps the configured radius).
        CGRect hole   = CGRectInset(inner, band_in + bleed, band_in + bleed);
        float  hole_r = corner - bleed; if (hole_r < 0.0f) hole_r = 0.0f;

        // The band mask has two forms, selected by focus_ring_blur_feather:
        //
        //   feather == 0 (sharp, default): an EVEN-ODD fill — outer rounded rect
        //     minus the hole — exactly as before. Crisp inner + outer edges.
        //
        //   feather  > 0 (soft): the band's CENTER-LINE stroked at width = band
        //     thickness, then gaussian-blurred. A stroke is a frame, not a fill, so
        //     blurring it only feathers a `feather`-wide ramp at each edge — it can
        //     NEVER fill the window center (the hole is preserved at any radius). An
        //     even-odd FILL, by contrast, collapses its hole under the blur (the
        //     "lost hole" bug). At feather→0 the centered stroke is pixel-identical
        //     to the even-odd band, so this is a clean continuation, not a separate
        //     look. lineWidth = (outer−hole) thickness; the centerline sits midway
        //     between the outer edge and the (bleed-adjusted) inner edge.
        id maskl = g_payload_focus_stroke.ca_mask;
        if (stb->feather > 0.0f) {
            // Pre-rendered feathered band as the mask's `contents` (NO live CAFilter —
            // that breaks the mask). Image is geometry-keyed/cached; we just reposition
            // the mask layer each frame so a move-drag is cheap.
            payload_focus_feather_mask_refresh(inner.size.width, inner.size.height,
                                               corner, bw, bleed, stb->feather,
                                               inset);
            if (s_fm_img) {
                float  pad   = stb->feather + 2.0f;
                // INSET: outer == the target rect, so the image pads off `inner`
                // directly (no band-width offset outside it).
                CGRect frame = CGRectMake(inner.origin.x - pad - (inset ? 0.0f : bw),
                                          inner.origin.y - pad - (inset ? 0.0f : bw),
                                          s_fm_img_size.width, s_fm_img_size.height);
                ((void (*)(id, SEL, CGPathRef))  objc_msgSend)(maskl, @selector(setPath:), (CGPathRef)NULL);
                ((void (*)(id, SEL, CGRect))     objc_msgSend)(maskl, @selector(setFrame:), frame);
                ((void (*)(id, SEL, CGFloat))    objc_msgSend)(maskl, @selector(setContentsScale:), (CGFloat)1.0);
                ((void (*)(id, SEL, id))         objc_msgSend)(maskl, @selector(setContents:), (id)s_fm_img);
                ((void (*)(id, SEL, id))         objc_msgSend)(maskl, @selector(setFilters:), nil);
            }
        } else {
            // Feather off: even-odd rounded outer minus hole (the original look).
            // Clear any feather image + restore the full-surface frame so the
            // path maps right.
            CGRect bounds = CGRectMake(0, 0, g_payload_focus_stroke.surface_size.width,
                                             g_payload_focus_stroke.surface_size.height);
            ((void (*)(id, SEL, id))     objc_msgSend)(maskl, @selector(setContents:), (id)nil);
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(maskl, @selector(setFrame:), bounds);

            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddRoundedRect(path, NULL, outer, outer_r, outer_r);
            CGPathAddRoundedRect(path, NULL, hole, hole_r, hole_r);
            ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(maskl, @selector(setPath:), path);
            CGPathRelease(path);

            CGColorRef opaque = CGColorCreateGenericRGB(0, 0, 0, 1);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(maskl, @selector(setFillColor:), opaque);
            if (opaque) CGColorRelease(opaque);
            ((void (*)(id, SEL, id)) objc_msgSend)(maskl, @selector(setFilters:), nil);
        }

        // Hard stroke overlay (focus_ring_blur_stroke): a rounded-rect outline on the
        // band's sharp inner seam — the `hole` cutout where the frost meets the sharp
        // center — outset half a lineWidth so it abuts the seam and grows outward. With
        // inner bleed off (bleed=0) `hole` == the window bounds (original behavior); with
        // bleed on it tracks the inset sharp edge, so the stroke always marks the real
        // seam (the two features compose: frost bleeds the content, stroke defines where
        // it stops). zPosition selects above (over the frost, crisp) vs below (under the
        // band, seen softened through the frost). Hidden when the knob is off — a live toggle.
        if (g_payload_focus_stroke.ca_stroke) {
            id st = g_payload_focus_stroke.ca_stroke;
            if (g_focus_ring_blur_stroke) {
                // A CAShapeLayer stroke straddles its path — drawn on the seam rect
                // directly, half the lineWidth would bleed INTO the window bounds.
                // Outset by half the width so the stroke's inner edge sits exactly
                // on the seam and the stroke grows OUTWARD into the band only.
                // (Holds for the INSET desktop ring too: the band is always on the
                // outward side of `hole`, so no flip is needed here.)
                float  sw = g_focus_ring_blur_stroke_width;
                CGRect srect = CGRectInset(hole, -sw * 0.5f, -sw * 0.5f);
                float  sr    = hole_r + sw * 0.5f;
                CGMutablePathRef spath = CGPathCreateMutable();
                CGPathAddRoundedRect(spath, NULL, srect, sr, sr);
                ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(st, @selector(setPath:), spath);
                CGPathRelease(spath);

                CGColorRef sc = CGColorCreateGenericRGB(stb->strokeclr_r, stb->strokeclr_g,
                                                        stb->strokeclr_b, stb->strokeclr_a);
                ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(st, @selector(setStrokeColor:), sc);
                if (sc) CGColorRelease(sc);
                ((void (*)(id, SEL, CGFloat)) objc_msgSend)(st, @selector(setLineWidth:), (CGFloat)g_focus_ring_blur_stroke_width);
                // zPosition: above the band (default) = +1; below = -1. The backdrop
                // (bd) sits at the default zPosition 0, so this orders the stroke vs it.
                CGFloat zp = (g_focus_ring_blur_stroke_position == 1) ? -1.0 : 1.0;
                ((void (*)(id, SEL, CGFloat)) objc_msgSend)(st, @selector(setZPosition:), zp);
                ((void (*)(id, SEL, BOOL)) objc_msgSend)(st, @selector(setHidden:), NO);
            } else {
                ((void (*)(id, SEL, BOOL)) objc_msgSend)(st, @selector(setHidden:), YES);
            }
        }

        // FR-21 xray: recolor the band segments overlapping other windows, masked
        // to the overlap rects. FROSTED: re-stroke the inner_stroke seam (requires
        // the stroke overlay, 0.5 z above it so it tracks the above/below choice).
        // SHARP: re-stroke the band's CENTERLINE at the ring width — recolors the
        // band itself, no inner_stroke needed (the old CG-path behavior). Rects
        // ship as screen-space frames; map them with the same y-down surface-local
        // transform as `inner`, outset by the tolerance so a same-rect window
        // still reaches the seam.
        if (g_payload_focus_stroke.ca_xray) {
            id xr = g_payload_focus_stroke.ca_xray;
            int xn = 0;
            if ((frosted ? g_focus_ring_blur_stroke : true)
                && g_focus_ring_xray && g_focus_ring_xray_count > 0) {
                CGMutablePathRef mpath = CGPathCreateMutable();
                for (int i = 0; i < g_focus_ring_xray_count; ++i) {
                    CGRect r = g_focus_ring_xray_rects[i];
                    CGRect lr = CGRectMake(r.origin.x - o.x, r.origin.y - o.y,
                                           r.size.width, r.size.height);
                    lr = CGRectInset(lr, -FOCUS_RING_XRAY_TOLERANCE, -FOCUS_RING_XRAY_TOLERANCE);
                    if (!CGRectIntersectsRect(lr, outer)) continue;
                    CGPathAddRect(mpath, NULL, lr);
                    ++xn;
                }
                if (xn > 0) {
                    // Frosted: re-stroke the inner_stroke with the SAME half-width
                    // outset as the stroke overlay above, so the recolor tracks the
                    // outset seam exactly. Sharp: the band centerline as before.
                    float  seam_w = frosted ? g_focus_ring_blur_stroke_width : bw;
                    // Sharp centerline: half a band outside the rect (outset ring)
                    // or half a band inside it (inset ring). Frosted follows `hole`,
                    // which already carries the inset flip. The radius lives on the
                    // seam in both modes, so the centerline is corner + bw/2 either way.
                    float  cl = inset ? bw * 0.5f : -bw * 0.5f;
                    CGRect seam   = frosted ? CGRectInset(hole, -seam_w * 0.5f, -seam_w * 0.5f)
                                            : CGRectInset(inner, cl, cl);
                    float  seam_r = frosted ? hole_r + seam_w * 0.5f : corner + bw * 0.5f;
                    if (seam_r < 0.0f) seam_r = 0.0f;
                    CGMutablePathRef xpath = CGPathCreateMutable();
                    CGPathAddRoundedRect(xpath, NULL, seam, seam_r, seam_r);
                    ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(xr, @selector(setPath:), xpath);
                    CGPathRelease(xpath);

                    CGColorRef xc = CGColorCreateGenericRGB(g_focus_ring_xray_r, g_focus_ring_xray_g,
                                                            g_focus_ring_xray_b, g_focus_ring_xray_a);
                    ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(xr, @selector(setStrokeColor:), xc);
                    if (xc) CGColorRelease(xc);
                    ((void (*)(id, SEL, CGFloat)) objc_msgSend)(xr, @selector(setLineWidth:), (CGFloat)seam_w);
                    // Frosted: ride the stroke overlay's above/below choice. Sharp:
                    // always above the band (below it would be invisible).
                    CGFloat xzp = frosted
                                ? ((g_focus_ring_blur_stroke_position == 1) ? -1.0 : 1.0) + 0.5
                                : 1.5;
                    ((void (*)(id, SEL, CGFloat)) objc_msgSend)(xr, @selector(setZPosition:), xzp);

                    id xmask = ((id (*)(id, SEL)) objc_msgSend)(xr, @selector(mask));
                    if (xmask) ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(xmask, @selector(setPath:), mpath);
                    ((void (*)(id, SEL, BOOL)) objc_msgSend)(xr, @selector(setHidden:), NO);
                }
                CGPathRelease(mpath);
            }
            if (xn == 0) ((void (*)(id, SEL, BOOL)) objc_msgSend)(xr, @selector(setHidden:), YES);
        }

        // Close the gated transaction, then flush so the change lands this frame
        // (the SA handler thread has no runloop to drain it).
        if (CATxCls) {
            ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(commit));
            ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(flush));
        }
    }
}

// =========================================================================
// Stroke window lifecycle: ensure → recreate → draw → destroy + the per-frame
// track entry called from the t3d batch hook.
// =========================================================================

static bool payload_focus_stroke_ensure(int cid, CGRect target_rect, uint64_t sid)
{
    if (g_payload_focus_stroke.initialized) return true;

    // ONE DISPLAY-SIZED surface pinned at the display origin, never moved or
    // resized: the type-5 layer-backed CA window, created directly at its final
    // on-screen position (the tree starts empty/transparent — no flash, no
    // off-screen dance). The band layers (payload_focus_surface_sync) place the
    // ring at the target's live position, so a window MOVE or RESIZE is just a
    // per-frame path update (no window move/resize, which SLS can't do cheaply).
    // The surface is recreated only on a cross-DISPLAY/space/target focus.
    CGRect surface_rect = payload_focus_display_rect_for(target_rect);
    CGSize stroke_size  = surface_rect.size;
    uint32_t wid = 0;

    if (!payload_focus_surface_create(cid, surface_rect, &wid)) {
        payload_focus_ring_log("stroke_create_fail", "reason=surface_create");
        return false;
    }

    // Attach to the target's current managed space so WS handles cross-
    // space visibility for us — if the user switches spaces, the stroke
    // window vanishes automatically and re-appears when they switch back.
    // do_focus_ring_show resolves the target's sid before calling here so
    // this is the right space at creation time.
    if (sid != 0) {
        uint32_t wlist[1] = { wid };
        CFArrayRef arr = cfarray_of_cfnumbers(wlist, sizeof(uint32_t),
                                               1, kCFNumberSInt32Type);
        if (arr) {
            SLSMoveWindowsToManagedSpace(cid, arr, sid);
            CFRelease(arr);
        }
    }

    // Two alpha slots at birth: NORMAL carries the user's `alpha` knob
    // (translucency); SYSTEM carries the on/off flag — if focus_ring is
    // currently disabled, the stroke window exists but is invisible until
    // SET_VISIBLE flips it on.
    SLSSetWindowAlpha(cid, wid, g_focus_ring_window_alpha);
    payload_focus_set_system_alpha(NULL, wid, g_payload_focus_ring.visible ? 1.0f : 0.0f);

    g_payload_focus_stroke.initialized       = true;
    g_payload_focus_stroke.wid               = wid;
    g_payload_focus_stroke.owner_cid         = cid;
    g_payload_focus_stroke.target_rect       = target_rect;
    g_payload_focus_stroke.surface_origin    = surface_rect.origin;
    g_payload_focus_stroke.surface_size      = stroke_size;
    g_payload_focus_stroke.attached_sid      = sid;

    payload_focus_ring_log("stroke_create",
                           "wid=%u surface=(%.0f,%.0f %.0fx%.0f) blur=%d sid=%llu",
                           wid, surface_rect.origin.x, surface_rect.origin.y,
                           stroke_size.width, stroke_size.height,
                           payload_focus_blur_effective(),
                           (unsigned long long)sid);

    // AC-6: ride the LB+T3D engine's per-frame tick. Idempotent (dedup by fn ptr),
    // so re-init on later SHOWs registers only once.
    lb_follower_register(payload_focus_ring_follower);
    return true;
}

static void payload_focus_stroke_draw(float radius, bool animated)
{
    if (!g_payload_focus_stroke.initialized) return;

    // One render path for every ring (FR-24): update the CA tree — band-vs-
    // backdrop visibility, mask + band paths, filters — and flush. `animated`
    // gates the implicit transition (discrete=ease, live tracking=instant glue).
    pthread_mutex_lock(&g_payload_focus_stroke.ctx_lock);
    payload_focus_surface_sync(radius, animated && g_focus_ring_animate);
    pthread_mutex_unlock(&g_payload_focus_stroke.ctx_lock);

    payload_focus_ring_log("stroke_draw",
                           "wid=%u blur=%d radius=%.1f band_w=%.1f surface=%.0fx%.0f",
                           g_payload_focus_stroke.wid,
                           payload_focus_blur_effective(), radius,
                           payload_focus_blur_effective() > 0
                               ? payload_focus_blur_band_width()
                               : FOCUS_RING_STROKE_WIDTH,
                           g_payload_focus_stroke.surface_size.width,
                           g_payload_focus_stroke.surface_size.height);
}

static void payload_focus_stroke_destroy(int cid)
{
    if (!g_payload_focus_stroke.initialized) return;

    pthread_mutex_lock(&g_payload_focus_stroke.ctx_lock);
    // Detach + release the retained CA tree.
    if (g_payload_focus_stroke.ca_ctx) {
        ((void (*)(id, SEL, id)) objc_msgSend)(g_payload_focus_stroke.ca_ctx, @selector(setLayer:), (id)nil);
    }
    if (g_payload_focus_stroke.ca_xray) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_xray, @selector(release));
        g_payload_focus_stroke.ca_xray = nil;
    }
    if (g_payload_focus_stroke.ca_stroke) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_stroke, @selector(release));
        g_payload_focus_stroke.ca_stroke = nil;
    }
    if (g_payload_focus_stroke.ca_tint) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_tint, @selector(release));
        g_payload_focus_stroke.ca_tint = nil;
    }
    if (g_payload_focus_stroke.ca_mask) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_mask, @selector(release));
        g_payload_focus_stroke.ca_mask = nil;
    }
    if (g_payload_focus_stroke.ca_backdrop) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_backdrop, @selector(release));
        g_payload_focus_stroke.ca_backdrop = nil;
    }
    if (g_payload_focus_stroke.ca_ctx) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_ctx, @selector(release));
        g_payload_focus_stroke.ca_ctx = nil;
    }
    pthread_mutex_unlock(&g_payload_focus_stroke.ctx_lock);

    if (g_payload_focus_stroke.wid) {
        extern CGError SLSReleaseWindow(int cid, uint32_t wid);
        // Release with the cid that actually OWNS the window — releasing from
        // a non-owning, non-universal cid silently leaks it. Fall back to the
        // passed cid if owner is unset.
        int owner = g_payload_focus_stroke.owner_cid ? g_payload_focus_stroke.owner_cid : cid;
        SLSReleaseWindow(owner, g_payload_focus_stroke.wid);
        g_payload_focus_stroke.wid = 0;
    }

    g_payload_focus_stroke.initialized       = false;
    g_payload_focus_stroke.target_wid        = 0;
    g_payload_focus_stroke.target_radius     = 0.0f;
    g_payload_focus_stroke.target_rect       = CGRectZero;
    g_payload_focus_stroke.surface_origin    = CGPointZero;
    g_payload_focus_stroke.surface_size      = CGSizeZero;
    g_payload_focus_stroke.attached_sid      = 0;

    payload_focus_ring_log("stroke_destroy", "ok");
}

// FR-9 pool lookup: the live entry parked on managed space `sid`, or NULL.
static struct focus_stroke *fr_pool_find(uint64_t sid)
{
    if (sid == 0) return NULL;
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (g_focus_stroke_pool[i].initialized &&
            g_focus_stroke_pool[i].attached_sid == sid)
            return &g_focus_stroke_pool[i];
    }
    return NULL;
}

// FR-9: select the pool entry that should host the ring for space `sid` —
// reuse the existing one, else a free slot, else evict the least-recently-used.
// The returned entry becomes g_active_stroke in do_focus_ring_show; the existing
// create/recreate logic there ensures/re-parks it. sid==0 (unresolved space)
// falls back to the current active entry as a scratch overlay (legacy behavior).
static struct focus_stroke *fr_pool_acquire(int cid, uint64_t sid)
{
    if (sid == 0) return g_active_stroke;

    struct focus_stroke *e = fr_pool_find(sid);
    if (e) return e;

    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (!g_focus_stroke_pool[i].initialized) return &g_focus_stroke_pool[i];
    }

    // Pool full of other spaces — evict the LRU entry. destroy operates on the
    // active entry (the macro), so point it at the victim first; the caller
    // immediately re-points active at the returned (now-free) slot.
    struct focus_stroke *lru = &g_focus_stroke_pool[0];
    for (int i = 1; i < FR_MAX_SPACES; i++) {
        if (g_focus_stroke_pool[i].last_used_mach < lru->last_used_mach)
            lru = &g_focus_stroke_pool[i];
    }
    g_active_stroke = lru;
    payload_focus_stroke_destroy(cid);
    payload_focus_ring_log("pool_evict", "sid=%llu slot=%ld",
                           (unsigned long long)sid, (long)(lru - g_focus_stroke_pool));
    return lru;
}

// FR-9: single-visible-ring invariant + per-display gate. Exactly one window
// holds focus, so exactly one ring should be on screen — set alpha 0 on every
// initialized entry except `keep`. Without this, a parked ring on another
// display's current space stays visible there (the ring showed on inactive
// displays). Called from every SHOW and from space_switch.
static void fr_pool_hide_others(int cid, struct focus_stroke *keep)
{
    int hidden = 0;
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        struct focus_stroke *fs = &g_focus_stroke_pool[i];
        if (fs == keep || !fs->initialized || !fs->wid) continue;
        payload_focus_set_system_alpha(NULL, fs->wid, 0.0f);
        // Invalidate the parked entry's tracked target so a later re-entry to
        // this space retargets from scratch (needs_new_surface) and SNAPS,
        // rather than crossfading from a now-stale focus target (the phantom-A
        // flash: focus A(d1)->C(d2)->B(d1) showed A->C->A->B). The active
        // (`keep`) entry is excluded, so genuine same-display A->B crossfade is
        // unaffected.
        if (fs->target_wid != 0) {
            payload_focus_ring_log("park_invalidate", "slot=%d wid=%u",
                                   i, fs->target_wid);
            fs->target_wid = 0;
        }
        hidden++;
    }
    if (hidden) payload_focus_ring_log("hide_others", "n=%d", hidden);
}

// FR-9 fade-in: ramp the incoming ring's alpha 0->1 matching the space slide's
// ease_out_expo (1 - 2^(-10t)) over the SAME duration, so the ring fades in as
// it rides in. Driven only on the animated path (fade_ms passed through the
// space_switch opcode; 0 = instant). A single GLOBAL animator — a new fade
// retargets it. AC-7: it's a ca_clock step client (no own CVDisplayLink) keyed
// by &g_focus_fade, registered on the incoming ring's display clock; alpha is
// written into the pump's shared per-VBL transaction so it lands in the same
// commit as the slide's LB+T3D motion.
static struct {
    pthread_mutex_t  lock;
    uint32_t         wid;          // incoming ring — fades 0->1 (the only one used by FR-9)
    int              cid;
    uint32_t         out_wid;      // outgoing ring — fades 1->0 (focus-change crossfade; 0 = none)
    int              out_cid;
    uint64_t         start_mach;
    double           duration_s;
    double           mach_to_s;
    int              easing;        // enum focus_ring_easing (kept in sync with focus_ring.h)
    uint32_t         did;           // ca_clock display this fade registered on (stale-clock guard)
    _Atomic bool     active;
} g_focus_fade = { .lock = PTHREAD_MUTEX_INITIALIZER };

// Crossfade-out stash: the previous focus ring's window, kept ALIVE (not destroyed)
// while it fades 1->0 alongside the incoming ring's 0->1. One slot only — a focus
// change that arrives mid-crossfade snap-finishes (releases) the prior outgoing
// window before stashing the next, so at most two ring windows ever coexist.
// Released by payload_focus_xfade_drop on fade completion (or on the next stash).
static struct focus_stroke g_focus_xfade_out = { .ctx_lock = PTHREAD_MUTEX_INITIALIZER };

// Release the stashed outgoing ring (SLS window + CA tree / CG context). Mirrors
// payload_focus_stroke_destroy's teardown but on the stash entry. Caller holds
// g_focus_fade.lock; also zeroes out_wid so the tick stops touching it.
static void payload_focus_xfade_drop_locked(void)
{
    struct focus_stroke *e = &g_focus_xfade_out;
    g_focus_fade.out_wid = 0;
    g_focus_fade.out_cid = 0;
    if (!e->initialized && !e->wid && !e->ca_ctx) return;

    @autoreleasepool {
        if (e->ca_ctx) ((void (*)(id, SEL, id)) objc_msgSend)(e->ca_ctx, @selector(setLayer:), (id)nil);
        if (e->ca_xray)     { ((void (*)(id, SEL)) objc_msgSend)(e->ca_xray,     @selector(release)); e->ca_xray = nil; }
        if (e->ca_stroke)   { ((void (*)(id, SEL)) objc_msgSend)(e->ca_stroke,   @selector(release)); e->ca_stroke = nil; }
        if (e->ca_tint)     { ((void (*)(id, SEL)) objc_msgSend)(e->ca_tint,     @selector(release)); e->ca_tint = nil; }
        if (e->ca_mask)     { ((void (*)(id, SEL)) objc_msgSend)(e->ca_mask,     @selector(release)); e->ca_mask = nil; }
        if (e->ca_backdrop) { ((void (*)(id, SEL)) objc_msgSend)(e->ca_backdrop, @selector(release)); e->ca_backdrop = nil; }
        if (e->ca_ctx)      { ((void (*)(id, SEL)) objc_msgSend)(e->ca_ctx,      @selector(release)); e->ca_ctx = nil; }
    }
    if (e->wid) {
        extern CGError SLSReleaseWindow(int cid, uint32_t wid);
        int owner = e->owner_cid ? e->owner_cid : SLSMainConnectionID();
        SLSReleaseWindow(owner, e->wid);
        e->wid = 0;
    }
    e->initialized = false;
    e->owner_cid   = 0;
}

static void payload_focus_xfade_drop(void)
{
    pthread_mutex_lock(&g_focus_fade.lock);
    payload_focus_xfade_drop_locked();
    pthread_mutex_unlock(&g_focus_fade.lock);
}

// Move a ring entry OUT into the crossfade stash (keep it alive for the 1->0
// fade) and clear that entry so it no longer owns a window / pool membership.
// Snap-finishes any prior outgoing window first (one slot => at most two ring
// windows coexist). `a` is usually g_active_stroke (same-space A->B reuses one
// pool slot), but FR-19 cross-display fade-out passes the DEPARTED display's
// pool slot (a different entry than the freshly-acquired active one) so its ring
// fades out in place on the old display while the new one fades in on the new
// display. Caller: SA handler thread.
static void payload_focus_xfade_stash_entry(struct focus_stroke *a)
{
    pthread_mutex_lock(&g_focus_fade.lock);
    payload_focus_xfade_drop_locked();          // finish any prior crossfade-out

    struct focus_stroke *e = &g_focus_xfade_out;
    e->wid         = a->wid;
    e->owner_cid   = a->owner_cid;
    e->ca_ctx      = a->ca_ctx;
    e->ca_backdrop = a->ca_backdrop;
    e->ca_mask     = a->ca_mask;
    e->ca_tint     = a->ca_tint;
    e->ca_stroke   = a->ca_stroke;
    e->ca_xray     = a->ca_xray;
    e->initialized = true;

    // Detach from the active entry WITHOUT releasing (the stash owns them now), and
    // reset its geometry/identity exactly as destroy would, so ensure() starts clean.
    a->wid = 0;
    a->ca_ctx = a->ca_backdrop = a->ca_mask = a->ca_tint = a->ca_stroke = a->ca_xray = nil;
    a->initialized       = false;
    a->target_wid        = 0;
    a->target_rect       = CGRectZero;
    a->surface_origin    = CGPointZero;
    a->surface_size      = CGSizeZero;
    a->attached_sid      = 0;
    pthread_mutex_unlock(&g_focus_fade.lock);
}

// Convenience: stash the current active entry (same-space A->B crossfade).
static void payload_focus_xfade_stash(void)
{
    payload_focus_xfade_stash_entry(g_active_stroke);
}

// FR-9: alpha easing for the fade tick. Mirrors enum focus_ring_easing in
// focus_ring.h (0=linear, 1=smoothstep, 2=ease-in quad, 3=ease-out expo). The
// daemon picks the curve (focus_ring_easing config) and ships it per switch.
static double focus_ease(int mode, double t)
{
    return payload_ease(mode, t);   // shared curve table — see payload_inc/easing.inc.m
}

static void payload_focus_fade_stop(void)
{
    if (!atomic_load(&g_focus_fade.active)) return;
    atomic_store(&g_focus_fade.active, false);
    // AC-7: flag-only. The ca_clock step self-settles (returns true) on its next
    // tick when it sees !active and the pump deactivates it / re-pauses the clock;
    // no blocking CVDisplayLinkStop. A later fade re-registers (idempotent by ctx).

    // FR-19: a crossfade aborted mid-flight left its outgoing ring at a partial
    // alpha — the tick's t>=1.0 cleanup (snap to 0 + xfade_drop) never ran, so it
    // would linger visible. Finish it here. No-op for an in-only FR-9 fade (no
    // outgoing) or a clean completion: the tick zeroes out_wid before stopping, so
    // we never touch the window it already released.
    if (g_focus_fade.out_wid) {
        payload_focus_set_system_alpha(NULL, g_focus_fade.out_wid, 0.0f);
        g_focus_fade.out_wid = 0;
    }
    payload_focus_xfade_drop();
}

// Write one ring's fade alpha — the SYSTEM slot, so the ramp composes with (and
// never clobbers) the user's `alpha` knob on the normal slot. Buffers onto the
// pump's shared per-VBL transaction when present (so it commits in the same frame
// as the slide), else a one-shot transaction (tx==NULL = the pump's create failed
// this tick). The cid arg is retained for call-site symmetry but unused: system
// alpha always goes through Dock's universal-owner cid.
static inline void payload_focus_fade_set_alpha(CFTypeRef tx, int cid, uint32_t wid, float a)
{
    (void)cid;
    payload_focus_set_system_alpha(tx, wid, a);
}

// AC-7 ca_clock step. Returns true once settled (pump deactivates the client +
// re-pauses the clock if it was the last active).
static bool payload_focus_fade_ca_step(void *ctx, CFTypeRef tx, uint32_t did)
{
    (void)ctx;
    if (!atomic_load(&g_focus_fade.active)) return true;   // settled (stopped)

    pthread_mutex_lock(&g_focus_fade.lock);
    uint32_t wid  = g_focus_fade.wid;
    int      cid  = g_focus_fade.cid;
    uint32_t owid = g_focus_fade.out_wid;
    int      ocid = g_focus_fade.out_cid;
    double   dur  = g_focus_fade.duration_s;
    uint64_t st   = g_focus_fade.start_mach;
    double   m2s  = g_focus_fade.mach_to_s;
    int      ez   = g_focus_fade.easing;
    uint32_t fdid = g_focus_fade.did;
    pthread_mutex_unlock(&g_focus_fade.lock);

    // Stale-clock guard: a global-singleton client re-registered on a different
    // display leaves an active slot on the old clock — release it so two clocks
    // don't double-tick the fade. The current clock keeps driving it.
    if (did != fdid) return true;

    if (!wid && !owid) { payload_focus_fade_stop(); return true; }

    double t = dur > 0.0 ? (double)(mach_absolute_time() - st) * m2s / dur : 1.0;
    if (t > 1.0) t = 1.0;
    double e = focus_ease(ez, t);   // alpha curve (daemon-selected)
    if (wid)  payload_focus_fade_set_alpha(tx, cid,  wid,  (float)e);          // incoming 0->1
    if (owid) payload_focus_fade_set_alpha(tx, ocid, owid, (float)(1.0 - e));  // outgoing 1->0 (crossfade)

    if (t >= 1.0) {
        if (wid)  payload_focus_fade_set_alpha(tx, cid, wid, 1.0f);
        if (owid) {
            payload_focus_fade_set_alpha(tx, ocid, owid, 0.0f);
            payload_focus_xfade_drop();   // release the outgoing ring window
        }
        // FR-19: clear the fade's wids before stopping so the hardened fade_stop
        // (which finalizes a mid-flight outgoing ring) never touches the outgoing
        // window we just released above.
        pthread_mutex_lock(&g_focus_fade.lock);
        g_focus_fade.wid     = 0;
        g_focus_fade.out_wid = 0;
        pthread_mutex_unlock(&g_focus_fade.lock);
        payload_focus_fade_stop();
        return true;   // settled
    }
    return false;   // keep ticking
}

// Drive the alpha animator. `in_wid` fades 0->1 (the incoming/revealed ring);
// `out_wid` (0 = none) fades 1->0 in lockstep for a true-overlap crossfade, and is
// released by the tick on completion. FR-9 uses the in-only wrapper below.
static void payload_focus_fade_start_xfade(int in_cid, uint32_t in_wid,
                                           int out_cid, uint32_t out_wid,
                                           double duration_s, int easing)
{
    if ((!in_wid && !out_wid) || duration_s <= 0.0) return;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);

    // AC-7: pace on the panel the incoming ring lives on. The active stroke's
    // tracked rect is the incoming ring (the freshly-shown one; the outgoing is
    // stashed in g_focus_xfade_out), so its display is the right clock. FR-19
    // cross-display fade drives two wids on different displays from this one
    // client — alpha is display-agnostic, pacing keys to the incoming panel.
    uint32_t did = payload_focus_display_id_for(g_payload_focus_stroke.target_rect);

    pthread_mutex_lock(&g_focus_fade.lock);
    g_focus_fade.wid        = in_wid;
    g_focus_fade.cid        = in_cid;
    g_focus_fade.out_wid    = out_wid;
    g_focus_fade.out_cid    = out_cid;
    g_focus_fade.easing     = easing;
    g_focus_fade.mach_to_s  = (double)tb.numer / ((double)tb.denom * 1e9);
    g_focus_fade.start_mach = mach_absolute_time();
    g_focus_fade.duration_s = duration_s;
    g_focus_fade.did        = did;
    atomic_store(&g_focus_fade.active, true);
    pthread_mutex_unlock(&g_focus_fade.lock);

    if (in_wid)  payload_focus_set_system_alpha(NULL, in_wid,  0.0f);   // incoming starts transparent
    if (out_wid) payload_focus_set_system_alpha(NULL, out_wid, 1.0f);   // outgoing starts opaque

    // Drive from the per-display ca_clock pump (refresh_hz=0 → no explicit range;
    // the clock for this did usually already exists from the slide's anim begin).
    // Register AFTER releasing g_focus_fade.lock (lock order: never hold an animator
    // lock across ca_clock_register's clients_lock). Idempotent by ctx — a retarget
    // mid-fade just re-activates the same client.
    ca_clock_register(did, 0.0f, payload_focus_fade_ca_step, &g_focus_fade);
    ca_clock_resume(did);
    payload_focus_ring_log("fade_ca", "via ca_clock did=0x%x dur=%.3f in=%u out=%u",
                           did, duration_s, in_wid, out_wid);
}

static void payload_focus_fade_start(int cid, uint32_t wid, double duration_s, int easing)
{
    payload_focus_xfade_drop();   // FR-9 path: finish any lingering focus-change crossfade-out
    payload_focus_fade_start_xfade(cid, wid, 0, 0, duration_s, easing);
}

static void payload_focus_stroke_track(CFTypeRef transaction, uint32_t wid,
                                       float x, float y, float w, float h)
{
    if (!g_payload_focus_stroke.initialized) return;
    if (!g_payload_focus_ring.visible) return;
    if (wid == 0 || wid != g_payload_focus_stroke.target_wid) return;

    // Cross-display re-pin: when the tracked window's CENTER leaves the surface
    // (it crossed onto another display mid-animation, e.g. window --display),
    // the band would land past the surface bounds and clip — reposition the
    // surface onto the display now under the center. Repositioning keeps the
    // SAME wid, so level/sublevel/z-order/alpha are all preserved (a
    // destroy+recreate would lose the target's sublevel, which
    // SLSGetWindowSubLevel can't read back on Tahoe). Daemon-side ring shows are
    // gated off while the display animates, so the follower is the sole writer
    // here — the re-pin can't race a concurrent show. The surface keeps its
    // size: two equal-size displays are covered exactly, but a window landing
    // near the far edge of a much LARGER destination can clip until settle
    // (single re-pin, no CA-tree resize).
    CGPoint tc = { x + w * 0.5f, y + h * 0.5f };
    CGRect surf = { g_payload_focus_stroke.surface_origin, g_payload_focus_stroke.surface_size };
    if (!CGRectContainsPoint(surf, tc)) {
        CGRect dr = payload_focus_display_rect_for(CGRectMake(x, y, w, h));
        if (dr.origin.x != g_payload_focus_stroke.surface_origin.x ||
            dr.origin.y != g_payload_focus_stroke.surface_origin.y) {
            extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x, float y, CGSRegionRef shape);
            CGRect shape = CGRectMake(0.0, 0.0, g_payload_focus_stroke.surface_size.width,
                                                g_payload_focus_stroke.surface_size.height);
            CGSRegionRef region = NULL;
            if (CGSNewRegionWithRect(&shape, &region) == kCGErrorSuccess && region) {
                SLSSetWindowShape(g_payload_focus_stroke.owner_cid, g_payload_focus_stroke.wid,
                                  dr.origin.x, dr.origin.y, region);
                CFRelease(region);
                g_payload_focus_stroke.surface_origin = dr.origin;
                payload_focus_ring_log("stroke_repin",
                                       "wid=%u -> display_origin=(%.0f,%.0f)",
                                       wid, dr.origin.x, dr.origin.y);
            }
        }
    }

    g_payload_focus_stroke.target_rect = CGRectMake(x, y, w, h);
    payload_focus_stroke_draw(g_payload_focus_stroke.target_radius, false);   // tracking: instant, glue to window
    (void)transaction;   // the CA flush self-syncs; no SLS txn ride needed.

    payload_focus_ring_log("stroke_track",
                           "wid=%u target_wid=%u rect=(%.0f,%.0f %.0fx%.0f)",
                           g_payload_focus_stroke.wid, wid, x, y, w, h);
}

// =========================================================================
// Deathwatch hook — called by deathwatch.inc.m when yabai dies. Frees every
// ring window so no alpha-0 overlay haunts a space after a crash. Name must
// match payload.m's forward decl.
// =========================================================================
static void payload_focus_ring_destroy_all(void)
{
    // FR-9: reap every per-space pool entry, not just the active one — parked
    // rings on other spaces would otherwise haunt those spaces after a crash.
    payload_focus_fade_stop();
    int cid = SLSMainConnectionID();
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (!g_focus_stroke_pool[i].initialized) continue;
        g_active_stroke = &g_focus_stroke_pool[i];
        payload_focus_stroke_destroy(cid);
    }
    g_active_stroke = &g_focus_stroke_pool[0];
    g_payload_focus_ring.visible       = false;
    g_payload_focus_ring.target_wid    = 0;
    g_payload_focus_ring.target_radius = 0.0f;
    payload_focus_ring_log("destroy_all", "ok");
}

// =========================================================================
// SA opcode handlers: SHOW, HIDE, SET_VISIBLE
// =========================================================================

// ===========================================================================
// Transform mirror — ride a sheet's slide-in/out animation
// ===========================================================================
// A modal sheet animates its entrance/exit by writing a per-tick CGAffineTransform
// into placement slot 0x8000001 of its CGS window; the real frame stays final.
// We can't ride that via a movement group (it's a transform, not a server move),
// and SLSGetScreenRectForWindow returns the final rect throughout. Instead, each
// VBL we READ the sheet's 0x8000001 slot and COPY its translate onto our overlay's
// own 0x8000001 slot (composing over the overlay's slot-0 positioning rather than
// replacing it), so the ring slides in lockstep with the sheet. Follows the real
// matrix frame-by-frame, so it's fully timing/easing-agnostic — an app retiming
// NSSheetAnimationTime, the pop-overshoot flavor, and reduce-motion all ride for
// free (reduce-motion → slot is identity → ring just lands). Only the translate
// is copied: it's anchor-independent, so it's portable onto our display-sized
// overlay; the sheet's subtle scale is dropped (anchor-bound, and ~1.0 anyway).
typedef CGError (*fr_get_at_placement_fn)(int cid, uint32_t wid, int placement, int arg3, CGAffineTransform *out);
typedef CGError (*fr_set_at_placement_fn)(int cid, uint32_t wid, int placement, int arg3, CGAffineTransform *t);

// The overlay's own window->screen positioning lives in slot 0, so we must NOT
// write slot 0 (that replaces it and shoves the overlay off-screen). Write our
// mirror translate into placement 0x8000001 — the same slot AppKit animates the
// sheet in — which COMPOSES over the overlay's baseline (catenated = base × ours)
// instead of replacing it. Reset = identity into 0x8000001.
#define FR_MIRROR_PLACEMENT 0x8000001

// Mirror mode: which live signal drives the ring. SHEET reads a modal sheet's
// 0x8000001 placement slot (2D translate). MC (exit) and MC_ENTER read the focused
// window's full CGSGetWindowTransform3D during a Mission-Control transition and project
// its natural frame through it, riding the ring band with the window AND cross-fading in
// lockstep: MC fades the ring IN (0->1) as the window grows thumbnail->full on exit;
// MC_ENTER fades it OUT (1->0) as the window shrinks full->thumbnail on enter, then
// parks it hidden. Zero-initialised statics default to SHEET (the shipping path).
#define FR_MIRROR_MODE_SHEET    0
#define FR_MIRROR_MODE_MC       1
#define FR_MIRROR_MODE_MC_ENTER 2

// Coupled-fade tunables. The exit fade is distance-driven (couples exactly to the ride);
// the enter fade is time-driven over FR_MC_ENTER_FADE_S, measured from the moment motion
// actually starts (NOT from arm — see the ca_step's motion-start re-base). The motion
// grace is how long the ride waits, still positioned on the resting window, for the
// animation to begin before declaring "never animated" (reduce-motion / duration-0). It
// is direction-specific: on ENTER, OSL fires ~280ms before app-Exposé actually spreads,
// so the grace must outlast that gap; on EXIT the window is already displaced at arm, so
// only a brief settle grace is needed.
#define FR_MC_ENTER_FADE_S         0.20
#define FR_MC_ENTER_MOTION_GRACE_S 0.50
#define FR_MC_EXIT_MOTION_GRACE_S  0.08

static struct {
    pthread_mutex_t  mutex;
    volatile uint32_t src_wid;       // window whose live transform we mirror (0 = idle)
    volatile uint32_t overlay_wid;   // our overlay receiving the translate (sheet mode)
    volatile bool     active;        // ca_clock step client active
    int      cid;
    bool     saw_motion;             // don't settle-stop before the slide actually begins
    int      mode;                   // FR_MIRROR_MODE_SHEET | FR_MIRROR_MODE_MC | FR_MIRROR_MODE_MC_ENTER
    CGRect   base_frame;             // MC modes: window's NATURAL frame (SLSGetWindowBounds) — size source + settle target
    double   base_dist;              // MC exit: arm-time |Δrect| (pos+size) from the settled frame — the fade's
                                     // 100%-remaining anchor. alpha = 1 - remaining/this. Couples the fade to the
                                     // WHOLE ride (translation + scale), so translation-heavy Exposé fades too.
    double   base_tx, base_ty;       // sheet transform at arm time; the captured band rect
                                     // already bakes this in, so we mirror (current - base)
    uint64_t start_mach;             // safety timeout reference
    double   mach_to_s;
    uint32_t did;                    // ca_clock display this mirror registered on (stale-clock guard)
    bool     initialized;
    fr_get_at_placement_fn get_at;
    fr_set_at_placement_fn set_xf;
} g_focus_mirror;

// MC-exit fade alpha: 0 when the band is at its arm-time distance from the settled frame,
// ramping to 1 as that distance closes to 0 (window lands). base_dist / cur_dist are L1
// rect distances (|Δx|+|Δy|+|Δw|+|Δh|), so the fade couples to the full ride — pure
// translation (Exposé) fades just as well as scale (Mission Control). A trivial ride
// (< ~4px total journey) has no meaningful fade — just show it.
static float fr_mc_exit_alpha(double base_dist, double cur_dist)
{
    if (base_dist < 4.0) return 1.0f;
    double p = 1.0 - cur_dist / base_dist;
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    return (float)p;
}

// Project a window's NATURAL frame through its live transform to the current on-screen
// rect. `natural` = SLSGetWindowBounds — the window's real frame, CONSTANT through the
// exit (for a transformed window bounds stays the full frame while
// SLSGetScreenRectForWindow returns the shrunk thumbnail = natural/scale).
// CGSGetWindowTransform3D is screen->local (scale = 1/visual_scale, translate rests at
// -natural.origin), so inverting gives visual.origin = -t/scale and visual.size =
// natural.size/scale. At rest (t = -natural.origin, scale = 1) it lands exactly on the
// natural frame = where the window sits. m is CATransform3D memory order: m[0]=sx,
// m[5]=sy, m[12]=tx, m[13]=ty (planar MC transform — no z).
static CGRect fr_project_frame_t3d(CGRect natural, const float m[16])
{
    double sx = m[0], sy = m[5], tx = m[12], ty = m[13];
    CGRect r = natural;
    if (sx != 0.0) { r.origin.x = -tx / sx; r.size.width  = natural.size.width  / sx; }
    if (sy != 0.0) { r.origin.y = -ty / sy; r.size.height = natural.size.height / sy; }
    return r;
}

// AC-7 ca_clock step. Returns true once settled (slide played out or 0.6s
// safety) so the pump deactivates it. The per-tick get_at
// (SLSGetWindowTransformAtPlacement) is a real SLS read on the pump thread under
// clients_lock — the one accepted blocking round-trip in a step (it mirrors a LIVE
// server value and can't be hoisted), bounded to ≤0.6s while a sheet animates.
// tx is unused: placement transforms have no transaction sibling in use, so
// set_xf stays a direct one-shot non-blocking write.
static bool payload_focus_mirror_ca_step(void *ctx, CFTypeRef tx, uint32_t did)
{
    (void)ctx;
    pthread_mutex_lock(&g_focus_mirror.mutex);
    uint32_t src     = g_focus_mirror.src_wid;
    uint32_t overlay = g_focus_mirror.overlay_wid;
    if (!g_focus_mirror.active || !src) {
        if (g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER)   // DIAG: enter ride cleared from under us
            logpf("FR_ENTER_STEP", "CA-BAIL active=%d src=%u mode=%d (mirror cleared externally)",
                  g_focus_mirror.active, src, g_focus_mirror.mode);
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return true;   // nothing to mirror → settle
    }
    // Stale-clock guard: mirror re-armed on a different display → release
    // this clock's slot; the current clock keeps driving it.
    if (did != g_focus_mirror.did) {
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return true;
    }
    int cid = g_focus_mirror.cid;

    // MC ride (modes 1 & 2): read the window's live CGSGetWindowTransform3D, project its
    // NATURAL frame through it to the current on-screen rect, and re-drive the ring band
    // there via the AC-6 follower each VBL — the ring rides the window. In lockstep it
    // cross-fades: MC (exit) fades IN as the window grows thumbnail->full; MC_ENTER fades
    // OUT as it shrinks full->thumbnail, then parks hidden. Settles when the transform
    // stops (exit: back to identity; enter: reached the thumbnail) or the 0.6s safety.
    // No placement-slot write; the follower's CA redraw moves the band (self-filtered on
    // the ring's target_wid). fr_mc_finalize centralises the four settle/degenerate exits.
    if (g_focus_mirror.mode == FR_MIRROR_MODE_MC ||
        g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER) {
        bool   is_enter = (g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER);
        uint32_t sw     = g_payload_focus_stroke.wid;
        float  m[16];
        CGRect base = g_focus_mirror.base_frame;

        // End state, shared by every terminal path below: exit lands the band on the
        // final frame at full opacity; enter parks it hidden (alpha 0, master off).
        #define FR_MC_FINALIZE() do {                                                   \
            if (is_enter) {                                                             \
                g_payload_focus_ring.visible = false;                                   \
                payload_focus_set_system_alpha(tx, sw, 0.0f);                           \
            } else {                                                                    \
                payload_focus_ring_follower(tx, src, base);                             \
                payload_focus_set_system_alpha(tx, sw,                                  \
                                               g_payload_focus_ring.visible ? 1.0f : 0.0f); \
            }                                                                           \
            g_focus_mirror.src_wid = 0;                                                 \
            g_focus_mirror.active  = false;                                             \
        } while (0)

        int rc_read = fr_cgs_read_window_t3d(cid, src, m);
        if (is_enter && rc_read != 0)                     // DIAG: did OUR (Dock-cid) getter fail mid-enter?
            logpf("FR_ENTER_STEP", "GETTER-FAIL rc=%d → finalize (park)", rc_read);
        if (rc_read != 0) {   // getter failed → finalize now
            FR_MC_FINALIZE();
            pthread_mutex_unlock(&g_focus_mirror.mutex);
            return true;
        }
        CGRect cur     = fr_project_frame_t3d(base, m);
        double dscale  = fabs((double)m[0] - 1.0) + fabs((double)m[5] - 1.0);
        double dpos    = fabs(cur.origin.x - base.origin.x) + fabs(cur.origin.y - base.origin.y);
        bool   moving  = (dscale > 0.01 || dpos > 0.5);
        uint64_t now   = mach_absolute_time();
        // First motion: anchor the fade + safety clock HERE, not at arm. On enter, OSL
        // fires well before the animation starts (app-Exposé spreads ~280ms later), so a
        // time-fade measured from arm would run out before the window even moves. Re-basing
        // at motion-start makes the fade track the real animation. (Exit sees motion on
        // tick 1, so start_mach ≈ arm here — no effect on the distance-driven exit fade.)
        if (moving && !g_focus_mirror.saw_motion) {
            g_focus_mirror.saw_motion = true;
            g_focus_mirror.start_mach = now;
        }
        double elapsed = (double)(now - g_focus_mirror.start_mach) * g_focus_mirror.mach_to_s;

        // Not moving yet and never has: hold, still positioned on the resting window, for
        // the grace window before declaring reduce-motion / duration-0. Enter needs a long
        // grace to bridge the OSL->spread gap; exit only needs a brief settle grace.
        if (!moving && !g_focus_mirror.saw_motion) {
            double grace = is_enter ? FR_MC_ENTER_MOTION_GRACE_S : FR_MC_EXIT_MOTION_GRACE_S;
            if (elapsed < grace) {   // still positioned by the arm; just wait
                pthread_mutex_unlock(&g_focus_mirror.mutex);
                return false;
            }
            if (is_enter) {
                logpf("FOCUS_RING_MC_ENTER", "no motion within %.2fs → snap hide", grace);
            }
            FR_MC_FINALIZE();
            pthread_mutex_unlock(&g_focus_mirror.mutex);
            return true;
        }

        payload_focus_ring_follower(tx, src, cur);   // ride the band to the current rect

        // Coupled fade, written in the SAME ca_step transaction as the placement so the
        // ring's alpha and geometry never disagree by a frame. Gate on target match so a
        // still-retargeting stroke (deferred focus-during-MC) isn't faded on the wrong wid.
        // cur_dist = how far the band still is from its settled frame (pos + size); the
        // exit fade closes with it, so translation-dominant Exposé fades as well as MC.
        if (g_payload_focus_stroke.target_wid == src) {
            double dsize    = fabs(cur.size.width - base.size.width) + fabs(cur.size.height - base.size.height);
            double cur_dist = dpos + dsize;
            float a = is_enter
                    ? (float)(1.0 - (elapsed / FR_MC_ENTER_FADE_S > 1.0 ? 1.0 : elapsed / FR_MC_ENTER_FADE_S))
                    : fr_mc_exit_alpha(g_focus_mirror.base_dist, cur_dist);
            payload_focus_set_system_alpha(tx, sw, a);
        }

        bool settled = ((!moving && g_focus_mirror.saw_motion) || elapsed > 0.6);
        if (settled) FR_MC_FINALIZE();
        #undef FR_MC_FINALIZE
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return settled;
    }

    // Sheet mode (mode 0): mirror the sheet's 0x8000001 placement slot onto the overlay.
    if (!overlay || !g_focus_mirror.get_at || !g_focus_mirror.set_xf) {
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return true;
    }
    CGAffineTransform t = CGAffineTransformIdentity;
    g_focus_mirror.get_at(cid, src, 0x8000001, 0, &t);
    bool moving = (fabs(t.tx) > 0.5 || fabs(t.ty) > 0.5);  // raw sheet transform active
    if (moving) g_focus_mirror.saw_motion = true;

    // Apply the sheet's transform RELATIVE to the capture-time baseline: the
    // band's drawn rect already bakes in base (the sheet's position when the
    // daemon captured the rect), so we offset by (current - base). First frame
    // ≈ 0 (band stays put, matching the sheet then); at rest it lands on -base,
    // pulling the band down onto the true final frame.
    double ax = t.tx - g_focus_mirror.base_tx;
    double ay = t.ty - g_focus_mirror.base_ty;
    // 1px coverage buffer in the direction the window ANIMATED (opposite the
    // captured base offset, since the slide runs from +base toward 0). Closes the
    // 1px gap at the leading edge where the ring lands just shy. Per-axis, only on
    // axes that actually animated.
    if (g_focus_mirror.base_tx != 0.0) ax -= (g_focus_mirror.base_tx > 0.0) ? 1.0 : -1.0;
    if (g_focus_mirror.base_ty != 0.0) ay -= (g_focus_mirror.base_ty > 0.0) ? 1.0 : -1.0;
    CGAffineTransform xf = CGAffineTransformMake(1, 0, 0, 1, ax, ay);
    g_focus_mirror.set_xf(cid, overlay, FR_MIRROR_PLACEMENT, 0, &xf);

    // Stop once the slide has played out (sheet transform back to rest) or the
    // safety window elapses — never settle-stop before the animation has begun.
    // The last applied value (current-base ≈ -base) is LEFT on the overlay so the
    // ring rests on the true final frame; the next show clears it (mirror_stop).
    double elapsed = (double)(mach_absolute_time() - g_focus_mirror.start_mach) * g_focus_mirror.mach_to_s;
    bool settled = ((!moving && g_focus_mirror.saw_motion) || elapsed > 0.6);
    if (settled) {
        g_focus_mirror.src_wid = 0;
        g_focus_mirror.active = false;
    }
    pthread_mutex_unlock(&g_focus_mirror.mutex);
    return settled;
}

static void payload_focus_mirror_init(void)
{
    if (g_focus_mirror.initialized) return;
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    g_focus_mirror.mach_to_s = (double)tb.numer / ((double)tb.denom * 1e9);
    pthread_mutex_init(&g_focus_mirror.mutex, NULL);
    g_focus_mirror.get_at = (fr_get_at_placement_fn)dlsym(RTLD_DEFAULT, "SLSGetWindowTransformAtPlacement");
    if (!g_focus_mirror.get_at)
        g_focus_mirror.get_at = (fr_get_at_placement_fn)dlsym(RTLD_DEFAULT, "_SLSGetWindowTransformAtPlacement");
    g_focus_mirror.set_xf = (fr_set_at_placement_fn)dlsym(RTLD_DEFAULT, "SLSSetWindowTransformAtPlacement");
    if (!g_focus_mirror.set_xf)
        g_focus_mirror.set_xf = (fr_set_at_placement_fn)dlsym(RTLD_DEFAULT, "_SLSSetWindowTransformAtPlacement");
    int t3d_ok = fr_cgs_t3d_resolve();   // string-xref resolve of _CGSGetWindowTransform3D (dlsym-null)
    logpf("FOCUS_RING_MC_RIDE", "init tf3d resolver=%s", t3d_ok ? "OK (string-xref)" : "FAILED");
    // AC-7: no own CVDisplayLink — the mirror is a ca_clock step client registered
    // in payload_focus_mirror_start.
    g_focus_mirror.initialized = true;
}

static void payload_focus_mirror_start(int cid, uint32_t sheet_wid, uint32_t overlay_wid,
                                       double base_tx, double base_ty)
{
    if (!sheet_wid || !overlay_wid) return;
    payload_focus_mirror_init();
    if (!g_focus_mirror.get_at || !g_focus_mirror.set_xf) return;  // SPIs unavailable

    // AC-7: pace on the panel the overlay ring lives on (same helper as the fade).
    uint32_t did = payload_focus_display_id_for(g_payload_focus_stroke.target_rect);

    pthread_mutex_lock(&g_focus_mirror.mutex);
    g_focus_mirror.cid         = cid;
    g_focus_mirror.src_wid     = sheet_wid;
    g_focus_mirror.mode        = FR_MIRROR_MODE_SHEET;
    g_focus_mirror.overlay_wid = overlay_wid;
    g_focus_mirror.saw_motion  = false;
    g_focus_mirror.base_tx     = base_tx;
    g_focus_mirror.base_ty     = base_ty;
    g_focus_mirror.start_mach  = mach_absolute_time();
    g_focus_mirror.did         = did;
    g_focus_mirror.active      = true;
    pthread_mutex_unlock(&g_focus_mirror.mutex);

    // Register on the ring's display clock AFTER releasing the mutex (lock order vs
    // clients_lock). Idempotent by ctx — a re-arm during an in-flight mirror just
    // re-activates the same client and retargets it.
    ca_clock_register(did, 0.0f, payload_focus_mirror_ca_step, &g_focus_mirror);
    ca_clock_resume(did);
}

// MC variant of payload_focus_mirror_start: ride the target window's live
// CGSGetWindowTransform3D (Mission-Control enter or exit) instead of a sheet's placement
// slot. base_frame = the window's NATURAL frame. mode selects direction (FR_MIRROR_MODE_MC
// exit / FR_MIRROR_MODE_MC_ENTER); base_dist is the exit fade's 100%-remaining anchor
// (arm-time |Δrect| from settled; pass 0.0 for enter, which fades on time). Drives the
// ring band via the AC-6 follower (CA redraw), so overlay_wid is advisory — the follower
// self-filters on the ring's target_wid, which the daemon set to this wid.
static void payload_focus_mirror_start_mc(int cid, uint32_t target_wid,
                                          uint32_t overlay_wid, CGRect base_frame,
                                          int mode, double base_dist)
{
    if (!target_wid) return;
    payload_focus_mirror_init();
    if (!fr_cgs_t3d_resolve()) return;   // getter unavailable -> caller leaves the ring at rest

    uint32_t did = payload_focus_display_id_for(base_frame);
    pthread_mutex_lock(&g_focus_mirror.mutex);
    g_focus_mirror.cid         = cid;
    g_focus_mirror.src_wid     = target_wid;
    g_focus_mirror.overlay_wid = overlay_wid;
    g_focus_mirror.saw_motion  = false;
    g_focus_mirror.mode        = mode;
    g_focus_mirror.base_frame  = base_frame;
    g_focus_mirror.base_dist   = base_dist;
    g_focus_mirror.start_mach  = mach_absolute_time();
    g_focus_mirror.did         = did;
    g_focus_mirror.active      = true;
    pthread_mutex_unlock(&g_focus_mirror.mutex);

    ca_clock_register(did, 0.0f, payload_focus_mirror_ca_step, &g_focus_mirror);
    ca_clock_resume(did);
}

// Stop any in-flight mirror and reset the overlay to identity. Called when the
// new focus target isn't animating, so a leftover transform never sticks.
static void payload_focus_mirror_stop(void)
{
    if (g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER || g_focus_mirror.mode == FR_MIRROR_MODE_MC)  // DIAG
        logpf("FR_ENTER_STEP", "MIRROR_STOP called while mode=%d src=%u active=%d (SHOW stomped the ride?)",
              g_focus_mirror.mode, g_focus_mirror.src_wid, g_focus_mirror.active);
    if (!g_focus_mirror.initialized || !g_focus_mirror.active) return;
    pthread_mutex_lock(&g_focus_mirror.mutex);
    if (g_focus_mirror.set_xf && g_focus_mirror.overlay_wid) {
        CGAffineTransform id = CGAffineTransformIdentity;
        g_focus_mirror.set_xf(g_focus_mirror.cid, g_focus_mirror.overlay_wid, FR_MIRROR_PLACEMENT, 0, &id);
    }
    g_focus_mirror.src_wid = 0;
    g_focus_mirror.active = false;
    // AC-7: flag-only — the ca_clock step self-settles on its next tick (sees
    // !active → returns true) and the pump deactivates it. Never block-stop the
    // tick under g_focus_mirror.mutex: the tick takes the same mutex (deadlock).
    pthread_mutex_unlock(&g_focus_mirror.mutex);
}

// SHOW wire = the packed struct below (little-endian, append-only). Style
// fields are stamped on every SHOW from the daemon's config values, so the
// payload needs no separate state-pull opcode. force_style=1 (an explicit
// config change) clears the payload-side color_override latch so config
// reasserts authority; passive focus events pass 0 and leave the latch
// untouched. The sid the stroke window attaches to is re-resolved
// here via SLSCopySpacesForWindows — the daemon doesn't need to know which
// display/space the wid lives on.
static void do_focus_ring_show(char *message)
{
    struct __attribute__((packed)) {
        uint32_t wid;
        float    x, y, w, h;
        float    radius;
        float    stroke_width;
        float    stroke_alpha;
        float    stroke_r, stroke_g, stroke_b;
        uint8_t  force_style;
        int32_t  blur_radius;
        int32_t  style;
        float    blur_saturation;
        float    blur_brightness;
        int32_t  blend_mode;
        uint8_t  blur_stroke;
        int32_t  blur_stroke_position;
        float    blur_stroke_width;
        float    blur_bleed;
        float    tint_r, tint_g, tint_b, tint_a;
        float    str_r, str_g, str_b, str_a;
        float    blur_contrast;
        float    blur_feather;   // appended (wire contract)
        uint8_t  animate;
        float    animate_duration;
        float    fade_duration;  // appended (wire contract — never reorder)
        int32_t  target_level;     // appended (wire contract — never reorder)
        int32_t  target_sublevel;  // appended (wire contract — never reorder)
        float    blur_hue;         // appended (wire contract — never reorder)
        // FR-21 xray (appended — wire contract — never reorder). xray_count
        // closes the fixed struct; that many 4-float rects follow it.
        uint8_t  xray;
        float    xray_r, xray_g, xray_b, xray_a;
        int32_t  xray_count;
        // appended (wire contract — never reorder): whole-window translucency,
        // the NORMAL alpha slot. Rects still follow the fixed struct (sizeof).
        float    window_alpha;
    } req;
    memcpy(&req, message, sizeof(req));

    // FR-21 xray: flag + color, then the variable-length overlap rect list
    // (screen-space frames; clamped to the shared wire cap).
    g_focus_ring_xray   = req.xray != 0;
    g_focus_ring_xray_r = req.xray_r;
    g_focus_ring_xray_g = req.xray_g;
    g_focus_ring_xray_b = req.xray_b;
    g_focus_ring_xray_a = req.xray_a < 0.0f ? 0.0f : (req.xray_a > 1.0f ? 1.0f : req.xray_a);
    {
        int n = req.xray_count;
        if (n < 0) n = 0;
        if (n > SA_FOCUS_RING_XRAY_MAX_RECTS) n = SA_FOCUS_RING_XRAY_MAX_RECTS;
        const char *cursor = message + sizeof(req);
        for (int i = 0; i < n; ++i) {
            float v[4];
            memcpy(v, cursor + i * 4 * sizeof(float), sizeof(v));
            g_focus_ring_xray_rects[i] = CGRectMake(v[0], v[1], v[2], v[3]);
        }
        g_focus_ring_xray_count = n;
    }

    // An explicit config change reasserts authority over the debug knob: clear
    // the latch so the config color/alpha below take effect (and persist).
    if (req.force_style) g_payload_focus_ring_color_override = false;

    // Update runtime style globals before any geometry calculations. Stroke
    // width feeds the band geometry in payload_focus_surface_sync. Clamp to a
    // sane range so a config typo can't render the ring invisible (alpha<=0)
    // or fill the screen (width>32). Width is never gated by the debug latch —
    // only color/alpha are.
    if (req.stroke_width  >= 0.0f && req.stroke_width  <= 32.0f) g_focus_ring_stroke_width = req.stroke_width;
    // Whole-window translucency (`alpha` knob) — the NORMAL alpha slot, stamped
    // on the window in the SHOW alpha block below. Not gated by the debug latch.
    g_focus_ring_window_alpha = req.window_alpha < 0.0f ? 0.0f
                              : (req.window_alpha > 1.0f ? 1.0f : req.window_alpha);
    // Skip the config-driven color/alpha restamp once the rgba/opacity knob has
    // claimed them, so an experimental color survives subsequent focus shows.
    if (!g_payload_focus_ring_color_override) {
        if (req.stroke_alpha >= 0.0f && req.stroke_alpha <= 1.0f) g_focus_ring_stroke_alpha = req.stroke_alpha;
        g_focus_ring_stroke_r = req.stroke_r;
        g_focus_ring_stroke_g = req.stroke_g;
        g_focus_ring_stroke_b = req.stroke_b;
    }

    // Background-blur radius. Always honored from config (not gated by the debug
    // color latch). Clamp defensively — the daemon already clamps to [0,64].
    g_focus_ring_blur_radius = req.blur_radius < 0 ? 0
                             : (req.blur_radius > 64 ? 64 : req.blur_radius);

    // req.style stays on the wire (contract — never reorder) but is IGNORED
    // since FR-24: rendering derives entirely from the blur radius above, which
    // the daemon keeps in lockstep with its style enum (FR-22).

    // Blur color adjustment + tint blend mode (any radius; identity defaults
    // leave the frost untouched). Clamp defensively — the daemon already clamps.
    g_focus_ring_blur_saturation = req.blur_saturation < 0.0f ? 0.0f
                                 : (req.blur_saturation > 4.0f ? 4.0f : req.blur_saturation);
    g_focus_ring_blur_brightness = req.blur_brightness < -1.0f ? -1.0f
                                 : (req.blur_brightness > 1.0f ? 1.0f : req.blur_brightness);
    g_focus_ring_blur_contrast = req.blur_contrast < 0.0f ? 0.0f
                               : (req.blur_contrast > 4.0f ? 4.0f : req.blur_contrast);
    g_focus_ring_blur_hue = req.blur_hue < 0.0f ? 0.0f
                          : (req.blur_hue > 360.0f ? 360.0f : req.blur_hue);
    g_focus_ring_blend_mode = (req.blend_mode < 0 || req.blend_mode >= FOCUS_RING_BLEND_COUNT)
                            ? 0 : req.blend_mode;

    // Hard stroke overlay (inner_stroke; identity default = off). Width clamped
    // defensively — the daemon already clamps to [0.5, 32].
    g_focus_ring_blur_stroke          = req.blur_stroke != 0;
    g_focus_ring_blur_stroke_position = (req.blur_stroke_position == 1) ? 1 : 0;
    g_focus_ring_blur_stroke_width    = req.blur_stroke_width < 0.5f ? 0.5f
                                      : (req.blur_stroke_width > 32.0f ? 32.0f : req.blur_stroke_width);

    // Inner bleed (any radius). Clamp to [0,64] defensively (daemon already
    // clamps); the per-window cap that keeps the cutout positive is applied at
    // mask time in payload_focus_surface_sync (the window size isn't known here).
    g_focus_ring_blur_bleed = req.blur_bleed < 0.0f ? 0.0f
                            : (req.blur_bleed > 64.0f ? 64.0f : req.blur_bleed);

    // Final per-layer RGBA (BLUR ring), already resolved daemon-side from the
    // focus_ring_blur_{,stroke_}{opacity,color} overrides. Applied verbatim.
    g_focus_ring_blur_tint_r = req.tint_r; g_focus_ring_blur_tint_g = req.tint_g;
    g_focus_ring_blur_tint_b = req.tint_b; g_focus_ring_blur_tint_a = req.tint_a;
    g_focus_ring_blur_strokeclr_r = req.str_r; g_focus_ring_blur_strokeclr_g = req.str_g;
    g_focus_ring_blur_strokeclr_b = req.str_b; g_focus_ring_blur_strokeclr_a = req.str_a;

    // Edge feather (any radius; 0 = off). Clamp defensively — daemon clamps to [0,64].
    g_focus_ring_blur_feather = req.blur_feather < 0.0f ? 0.0f
                              : (req.blur_feather > 64.0f ? 64.0f : req.blur_feather);

    // Discrete-transition animation. Clamp duration defensively — daemon clamps to [0,2].
    g_focus_ring_animate = req.animate != 0;
    g_focus_ring_animate_duration = req.animate_duration < 0.0f ? 0.0f
                                  : (req.animate_duration > 2.0f ? 2.0f : req.animate_duration);
    g_focus_ring_fade_duration = req.fade_duration < 0.0f ? 0.0f
                               : (req.fade_duration > 5.0f ? 5.0f : req.fade_duration);

    // Stamp this SHOW's resolved style into the bank for its ring KIND (wid 0 =
    // desktop). Redraws that happen without a SHOW read the bank in
    // payload_focus_surface_sync, so desktop-override styling can never leak
    // into a window ring (or vice versa) via the shared globals above.
    {
        struct fr_style_bank *bank = (req.wid == 0) ? &g_fr_style_desktop : &g_fr_style_main;
        bank->band_width  = g_focus_ring_stroke_width;
        bank->blur        = g_focus_ring_blur_radius;
        bank->sat         = g_focus_ring_blur_saturation;
        bank->bri         = g_focus_ring_blur_brightness;
        bank->con         = g_focus_ring_blur_contrast;
        bank->hue         = g_focus_ring_blur_hue;
        bank->feather     = g_focus_ring_blur_feather;
        bank->blend       = g_focus_ring_blend_mode;
        bank->tint_r      = g_focus_ring_blur_tint_r;
        bank->tint_g      = g_focus_ring_blur_tint_g;
        bank->tint_b      = g_focus_ring_blur_tint_b;
        bank->tint_a      = g_focus_ring_blur_tint_a;
        bank->strokeclr_r = g_focus_ring_blur_strokeclr_r;
        bank->strokeclr_g = g_focus_ring_blur_strokeclr_g;
        bank->strokeclr_b = g_focus_ring_blur_strokeclr_b;
        bank->strokeclr_a = g_focus_ring_blur_strokeclr_a;
    }

    payload_focus_ring_log("show_recv",
                           "wid=%u rect=(%.0f,%.0f %.0fx%.0f) radius=%.1f width=%.2f alpha=%.2f rgb=(%.2f,%.2f,%.2f) force=%d",
                           req.wid,
                           req.x, req.y, req.w, req.h, req.radius,
                           g_focus_ring_stroke_width, g_focus_ring_stroke_alpha,
                           g_focus_ring_stroke_r, g_focus_ring_stroke_g, g_focus_ring_stroke_b,
                           req.force_style);

    // All styles (including the CABackdropLayer BLUR overlay) run on Dock's
    // MAIN cid — the behind-window CA blur composites there; no dedicated
    // connection needed.
    int cid = SLSMainConnectionID();
    CGRect target_rect = CGRectMake(req.x, req.y, req.w, req.h);

    // Read the target's sheet-slide transform AS EARLY AS POSSIBLE — closest to
    // the daemon's rect-capture instant — so the mirror baseline matches the
    // offset baked into the captured rect (minimizes the residual settle shift).
    // Identity for non-animating windows. Used by the mirror trigger at the end.
    payload_focus_mirror_init();
    CGAffineTransform mirror_base = CGAffineTransformIdentity;
    if (g_focus_mirror.get_at) g_focus_mirror.get_at(cid, req.wid, 0x8000001, 0, &mirror_base);

    // Resolve the target's current managed sid so the stroke window
    // attaches to the correct space. Cross-space focus moves trigger a
    // destroy/recreate when attached_sid no longer matches.
    extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
    uint64_t sid = 0;
    if (req.wid != 0) {
        uint32_t wlist[1] = { req.wid };
        CFArrayRef warr = cfarray_of_cfnumbers(wlist, sizeof(uint32_t),
                                                1, kCFNumberSInt32Type);
        if (warr) {
            CFArrayRef sids = SLSCopySpacesForWindows(cid, 0x7, warr);
            if (sids && CFArrayGetCount(sids) > 0) {
                CFNumberRef n = CFArrayGetValueAtIndex(sids, 0);
                CFNumberGetValue(n, kCFNumberSInt64Type, &sid);
            }
            if (sids) CFRelease(sids);
            CFRelease(warr);
        }
    }

    // FR-9: the desktop/wallpaper ring (wid==0) has no window to resolve a space
    // from. Key it to the CURRENT space of the display it covers, so it lives in
    // that space's pool entry — then space_switch vanishes it on leave and a
    // later window-focus replaces it. Without this it lands in a sid==0 scratch
    // entry that no space-keyed lookup can ever find again, so it gets stuck
    // visible after a switch (the desktop-ring-won't-disappear bug).
    if (sid == 0) {
        extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
        CGPoint c = CGPointMake(req.x + req.w / 2.0f, req.y + req.h / 2.0f);
        CGDirectDisplayID ddid = 0;
        uint32_t dcnt = 0;
        if (CGGetDisplaysWithPoint(c, 1, &ddid, &dcnt) == kCGErrorSuccess && dcnt > 0) {
            CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ddid);
            if (u) {
                CFStringRef uuid = CFUUIDCreateString(NULL, u);
                if (uuid) {
                    sid = SLSManagedDisplayGetCurrentSpace(cid, uuid);
                    CFRelease(uuid);
                }
                CFRelease(u);
            }
        }
    }

    // FR-19: remember the entry that was active going INTO this show (the ring
    // currently on screen) BEFORE fr_pool_acquire below repoints g_active_stroke.
    // When focus crosses to a DIFFERENT pool slot (cross-display: each display's
    // current space is a distinct sid), this old slot is the departed display's
    // ring — faded out below instead of being snapped off by fr_pool_hide_others.
    struct focus_stroke *prev_active = g_active_stroke;

    // FR-9: route to this space's pool entry. Cross-space focus now selects a
    // DIFFERENT entry rather than destroying the current one, so every space's
    // ring persists parked on its own window (and rides the slide on re-entry).
    // The create/recreate logic below then operates on the selected entry: a
    // matching parked entry (same wid, same sid) is reused; a fresh/evicted slot
    // is built. sid==0 keeps the current active entry (legacy scratch).
    g_active_stroke = fr_pool_acquire(cid, sid);
    g_active_stroke->last_used_mach = mach_absolute_time();

    // Decide create / recreate. The display-sized surface needs to be rebuilt
    // when focus moves to a different wid, a different space, or a different
    // DISPLAY (the surface is sized+pinned to one display, so a cross-display
    // focus needs a fresh surface bound to the new display/space). A same-
    // display move or resize needs NO surface change — the draw below just
    // repaints the stroke at the new position inside the existing surface.
    bool needs_new_surface = false;
    if (g_payload_focus_stroke.initialized) {
        CGRect  surf = { g_payload_focus_stroke.surface_origin,
                         g_payload_focus_stroke.surface_size };
        CGPoint tc   = { target_rect.origin.x + target_rect.size.width  / 2.0f,
                         target_rect.origin.y + target_rect.size.height / 2.0f };
        needs_new_surface = (g_payload_focus_stroke.target_wid  != req.wid) ||
                            (g_payload_focus_stroke.attached_sid != sid)     ||
                            !CGRectContainsPoint(surf, tc);
        // (FR-24: blur 0<->N never rebuilds — it's a live layer toggle inside
        // payload_focus_surface_sync on the one CA window.)
    }

    // True-overlap crossfade gate: a real ring CHANGE on the SAME visible space,
    // with the dissolve enabled. Then we keep the OLD ring window alive (stash) and
    // fade it 1->0 while the fresh one fades 0->1 (alpha block below), instead of
    // destroying it. Cross-space / style-toggle / first-show fall through to snap.
    //
    // FR-19: the outgoing target_wid==0 is overloaded — it's BOTH the desktop
    // (wallpaper) ring AND the sentinel fr_pool_hide_others stamps on a parked-
    // invalidated entry to force a snap (phantom-A flash fix). Distinguish them by
    // slot identity: the desktop ring is the ACTIVE slot being rebuilt in place
    // (prev_active == g_active_stroke), whereas an invalidated park is always a
    // DIFFERENT slot re-acquired on re-entry. So allow a target_wid==0 outgoing to
    // crossfade only when it's the active slot — giving desktop->window the same
    // dissolve as window->desktop, while the phantom-park case still snaps.
    bool want_xfade = g_payload_focus_stroke.initialized
                   && needs_new_surface
                   && g_payload_focus_ring.visible
                   && g_focus_ring_animate
                   && g_focus_ring_fade_duration > 0.0f
                   && (g_payload_focus_stroke.target_wid != 0 || prev_active == g_active_stroke)
                   && g_payload_focus_stroke.target_wid != req.wid
                   && g_payload_focus_stroke.attached_sid == sid;

    // FR-19: cross-display (cross-pool) fade-out gate. When focus lands on a
    // DIFFERENT pool slot than the one that was on screen (prev_active), the old
    // ring belongs to the departed display and would otherwise be snapped to
    // alpha 0 by fr_pool_hide_others. Instead route it through the SAME crossfade
    // stash so it fades 1->0 on the old display while the new ring fades 0->1 on
    // the new one. Distinct from want_xfade (same slot reused, attached_sid==sid)
    // and mutually exclusive with it: cross-pool implies prev_active != active.
    // Same enable conditions as want_xfade so the two transitions read alike.
    //
    // FR-19: like want_xfade, allow a desktop (target_wid==0) outgoing. prev_active
    // is always the ACTIVE entry, which fr_pool_hide_others never invalidates (keep
    // is excluded), so target_wid==0 here is a live desktop ring, not a phantom-park
    // sentinel — and the wid!=0 clause already filters a destroyed/hidden slot. Two
    // desktop rings on different displays are both wid 0, so the "is a real change"
    // test can't be wid inequality alone; the distinct pool slot (prev_active !=
    // active, required above) IS the change. This lights up d1 desktop -> d2 desktop.
    bool want_xdisplay_fade = (prev_active != g_active_stroke)
                           && prev_active->initialized
                           && prev_active->wid != 0
                           && (prev_active->target_wid != req.wid ||
                               (prev_active->target_wid == 0 && req.wid == 0))
                           && g_payload_focus_ring.visible
                           && g_focus_ring_animate
                           && g_focus_ring_fade_duration > 0.0f;

    if (!g_payload_focus_stroke.initialized || needs_new_surface) {
        if (g_payload_focus_stroke.initialized) {
            if (want_xfade) payload_focus_xfade_stash(); // keep old alive for the 1->0 fade
            else            payload_focus_stroke_destroy(cid);
        }
        if (!payload_focus_stroke_ensure(cid, target_rect, sid)) {
            if (want_xfade) payload_focus_xfade_drop();  // ensure failed — don't orphan the stash
            payload_focus_ring_log("show_skip",
                                   "wid=%u reason=ensure_failed",
                                   req.wid);
            return;
        }
        // The fresh ring is born TRANSPARENT when crossfading so it never flashes at
        // full alpha before the fade-in (it's ordered in below, then ramped 0->1).
        // Both the same-space (want_xfade) and cross-display (want_xdisplay_fade)
        // dissolves fade the incoming ring in from 0.
        if (want_xfade || want_xdisplay_fade) {
            payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid, 0.0f);
        }
    }

    g_payload_focus_stroke.target_wid    = req.wid;
    g_payload_focus_stroke.target_radius = req.radius;
    g_payload_focus_stroke.target_rect   = target_rect;

    // Mirror to global state for the t3d hook's filter.
    g_payload_focus_ring.target_wid    = req.wid;
    g_payload_focus_ring.target_radius = req.radius;

    // Update the overlay: payload_focus_surface_sync sets the band/backdrop
    // layers + paths and flushes the CA transaction itself. Always SNAP the band
    // to the target rect (animated=false): an eased path morph here TRAILS the
    // window during a drag/move (visible lag) and scales-out on a fresh window.
    // Between-window transitions are carried by the alpha crossfade above; live
    // tracking glues.
    payload_focus_stroke_draw(req.radius, false);

    // Z-order the ring relative to the target. order_below (the default) puts it
    // BEHIND the target wid — only effective when the ring shares the target's
    // window level (the level knob; default 0 matches normal app windows). The
    // knob is honored unconditionally; inner-bleed edge-sampling only works with
    // the ring ordered ABOVE, so it is inert when below.
    //
    // Copy the target's z-band onto the ring BEFORE ordering. SLSOrderWindow's
    // relative order only resolves against the target when both share a window
    // level + sublevel — a BSP target sits at the -20 LAYER_BELOW sublevel, and
    // a ring left at sublevel 0 sorts above it regardless of `order`. The daemon
    // supplies both (req.target_level/target_sublevel); it reads the sublevel
    // Tahoe-correctly via window_sub_level() (the raw SLSGetWindowSubLevel SPI
    // returns 0 on Tahoe, so we can't read it here). The setters are fine on Tahoe.
    extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
    SLSSetWindowLevel(cid, g_payload_focus_stroke.wid, req.target_level);
    SLSSetWindowSubLevel(cid, g_payload_focus_stroke.wid, req.target_sublevel);

    extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
    bool bleed_active = g_focus_ring_blur_bleed > 0.0f;
    bool order_below = g_payload_focus_ring_order_below;   // bleed never overrides the knob
    int order = order_below ? -1 : 1;
    CGError order_rc = SLSOrderWindow(cid, g_payload_focus_stroke.wid, order, req.wid);
    payload_focus_ring_log("show_done",
                           "target=%u overlay=%u cid=%d %s%s level=%d sublevel=%d order_rc=%d",
                           req.wid, g_payload_focus_stroke.wid, cid,
                           order_below ? "below" : "above",
                           bleed_active ? " (bleed-on)" : "",
                           req.target_level, req.target_sublevel, (int)order_rc);

    // FR-9: a parked ring re-entered after being vanished (space_switch zeroed its
    // alpha when it was the outgoing space) must be made visible again. ensure()
    // sets alpha on a fresh surface, but the reuse path doesn't — so set it every
    // SHOW, honoring the global enable flag. (Gated daemon-side during a slide, so
    // this never fights the ride; it lands on the post-slide backstop re-show.)
    {
        int alpha_owner = g_payload_focus_stroke.owner_cid
                        ? g_payload_focus_stroke.owner_cid : cid;
        // NORMAL slot = the user's `alpha` knob, restamped on every SHOW (config
        // changes reissue a SHOW; the reuse path skips creation where it's also
        // stamped). Visibility below rides the SYSTEM slot, so the two compose.
        SLSSetWindowAlpha(alpha_owner, g_payload_focus_stroke.wid, g_focus_ring_window_alpha);
        if (want_xfade && g_focus_xfade_out.initialized) {
            // True-overlap crossfade: incoming ring 0->1 while the stashed outgoing
            // ring 1->0, both over focus_ring_fade_duration. The outgoing window is
            // released by the tick on completion. Smoothstep ease (mode 1).
            int out_owner = g_focus_xfade_out.owner_cid ? g_focus_xfade_out.owner_cid : cid;
            payload_focus_fade_start_xfade(alpha_owner, g_payload_focus_stroke.wid,
                                           out_owner,   g_focus_xfade_out.wid,
                                           (double)g_focus_ring_fade_duration, 1);
        } else if (want_xdisplay_fade) {
            // FR-19: cross-display dissolve. Stash the DEPARTED display's ring
            // (prev_active, a different pool slot than the active one) so it fades
            // 1->0 in place while the incoming ring fades 0->1 on the new display.
            // Stashing detaches prev_active from the pool (initialized=false), so
            // the fr_pool_hide_others sweep below skips it and the fade owns its
            // alpha. The stash also zeroes its target_wid, so a later re-entry to
            // that space rebuild-snaps (no phantom-A crossfade from a stale target).
            payload_focus_xfade_stash_entry(prev_active);
            if (g_focus_xfade_out.initialized) {
                int out_owner = g_focus_xfade_out.owner_cid ? g_focus_xfade_out.owner_cid : cid;
                payload_focus_fade_start_xfade(alpha_owner, g_payload_focus_stroke.wid,
                                               out_owner,   g_focus_xfade_out.wid,
                                               (double)g_focus_ring_fade_duration, 1);
                payload_focus_ring_log("xdisplay_fade",
                                       "in_wid=%u out_wid=%u dur=%.3f",
                                       g_payload_focus_stroke.wid, g_focus_xfade_out.wid,
                                       g_focus_ring_fade_duration);
            } else {
                // Stash failed to capture (no window) — just show the incoming ring.
                payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid,
                                               g_payload_focus_ring.visible ? 1.0f : 0.0f);
            }
        } else if (atomic_load(&g_focus_fade.active) &&
                   g_focus_fade.wid == g_payload_focus_stroke.wid) {
            // FR-19: a duplicate idempotent re-show (a single desktop click fans
            // out to multiple wid==0 shows — EVENT_HANDLER(DESKTOP_CLICK) plus the
            // SLS focus resolver, tens of ms apart) landed on the SAME overlay an
            // in-flight crossfade is fading IN. The snap branch below would abort
            // that fade — stranding the stashed outgoing ring visible (the desktop-
            // ring-linger bug) and snapping the incoming ring instead of dissolving
            // it in. Leave the crossfade alone — let it ride to completion.
            payload_focus_ring_log("xfade_keep",
                                   "wid=%u (duplicate re-show during fade)",
                                   g_payload_focus_stroke.wid);
        } else {
            // A pure focus change (not a slide; shows are daemon-gated during one)
            // supersedes any in-flight fade — snap the active ring to its final alpha.
            payload_focus_fade_stop();
            payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid,
                                           g_payload_focus_ring.visible ? 1.0f : 0.0f);
        }
        // Single-visible-ring / per-display gate: hide every other space's ring
        // (e.g. a parked ring on another display's current space). The stashed
        // outgoing window is NOT a pool member, so this never touches it.
        fr_pool_hide_others(cid, g_active_stroke);
    }

    // Transform mirror: if the target was mid sheet-slide when we captured the
    // rect (mirror_base, read at show entry), ride the slide each VBL until it
    // settles; else make sure no stale transform sticks to the overlay.
    //
    // The mirror is a SINGLE shared engine — an MC enter/exit ride (mode MC /
    // MC_ENTER) also lives in g_focus_mirror. A SHOW landing mid-ride (app-Exposé
    // reveals the front app's windows -> focus event -> re-show) would otherwise
    // hit the else-branch and mirror_stop() would clear the ride out from under
    // the ca_step. While an MC ride owns the overlay, leave it alone — the sheet
    // teardown must not clobber it.
    bool mc_ride_active = g_focus_mirror.active &&
                          (g_focus_mirror.mode == FR_MIRROR_MODE_MC ||
                           g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER);
    if (!mc_ride_active && g_focus_mirror.get_at && g_focus_mirror.set_xf) {
        bool moving = (fabs(mirror_base.tx) > 0.5 || fabs(mirror_base.ty) > 0.5);
        payload_focus_ring_log("mirror", "target=%u overlay=%u moving=%d base=(%.1f,%.1f)",
                               req.wid, g_payload_focus_stroke.wid, moving ? 1 : 0,
                               mirror_base.tx, mirror_base.ty);
        if (moving) payload_focus_mirror_start(cid, req.wid, g_payload_focus_stroke.wid,
                                               mirror_base.tx, mirror_base.ty);
        else        payload_focus_mirror_stop();
    }
}

static void do_focus_ring_hide(char *message)
{
    (void)message;
    payload_focus_ring_log("hide_recv", "prev_wid=%u", g_payload_focus_ring.target_wid);

    payload_focus_fade_stop();
    payload_focus_stroke_destroy(SLSMainConnectionID());
    g_payload_focus_ring.target_wid    = 0;
    g_payload_focus_ring.target_radius = 0.0f;
}

// FR-19: animated dismiss/reveal of the ACTIVE ring for the desktop toggle (and
// the Esc dismiss). Unlike do_focus_ring_hide (instant teardown) this fades the
// ring's alpha 1<->0 over fade_ms on the ca_clock pump and leaves it PARKED — a
// fade-out stops at alpha 0 without destroying the surface, so the reverse toggle
// just fades the same ring back in. The ring reliably persists between two
// desktop clicks because no focus/show event fires in between (returning from a
// window goes through the rebuild SHOW path, not the toggle branch). Drives the
// active stroke directly through the crossfade engine: fade-in = incoming-only
// (0->1), fade-out = outgoing-only (1->0). fade_ms<=0 or no ring => instant snap.
// Deliberately does NOT touch g_payload_focus_ring.visible (the master switch).
static void do_focus_ring_fade_visible(char *message)
{
    uint8_t v;
    memcpy(&v, message, sizeof(v)); message += sizeof(v);
    int32_t fade_ms;
    memcpy(&fade_ms, message, sizeof(fade_ms)); message += sizeof(fade_ms);
    int32_t easing;
    memcpy(&easing, message, sizeof(easing));
    bool visible = v != 0;

    uint32_t wid   = g_payload_focus_stroke.wid;
    int      owner = g_payload_focus_stroke.owner_cid
                   ? g_payload_focus_stroke.owner_cid : SLSMainConnectionID();

    payload_focus_ring_log("fade_visible_recv", "wid=%u visible=%d fade_ms=%d",
                           wid, visible ? 1 : 0, fade_ms);

    if (!wid || !g_payload_focus_stroke.initialized) return;

    if (fade_ms <= 0) {                          // fade off => snap
        payload_focus_fade_stop();
        payload_focus_set_system_alpha(NULL, wid, visible ? 1.0f : 0.0f);
        return;
    }

    double dur = (double)fade_ms / 1000.0;
    if (visible) payload_focus_fade_start_xfade(owner, wid, 0, 0, dur, easing);  // 0->1
    else         payload_focus_fade_start_xfade(0, 0, owner, wid, dur, easing);  // 1->0 (parks at 0)
}

static void do_focus_ring_set_visible(char *message)
{
    uint8_t v;
    memcpy(&v, message, sizeof(v));
    bool visible = v != 0;

    payload_focus_ring_log("set_visible_recv", "visible=%d", visible ? 1 : 0);

    g_payload_focus_ring.visible = visible;

    if (!visible) {
        // FR-9: DISABLE applies to EVERY per-space ring, not just the active one
        // — otherwise a parked ring would still flash in when you switch to its
        // space after disabling. System slot via Dock's universal-owner cid, so
        // the BLUR overlay's dedicated connection needs no special-casing.
        for (int i = 0; i < FR_MAX_SPACES; i++) {
            struct focus_stroke *fs = &g_focus_stroke_pool[i];
            if (!fs->initialized || !fs->wid) continue;
            payload_focus_set_system_alpha(NULL, fs->wid, 0.0f);
            payload_focus_ring_log("set_visible", "wid=%u visible=0", fs->wid);
        }
        return;
    }

    // ENABLE re-asserts only the ACTIVE ring — never the whole pool. The daemon
    // re-asserts SET_VISIBLE from window_did_receive_focus (fresh-SA self-heal),
    // and re-lighting parked rings (exit-ride settles and fr_pool_hide_others
    // park them at alpha 0) makes the land-time reveal blink (fade start snaps
    // to 0). The self-heal only ever needs the ring the user is looking at.
    if (g_payload_focus_stroke.initialized && g_payload_focus_stroke.wid) {
        payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid, 1.0f);
        payload_focus_ring_log("set_visible", "wid=%u visible=1 (active only)", g_payload_focus_stroke.wid);
    }
}

// FR-9: ride a space switch. The outgoing space's ring is parked dark (alpha 0)
// — on the animated path the slide has already ridden it OFF as an exit rider
// (SPA-21) and parks it dark at settle, so the write here is the belt for the
// non-animated and land-time paths. The incoming space's ring is revealed
// (alpha 1) and, being a managed-space member already parked on its window,
// rides IN with the slide for free. Either entry may be absent (space never
// focused / cold pool) — then there's just nothing to vanish or ride, and the
// daemon's post-slide backstop re-show re-resolves the destination ring.
// FR-9: create + park a ring for `wid` on space `sid` (geometry from the daemon).
// Mirrors the create-core of do_focus_ring_show but reuses the current style
// globals (set by the last show_recv) instead of a full req — the space_switch
// opcode only carries geometry. Called when the destination space has no live
// pool entry to ride in, so the ring is born already parked on the destination's
// focused window and rides the slide. Returns the parked entry, or NULL on fail.
static struct focus_stroke *payload_focus_ring_park(int cid, uint32_t wid,
                                                    CGRect target_rect,
                                                    float radius, uint64_t sid)
{
    if (sid == 0 || wid == 0) return NULL;

    g_active_stroke = fr_pool_acquire(cid, sid);
    g_active_stroke->last_used_mach = mach_absolute_time();

    bool needs_new_surface = false;
    if (g_payload_focus_stroke.initialized) {
        CGRect  surf = { g_payload_focus_stroke.surface_origin,
                         g_payload_focus_stroke.surface_size };
        CGPoint tc   = { target_rect.origin.x + target_rect.size.width  / 2.0f,
                         target_rect.origin.y + target_rect.size.height / 2.0f };
        needs_new_surface = (g_payload_focus_stroke.target_wid  != wid) ||
                            (g_payload_focus_stroke.attached_sid != sid)  ||
                            !CGRectContainsPoint(surf, tc);
    }

    if (!g_payload_focus_stroke.initialized || needs_new_surface) {
        if (g_payload_focus_stroke.initialized) payload_focus_stroke_destroy(cid);
        if (!payload_focus_stroke_ensure(cid, target_rect, sid)) {
            payload_focus_ring_log("park_skip", "wid=%u sid=%llu reason=ensure_failed",
                                   wid, (unsigned long long)sid);
            return NULL;
        }
    }

    g_payload_focus_stroke.target_wid    = wid;
    g_payload_focus_stroke.target_radius = radius;
    g_payload_focus_stroke.target_rect   = target_rect;
    g_payload_focus_ring.target_wid      = wid;
    g_payload_focus_ring.target_radius   = radius;

    payload_focus_stroke_draw(radius, false);   // park = setup; revealed via the alpha fade

    extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
    bool order_below = g_payload_focus_ring_order_below;   // bleed never overrides the knob
    SLSOrderWindow(cid, g_payload_focus_stroke.wid, order_below ? -1 : 1, wid);

    return g_active_stroke;
}

// SPA-17: park the ring on `target_wid` at `rect` for the space slide's geo-ride
// and return the ring OVERLAY wid (0 if no target / park failed). Called from the
// cross-fade seed (forward-declared in payload.m — this TU includes
// space_animation.inc.m earlier). Parking is idempotent with the FOCUS_RING_
// SPACE_SWITCH path: whichever runs first parks, the other reuses the surface
// (needs_new_surface guard in payload_focus_ring_park). The slide drives only the
// ring's GEO (Transform3D); its ALPHA reveal stays with the focus_ring fade.
uint32_t payload_focus_ring_park_for_slide(int cid, uint32_t target_wid,
                                           CGRect rect, float radius, uint64_t sid)
{
    if (target_wid == 0 || sid == 0) return 0;
    struct focus_stroke *s = payload_focus_ring_park(cid, target_wid, rect, radius, sid);
    return s ? g_payload_focus_stroke.wid : 0;
}

// SPA-21: hand the OUTGOING space's live ring to the slide as an exit rider —
// returns its overlay wid (0 = nothing to ride: cold pool / ring disabled).
// The slide owns GEO only and parks the ring dark (alpha 0) at settle/handoff,
// leaving the pool entry exactly as the old switch-start vanish did — at the
// slide's end instead of its start. Call AFTER the in-side park: a full pool's
// LRU acquire can evict this entry, and the post-park lookup reflects it.
uint32_t payload_focus_ring_adopt_for_exit(uint64_t out_sid)
{
    if (!g_payload_focus_ring.visible) return 0;
    struct focus_stroke *out = fr_pool_find(out_sid);
    if (!out || !out->initialized || !out->wid) return 0;
    // The slide's settle parks this ring dark through its own pump transaction,
    // which bypasses payload_focus_set_system_alpha — pre-stamp the advisory
    // alpha so the next inbound reveal doesn't mistake the entry for still-lit.
    out->last_alpha = 0.0f;
    return out->wid;
}

static void do_focus_ring_space_switch(char *message)
{
    struct __attribute__((packed)) {
        uint64_t out_sid;
        uint64_t in_sid;
        int32_t  fade_ms;     // >0: fade incoming 0->1 over this (animated path); 0: instant
        int32_t  easing;      // alpha curve (enum focus_ring_easing)
        uint32_t dest_wid;    // incoming space's focused window (0 = toggle-only)
        float    dest_x, dest_y, dest_w, dest_h;   // its screen rect
        float    dest_radius; // its corner radius
    } req;
    memcpy(&req, message, sizeof(req));

    int cid = SLSMainConnectionID();

    struct focus_stroke *out = fr_pool_find(req.out_sid);
    if (out && out->wid) {
        payload_focus_set_system_alpha(NULL, out->wid, 0.0f);
    }

    struct focus_stroke *in = fr_pool_find(req.in_sid);
    // FR-9: ensure the incoming ring sits at the daemon's freshly-resolved
    // dest_rect before it rides in. Park fresh when there's no live entry
    // (never-visited / evicted), AND re-park a live entry whose target wid or
    // rect is STALE — i.e. its window moved while the space was inactive (e.g.
    // an animation cancelled on the space switch snapped it to a new rect).
    // Without this the stale entry rides in at its old rect and visibly snaps to
    // the real position once the post-slide backstop re-show lands (the "ring
    // stuck at cancellation position" disconnect). A live entry already AT dest
    // is left untouched, so the smooth "rides for free" common path is unchanged.
    if (req.dest_wid != 0) {
        CGRect dest_rect = CGRectMake(req.dest_x, req.dest_y, req.dest_w, req.dest_h);
        bool stale = (!in || !in->wid) ||
                     (in->target_wid != req.dest_wid) ||
                     !CGRectEqualToRect(in->target_rect, dest_rect);
        if (stale) {
            in = payload_focus_ring_park(cid, req.dest_wid, dest_rect, req.dest_radius, req.in_sid);
        }
    }
    if (in && in->wid) {
        int owner = in->owner_cid ? in->owner_cid : cid;
        bool do_fade = (req.fade_ms > 0 && g_payload_focus_ring.visible);
        if (g_payload_focus_ring.visible && in->last_alpha >= 0.99f) {
            // Already lit at the destination — a fresh park is born visible while
            // the master flag is on, and the SPA-21 exit-ride keeps the incoming
            // ring riding in lit. Re-running the reveal would snap it to alpha 0
            // first (fade_start_xfade seeds the incoming at 0) — the land blink.
            // Leave it alone; just cancel any stale fade so a lingering tick
            // can't yank the alpha afterwards.
            payload_focus_fade_stop();
            payload_focus_ring_log("space_switch", "reveal_skip in=%u reason=already_lit", in->wid);
        } else if (do_fade) {
            // Fade in over fade_ms on the independent fade link. The daemon delays
            // this whole send by focus_ring_fade_delay so it lands AFTER the slide
            // — no cross-fade animator running then, so no commit-stream clash (the
            // old flicker), and the fade can outlast the slide / honor any duration.
            payload_focus_fade_start(owner, in->wid, (double)req.fade_ms / 1000.0, req.easing);
        } else {
            // Native / snap: reveal instantly (cancel any stale fade first).
            payload_focus_fade_stop();
            payload_focus_set_system_alpha(NULL, in->wid, g_payload_focus_ring.visible ? 1.0f : 0.0f);
        }
        g_active_stroke = in;   // t3d/track now target the destination's ring
    }

    // Single-visible-ring / per-display gate: only the incoming ring shows.
    fr_pool_hide_others(cid, in);

    payload_focus_ring_log("space_switch",
                           "out_sid=%llu in_sid=%llu out=%u in=%u fade_ms=%d",
                           (unsigned long long)req.out_sid,
                           (unsigned long long)req.in_sid,
                           out ? out->wid : 0, in ? in->wid : 0, req.fade_ms);
}

// =========================================================================
// Focus-ring follower (AC-6) — registered into the LB+T3D engine's per-frame
// follower registry (lb_follower_register) at stroke init. The engine calls this
// for every animated wid each tick; payload_focus_stroke_track self-filters
// (no-op unless wid is the tracked target). Runs on the pump thread under
// g_anim_lock, so it only touches the passed tx — a constraint the CA redraw
// inside track already satisfies (no blocking SLS round-trip). Also called
// directly by the debug-only translate3d batch path (window_transform.inc.m).
// =========================================================================
// SA_OPCODE_FOCUS_RING_MC_RIDE handler (MC EXIT). Wire: [u32 wid]. The ring was ridden
// out + faded to 0 on MC enter (see do_focus_ring_mc_enter_ride). This handler opens the
// visibility gate, positions the band at the window's CURRENT (thumbnail) rect while
// still invisible, and arms the MC mirror — which rides the band thumbnail->full AND
// fades alpha 0->1 in lockstep with the scale, reaching full opacity exactly as the
// window lands. Starting at alpha 0 means there is no full-size frame to flash. Getter
// unavailable / no bounds -> snap-reveal at the final rect (no ride, but the ring returns).
static void do_focus_ring_mc_ride(char *message)
{
    struct __attribute__((packed)) { uint32_t wid; } req;
    memcpy(&req, message, sizeof req);
    if (!req.wid) return;

    // Open the visibility gate (payload_focus_stroke_track paints only while visible),
    // and start at alpha 0 — the ride fades it in from here.
    uint32_t sw = g_payload_focus_stroke.wid;
    g_payload_focus_ring.visible = true;
    payload_focus_set_system_alpha(NULL, sw, 0.0f);

    payload_focus_mirror_init();          // resolves the tf3d string-xref (idempotent)
    if (!fr_cgs_t3d_resolve()) {
        payload_focus_set_system_alpha(NULL, sw, 1.0f);   // no ride → snap reveal at final
        logpf("FOCUS_RING_MC_RIDE", "arm wid=%u resolver=FAILED (reveal, no ride)", req.wid);
        return;
    }

    int    cid  = SLSMainConnectionID();
    // base = the window's NATURAL frame (SLSGetWindowBounds): constant through the exit,
    // both the SIZE source (visual = natural/scale) and the settle target.
    CGRect base = {0};
    if (SLSGetWindowBounds(cid, req.wid, &base) != kCGErrorSuccess ||
        base.size.width <= 0 || base.size.height <= 0) {
        payload_focus_set_system_alpha(NULL, sw, 1.0f);   // no ride → snap reveal at final
        logpf("FOCUS_RING_MC_RIDE", "arm wid=%u no bounds (reveal, no ride)", req.wid);
        return;
    }

    // Position the band at the thumbnail now (still invisible), then let the ca_step ride
    // it to full and fade alpha 0->1. base_dist = the arm-time |Δrect| from the settled
    // frame = the fade's 100%-remaining anchor (couples the fade to translation + scale,
    // so Exposé — which barely scales — still fades). If the read failed / the stroke
    // isn't this target yet, skip the pre-place (the ca_step catches up) and leave
    // base_dist 0 so the fade degrades to an immediate show (no journey to ride).
    float  m[16] = {0};
    int    rc    = fr_cgs_read_window_t3d(cid, req.wid, m);
    double base_dist = 0.0;
    if (rc == 0 && g_payload_focus_stroke.target_wid == req.wid) {
        CGRect arm = fr_project_frame_t3d(base, m);
        payload_focus_ring_follower(NULL, req.wid, arm);
        base_dist = fabs(arm.origin.x - base.origin.x) + fabs(arm.origin.y - base.origin.y)
                  + fabs(arm.size.width - base.size.width) + fabs(arm.size.height - base.size.height);
    }

    payload_focus_mirror_start_mc(cid, req.wid, sw, base, FR_MIRROR_MODE_MC, base_dist);
    logpf("FOCUS_RING_MC_RIDE", "armed wid=%u rc=%d natural=(%.0f,%.0f %.0fx%.0f) sx=%.3f dist=%.0f",
          req.wid, rc, base.origin.x, base.origin.y, base.size.width, base.size.height, m[0], base_dist);
}

// SA_OPCODE_FOCUS_RING_MC_ENTER_RIDE handler (MC ENTER). Wire: [u32 wid]. Inverse of the
// exit ride: the ring is currently visible on the focused window. Keep it visible and arm
// the MC mirror in enter mode — it rides the band full->thumbnail as the window shrinks
// into Mission Control AND fades alpha 1->0 over FR_MC_ENTER_FADE_S, then parks the ring
// hidden. Getter unavailable / no bounds -> snap-hide (graceful degrade).
static void do_focus_ring_mc_enter_ride(char *message)
{
    struct __attribute__((packed)) { uint32_t wid; } req;
    memcpy(&req, message, sizeof req);
    if (!req.wid) return;

    uint32_t sw = g_payload_focus_stroke.wid;

    payload_focus_mirror_init();
    if (!fr_cgs_t3d_resolve()) {
        g_payload_focus_ring.visible = false;             // no ride → snap hide
        payload_focus_set_system_alpha(NULL, sw, 0.0f);
        logpf("FOCUS_RING_MC_ENTER", "arm wid=%u resolver=FAILED (snap hide)", req.wid);
        return;
    }

    int    cid  = SLSMainConnectionID();
    CGRect base = {0};
    if (SLSGetWindowBounds(cid, req.wid, &base) != kCGErrorSuccess ||
        base.size.width <= 0 || base.size.height <= 0) {
        g_payload_focus_ring.visible = false;             // no ride → snap hide
        payload_focus_set_system_alpha(NULL, sw, 0.0f);
        logpf("FOCUS_RING_MC_ENTER", "arm wid=%u no bounds (snap hide)", req.wid);
        return;
    }

    // Stay visible (alpha as-is) through the fade; the ca_step drives it 1->0 while the
    // band rides into the thumbnail, then parks the ring hidden at settle. base_dist is
    // unused for enter (time-driven fade), pass 0.0.
    g_payload_focus_ring.visible = true;
    payload_focus_mirror_start_mc(cid, req.wid, sw, base, FR_MIRROR_MODE_MC_ENTER, 0.0);
    logpf("FOCUS_RING_MC_ENTER", "armed wid=%u natural=(%.0f,%.0f %.0fx%.0f)",
          req.wid, base.origin.x, base.origin.y, base.size.width, base.size.height);
}

static void payload_focus_ring_follower(CFTypeRef tx, uint32_t wid, CGRect rect)
{
    payload_focus_stroke_track(tx, wid, rect.origin.x, rect.origin.y,
                               rect.size.width, rect.size.height);
}
