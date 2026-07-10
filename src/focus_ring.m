#include "focus_ring.h"
#include "misc/extern.h"
#include "misc/helpers.h"
#include "display_manager.h"
#include "display.h"
#include "sa.h"
#include "window_iterator.h"
#include "window_manager.h"   // g_window_manager.space_animation_duration (fade_delay auto)

#include <Cocoa/Cocoa.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>  // kAXSheetRole / kAXDrawerRole
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <stdarg.h>
#include <time.h>
#include <math.h>

extern int g_connection;
extern struct window_manager g_window_manager;

// Monotonic focus-ring intent epoch. Bumped synchronously (caller thread) by
// every NEW ring intent — show/hide/display-show/space-switch/drag. Each
// async or deferred block captures the epoch at schedule time and no-ops if a
// newer intent has since landed. Single supersession authority: an ordinary
// WINDOW_FOCUSED cancels a pending deferred space-switch fade (FR-9) and a
// newer focus wins the show_for_wid dispatch race.
static uint64_t g_focus_ring_epoch = 0;

// Bump and return the new epoch. Call on the caller (event) thread, before any
// dispatch_async/dispatch_after, then capture the return by value in the block.
static inline uint64_t focus_ring_bump_epoch(void)
{
    return __atomic_add_fetch(&g_focus_ring_epoch, 1, __ATOMIC_RELAXED);
}

// True if `e` is still the current epoch (i.e. this block was not superseded).
static inline bool focus_ring_epoch_current(uint64_t e)
{
    return e == __atomic_load_n(&g_focus_ring_epoch, __ATOMIC_RELAXED);
}

// Set across a window drag (begin->end). While true, focus_ring_show_for_wid /
// _show_for_display early-return so nothing repaints mid-drag (e.g. a modal-
// parent WINDOW_MOVED reshow). Same-thread as the drag hooks (event loop), but
// atomic since the show paths can be reached off other event sources.
static bool g_focus_ring_drag_suppressed = false;

// Set across a FLOAT/unmanaged window drag (DidStart->DidEnd). The OS moves the
// window natively and emits a WINDOW_MOVED stream; while true, focus_ring_show_for_wid
// bypasses the coalesce defer so the ring tracks the window at VBL rate instead of
// trailing it by coalesce_ms. Safe to skip the defer here: it exists to absorb the
// stale-sibling 815 focus bounce, but the focused wid doesn't change mid-drag. The
// per-display VBL throttle still caps the actual send rate.
static bool g_focus_ring_drag_follow = false;

// FR-9 deferred animated-switch fade deadline. Set to (now + fade_delay) when
// a deferred reveal is in flight; tells space_transition_finish to keep its
// hands off the ring while the fade owns the reveal. __atomic_* — matches
// event_loop.c's space_transition model.
static uint64_t g_focus_ring_deferred_until_ns = 0;
static uint64_t focus_ring_now_ns(void);   // defined below; used by deferred-fade helpers above it

// Reads per-window corner radius via SLSWindowIteratorGetCornerRadii (app-
// requested) with a fallback to GetResolvedCornerRadii (compositor-applied).
static void get_corner_radius_for_window(uint32_t target_wid, float *out_radius)
{
    CFArrayRef window_ref = cfarray_of_cfnumbers(&target_wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    if (!window_ref) return;
    CFTypeRef query = SLSWindowQueryWindows(g_connection, window_ref, 1);
    if (query) {
        CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
        if (iterator) {
            if (SLSWindowIteratorGetCount(iterator) == 1 &&
                SLSWindowIteratorAdvance(iterator)) {
                float regular_radius = 0.0f;
                CFArrayRef radii_array = SLSWindowIteratorGetCornerRadii(iterator, 0);
                if (radii_array && CFArrayGetCount(radii_array) >= 4) {
                    CFNumberRef radius_num = CFArrayGetValueAtIndex(radii_array, 0);
                    if (radius_num) {
                        double radius_value = 0.0;
                        if (CFNumberGetValue(radius_num, kCFNumberFloat64Type, &radius_value)) {
                            regular_radius = (float)radius_value;
                        }
                    }
                    CFRelease(radii_array);
                }

                float resolved_radius = 0.0f;
                CFArrayRef resolved_array = SLSWindowIteratorGetResolvedCornerRadii(iterator);
                if (resolved_array && CFArrayGetCount(resolved_array) >= 1) {
                    CFNumberRef resolved_num = CFArrayGetValueAtIndex(resolved_array, 0);
                    if (resolved_num) {
                        double resolved_value = 0.0;
                        if (CFNumberGetValue(resolved_num, kCFNumberFloat64Type, &resolved_value)) {
                            resolved_radius = (float)resolved_value;
                        }
                    }
                }
                if (resolved_array) CFRelease(resolved_array);

                *out_radius = (resolved_radius > 0.0f) ? resolved_radius : regular_radius;
            }
            CFRelease(iterator);
        }
        CFRelease(query);
    }
    CFRelease(window_ref);
}

// Serial queue for off-runloop focus_ring work. SLS RPCs (3-5 round-trips per
// cache miss) inline in the AX handler would wedge the main CFRunLoop and queue
// subsequent AX notifications. Serial ordering keeps throttle state coherent
// and makes rapid focus changes last-write-wins.
static dispatch_queue_t g_focus_ring_dispatch_queue = NULL;
static pthread_once_t g_focus_ring_dispatch_once = PTHREAD_ONCE_INIT;
static void focus_ring_dispatch_init(void) {
    g_focus_ring_dispatch_queue = dispatch_queue_create(
        "com.koekeishiya.yabai.focus_ring.daemon",
        DISPATCH_QUEUE_SERIAL);
}

// =========================================================================
// Ring event log — one timestamped line per event, daemon side.
// =========================================================================
// Per-tree log dir (see src/misc/log.h) so parallel checkouts keep separate
// traces. YB_LOG_TREE is baked in by the makefile; the fallback keeps a hand
// build compiling. Verbose-gated: silent unless -V/--verbose.
#ifndef YB_LOG_TREE
#define YB_LOG_TREE "unknown"
#endif
#define FOCUS_RING_LOG_DIR  "/tmp/logs/yabai/" YB_LOG_TREE
#define FOCUS_RING_LOG_PATH FOCUS_RING_LOG_DIR "/focus_ring.log"

static int g_focus_ring_log_fd = -1;
static pthread_once_t g_focus_ring_log_once = PTHREAD_ONCE_INIT;

static void focus_ring_log_open(void)
{
    mkdir("/tmp/logs", 0755);
    mkdir("/tmp/logs/yabai", 0755);
    mkdir(FOCUS_RING_LOG_DIR, 0755);
    g_focus_ring_log_fd = open(FOCUS_RING_LOG_PATH,
                               O_WRONLY | O_CREAT | O_APPEND,
                               0644);
}

void focus_ring_log(const char *source, const char *fmt, ...)
{
    if (!g_verbose) return;
    pthread_once(&g_focus_ring_log_once, focus_ring_log_open);
    if (g_focus_ring_log_fd < 0) return;

    char buf[512];
    int off = 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    int n = snprintf(buf + off, sizeof(buf) - off,
                     "[%ld.%09ld] [yabai] [%s] enabled=%d ",
                     (long)ts.tv_sec, (long)ts.tv_nsec, source,
                     focus_ring_get_enabled() ? 1 : 0);
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
    (void)write(g_focus_ring_log_fd, buf, (size_t)off);
}

// =========================================================================
// Daemon-side state — overlays render in the SA payload.
// Tracks the current target so SLS move/resize events can decide whether
// to send a refresh and so the per-VBL throttle has a reference point.
// =========================================================================

static struct {
    bool     enabled;                // user-facing on/off
    float    stroke_width;           // px; clamped to [MIN, MAX]
    float    stroke_opacity;         // 0..1; fill opacity (the tint wash alpha)
    float    window_alpha;           // 0..1; whole-window translucency (NORMAL alpha slot)
    float    stroke_r, stroke_g, stroke_b; // 0..1; pushed to payload on SHOW
    int      color_mode;             // enum focus_ring_color_mode
    int      blur_radius;            // background-blur px; 0 = off; pushed on SHOW
    int      style;                  // enum focus_ring_style; pushed on SHOW
    int      modal_mode;             // enum focus_ring_modal_mode; daemon-side target re-resolution
    uint32_t modal_parent_wid;       // focused parent when framing its modal child (follow); 0 otherwise
    uint32_t modal_child_wid;        // the resolved sheet/drawer child currently framed; caches the AX walk so WINDOW_MOVED re-resolves skip it
    uint32_t modal_skip_wid;         // one-shot: a closing child to exclude from the next modal resolve
    float    blur_saturation;        // colorSaturate inputAmount; 1.0 = identity; pushed on SHOW
    float    blur_brightness;        // colorBrightness inputAmount; 0.0 = identity; pushed on SHOW
    float    blur_contrast;          // colorContrast inputAmount; 1.0 = identity; pushed on SHOW
    float    blur_hue;               // colorHueRotate angle (degrees); 0.0 = identity; pushed on SHOW
    int      blend_mode;             // enum focus_ring_blend_mode; tint compositingFilter; pushed on SHOW
    bool     blur_stroke;            // overlay a hard stroke on the blur ring; pushed on SHOW
    int      blur_stroke_position;   // enum focus_ring_blur_stroke_position; pushed on SHOW
    float    blur_stroke_width;      // px; stroke thickness independent of band; pushed on SHOW
    float    blur_bleed;             // inner-bleed px; 0 = off; BLUR only; pushed on SHOW
    // Per-layer color/opacity overrides for the BLUR ring. -1 opacity / !is_set color
    // = inherit the base stroke_opacity / stroke_{r,g,b}. Resolved at SHOW.
    float    blur_opacity;           // frost wash alpha override; -1 = inherit
    uint32_t blur_color;             // frost wash RGB override (0x00RRGGBB)
    bool     blur_color_is_set;
    float    blur_stroke_opacity;    // stroke overlay alpha override; -1 = inherit
    uint32_t blur_stroke_color;      // stroke overlay RGB override (0x00RRGGBB)
    bool     blur_stroke_color_is_set;
    float    blur_feather;           // band-mask edge feather px; 0 = off; BLUR only; pushed on SHOW
    bool     animate;                // ease the BLUR band on discrete transitions; pushed on SHOW
    float    animate_duration;       // discrete-transition ease duration (s); pushed on SHOW
    float    fade_duration;          // FR-9: fade duration (s); 0 = fade off (FR-22: replaces fade_enabled)
    int      fade_easing;            // FR-9: alpha easing curve (enum focus_ring_easing)
    float    fade_delay;             // FR-9: delay (s) from switch start before fade fires; <0 = auto (= space_animation_duration)
    float    coalesce_ms;            // focus-change coalesce window (ms); 0 = off; absorbs the stale-sibling 815 bounce
    // FR-20: desktop-ring style overrides (target wid 0), all inherit-by-default
    // and resolved daemon-side at SHOW (focus_ring_show_for_display) — the payload
    // never sees the inherit logic. Floats use -1 = inherit; blur (int) uses -1;
    // color and hsbc carry an is_set flag (0x000000 / 0.0 are valid values).
    // desktop_enabled is a sub-toggle (gated under .enabled). top_margin is an
    // ABSOLUTE inset of the top edge from the screen's top.
    bool     desktop_enabled;        // sub-toggle: desktop ring shows only if this AND .enabled
    float    desktop_width;          // px; -1 = inherit stroke_width
    float    desktop_radius;         // px corner radius (band's INNER edge); 0 = square
    float    desktop_opacity;        // 0..1; -1 = inherit stroke_opacity
    float    desktop_top_margin;     // px; absolute top-edge inset; 0 = screen top
    float    desktop_alpha;          // 0..1 window translucency; -1 = inherit window_alpha
    uint32_t desktop_color;          // RGB override (0x00RRGGBB); valid when _set
    bool     desktop_color_set;
    int      desktop_blur;           // background-blur px; -1 = inherit blur_radius
    float    desktop_hsbc[4];        // hue,saturation,brightness,contrast; valid when _set
    bool     desktop_hsbc_set;
    float    desktop_feather;        // band-mask feather px; -1 = inherit blur_feather
    int      desktop_blend;          // enum focus_ring_blend_mode; -1 = inherit blend_mode
    // FR-21: xray ring — recolor the band segments overlapping other windows'
    // frames. The overlap rects are resolved per-SHOW (focus_ring_xray_overlap_rects)
    // and shipped on the wire; color RGBA pushed on SHOW.
    bool     xray;                   // user-facing on/off
    float    xray_r, xray_g, xray_b, xray_a;
    uint32_t last_target_wid;
    CGRect   last_target_screen_rect;
    uint32_t last_target_did;
    float    last_target_radius;

    // Per-display VBL-period throttle; the refresh interval comes from the
    // display_timing cache.
    uint64_t last_send_ns;
    uint32_t last_send_did;
} g_focus_ring = {
    .enabled        = FOCUS_RING_DEFAULT_ENABLED,
    .stroke_width   = FOCUS_RING_DEFAULT_WIDTH,
    .stroke_opacity = FOCUS_RING_DEFAULT_OPACITY,
    .window_alpha   = FOCUS_RING_DEFAULT_ALPHA,
    .stroke_r       = FOCUS_RING_DEFAULT_R,
    .stroke_g       = FOCUS_RING_DEFAULT_G,
    .stroke_b       = FOCUS_RING_DEFAULT_B,
    .color_mode     = FOCUS_RING_COLOR_FIXED,
    .blur_radius    = FOCUS_RING_DEFAULT_BLUR,
    .style          = FOCUS_RING_DEFAULT_STYLE,
    .modal_mode     = FOCUS_RING_DEFAULT_MODAL,
    .blur_saturation = FOCUS_RING_DEFAULT_SATURATION,
    .blur_brightness = FOCUS_RING_DEFAULT_BRIGHTNESS,
    .blur_contrast   = FOCUS_RING_DEFAULT_CONTRAST,
    .blur_hue        = FOCUS_RING_DEFAULT_HUE,
    .blend_mode      = FOCUS_RING_DEFAULT_BLEND_MODE,
    .blur_stroke          = FOCUS_RING_DEFAULT_BLUR_STROKE,
    .blur_stroke_position = FOCUS_RING_DEFAULT_BLUR_STROKE_POSITION,
    .blur_stroke_width    = FOCUS_RING_DEFAULT_BLUR_STROKE_WIDTH,
    .blur_bleed      = FOCUS_RING_DEFAULT_BLEED,
    .blur_opacity        = FOCUS_RING_DEFAULT_BLUR_OPACITY,
    .blur_stroke_opacity = FOCUS_RING_DEFAULT_BLUR_STROKE_OPACITY,
    .blur_feather        = FOCUS_RING_DEFAULT_BLUR_FEATHER,
    .animate             = FOCUS_RING_DEFAULT_ANIMATE,
    .animate_duration    = FOCUS_RING_DEFAULT_ANIMATE_DURATION,
    .fade_duration       = FOCUS_RING_DEFAULT_FADE_DURATION,
    .fade_easing         = FOCUS_RING_DEFAULT_EASING,
    .fade_delay          = FOCUS_RING_DEFAULT_FADE_DELAY,
    .coalesce_ms         = FOCUS_RING_DEFAULT_COALESCE_MS,
    .desktop_enabled     = FOCUS_RING_DESKTOP_DEFAULT_ENABLED,
    .desktop_width       = FOCUS_RING_DESKTOP_DEFAULT_WIDTH,
    .desktop_radius      = FOCUS_RING_DESKTOP_DEFAULT_RADIUS,
    .desktop_opacity     = FOCUS_RING_DESKTOP_DEFAULT_OPACITY,
    .desktop_top_margin  = FOCUS_RING_DESKTOP_DEFAULT_TOP_MARGIN,
    .desktop_alpha       = FOCUS_RING_DESKTOP_DEFAULT_ALPHA,
    .desktop_blur        = FOCUS_RING_DESKTOP_DEFAULT_BLUR,
    .desktop_feather     = FOCUS_RING_DESKTOP_DEFAULT_FEATHER,
    .desktop_blend       = FOCUS_RING_DESKTOP_DEFAULT_BLEND,
    // desktop_color_set / desktop_hsbc_set zero-init false = inherit.
    .xray                = FOCUS_RING_DEFAULT_XRAY,
    .xray_r              = FOCUS_RING_XRAY_DEFAULT_R,
    .xray_g              = FOCUS_RING_XRAY_DEFAULT_G,
    .xray_b              = FOCUS_RING_XRAY_DEFAULT_B,
    .xray_a              = FOCUS_RING_XRAY_DEFAULT_A,
    // blur_color / blur_stroke_color *_is_set default to false (zero-init) = inherit.
};

bool focus_ring_deferred_fade_pending(void) {
    return focus_ring_now_ns() < __atomic_load_n(&g_focus_ring_deferred_until_ns, __ATOMIC_RELAXED);
}

bool focus_ring_get_enabled(void)             { return g_focus_ring.enabled; }
void focus_ring_set_enabled(bool enabled)
{
    g_focus_ring.enabled = enabled;
    // Drive Dock-side overlay alpha via SET_VISIBLE. Cheap (single opcode,
    // no redraw). When flipping ON, the next focus event (AX or payload-
    // side SLS 815) will paint the stroke into the now-visible overlay.
    scripting_addition_focus_ring_set_visible(enabled);
    focus_ring_log("set_enabled", "enabled=%d", enabled ? 1 : 0);
}
uint32_t focus_ring_get_target_wid(void)      { return g_focus_ring.last_target_wid; }

float focus_ring_get_width(void)   { return g_focus_ring.stroke_width; }
float focus_ring_get_opacity(void) { return g_focus_ring.stroke_opacity; }

// Forward decl — defined at the bottom of this file. Setters re-issue SHOW for
// the current target so a style change is visible immediately rather than on
// the next focus event.
static void focus_ring_reissue_show_for_last_target(const char *trigger, bool force_style);

void focus_ring_set_width(float width)
{
    if (width < FOCUS_RING_MIN_WIDTH) width = FOCUS_RING_MIN_WIDTH;
    if (width > FOCUS_RING_MAX_WIDTH) width = FOCUS_RING_MAX_WIDTH;
    g_focus_ring.stroke_width = width;
    focus_ring_log("set_width", "width=%.2f", width);
    focus_ring_reissue_show_for_last_target("set_width", false);
}

void focus_ring_set_opacity(float opacity)
{
    if (opacity < 0.0f) opacity = 0.0f;
    if (opacity > 1.0f) opacity = 1.0f;
    g_focus_ring.stroke_opacity = opacity;
    focus_ring_log("set_opacity", "opacity=%.2f", opacity);
    focus_ring_reissue_show_for_last_target("set_opacity", false);
}

// Whole-window translucency (`alpha`) — the ring window's NORMAL alpha slot,
// distinct from `opacity` (the fill/tint wash alpha). Show/hide and fades ride
// the SYSTEM alpha slot payload-side, so this composes with them (the compositor
// multiplies the two slots) instead of being clobbered by a fade.
float focus_ring_get_alpha(void) { return g_focus_ring.window_alpha; }

void focus_ring_set_alpha(float alpha)
{
    if (alpha < 0.0f) alpha = 0.0f;
    if (alpha > 1.0f) alpha = 1.0f;
    g_focus_ring.window_alpha = alpha;
    focus_ring_log("set_alpha", "alpha=%.2f", alpha);
    focus_ring_reissue_show_for_last_target("set_alpha", false);
}

int focus_ring_get_blur_radius(void) { return g_focus_ring.blur_radius; }

void focus_ring_set_blur_radius(int radius)
{
    if (radius < 0)                   radius = 0;
    if (radius > FOCUS_RING_MAX_BLUR) radius = FOCUS_RING_MAX_BLUR;
    g_focus_ring.blur_radius = radius;
    // FR-22: style is INFERRED from the blur radius — sharp stroke at 0, blur
    // above. The SHOW wire still carries `style`, so keep the field in lockstep
    // here; inference means the two can never disagree.
    g_focus_ring.style = (radius > 0) ? FOCUS_RING_STYLE_BLUR : FOCUS_RING_STYLE_STROKE;
    focus_ring_log("set_blur_radius", "radius=%d style=%d", radius, g_focus_ring.style);
    // force_style so the change is never dropped by the VBL throttle.
    focus_ring_reissue_show_for_last_target("set_blur_radius", true);
}

float focus_ring_get_blur_saturation(void) { return g_focus_ring.blur_saturation; }

void focus_ring_set_blur_saturation(float saturation)
{
    if (saturation < FOCUS_RING_MIN_SATURATION) saturation = FOCUS_RING_MIN_SATURATION;
    if (saturation > FOCUS_RING_MAX_SATURATION) saturation = FOCUS_RING_MAX_SATURATION;
    g_focus_ring.blur_saturation = saturation;
    focus_ring_log("set_blur_saturation", "saturation=%.2f", saturation);
    // force_style so the change is never dropped by the VBL throttle.
    focus_ring_reissue_show_for_last_target("set_blur_saturation", true);
}

float focus_ring_get_blur_brightness(void) { return g_focus_ring.blur_brightness; }

void focus_ring_set_blur_brightness(float brightness)
{
    if (brightness < FOCUS_RING_MIN_BRIGHTNESS) brightness = FOCUS_RING_MIN_BRIGHTNESS;
    if (brightness > FOCUS_RING_MAX_BRIGHTNESS) brightness = FOCUS_RING_MAX_BRIGHTNESS;
    g_focus_ring.blur_brightness = brightness;
    focus_ring_log("set_blur_brightness", "brightness=%.2f", brightness);
    focus_ring_reissue_show_for_last_target("set_blur_brightness", true);
}

float focus_ring_get_blur_contrast(void) { return g_focus_ring.blur_contrast; }

void focus_ring_set_blur_contrast(float contrast)
{
    if (contrast < FOCUS_RING_MIN_CONTRAST) contrast = FOCUS_RING_MIN_CONTRAST;
    if (contrast > FOCUS_RING_MAX_CONTRAST) contrast = FOCUS_RING_MAX_CONTRAST;
    g_focus_ring.blur_contrast = contrast;
    focus_ring_log("set_blur_contrast", "contrast=%.2f", contrast);
    focus_ring_reissue_show_for_last_target("set_blur_contrast", true);
}

float focus_ring_get_blur_hue(void) { return g_focus_ring.blur_hue; }

void focus_ring_set_blur_hue(float hue)
{
    if (hue < FOCUS_RING_MIN_HUE) hue = FOCUS_RING_MIN_HUE;
    if (hue > FOCUS_RING_MAX_HUE) hue = FOCUS_RING_MAX_HUE;
    g_focus_ring.blur_hue = hue;
    focus_ring_log("set_blur_hue", "hue=%.2f", hue);
    focus_ring_reissue_show_for_last_target("set_blur_hue", true);
}

int focus_ring_get_blend_mode(void) { return g_focus_ring.blend_mode; }

void focus_ring_set_blend_mode(int mode)
{
    if (mode < FOCUS_RING_BLEND_NORMAL || mode >= FOCUS_RING_BLEND_COUNT) {
        mode = FOCUS_RING_BLEND_NORMAL;
    }
    g_focus_ring.blend_mode = mode;
    focus_ring_log("set_blend_mode", "mode=%d", mode);
    focus_ring_reissue_show_for_last_target("set_blend_mode", true);
}

bool focus_ring_get_blur_stroke(void) { return g_focus_ring.blur_stroke; }

void focus_ring_set_blur_stroke(bool enabled)
{
    g_focus_ring.blur_stroke = enabled;
    focus_ring_log("set_blur_stroke", "enabled=%d", enabled ? 1 : 0);
    // force_style so the change is never dropped by the VBL throttle.
    focus_ring_reissue_show_for_last_target("set_blur_stroke", true);
}

int focus_ring_get_blur_stroke_position(void) { return g_focus_ring.blur_stroke_position; }

void focus_ring_set_blur_stroke_position(int position)
{
    if (position != FOCUS_RING_BLUR_STROKE_ABOVE && position != FOCUS_RING_BLUR_STROKE_BELOW) {
        position = FOCUS_RING_BLUR_STROKE_ABOVE;
    }
    g_focus_ring.blur_stroke_position = position;
    focus_ring_log("set_blur_stroke_position", "position=%d", position);
    focus_ring_reissue_show_for_last_target("set_blur_stroke_position", true);
}

float focus_ring_get_blur_stroke_width(void) { return g_focus_ring.blur_stroke_width; }

void focus_ring_set_blur_stroke_width(float width)
{
    if (width < FOCUS_RING_MIN_BLUR_STROKE_WIDTH) width = FOCUS_RING_MIN_BLUR_STROKE_WIDTH;
    if (width > FOCUS_RING_MAX_BLUR_STROKE_WIDTH) width = FOCUS_RING_MAX_BLUR_STROKE_WIDTH;
    g_focus_ring.blur_stroke_width = width;
    focus_ring_log("set_blur_stroke_width", "width=%.2f", width);
    focus_ring_reissue_show_for_last_target("set_blur_stroke_width", true);
}

float focus_ring_get_blur_bleed(void) { return g_focus_ring.blur_bleed; }

void focus_ring_set_blur_bleed(float bleed)
{
    if (bleed < FOCUS_RING_MIN_BLEED) bleed = FOCUS_RING_MIN_BLEED;
    if (bleed > FOCUS_RING_MAX_BLEED) bleed = FOCUS_RING_MAX_BLEED;
    g_focus_ring.blur_bleed = bleed;
    focus_ring_log("set_blur_bleed", "bleed=%.2f", bleed);
    // force_style so the change is never dropped by the VBL throttle (it also
    // flips the ring's z-order above the target, which must land immediately).
    focus_ring_reissue_show_for_last_target("set_blur_bleed", true);
}

// --- Per-layer color/opacity overrides (BLUR ring frost wash + stroke overlay) ---
// Opacity clamps to [0,1] unless it's the inherit sentinel (-1). Color stores RGB
// only (alpha comes from the matching opacity); set_*_inherit clears the override.

float focus_ring_get_blur_opacity(void) { return g_focus_ring.blur_opacity; }

void focus_ring_set_blur_opacity(float opacity)
{
    if (opacity != FOCUS_RING_BLUR_OPACITY_INHERIT) {
        if (opacity < 0.0f) opacity = 0.0f;
        if (opacity > 1.0f) opacity = 1.0f;
    }
    g_focus_ring.blur_opacity = opacity;
    focus_ring_log("set_blur_opacity", "opacity=%.2f", opacity);
    focus_ring_reissue_show_for_last_target("set_blur_opacity", true);
}

uint32_t focus_ring_get_blur_color(void) { return 0xff000000 | (g_focus_ring.blur_color & 0x00ffffff); }
bool     focus_ring_get_blur_color_is_set(void) { return g_focus_ring.blur_color_is_set; }

void focus_ring_set_blur_color(uint32_t argb)
{
    g_focus_ring.blur_color = argb & 0x00ffffff;
    g_focus_ring.blur_color_is_set = true;
    focus_ring_log("set_blur_color", "rgb=0x%06x", g_focus_ring.blur_color);
    focus_ring_reissue_show_for_last_target("set_blur_color", true);
}

void focus_ring_set_blur_color_inherit(void)
{
    g_focus_ring.blur_color_is_set = false;
    focus_ring_log("set_blur_color", "inherit");
    focus_ring_reissue_show_for_last_target("set_blur_color_inherit", true);
}

float focus_ring_get_blur_stroke_opacity(void) { return g_focus_ring.blur_stroke_opacity; }

void focus_ring_set_blur_stroke_opacity(float opacity)
{
    if (opacity != FOCUS_RING_BLUR_OPACITY_INHERIT) {
        if (opacity < 0.0f) opacity = 0.0f;
        if (opacity > 1.0f) opacity = 1.0f;
    }
    g_focus_ring.blur_stroke_opacity = opacity;
    focus_ring_log("set_blur_stroke_opacity", "opacity=%.2f", opacity);
    focus_ring_reissue_show_for_last_target("set_blur_stroke_opacity", true);
}

uint32_t focus_ring_get_blur_stroke_color(void) { return 0xff000000 | (g_focus_ring.blur_stroke_color & 0x00ffffff); }
bool     focus_ring_get_blur_stroke_color_is_set(void) { return g_focus_ring.blur_stroke_color_is_set; }

void focus_ring_set_blur_stroke_color(uint32_t argb)
{
    g_focus_ring.blur_stroke_color = argb & 0x00ffffff;
    g_focus_ring.blur_stroke_color_is_set = true;
    focus_ring_log("set_blur_stroke_color", "rgb=0x%06x", g_focus_ring.blur_stroke_color);
    focus_ring_reissue_show_for_last_target("set_blur_stroke_color", true);
}

void focus_ring_set_blur_stroke_color_inherit(void)
{
    g_focus_ring.blur_stroke_color_is_set = false;
    focus_ring_log("set_blur_stroke_color", "inherit");
    focus_ring_reissue_show_for_last_target("set_blur_stroke_color_inherit", true);
}

float focus_ring_get_blur_feather(void) { return g_focus_ring.blur_feather; }

void focus_ring_set_blur_feather(float feather)
{
    if (feather < FOCUS_RING_MIN_BLUR_FEATHER) feather = FOCUS_RING_MIN_BLUR_FEATHER;
    if (feather > FOCUS_RING_MAX_BLUR_FEATHER) feather = FOCUS_RING_MAX_BLUR_FEATHER;
    g_focus_ring.blur_feather = feather;
    focus_ring_log("set_blur_feather", "feather=%.2f", feather);
    focus_ring_reissue_show_for_last_target("set_blur_feather", true);
}

bool focus_ring_get_animate(void) { return g_focus_ring.animate; }

void focus_ring_set_animate(bool enabled)
{
    g_focus_ring.animate = enabled;
    focus_ring_log("set_animate", "enabled=%d", enabled ? 1 : 0);
    focus_ring_reissue_show_for_last_target("set_animate", true);
}

// Resolve the two BLUR-ring layers' final RGBA from the per-layer overrides, falling
// back to the caller-supplied base color/opacity when a layer is set to inherit.
// The base is the main ring's stroke color/opacity for window shows, or the
// desktop-resolved color/opacity for the desktop ring (an explicit blur_color /
// inner_stroke_color layer override still wins over either base). The payload
// receives these final values and applies them directly (no inherit logic
// payload-side). `tint_*` = frost wash, `str_*` = stroke overlay.
static void focus_ring_resolve_blur_layers(float base_r, float base_g, float base_b, float base_a,
                                           float *tint_r, float *tint_g, float *tint_b, float *tint_a,
                                           float *str_r,  float *str_g,  float *str_b,  float *str_a)
{
    if (g_focus_ring.blur_color_is_set) {
        *tint_r = ((g_focus_ring.blur_color >> 16) & 0xff) / 255.0f;
        *tint_g = ((g_focus_ring.blur_color >>  8) & 0xff) / 255.0f;
        *tint_b = ( g_focus_ring.blur_color        & 0xff) / 255.0f;
    } else {
        *tint_r = base_r; *tint_g = base_g; *tint_b = base_b;
    }
    *tint_a = (g_focus_ring.blur_opacity >= 0.0f) ? g_focus_ring.blur_opacity : base_a;

    if (g_focus_ring.blur_stroke_color_is_set) {
        *str_r = ((g_focus_ring.blur_stroke_color >> 16) & 0xff) / 255.0f;
        *str_g = ((g_focus_ring.blur_stroke_color >>  8) & 0xff) / 255.0f;
        *str_b = ( g_focus_ring.blur_stroke_color        & 0xff) / 255.0f;
    } else {
        *str_r = base_r; *str_g = base_g; *str_b = base_b;
    }
    *str_a = (g_focus_ring.blur_stroke_opacity >= 0.0f) ? g_focus_ring.blur_stroke_opacity : base_a;
}

// =========================================================================
// Stroke color + live accent tracking (focus_ring_color).
//
// AUTO mode resolves +[NSColor controlAccentColor] (which folds the
// "Multicolor" choice down to the standard macOS blue) and installs a
// distributed-notification observer so the ring re-colors live when the user
// changes the accent in System Settings. MUST live daemon-side: the SA payload
// links no AppKit, so NSColor is unavailable there — the daemon resolves to
// RGB and stamps it on every SA SHOW.
// =========================================================================
static id g_focus_ring_accent_observer = nil;   // NSDistributedNotificationCenter token

// Resolve the System Settings accent color to linear 0..1 sRGB components.
// Returns false (leaving outputs untouched) if AppKit can't produce an RGB
// color — caller keeps the previous value.
static bool focus_ring_resolve_accent_rgb(float *out_r, float *out_g, float *out_b)
{
    @autoreleasepool {
        NSColor *base = [NSColor controlAccentColor];
        NSColor *c = [base colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (!c) c = [base colorUsingColorSpace:[NSColorSpace genericRGBColorSpace]];
        if (!c) return false;
        CGFloat r = 0, g = 0, b = 0, a = 1;
        [c getRed:&r green:&g blue:&b alpha:&a];
        *out_r = (float)fmax(0.0, fmin(1.0, r));
        *out_g = (float)fmax(0.0, fmin(1.0, g));
        *out_b = (float)fmax(0.0, fmin(1.0, b));
        return true;
    }
}

// Pull the current accent into g_focus_ring and repaint the focused target.
// Called on set_color_auto and on every accent-change notification.
static void focus_ring_refresh_accent(const char *trigger)
{
    float r = g_focus_ring.stroke_r, g = g_focus_ring.stroke_g, b = g_focus_ring.stroke_b;
    if (focus_ring_resolve_accent_rgb(&r, &g, &b)) {
        g_focus_ring.stroke_r = r;
        g_focus_ring.stroke_g = g;
        g_focus_ring.stroke_b = b;
    }
    focus_ring_log("accent", "trigger=%s rgb=(%.2f,%.2f,%.2f)", trigger, r, g, b);
    focus_ring_reissue_show_for_last_target(trigger, true);
}

static void focus_ring_accent_observer_install(void)
{
    if (g_focus_ring_accent_observer) return;
    // System Settings posts this distributed notification when the user
    // changes the accent OR highlight color. Delivered on the main run loop;
    // the repaint bounces onto the focus_ring serial queue.
    g_focus_ring_accent_observer =
        [[NSDistributedNotificationCenter defaultCenter]
            addObserverForName:@"AppleColorPreferencesChangedNotification"
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note __attribute__((unused))) {
            focus_ring_refresh_accent("accent_changed");
        }];
    focus_ring_log("accent_observe", "installed=%d", g_focus_ring_accent_observer ? 1 : 0);
}

static void focus_ring_accent_observer_remove(void)
{
    if (!g_focus_ring_accent_observer) return;
    [[NSDistributedNotificationCenter defaultCenter]
        removeObserver:g_focus_ring_accent_observer];
    g_focus_ring_accent_observer = nil;
    focus_ring_log("accent_observe", "removed=1");
}

uint32_t focus_ring_get_color(void)
{
    uint8_t r = (uint8_t)lround(g_focus_ring.stroke_r * 255.0f);
    uint8_t g = (uint8_t)lround(g_focus_ring.stroke_g * 255.0f);
    uint8_t b = (uint8_t)lround(g_focus_ring.stroke_b * 255.0f);
    return (0xFFu << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

bool focus_ring_get_color_is_auto(void)
{
    return g_focus_ring.color_mode == FOCUS_RING_COLOR_AUTO;
}

// FR-22: named color presets from the macOS System Settings → Appearance accent
// palette. Alpha is forced 0xFF — ring transparency stays the separate `opacity`
// knob. Accepted anywhere the variadic command takes a color value. These are
// the commonly-cited accent hexes; tune against controlAccentColor on-device if
// a swatch looks off.
bool focus_ring_color_preset(const char *name, uint32_t *argb)
{
    if (!name || !argb) return false;
    static const struct { const char *name; uint32_t argb; } presets[] = {
        { "blue",   0xFF007AFF },
        { "purple", 0xFFA550A5 },
        { "pink",   0xFFF74F9E },
        { "red",    0xFFFF5257 },
        { "orange", 0xFFF7821B },
        { "yellow", 0xFFFFC600 },
        { "green",  0xFF62BA46 },
        { "grey",   0xFF8C8C8C },
        { "gray",   0xFF8C8C8C },
    };
    for (int i = 0; i < (int)(sizeof(presets) / sizeof(presets[0])); ++i) {
        if (strcmp(name, presets[i].name) == 0) { *argb = presets[i].argb; return true; }
    }
    return false;
}

void focus_ring_set_color(uint32_t argb)
{
    g_focus_ring.color_mode = FOCUS_RING_COLOR_FIXED;
    focus_ring_accent_observer_remove();   // leaving AUTO — stop tracking
    g_focus_ring.stroke_r = ((argb >> 16) & 0xFF) / 255.0f;
    g_focus_ring.stroke_g = ((argb >>  8) & 0xFF) / 255.0f;
    g_focus_ring.stroke_b = ((argb >>  0) & 0xFF) / 255.0f;
    focus_ring_log("set_color", "argb=0x%08x rgb=(%.2f,%.2f,%.2f)",
                   argb, g_focus_ring.stroke_r, g_focus_ring.stroke_g, g_focus_ring.stroke_b);
    focus_ring_reissue_show_for_last_target("set_color", true);
}

void focus_ring_set_color_auto(void)
{
    g_focus_ring.color_mode = FOCUS_RING_COLOR_AUTO;
    focus_ring_accent_observer_install();
    focus_ring_refresh_accent("set_color_auto");
}

static uint64_t focus_ring_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// Forward declaration — focus_ring_reissue_show_for_last_target calls this
// directly on the dispatch queue.
bool focus_ring_show_for_wid_at_rect_sync(uint32_t target_wid, CGRect target_rect, bool force_style);

// =========================================================================
// FR-21 xray — overlap-rect resolve.
//
// Collect the screen-space FRAMES (not intersections — the payload clips its
// re-stroke against full frames, so the visible overlap keeps tracking while
// the ring follows an animated target) of other windows on `target_wid`'s
// space whose bounds intersect `band`. Pure SLS on g_connection + a caller-
// provided fixed array, so it is safe on the focus_ring dispatch queue (no
// g_window_manager, no ts_alloc). Cost is three SLS round-trips per SHOW —
// focus-change cadence, not per-frame.
//
// Filters: the target itself; tag bit 9 (kCGSIgnoreForEventsTagBit) — the
// decorative-overlay marker every yabai overlay carries, so we never xray
// against our own windows; levels other than 0/3/8 and the unmanaged "real
// window" tag/attribute heuristic, both mirroring space_window_list (we
// can't consult g_window_manager on this queue).
//
// Known soft spot: SLSWindowQueryWindows' valid-but-empty failure mode (see
// space.c) silently yields zero rects for that SHOW; the next SHOW self-heals.
// =========================================================================
static int focus_ring_xray_overlap_rects(uint32_t target_wid, CGRect band,
                                         CGRect *out, int max)
{
    int n = 0;
    if (target_wid == 0 || max <= 0) return 0;

    uint64_t sid = 0;
    {
        CFArrayRef wid_ref = cfarray_of_cfnumbers(&target_wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        CFArrayRef space_ref = SLSCopySpacesForWindows(g_connection, 0x7, wid_ref);
        if (space_ref) {
            if (CFArrayGetCount(space_ref) > 0) {
                CFNumberGetValue(CFArrayGetValueAtIndex(space_ref, 0), kCFNumberSInt64Type, &sid);
            }
            CFRelease(space_ref);
        }
        CFRelease(wid_ref);
    }
    if (!sid) return 0;

    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef space_list_ref = cfarray_of_cfnumbers(&sid, sizeof(uint64_t), 1, kCFNumberSInt64Type);
    CFArrayRef window_list_ref = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_list_ref, 0x2, &set_tags, &clear_tags);
    CFRelease(space_list_ref);
    if (!window_list_ref) return 0;

    if (CFArrayGetCount(window_list_ref) > 0) {
        CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list_ref, 0x0);
        if (query) {
            CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
            if (iterator) {
                while (n < max && SLSWindowIteratorAdvance(iterator)) {
                    uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
                    if (wid == 0 || wid == target_wid) continue;

                    uint64_t tags = SLSWindowIteratorGetTags(iterator);
                    if (tags & (1ULL << 9)) continue;

                    int level = SLSWindowIteratorGetLevel(iterator);
                    if (level != 0 && level != 3 && level != 8) continue;

                    uint64_t attributes = SLSWindowIteratorGetAttributes(iterator);
                    if (!(((attributes & 0x2) || (tags & 0x400000000000000))
                          && ((tags & 0x1) || ((tags & 0x2) && (tags & 0x80000000))))) continue;

                    CGRect bounds = SLSWindowIteratorGetBounds(iterator);
                    if (!CGRectIntersectsRect(bounds, band)) continue;

                    out[n++] = bounds;
                }
                CFRelease(iterator);
            }
            CFRelease(query);
        }
    }
    CFRelease(window_list_ref);
    return n;
}

// Synchronous worker — runs exclusively on g_focus_ring_dispatch_queue; the
// public entry points hand off here so the AX-notification CFRunLoop never
// blocks on SLS RPCs or SA round-trips. force_style=true (explicit config
// change) bypasses the VBL throttle and tells the payload to clear its
// debug-knob color latch.
static inline bool focus_ring_rect_equal(CGRect a, CGRect b)
{
    const CGFloat e = 0.5f;   // sub-pixel; rects from the same SLS query are exact
    CGFloat dx = a.origin.x    - b.origin.x;    if (dx < 0) dx = -dx;
    CGFloat dy = a.origin.y    - b.origin.y;    if (dy < 0) dy = -dy;
    CGFloat dw = a.size.width  - b.size.width;  if (dw < 0) dw = -dw;
    CGFloat dh = a.size.height - b.size.height; if (dh < 0) dh = -dh;
    return dx < e && dy < e && dw < e && dh < e;
}

bool focus_ring_show_for_wid_at_rect_sync(uint32_t target_wid, CGRect target_rect, bool force_style)
{
    if (!g_focus_ring.enabled) {
        focus_ring_log("show_skip", "wid=%u reason=disabled", target_wid);
        return false;
    }
    if (target_wid == 0) {
        focus_ring_log("show_skip", "wid=0 reason=zero_wid");
        return false;
    }

    CGPoint target_center = CGPointMake(
        target_rect.origin.x + target_rect.size.width  / 2.0f,
        target_rect.origin.y + target_rect.size.height / 2.0f);
    uint32_t target_did = display_manager_point_display_id(target_center);
    if (target_did == 0) {
        focus_ring_log("show_skip", "wid=%u reason=no_display", target_wid);
        return false;
    }

    if (target_did != g_focus_ring.last_target_did && g_focus_ring.last_target_did != 0) {
        focus_ring_log("xdisplay", "wid=%u target_did=%u last_target_did=%u",
                       target_wid, target_did, g_focus_ring.last_target_did);
    }

    // Idempotent re-show guard. A focus event can re-fire SHOW for the window the
    // ring is ALREADY framing with no geometry change — e.g. the same-app
    // focus_recall handball (event_loop.c) posts a SECOND WINDOW_FOCUSED tens of
    // ms after the reveal, outside the VBL throttle window below. Re-issuing the
    // SA SHOW is a visible on/off redraw (FR-4 flicker). Skip when wid AND rect
    // are unchanged and this isn't a forced style refresh: a real move changes
    // the rect, a style change sets force_style, and a prior HIDE zeroed
    // last_target_wid — so every legitimate re-show still fires.
    if (!force_style &&
        target_wid == g_focus_ring.last_target_wid &&
        target_did == g_focus_ring.last_target_did &&
        focus_ring_rect_equal(target_rect, g_focus_ring.last_target_screen_rect)) {
        focus_ring_log("show_skip", "wid=%u reason=idempotent_rect_unchanged", target_wid);
        return true;
    }

    // Radius rarely changes — cache it when the wid hasn't changed.
    float radius;
    if (target_wid == g_focus_ring.last_target_wid && g_focus_ring.last_target_radius > 0.0f) {
        radius = g_focus_ring.last_target_radius;
    } else {
        radius = 0.0f;
        get_corner_radius_for_window(target_wid, &radius);
    }

    // Per-display VBL-period throttle. Same wid + within one refresh
    // interval of the last send => skip. Suppresses burst events that
    // would otherwise queue redundant SA round-trips during drag.
    // Throttle is bypassed when wid changes (focus transition snaps).
    struct display_timing *dt = display_timing_get(target_did);
    uint64_t now_ns = focus_ring_now_ns();
    if (!force_style &&
        dt && dt->valid &&
        target_wid == g_focus_ring.last_target_wid &&
        target_did == g_focus_ring.last_send_did &&   // cross-display focus has a different did -> bypasses
        target_did == g_focus_ring.last_target_did && // and a stale last_target (deferred-fade owned) can't fake a throttle
        g_focus_ring.last_send_ns > 0 &&
        now_ns - g_focus_ring.last_send_ns < dt->refresh_interval_ns) {
        focus_ring_log("throttled",
                       "wid=%u did=%u dt_ns=%llu interval_ns=%llu",
                       target_wid, target_did,
                       (unsigned long long)(now_ns - g_focus_ring.last_send_ns),
                       (unsigned long long)dt->refresh_interval_ns);
        // Refresh tracking state even when throttled (defensive — non-target
        // move events are filtered before reaching here).
        g_focus_ring.last_target_wid         = target_wid;
        g_focus_ring.last_target_screen_rect = target_rect;
        g_focus_ring.last_target_did         = target_did;
        g_focus_ring.last_target_radius      = radius;
        return true;
    }

    // Payload re-resolves the target's sid inside the SHOW handler via
    // SLSCopySpacesForWindows — the daemon passes no display/space ids.
    // did is tracked locally only for VBL throttle keying.
    focus_ring_log("sa_call", "wid=%u did=%u", target_wid, target_did);

    float tint_r, tint_g, tint_b, tint_a, str_r, str_g, str_b, str_a;
    focus_ring_resolve_blur_layers(g_focus_ring.stroke_r, g_focus_ring.stroke_g,
                                   g_focus_ring.stroke_b, g_focus_ring.stroke_opacity,
                                   &tint_r, &tint_g, &tint_b, &tint_a, &str_r, &str_g, &str_b, &str_a);

    // FR-21 xray: resolve the overlapping windows' frames for this SHOW. The
    // recolor renders on the sharp (blur=0) band directly, or on the frosted
    // ring's hard stroke overlay (inner_stroke) — skip the SLS round-trips for
    // a frosted ring without the stroke overlay (nothing would render it).
    CGRect xray_rects[SA_FOCUS_RING_XRAY_MAX_RECTS];
    int    xray_count = 0;
    bool   xray_renders = (g_focus_ring.style == FOCUS_RING_STYLE_STROKE)
                       || (g_focus_ring.style == FOCUS_RING_STYLE_BLUR && g_focus_ring.blur_stroke);
    if (g_focus_ring.xray && xray_renders) {
        CGRect band = CGRectInset(target_rect, -g_focus_ring.stroke_width, -g_focus_ring.stroke_width);
        xray_count = focus_ring_xray_overlap_rects(target_wid, band,
                                                   xray_rects, SA_FOCUS_RING_XRAY_MAX_RECTS);
    }

    bool ok = scripting_addition_focus_ring_show(target_wid,
                                                  target_rect.origin.x,
                                                  target_rect.origin.y,
                                                  target_rect.size.width,
                                                  target_rect.size.height,
                                                  radius,
                                                  g_focus_ring.stroke_width,
                                                  g_focus_ring.stroke_opacity,
                                                  g_focus_ring.stroke_r,
                                                  g_focus_ring.stroke_g,
                                                  g_focus_ring.stroke_b,
                                                  force_style,
                                                  g_focus_ring.blur_radius,
                                                  g_focus_ring.style,
                                                  g_focus_ring.blur_saturation,
                                                  g_focus_ring.blur_brightness,
                                                  g_focus_ring.blend_mode,
                                                  g_focus_ring.blur_stroke,
                                                  g_focus_ring.blur_stroke_position,
                                                  g_focus_ring.blur_stroke_width,
                                                  g_focus_ring.blur_bleed,
                                                  tint_r, tint_g, tint_b, tint_a,
                                                  str_r, str_g, str_b, str_a,
                                                  g_focus_ring.blur_contrast,
                                                  g_focus_ring.blur_feather,
                                                  g_focus_ring.animate,
                                                  g_focus_ring.animate_duration,
                                                  g_focus_ring.fade_duration,
                                                  g_focus_ring.blur_hue,
                                                  g_focus_ring.xray,
                                                  g_focus_ring.xray_r,
                                                  g_focus_ring.xray_g,
                                                  g_focus_ring.xray_b,
                                                  g_focus_ring.xray_a,
                                                  xray_count,
                                                  xray_rects,
                                                  g_focus_ring.window_alpha);

    g_focus_ring.last_target_wid         = target_wid;
    g_focus_ring.last_target_screen_rect = target_rect;
    g_focus_ring.last_target_did         = target_did;
    g_focus_ring.last_target_radius      = radius;
    g_focus_ring.last_send_ns            = now_ns;
    g_focus_ring.last_send_did           = target_did;

    focus_ring_log("show",
                   "wid=%u did=%u rect=(%.0f,%.0f %.0fx%.0f) radius=%.1f xray_n=%d sa_ok=%d",
                   target_wid, target_did,
                   target_rect.origin.x, target_rect.origin.y,
                   target_rect.size.width, target_rect.size.height,
                   radius, xray_count, ok ? 1 : 0);
    return ok;
}

// Return an SLS-attached CHILD window of `wid` (parent_id == wid), or 0 if it
// has none. CHEAP PRESENCE GATE only: SLS "attached" is necessary but NOT
// sufficient for a real modal — Chrome's find bar and autosuggest are
// SLS-attached floating panels too (window_attached_ax_sheet_child is the
// authoritative AX gate that follows). SLSCopyAssociatedWindows returns the
// whole attached group (children + the window itself) front-to-back. Runs on
// the focus_ring dispatch queue.
static uint32_t window_frontmost_attached_child(uint32_t wid)
{
    if (wid == 0) return 0;
    CFArrayRef assoc = SLSCopyAssociatedWindows(g_connection, wid);
    if (!assoc) return 0;

    uint32_t child = 0;
    CFIndex n = CFArrayGetCount(assoc);
    for (CFIndex i = 0; i < n && child == 0; i++) {
        uint32_t cand = 0;
        CFNumberRef num = CFArrayGetValueAtIndex(assoc, i);
        if (!num || !CFNumberGetValue(num, kCFNumberSInt32Type, &cand)) continue;
        if (cand == 0 || cand == wid) continue;
        if (cand == g_focus_ring.modal_skip_wid) continue;  // a child being torn down

        // Confirm cand is a child of wid (not the parent or a sibling).
        CFTypeRef it = NULL;
        if (window_iterator_de_window(g_connection, cand, &it)) {
            if (SLSWindowIteratorAdvance(it) &&
                SLSWindowIteratorGetParentID(it) == wid) {
                child = cand;
            }
            if (it) CFRelease(it);
        }
    }
    CFRelease(assoc);
    return child;
}

// Cheap SLS check: is `cand` still an attached child (parent_id == parent)?
// Backs the modal resolve's cache fast-path so a fresh AX walk doesn't fire on
// every WINDOW_MOVED while a sheet-parent is dragged.
static bool window_is_attached_child_of(uint32_t cand, uint32_t parent)
{
    if (cand == 0 || parent == 0) return false;
    CFTypeRef it = NULL;
    if (!window_iterator_de_window(g_connection, cand, &it)) return false;
    bool ok = SLSWindowIteratorAdvance(it) &&
              SLSWindowIteratorGetParentID(it) == parent;
    CFRelease(it);
    return ok;
}

// AUTHORITATIVE modal gate: return the wid of `parent_wid`'s attached
// AXSheet/AXDrawer child, or 0 if it has none.
//
// SLS attachment alone can't separate a real modal from a helper panel —
// Chrome's find bar / autosuggest are SLS-attached floating panels with tags
// identical to a real sheet's (kCGSAttachedWindowTagBit + kCGSFloatingWindow).
// The one signal that separates them, established empirically, is the AX role:
//
//   real sheet (System Settings, iTerm prefs): role==AXSheet, reachable ONLY as
//       a child of the parent's AX element (kAXChildrenAttribute); ABSENT from
//       the app's flat kAXWindowsAttribute list.
//   Chrome helper panel: role==AXWindow, present in the flat kAXWindows list and
//       ABSENT from the parent's AX children.
//
// So we walk the parent's kAXChildrenAttribute and accept the first
// AXSheet/AXDrawer (mirrors the FFM_AUTOFOCUS gate in event_loop.c). Runs on
// the focus_ring dispatch queue: only g_connection SLS + AX mach-IPC, no
// g_window_manager access, so it's safe off the main thread. The caller gates
// this behind an SLS presence check (window_frontmost_attached_child) and caches
// the result, so the AX cost lands only on a fresh resolve with a child present.
static uint32_t window_attached_ax_sheet_child(uint32_t parent_wid)
{
    if (parent_wid == 0) return 0;

    pid_t pid = 0;
    {
        CFTypeRef it = NULL;
        if (window_iterator_de_window(g_connection, parent_wid, &it)) {
            if (SLSWindowIteratorAdvance(it)) pid = SLSWindowIteratorGetPID(it);
            CFRelease(it);
        }
    }
    if (pid <= 0) return 0;

    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) return 0;
    AXUIElementSetMessagingTimeout(app, 1.0f);

    // Locate the parent's AX element in the app's window list (matched by wid).
    AXUIElementRef parent_ax = NULL;
    CFTypeRef windows = NULL;
    AXUIElementCopyAttributeValue(app, kAXWindowsAttribute, &windows);
    if (windows) {
        for (CFIndex i = 0, n = CFArrayGetCount(windows); i < n; i++) {
            AXUIElementRef ref = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            if (ax_window_id(ref) == parent_wid) {
                parent_ax = (AXUIElementRef)CFRetain(ref);
                break;
            }
        }
        CFRelease(windows);
    }

    uint32_t sheet = 0;
    if (parent_ax) {
        CFTypeRef children = NULL;
        AXUIElementCopyAttributeValue(parent_ax, kAXChildrenAttribute, &children);
        if (children) {
            for (CFIndex i = 0, n = CFArrayGetCount(children); i < n && sheet == 0; i++) {
                AXUIElementRef el = (AXUIElementRef)CFArrayGetValueAtIndex(children, i);
                uint32_t cand = ax_window_id(el);
                if (cand == 0 || cand == g_focus_ring.modal_skip_wid) continue;  // a child being torn down

                CFTypeRef role = NULL;
                AXUIElementCopyAttributeValue(el, kAXRoleAttribute, &role);
                if (role && (CFEqual(role, kAXSheetRole) || CFEqual(role, kAXDrawerRole)))
                    sheet = cand;
                if (role) CFRelease(role);
            }
            CFRelease(children);
        }
        CFRelease(parent_ax);
    }

    CFRelease(app);
    return sheet;
}

// Resolve the wid the ring should actually frame, honoring focus_ring_modal.
// In follow/both, retarget to the parent's attached AXSheet/AXDrawer child so
// the ring frames the modal directly; otherwise frame the focused window
// unchanged. A plain SLS-attached panel (Chrome find bar) is NOT retargeted.
static uint32_t focus_ring_resolve_modal_target(uint32_t target_wid)
{
    int mode = g_focus_ring.modal_mode;
    if (mode != FOCUS_RING_MODAL_FOLLOW && mode != FOCUS_RING_MODAL_BOTH) {
        g_focus_ring.modal_parent_wid = 0;
        g_focus_ring.modal_child_wid  = 0;
        return target_wid;
    }

    uint32_t skip = g_focus_ring.modal_skip_wid;

    // Fast path: already framing a sheet child of THIS parent and it's still
    // attached — reuse it without a fresh AX walk. Keeps the AX cost off the
    // WINDOW_MOVED hot-path while a sheet-parent is dragged (the move handler
    // re-resolves from the parent on every move event).
    if (g_focus_ring.modal_parent_wid == target_wid &&
        g_focus_ring.modal_child_wid != 0 &&
        g_focus_ring.modal_child_wid != skip &&
        window_is_attached_child_of(g_focus_ring.modal_child_wid, target_wid)) {
        g_focus_ring.modal_skip_wid = 0;
        return g_focus_ring.modal_child_wid;
    }

    // Fresh resolve. Cheap SLS presence gate first: only pay for the AX sheet
    // walk when the parent actually has an attached child.
    uint32_t child = 0;
    if (window_frontmost_attached_child(target_wid) != 0)
        child = window_attached_ax_sheet_child(target_wid);
    g_focus_ring.modal_skip_wid = 0;  // one-shot exclusion consumed above

    if (child) {
        // Remember the parent: the child (a Catalyst/SwiftUI sheet) rides the
        // parent's drag but doesn't emit its own move event, so the ring tracks
        // the parent's WINDOW_MOVED and re-fetches the child's new rect there.
        g_focus_ring.modal_parent_wid = target_wid;
        g_focus_ring.modal_child_wid  = child;
        focus_ring_log("modal_retarget", "parent=%u child=%u mode=%d",
                       target_wid, child, mode);
        return child;
    }
    g_focus_ring.modal_parent_wid = 0;
    g_focus_ring.modal_child_wid  = 0;
    return target_wid;
}

// FR-1 (state-gate half): the single daemon-side classifier every ring entry point
// consults to decide whether a wid is paintable RIGHT NOW. It only CLASSIFIES —
// the action per result (skip vs defer-to-settle) is the caller's, because the
// ordering differs per call site:
//
//   THUMBNAIL — the window is an inactive-stage thumbnail: ordered out and rendered
//     via a shrink Transform3D, so SLSGetScreenRectForWindow returns the tiny
//     composited rect and the ring would frame the thumbnail. Callers SUPPRESS —
//     the relocate is owned by the focus-arbitration side. Not classified in this
//     tree (stages are not part of this build).
//   MINIMIZED — the WINDOW_FOCUSED handler already routes minimized wids to
//     lost_focused, but a direct show (or a stale focus resolve) could slip one
//     through; callers SUPPRESS (DEMINIMIZE re-shows).
//   ANIMATING — the target's display is mid-animation (space slides are caught
//     earlier by the caller's space_transition_active gate). Painting now lands on
//     an in-flight rect, so callers DEFER to the unified settle, which re-resolves
//     and reveals once motion ends. Only probed when check_animating is set: it
//     costs an SLS round-trip (window_display_id + display_is_animating), which the
//     drag-restroke hot path (show_for_wid_rect) skips since an explicit-rect paint
//     WANTS to run mid-transform.
//
// The payload ring is state-blind (it draws the daemon's rect verbatim), so the gate
// MUST be daemon-side. Runs on the caller (event/SLS) thread before any dispatch —
// window_manager_find_window and these SLS reads are NOT safe on the focus_ring
// serial queue.
enum focus_ring_target_state {
    FOCUS_RING_TARGET_OK = 0,
    FOCUS_RING_TARGET_THUMBNAIL,
    FOCUS_RING_TARGET_MINIMIZED,
    FOCUS_RING_TARGET_ANIMATING,
};

static enum focus_ring_target_state focus_ring_target_eligibility(uint32_t wid, bool check_animating)
{
    if (wid == 0) return FOCUS_RING_TARGET_OK;   // 0 = restore / explicit-rect sentinel; callers handle
    struct window *w = window_manager_find_window(&g_window_manager, wid);
    if (!w) return FOCUS_RING_TARGET_OK;
    // (stage-thumbnail classification not in this build)
    if (window_check_flag(w, WINDOW_MINIMIZE)) return FOCUS_RING_TARGET_MINIMIZED;
    if (check_animating) {
        uint32_t did = window_display_id(wid);
        if (did && display_is_animating(did))  return FOCUS_RING_TARGET_ANIMATING;
    }
    return FOCUS_RING_TARGET_OK;
}

// Internal core for the wid-based ring show. defer_when_animating gates the FR-1
// animating-defer: true for normal focus shows (focus_ring_show_for_wid); false for the
// settle's own resume (focus_ring_show_for_wid_settled), which must paint even while the
// display still reports animating (a ~640ms stage SEND outlasts the 0.5s settle cap) —
// re-arming the poll that called us would loop / strand the ring hidden.
static bool focus_ring_show_for_wid_impl(uint32_t target_wid, bool defer_when_animating)
{
    if (!g_focus_ring.enabled) return false;

    // Unified eligibility gate (FR-1). ANIMATING is only ever returned when
    // defer_when_animating is set (it IS the classifier's check_animating arg), so the
    // settle-resume path falls straight through to the paint below.
    enum focus_ring_target_state state =
        focus_ring_target_eligibility(target_wid, defer_when_animating);
    if (state == FOCUS_RING_TARGET_THUMBNAIL) {
        focus_ring_log("show_skip", "wid=%u reason=stage_thumbnail", target_wid);
        return false;
    }
    if (state == FOCUS_RING_TARGET_MINIMIZED) {
        focus_ring_log("show_skip", "wid=%u reason=minimized", target_wid);
        return false;
    }
    if (__atomic_load_n(&g_focus_ring_drag_suppressed, __ATOMIC_RELAXED)) {
        focus_ring_log("show_skip", "wid=%u reason=drag_suppressed", target_wid);
        return false;
    }
    // FR-4: the single choke point for every wid-based ring show. Never paint
    // while a space-switch slide is in flight — the ring is hidden at slide START
    // and re-shown at the SETTLED position by SPACE_TRANSITION_END. Any show in
    // between resolves the window's MID-SLIDE rect (which lands off-screen, or
    // visibly on the adjacent display, before END corrects it). Gating here
    // instead of at each call site covers all current and future callers;
    // END/fallback clear the flag before their re-show, so the settled reveal
    // still goes through. Ordered BEFORE the FR-1 animating-defer below: a slide
    // also makes the display "animating", but FR-4 owns the slide's single
    // re-show and deliberately short-circuits the settle — so the
    // space-transition gate must win.
    // Display-scoped: suppress only when the in-flight slide is on THIS target's
    // display — a slide on another display must not gate this show.
    // window_display_id (SLS round-trip) is only paid when a transition is
    // actually active (&& short-circuits).
    extern bool space_transition_active(void);
    extern bool space_transition_on_display(uint32_t did);
    if (space_transition_active() && space_transition_on_display(window_display_id(target_wid))) {
        focus_ring_log("show_skip", "wid=%u reason=space_transition_active", target_wid);
        return false;
    }
    // FR-1: the target's display is mid-animation (space slides were caught just
    // above). Painting now lands on an in-flight rect; defer to the unified
    // settle, which re-resolves + reveals once motion ends. resume_wid = this
    // target so the reveal lands on it.
    if (state == FOCUS_RING_TARGET_ANIMATING) {
        extern uint32_t focus_ring_settle_arm_public(uint32_t did, uint32_t resume_wid);
        uint32_t did = window_display_id(target_wid);
        focus_ring_log("show_defer", "wid=%u reason=display_animating did=%u", target_wid, did);
        focus_ring_settle_arm_public(did, target_wid);
        return false;
    }
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    uint64_t my_epoch = focus_ring_bump_epoch();
    // Coalesce focus-change bounces: a stale same-space sibling 815 can briefly
    // resolve focus to the previous front window and back (SLS z-order lag after a
    // click). Defer the resolve+send by coalesce_ms; if a newer focus intent
    // supersedes within that window the epoch check below drops this block, so the
    // intermediate never paints. 0 = off (send on the next queue turn).
    // Rect resolution is deferred too so it reads the SETTLED geometry.
    void (^work)(void) = ^{
        if (!focus_ring_epoch_current(my_epoch)) {
            focus_ring_log("epoch_superseded", "src=show_for_wid wid=%u e=%llu",
                           target_wid, (unsigned long long)my_epoch);
            return;
        }
        uint32_t wid = focus_ring_resolve_modal_target(target_wid);
        CGRect target_rect;
        if (SLSGetScreenRectForWindow(g_connection, wid, &target_rect) != kCGErrorSuccess) {
            focus_ring_log("show_skip", "wid=%u reason=no_screen_rect", wid);
            return;
        }
        focus_ring_show_for_wid_at_rect_sync(wid, target_rect, false);
    };
    float coalesce_ms = g_focus_ring.coalesce_ms;
    bool drag_follow = __atomic_load_n(&g_focus_ring_drag_follow, __ATOMIC_RELAXED);
    if (coalesce_ms > 0.0f && !drag_follow) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(coalesce_ms * (double)NSEC_PER_MSEC)),
                       g_focus_ring_dispatch_queue, work);
    } else {
        dispatch_async(g_focus_ring_dispatch_queue, work);
    }
    return true;
}

// Public entry: resolve the target's screen rect via SLS, then redraw. Defers to
// the unified settle when the target's display is mid-animation (FR-1) so every
// direct caller is animating-deferred.
bool focus_ring_show_for_wid(uint32_t target_wid)
{
    return focus_ring_show_for_wid_impl(target_wid, true);
}

// Settle-resume entry: called ONLY by the unified settle poll (event_loop.c) when
// the animation has ended OR the 0.5s settle cap elapsed mid-motion. The display
// may still report animating at the cap, so this bypasses the FR-1 animating-defer
// and paints unconditionally — re-entering the defer would re-arm the very poll
// that called us. The thumbnail / minimized guards still apply.
bool focus_ring_show_for_wid_settled(uint32_t target_wid)
{
    return focus_ring_show_for_wid_impl(target_wid, false);
}

// Like focus_ring_show_for_wid, but frames an explicit rect instead of resolving
// via SLSGetScreenRectForWindow. Used by the WINDOW_MOVED/RESIZED re-stroke for
// managed BSP windows: right after a transform-follow drag the window's drag-warp
// transform is still springing back, so an SLS read returns the mid-spring
// transformed bounds — the caller passes the window's node rect (layout truth)
// instead. Same suppress / space-transition / epoch / coalesce guards as the SLS
// variant so it can't paint mid-drag or mid-space-switch. No modal re-resolve:
// the target IS this managed window (a modal retarget would point the ring's
// target at the unmanaged child wid, not this one).
bool focus_ring_show_for_wid_rect(uint32_t target_wid, CGRect rect)
{
    if (!g_focus_ring.enabled) return false;
    // check_animating=false: this entry exists to paint at the caller-supplied rect
    // precisely WHILE the live SLS rect is transform-tainted (drag-warp spring-back),
    // so a mid-animation display is the expected case here, not a reason to defer. Only
    // the thumbnail / minimized suppressions apply.
    enum focus_ring_target_state state = focus_ring_target_eligibility(target_wid, false);
    if (state == FOCUS_RING_TARGET_THUMBNAIL) {
        focus_ring_log("show_skip", "wid=%u reason=stage_thumbnail", target_wid);
        return false;
    }
    if (state == FOCUS_RING_TARGET_MINIMIZED) {
        focus_ring_log("show_skip", "wid=%u reason=minimized", target_wid);
        return false;
    }
    if (__atomic_load_n(&g_focus_ring_drag_suppressed, __ATOMIC_RELAXED)) {
        focus_ring_log("show_skip", "wid=%u reason=drag_suppressed", target_wid);
        return false;
    }
    // FR-4, display-scoped: suppress only when the in-flight slide is on THIS
    // target's display; window_display_id (SLS round-trip) is only paid when a
    // transition is actually active (&& short-circuits).
    extern bool space_transition_active(void);
    extern bool space_transition_on_display(uint32_t did);
    if (space_transition_active() && space_transition_on_display(window_display_id(target_wid))) {
        focus_ring_log("show_skip", "wid=%u reason=space_transition_active", target_wid);
        return false;
    }
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    uint64_t my_epoch = focus_ring_bump_epoch();
    CGRect r = rect;
    void (^work)(void) = ^{
        if (!focus_ring_epoch_current(my_epoch)) {
            focus_ring_log("epoch_superseded", "src=show_for_wid_rect wid=%u e=%llu",
                           target_wid, (unsigned long long)my_epoch);
            return;
        }
        focus_ring_show_for_wid_at_rect_sync(target_wid, r, false);
    };
    float coalesce_ms = g_focus_ring.coalesce_ms;
    bool drag_follow = __atomic_load_n(&g_focus_ring_drag_follow, __ATOMIC_RELAXED);
    if (coalesce_ms > 0.0f && !drag_follow) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(coalesce_ms * (double)NSEC_PER_MSEC)),
                       g_focus_ring_dispatch_queue, work);
    } else {
        dispatch_async(g_focus_ring_dispatch_queue, work);
    }
    return true;
}

void focus_ring_set_visible_async(bool visible)
{
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        scripting_addition_focus_ring_set_visible(visible);
    });
}

// MC-exit ring ride: arm the payload's MC-mode transform mirror on `wid` from the
// SAME serial queue as the show/visibility sends, so it lands after them. The payload
// converges regardless of exact ordering — the mirror's ca_clock re-checks visible +
// target each VBL — so a delayed (coalesced) show just costs at most a frame of the
// ride. No-op for wid 0.
void focus_ring_mc_ride_async(uint32_t wid)
{
    if (!wid) return;
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        scripting_addition_focus_ring_mc_ride(wid);
    });
}

// MC-ENTER ring ride: fade the ring out while riding the window into its thumbnail, then
// park it hidden. Same serial queue as the show/visibility sends. No-op for wid 0.
void focus_ring_mc_enter_ride_async(uint32_t wid)
{
    if (!wid) return;
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        scripting_addition_focus_ring_mc_enter_ride(wid);
    });
}

void focus_ring_hide(void)
{
    if (!g_focus_ring.enabled) return;
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    uint64_t my_epoch = focus_ring_bump_epoch();
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        if (!focus_ring_epoch_current(my_epoch)) {
            focus_ring_log("epoch_superseded", "src=hide e=%llu",
                           (unsigned long long)my_epoch);
            return;
        }
        focus_ring_log("hide", "prev_wid=%u", g_focus_ring.last_target_wid);
        scripting_addition_focus_ring_hide();
        g_focus_ring.last_target_wid    = 0;
        g_focus_ring.last_target_radius = 0.0f;
        g_focus_ring.last_send_ns       = 0;
    });
}
void focus_ring_set_drag_follow(bool on)
{
    if (!g_focus_ring.enabled) return;
    if (__atomic_exchange_n(&g_focus_ring_drag_follow, on, __ATOMIC_RELAXED) == on) return;
    focus_ring_log("drag_follow", "follow=%d", on ? 1 : 0);
}

// Conditional hide for a window that's going away (destroy / minimize): only
// clears the ring if `wid` is STILL the committed target at drain time. `reason`
// is a static string (a literal) folded into the log line.
//
// The decision must be made on the dispatch queue, not the main thread: show and
// hide are both async, and the queue is the only place their ordering is
// authoritative. A main-thread guard reads stale state (the last *committed*
// target, or a focused_window_id a destroy/space-change left out of sync) and
// would either wipe a ring belonging to the newly-focused window or miss one
// genuinely stuck on the dead wid. Checking last_target_wid here, after any
// enqueued show has run, resolves both orderings:
//   - focus moved to a survivor S: show(S) ran first → last_target==S != wid → skip
//   - ring genuinely on the dead wid: last_target==wid → hide
void focus_ring_hide_for_wid(uint32_t wid, const char *reason)
{
    if (!g_focus_ring.enabled) return;
    if (wid == 0) return;
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        if (g_focus_ring.last_target_wid != wid) {
            focus_ring_log("hide_skip", "wid=%u cur_target=%u reason=%s",
                           wid, g_focus_ring.last_target_wid, reason ? reason : "?");
            return;
        }
        focus_ring_log("hide", "prev_wid=%u reason=%s", wid, reason ? reason : "?");
        scripting_addition_focus_ring_hide();
        g_focus_ring.last_target_wid    = 0;
        g_focus_ring.last_target_radius = 0.0f;
        g_focus_ring.last_send_ns       = 0;
    });
}

// Live-follow reposition for a window that MOVED or RESIZED. Re-parks the ring
// on the window's new rect, but ONLY when `wid` is STILL the committed target —
// moving or resizing a BACKGROUND window can't steal the ring off the focused
// one. Runs on the event thread (its only callers are the AX move/resize
// handlers). focus_ring_show_for_wid re-resolves the live SLS rect: the
// idempotent guard skips a no-op move (rect unchanged) and the per-VBL throttle
// coalesces drag bursts to one send per refresh.
void focus_ring_reposition_for_wid(uint32_t wid)
{
    if (!g_focus_ring.enabled) return;
    if (wid == 0) return;
    if (wid != g_focus_ring.last_target_wid) return;
    focus_ring_show_for_wid(wid);
}

// SPA-17: resolve the destination space's focused window + its natural rect +
// corner radius — the geometry the focus ring parks on. Shared by
// focus_ring_space_switch (park + alpha fade) and the animated slide seed
// (space_manager ships it on the SPACE_ANIMATE wire so the ring rides the slide
// as a geo-rider). Returns false (and *out_wid=0) when there's no parkable
// target. MUST run on the caller/event thread: space_manager_preferred_focus_wid
// → space_window_list uses the single-threaded ts_alloc arena (off-thread
// resolution aborts in ts_resize). Natural bounds (SLSGetWindowBounds), not the
// rendered rect: transform-independent (a residual slide transform on dest_wid
// won't skew it) and the window's ACTUAL rect, so constrained windows (System
// Settings centering in their tile) get a ring that hugs the window rather than
// the BSP slot.
bool focus_ring_resolve_dest(uint64_t in_sid, uint32_t *out_wid, CGRect *out_rect, float *out_radius)
{
    extern uint32_t space_manager_preferred_focus_wid(uint64_t sid, const char **out_source, uint32_t *out_view_last);
    uint32_t dest_wid = space_manager_preferred_focus_wid(in_sid, NULL, NULL);
    // Priority 3 (mirrors the focus path's own z-topmost fallback): rich SLS
    // query on the DESTINATION space. An inactive space's z-order is frozen
    // from when it was last left, so row[0] is the window macOS reveals on
    // commit — this answers for spaces never visited since restart and for
    // untracked windows, which the recall + tracked-list resolver above
    // cannot. Wildcard owner is deliberate: the destination space has no
    // front app yet, so there is nothing to owner-scope by.
    if (dest_wid == 0) {
        extern uint32_t space_query_focused_wid(uint64_t sid, int owner, uint64_t include_tags, uint64_t exclude_tags);
        dest_wid = space_query_focused_wid(in_sid, 0, WQ_TAG_NORMAL,
                                           WQ_TAG_STICKY | WQ_TAG_HIDDEN | WQ_TAG_MINIMIZED);
    }
    CGRect   dest_rect = CGRectZero;
    float    dest_radius = 0.0f;
    if (dest_wid != 0) {
        if (SLSGetWindowBounds(g_connection, dest_wid, &dest_rect) == kCGErrorSuccess) {
            get_corner_radius_for_window(dest_wid, &dest_radius);
        } else {
            dest_wid = 0;   // no rect → can't park; fall back to toggle-only
        }
    }
    if (out_wid)    *out_wid    = dest_wid;
    if (out_rect)   *out_rect   = dest_rect;
    if (out_radius) *out_radius = dest_radius;
    return dest_wid != 0;
}

// FR-9: drive the per-space ring ride across a space switch. Anticipate ON:
// vanish the outgoing space's parked ring and reveal the incoming space's,
// parked on the destination's focused window. OFF: legacy hide+reshow (the
// SPACE_CHANGED path re-shows on the destination at slide settle).
//
// SPA-17: the ring does NOT "ride for free" — it's a standalone overlay at the
// target's natural rect, and the slide moves window pixels via Transform3D
// without touching the ring's bounds. The geometric ride is driven separately:
// the animated slide seed parks the ring (via the ring geometry it carries on
// the SPACE_ANIMATE wire) and adds it as a geo-only rider on the same per-frame
// translate. This function owns only the ALPHA reveal.
//
// `animated` marks the yabai-driven slide: only then is the incoming ring faded
// in, over fade_duration with the fade `easing` curve (the geo ride follows the
// slide's own space_animation_easing). Native / snap switches pass
// animated=false → instant reveal.
//
// last_target_wid is zeroed so the post-slide backstop re-show isn't swallowed
// by the idempotent-rect guard — it must re-confirm the destination geometry.
void focus_ring_space_switch(uint64_t out_sid, uint64_t in_sid, bool animated)
{
    if (!g_focus_ring.enabled) return;

    extern bool space_nav_observer_get_enabled(void);   // = focus_ring_anticipate

    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);

    // NATIVE (non-animated) switch keeps the legacy anticipate behavior:
    // anticipate OFF just hides (the post-switch focus path re-shows instantly);
    // anticipate ON parks + reveals at the destination immediately.
    if (!animated) {
        if (!space_nav_observer_get_enabled()) { focus_ring_hide(); return; }
        int easing = g_focus_ring.fade_easing;
        // Resolve the destination space's focused window so the payload can PARK
        // a ring on it when that space has no live pool entry (never-visited /
        // evicted). Front-process-INDEPENDENT resolver: at switch time the front
        // app is still the OUTGOING space's, so a front-scoped lookup resolves
        // the wrong space. dest_wid==0 → payload toggle-only.
        //
        // MUST run on the CALLER (event) thread, NOT inside the dispatch block:
        // the resolver uses the ts_alloc temp-storage arena, which is
        // single-threaded (owned by the event thread) — resolving on the
        // focus-ring queue aborts in ts_resize. Only the SA send is deferred.
        // (The ANIMATED path needs no resolve here — the slide seed ships its
        // own ring geometry on the SPACE_ANIMATE wire.)
        uint32_t dest_wid; CGRect dest_rect; float dest_radius;
        focus_ring_resolve_dest(in_sid, &dest_wid, &dest_rect, &dest_radius);
        dispatch_async(g_focus_ring_dispatch_queue, ^{
            focus_ring_log("space_switch", "native out=%llu in=%llu dest_wid=%u",
                           (unsigned long long)out_sid, (unsigned long long)in_sid, dest_wid);
            scripting_addition_focus_ring_space_switch(out_sid, in_sid, 0, easing,
                                                       dest_wid, dest_rect, dest_radius);
            g_focus_ring.last_target_wid = 0;
            g_focus_ring.last_send_ns    = 0;
        });
        return;
    }

    // ANIMATED: no land-time fade. The SPA-21 exit-ride keeps the incoming ring
    // riding in lit (born-lit park + geo-rider) while the outgoing ring rides
    // off with its space, so a deferred reveal has nothing to fade in — and
    // running one would snap the already-lit ring to alpha 0 first (a land
    // blink). The transition gate owns the land: space_transition_finish
    // re-shows the settled focus via the settle path, which also re-parks a
    // ride-in whose rect went stale while the space was inactive. fade_duration
    // still drives the focus-change crossfade; it just doesn't play on space
    // switches.
    //
    // Bump the epoch ONCE for this switch intent so pre-switch show/hide intents
    // die, and reset local tracking (epoch-guarded) so the settled re-show isn't
    // swallowed by the idempotent-rect guard. The outgoing ring needs no hide
    // here: the slide seed adopted it as an exit rider and the payload parks it
    // dark at settle.
    uint64_t my_epoch = focus_ring_bump_epoch();
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        if (!focus_ring_epoch_current(my_epoch)) {
            focus_ring_log("epoch_superseded", "src=space_switch_hide e=%llu",
                           (unsigned long long)my_epoch);
            return;
        }
        focus_ring_log("exit_ride", "prev_wid=%u out_sid=%llu",
                       g_focus_ring.last_target_wid, (unsigned long long)out_sid);
        g_focus_ring.last_target_wid    = 0;
        g_focus_ring.last_target_radius = 0.0f;
        g_focus_ring.last_send_ns       = 0;
    });
}

void focus_ring_show_for_display(uint32_t did)
{
    if (!g_focus_ring.enabled) return;
    // FR-20: desktop ring is a sub-toggle under the master enable.
    if (!g_focus_ring.desktop_enabled) {
        focus_ring_log("show_skip", "did=%u reason=desktop_disabled", did);
        return;
    }
    if (did == 0) return;
    if (__atomic_load_n(&g_focus_ring_drag_suppressed, __ATOMIC_RELAXED)) {
        focus_ring_log("show_skip", "did=%u reason=drag_suppressed", did);
        return;
    }
    // FR-4: same space-transition choke point as focus_ring_show_for_wid,
    // display-scoped (`did` is already this display). Suppress while a slide is
    // in flight; END re-resolves.
    extern bool space_transition_active(void);
    extern bool space_transition_on_display(uint32_t did);
    if (space_transition_active() && space_transition_on_display(did)) {
        focus_ring_log("show_skip", "did=%u reason=space_transition_active", did);
        return;
    }
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    uint64_t my_epoch = focus_ring_bump_epoch();
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        if (!focus_ring_epoch_current(my_epoch)) {
            focus_ring_log("epoch_superseded", "src=show_for_display did=%u e=%llu",
                           did, (unsigned long long)my_epoch);
            return;
        }
        // FR-20: resolve the desktop-ring style overrides — each falls back to
        // the main ring when set to inherit; radius/top_margin are desktop-only.
        float dt_width   = (g_focus_ring.desktop_width   >= 0.0f) ? g_focus_ring.desktop_width   : g_focus_ring.stroke_width;
        float dt_opacity = (g_focus_ring.desktop_opacity >= 0.0f) ? g_focus_ring.desktop_opacity : g_focus_ring.stroke_opacity;
        float dt_radius  = g_focus_ring.desktop_radius;
        float dt_topmrg  = g_focus_ring.desktop_top_margin;
        float dt_alpha   = (g_focus_ring.desktop_alpha   >= 0.0f) ? g_focus_ring.desktop_alpha   : g_focus_ring.window_alpha;
        int   dt_blur    = (g_focus_ring.desktop_blur    >= 0)    ? g_focus_ring.desktop_blur    : g_focus_ring.blur_radius;
        float dt_feather = (g_focus_ring.desktop_feather >= 0.0f) ? g_focus_ring.desktop_feather : g_focus_ring.blur_feather;
        float dt_r = g_focus_ring.stroke_r, dt_g = g_focus_ring.stroke_g, dt_b = g_focus_ring.stroke_b;
        if (g_focus_ring.desktop_color_set) {
            dt_r = ((g_focus_ring.desktop_color >> 16) & 0xff) / 255.0f;
            dt_g = ((g_focus_ring.desktop_color >>  8) & 0xff) / 255.0f;
            dt_b = ( g_focus_ring.desktop_color        & 0xff) / 255.0f;
        }
        float dt_hue = g_focus_ring.blur_hue,        dt_sat = g_focus_ring.blur_saturation,
              dt_bri = g_focus_ring.blur_brightness, dt_con = g_focus_ring.blur_contrast;
        if (g_focus_ring.desktop_hsbc_set) {
            dt_hue = g_focus_ring.desktop_hsbc[0];
            dt_sat = g_focus_ring.desktop_hsbc[1];
            dt_bri = g_focus_ring.desktop_hsbc[2];
            dt_con = g_focus_ring.desktop_hsbc[3];
        }
        int dt_blend = (g_focus_ring.desktop_blend >= 0) ? g_focus_ring.desktop_blend
                                                         : g_focus_ring.blend_mode;
        // Style stays inferred from the (resolved) blur radius — payload ignores
        // the wire field but keep it in lockstep (FR-22/FR-24 convention).
        int dt_style = (dt_blur > 0) ? FOCUS_RING_STYLE_BLUR : FOCUS_RING_STYLE_STROKE;

        // FR-20: the desktop ring frames the FULL display — top at the screen's
        // true edge (y=0, behind the menubar), spanning behind the Dock too. The
        // payload renders the wid==0 ring INSET — the band grows INWARD from the
        // rect (outer edge ON the rect), the inverse of the window ring's outward
        // band — so pass the display bounds straight through: the stroke's outer
        // edge lands flush on the screen boundary and the full configured width
        // sits on-screen.
        CGRect rect = CGDisplayBounds(did);
        // top-margin is an ABSOLUTE inset from the screen's top edge (min-y in CG
        // top-left display coords): 0 = ring top flush with the screen top; set
        // ≈ the menubar height to tuck the ring below the menubar.
        if (dt_topmrg > 0.0f) {
            rect.origin.y    += dt_topmrg;
            rect.size.height -= dt_topmrg;
        }

        // FR-19: coalesce duplicate desktop shows. A single desktop click fans
        // out to multiple focus_ring_show_for_display callers tens of ms apart;
        // the 2nd+ are idempotent re-shows not worth an SA round-trip. Skip when
        // the desktop ring for this display is already the tracked target at the
        // same rect within the coalesce window — scaled to the fade duration so
        // the ~90ms duplicates land inside it (the 64ms VBL constant is too
        // short). focus_ring_hide zeroes last_send_ns, so a re-show after a hide
        // always proceeds. Desktop twin of the idempotent_rect_unchanged guard
        // in focus_ring_show_for_wid_at_rect_sync.
        double coalesce_ms = (g_focus_ring.animate && g_focus_ring.fade_duration > 0.0f)
                           ? (double)g_focus_ring.fade_duration * 1000.0
                           : FOCUS_RING_MAX_COALESCE_MS;
        uint64_t now_ns = focus_ring_now_ns();
        if (g_focus_ring.last_target_wid == 0 &&
            g_focus_ring.last_target_did == did &&
            focus_ring_rect_equal(rect, g_focus_ring.last_target_screen_rect) &&
            g_focus_ring.last_send_ns > 0 &&
            (now_ns - g_focus_ring.last_send_ns) < (uint64_t)(coalesce_ms * 1e6)) {
            focus_ring_log("show_skip", "did=%u reason=idempotent_desktop_dup", did);
            return;
        }

        focus_ring_log("sa_call_desktop",
                       "did=%u rect=(%.0f,%.0f %.0fx%.0f)",
                       did, rect.origin.x, rect.origin.y,
                       rect.size.width, rect.size.height);

        float tint_r, tint_g, tint_b, tint_a, str_r, str_g, str_b, str_a;
        focus_ring_resolve_blur_layers(dt_r, dt_g, dt_b, dt_opacity,
                                       &tint_r, &tint_g, &tint_b, &tint_a, &str_r, &str_g, &str_b, &str_a);

        bool ok = scripting_addition_focus_ring_show(
            0,
            rect.origin.x, rect.origin.y,
            rect.size.width, rect.size.height,
            dt_radius,
            dt_width,
            dt_opacity,
            dt_r,
            dt_g,
            dt_b,
            false,
            dt_blur,
            dt_style,
            dt_sat,
            dt_bri,
            dt_blend,
            g_focus_ring.blur_stroke,
            g_focus_ring.blur_stroke_position,
            g_focus_ring.blur_stroke_width,
            g_focus_ring.blur_bleed,
            tint_r, tint_g, tint_b, tint_a,
            str_r, str_g, str_b, str_a,
            dt_con,
            dt_feather,
            g_focus_ring.animate,
            g_focus_ring.animate_duration,
            g_focus_ring.fade_duration,
            dt_hue,
            // FR-21 xray: no overlap resolve for the desktop ring (wid 0 — the
            // display-sized band would xray against every window on the space).
            false, 0.0f, 0.0f, 0.0f, 0.0f, 0, NULL,
            dt_alpha);

        g_focus_ring.last_target_wid         = 0;
        g_focus_ring.last_target_screen_rect = rect;
        g_focus_ring.last_target_did         = did;
        g_focus_ring.last_target_radius      = dt_radius;
        g_focus_ring.last_send_ns            = focus_ring_now_ns();
        g_focus_ring.last_send_did           = did;

        focus_ring_log("show_desktop",
                       "did=%u rect=(%.0f,%.0f %.0fx%.0f) sa_ok=%d",
                       did, rect.origin.x, rect.origin.y,
                       rect.size.width, rect.size.height, ok ? 1 : 0);
    });
}

// Re-paint the currently focused target with the style values in g_focus_ring.
// Called from the config setters and the accent observer so the user sees the
// change immediately rather than on the next focus event. No-op when disabled
// or when no target is tracked. force_style propagates to the payload (clear
// debug latch) and bypasses the VBL throttle so a config change is never
// dropped. Style rides the SHOW packed-req fields: one dispatch_async, one SA
// round-trip.
static void focus_ring_reissue_show_for_last_target(const char *trigger, bool force_style)
{
    if (!g_focus_ring.enabled) return;
    if (g_focus_ring.last_target_wid == 0) return;
    switch (focus_ring_target_eligibility(g_focus_ring.last_target_wid, true)) {
    case FOCUS_RING_TARGET_THUMBNAIL:
        focus_ring_log("restyle_skip", "wid=%u trigger=%s reason=stage_thumbnail",
                       g_focus_ring.last_target_wid, trigger);
        return;
    case FOCUS_RING_TARGET_MINIMIZED:
        focus_ring_log("restyle_skip", "wid=%u trigger=%s reason=minimized",
                       g_focus_ring.last_target_wid, trigger);
        return;
    case FOCUS_RING_TARGET_ANIMATING:
        focus_ring_log("restyle_skip", "wid=%u trigger=%s reason=display_animating",
                       g_focus_ring.last_target_wid, trigger);
        return;
    case FOCUS_RING_TARGET_OK:
        break;
    }

    uint32_t wid = g_focus_ring.last_target_wid;
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        CGRect target_rect;
        if (SLSGetScreenRectForWindow(g_connection, wid, &target_rect) != kCGErrorSuccess) {
            focus_ring_log("restyle_skip", "wid=%u trigger=%s reason=no_screen_rect",
                           wid, trigger);
            return;
        }
        focus_ring_log("restyle", "wid=%u trigger=%s force=%d", wid, trigger, force_style);
        focus_ring_show_for_wid_at_rect_sync(wid, target_rect, force_style);
    });
}
