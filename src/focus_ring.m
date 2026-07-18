#include "focus_ring.h"
#include "misc/extern.h"
#include "misc/helpers.h"
#include "display_manager.h"
#include "display.h"
#include "sa.h"
#include "window_iterator.h"
#include "window_manager.h"

#include <Cocoa/Cocoa.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include <stdarg.h>
#include <time.h>
#include <math.h>

extern int g_connection;
extern struct window_manager g_window_manager;

// NOTE: intent epoch — bump on the caller thread BEFORE any dispatch, capture
// by value in the block, no-op if superseded. Sole supersession authority for
// show/hide/space-switch races.
static uint64_t g_focus_ring_epoch = 0;

static inline uint64_t focus_ring_bump_epoch(void)
{
    return __atomic_add_fetch(&g_focus_ring_epoch, 1, __ATOMIC_RELAXED);
}

static inline bool focus_ring_epoch_current(uint64_t e)
{
    return e == __atomic_load_n(&g_focus_ring_epoch, __ATOMIC_RELAXED);
}

static bool g_focus_ring_drag_suppressed = false;

// NOTE: while an OS-driven (float) drag is live, shows skip the coalesce defer
// so the ring tracks at VBL rate; the per-display throttle still caps sends.
static bool g_focus_ring_drag_follow = false;

static uint64_t g_focus_ring_deferred_until_ns = 0;
static uint64_t focus_ring_now_ns(void);

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

// NOTE: serial — drain order on this queue is the show/hide ordering authority
// (focus_ring_hide_for_wid depends on it); SLS RPCs must stay off the AX runloop.
static dispatch_queue_t g_focus_ring_dispatch_queue = NULL;
static pthread_once_t g_focus_ring_dispatch_once = PTHREAD_ONCE_INIT;
static void focus_ring_dispatch_init(void) {
    g_focus_ring_dispatch_queue = dispatch_queue_create(
        "com.koekeishiya.yabai.focus_ring.daemon",
        DISPATCH_QUEUE_SERIAL);
}

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

static struct {
    bool     enabled;
    float    band_width;
    float    color_opacity;
    float    window_alpha;
    float    color_r, color_g, color_b;
    int      color_mode;
    int      blur_radius;
    int      modal_mode;
    uint32_t modal_parent_wid;
    uint32_t modal_child_wid;
    uint32_t modal_skip_wid;
    float    saturation;
    float    brightness;
    float    contrast;
    float    hue;
    int      blend_mode;
    bool     inner_stroke;
    int      inner_stroke_position;
    float    inner_stroke_width;
    float    bleed;
    float    inner_stroke_opacity;
    uint32_t inner_stroke_color;
    bool     inner_stroke_color_is_set;
    float    feather;
    float    fade_duration;
    int      fade_easing;
    float    fade_delay;
    float    coalesce_ms;
    bool     desktop_enabled;
    float    desktop_width;
    float    desktop_radius;
    float    desktop_opacity;
    float    desktop_top_margin;
    float    desktop_alpha;
    uint32_t desktop_color;
    bool     desktop_color_set;
    int      desktop_blur;
    float    desktop_hsbc[4];
    bool     desktop_hsbc_set;
    float    desktop_feather;
    int      desktop_blend;
    bool     xray;
    float    xray_r, xray_g, xray_b, xray_a;
    uint32_t last_target_wid;
    CGRect   last_target_screen_rect;
    uint32_t last_target_did;
    float    last_target_radius;

    uint64_t last_send_ns;
    uint32_t last_send_did;
} g_focus_ring = {
    .enabled        = FOCUS_RING_DEFAULT_ENABLED,
    .band_width     = FOCUS_RING_DEFAULT_WIDTH,
    .color_opacity  = FOCUS_RING_DEFAULT_COLOR_OPACITY,
    .window_alpha   = FOCUS_RING_DEFAULT_ALPHA,
    .color_r        = FOCUS_RING_DEFAULT_R,
    .color_g        = FOCUS_RING_DEFAULT_G,
    .color_b        = FOCUS_RING_DEFAULT_B,
    .color_mode     = FOCUS_RING_COLOR_FIXED,
    .blur_radius    = FOCUS_RING_DEFAULT_BLUR,
    .modal_mode     = FOCUS_RING_DEFAULT_MODAL,
    .saturation     = FOCUS_RING_DEFAULT_SATURATION,
    .brightness     = FOCUS_RING_DEFAULT_BRIGHTNESS,
    .contrast       = FOCUS_RING_DEFAULT_CONTRAST,
    .hue            = FOCUS_RING_DEFAULT_HUE,
    .blend_mode     = FOCUS_RING_DEFAULT_BLEND_MODE,
    .inner_stroke          = FOCUS_RING_DEFAULT_INNER_STROKE,
    .inner_stroke_position = FOCUS_RING_DEFAULT_INNER_STROKE_POSITION,
    .inner_stroke_width    = FOCUS_RING_DEFAULT_INNER_STROKE_WIDTH,
    .bleed          = FOCUS_RING_DEFAULT_BLEED,
    .inner_stroke_opacity = FOCUS_RING_DEFAULT_INNER_STROKE_OPACITY,
    .feather        = FOCUS_RING_DEFAULT_FEATHER,
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
    .xray                = FOCUS_RING_DEFAULT_XRAY,
    .xray_r              = FOCUS_RING_XRAY_DEFAULT_R,
    .xray_g              = FOCUS_RING_XRAY_DEFAULT_G,
    .xray_b              = FOCUS_RING_XRAY_DEFAULT_B,
    .xray_a              = FOCUS_RING_XRAY_DEFAULT_A,
};

bool focus_ring_deferred_fade_pending(void) {
    return focus_ring_now_ns() < __atomic_load_n(&g_focus_ring_deferred_until_ns, __ATOMIC_RELAXED);
}

bool focus_ring_get_enabled(void)             { return g_focus_ring.enabled; }
void focus_ring_set_enabled(bool enabled)
{
    g_focus_ring.enabled = enabled;
    scripting_addition_focus_ring_set_visible(enabled);
    focus_ring_log("set_enabled", "enabled=%d", enabled ? 1 : 0);
}
uint32_t focus_ring_get_target_wid(void)      { return g_focus_ring.last_target_wid; }

float focus_ring_get_width(void)   { return g_focus_ring.band_width; }
float focus_ring_get_color_opacity(void) { return g_focus_ring.color_opacity; }

static void focus_ring_reissue_show_for_last_target(const char *trigger, bool force_style);

void focus_ring_set_width(float width)
{
    if (width < FOCUS_RING_MIN_WIDTH) width = FOCUS_RING_MIN_WIDTH;
    if (width > FOCUS_RING_MAX_WIDTH) width = FOCUS_RING_MAX_WIDTH;
    g_focus_ring.band_width = width;
    focus_ring_log("set_width", "width=%.2f", width);
    focus_ring_reissue_show_for_last_target("set_width", true);
}

void focus_ring_set_color_opacity(float opacity)
{
    if (opacity < 0.0f) opacity = 0.0f;
    if (opacity > 1.0f) opacity = 1.0f;
    g_focus_ring.color_opacity = opacity;
    focus_ring_log("set_color_opacity", "opacity=%.2f", opacity);
    focus_ring_reissue_show_for_last_target("set_color_opacity", true);
}

float focus_ring_get_alpha(void) { return g_focus_ring.window_alpha; }

void focus_ring_set_alpha(float alpha)
{
    if (alpha < 0.0f) alpha = 0.0f;
    if (alpha > 1.0f) alpha = 1.0f;
    g_focus_ring.window_alpha = alpha;
    focus_ring_log("set_alpha", "alpha=%.2f", alpha);
    focus_ring_reissue_show_for_last_target("set_alpha", true);
}

int focus_ring_get_blur_radius(void) { return g_focus_ring.blur_radius; }

void focus_ring_set_blur_radius(int radius)
{
    if (radius < 0)                   radius = 0;
    if (radius > FOCUS_RING_MAX_BLUR) radius = FOCUS_RING_MAX_BLUR;
    g_focus_ring.blur_radius = radius;
    focus_ring_log("set_blur_radius", "radius=%d", radius);
    focus_ring_reissue_show_for_last_target("set_blur_radius", true);
}

float focus_ring_get_saturation(void) { return g_focus_ring.saturation; }

void focus_ring_set_saturation(float saturation)
{
    if (saturation < FOCUS_RING_MIN_SATURATION) saturation = FOCUS_RING_MIN_SATURATION;
    if (saturation > FOCUS_RING_MAX_SATURATION) saturation = FOCUS_RING_MAX_SATURATION;
    g_focus_ring.saturation = saturation;
    focus_ring_log("set_saturation", "saturation=%.2f", saturation);
    focus_ring_reissue_show_for_last_target("set_saturation", true);
}

float focus_ring_get_brightness(void) { return g_focus_ring.brightness; }

void focus_ring_set_brightness(float brightness)
{
    if (brightness < FOCUS_RING_MIN_BRIGHTNESS) brightness = FOCUS_RING_MIN_BRIGHTNESS;
    if (brightness > FOCUS_RING_MAX_BRIGHTNESS) brightness = FOCUS_RING_MAX_BRIGHTNESS;
    g_focus_ring.brightness = brightness;
    focus_ring_log("set_brightness", "brightness=%.2f", brightness);
    focus_ring_reissue_show_for_last_target("set_brightness", true);
}

float focus_ring_get_contrast(void) { return g_focus_ring.contrast; }

void focus_ring_set_contrast(float contrast)
{
    if (contrast < FOCUS_RING_MIN_CONTRAST) contrast = FOCUS_RING_MIN_CONTRAST;
    if (contrast > FOCUS_RING_MAX_CONTRAST) contrast = FOCUS_RING_MAX_CONTRAST;
    g_focus_ring.contrast = contrast;
    focus_ring_log("set_contrast", "contrast=%.2f", contrast);
    focus_ring_reissue_show_for_last_target("set_contrast", true);
}

float focus_ring_get_hue(void) { return g_focus_ring.hue; }

void focus_ring_set_hue(float hue)
{
    if (hue < FOCUS_RING_MIN_HUE) hue = FOCUS_RING_MIN_HUE;
    if (hue > FOCUS_RING_MAX_HUE) hue = FOCUS_RING_MAX_HUE;
    g_focus_ring.hue = hue;
    focus_ring_log("set_hue", "hue=%.2f", hue);
    focus_ring_reissue_show_for_last_target("set_hue", true);
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

bool focus_ring_get_inner_stroke(void) { return g_focus_ring.inner_stroke; }

void focus_ring_set_inner_stroke(bool enabled)
{
    g_focus_ring.inner_stroke = enabled;
    focus_ring_log("set_inner_stroke", "enabled=%d", enabled ? 1 : 0);
    focus_ring_reissue_show_for_last_target("set_inner_stroke", true);
}

int focus_ring_get_inner_stroke_position(void) { return g_focus_ring.inner_stroke_position; }

void focus_ring_set_inner_stroke_position(int position)
{
    if (position != FOCUS_RING_INNER_STROKE_ABOVE && position != FOCUS_RING_INNER_STROKE_BELOW) {
        position = FOCUS_RING_INNER_STROKE_ABOVE;
    }
    g_focus_ring.inner_stroke_position = position;
    focus_ring_log("set_inner_stroke_position", "position=%d", position);
    focus_ring_reissue_show_for_last_target("set_inner_stroke_position", true);
}

float focus_ring_get_inner_stroke_width(void) { return g_focus_ring.inner_stroke_width; }

void focus_ring_set_inner_stroke_width(float width)
{
    if (width < FOCUS_RING_MIN_INNER_STROKE_WIDTH) width = FOCUS_RING_MIN_INNER_STROKE_WIDTH;
    if (width > FOCUS_RING_MAX_INNER_STROKE_WIDTH) width = FOCUS_RING_MAX_INNER_STROKE_WIDTH;
    g_focus_ring.inner_stroke_width = width;
    focus_ring_log("set_inner_stroke_width", "width=%.2f", width);
    focus_ring_reissue_show_for_last_target("set_inner_stroke_width", true);
}

float focus_ring_get_bleed(void) { return g_focus_ring.bleed; }

void focus_ring_set_bleed(float bleed)
{
    if (bleed < FOCUS_RING_MIN_BLEED) bleed = FOCUS_RING_MIN_BLEED;
    if (bleed > FOCUS_RING_MAX_BLEED) bleed = FOCUS_RING_MAX_BLEED;
    g_focus_ring.bleed = bleed;
    focus_ring_log("set_bleed", "bleed=%.2f", bleed);
    focus_ring_reissue_show_for_last_target("set_bleed", true);
}

float focus_ring_get_inner_stroke_opacity(void) { return g_focus_ring.inner_stroke_opacity; }

void focus_ring_set_inner_stroke_opacity(float opacity)
{
    if (opacity != FOCUS_RING_OPACITY_INHERIT) {
        if (opacity < 0.0f) opacity = 0.0f;
        if (opacity > 1.0f) opacity = 1.0f;
    }
    g_focus_ring.inner_stroke_opacity = opacity;
    focus_ring_log("set_inner_stroke_opacity", "opacity=%.2f", opacity);
    focus_ring_reissue_show_for_last_target("set_inner_stroke_opacity", true);
}

uint32_t focus_ring_get_inner_stroke_color(void) { return 0xff000000 | (g_focus_ring.inner_stroke_color & 0x00ffffff); }
bool     focus_ring_get_inner_stroke_color_is_set(void) { return g_focus_ring.inner_stroke_color_is_set; }

void focus_ring_set_inner_stroke_color(uint32_t argb)
{
    g_focus_ring.inner_stroke_color = argb & 0x00ffffff;
    g_focus_ring.inner_stroke_color_is_set = true;
    focus_ring_log("set_inner_stroke_color", "rgb=0x%06x", g_focus_ring.inner_stroke_color);
    focus_ring_reissue_show_for_last_target("set_inner_stroke_color", true);
}

void focus_ring_set_inner_stroke_color_inherit(void)
{
    g_focus_ring.inner_stroke_color_is_set = false;
    focus_ring_log("set_inner_stroke_color", "inherit");
    focus_ring_reissue_show_for_last_target("set_inner_stroke_color_inherit", true);
}

float focus_ring_get_feather(void) { return g_focus_ring.feather; }

void focus_ring_set_feather(float feather)
{
    if (feather < FOCUS_RING_MIN_FEATHER) feather = FOCUS_RING_MIN_FEATHER;
    if (feather > FOCUS_RING_MAX_FEATHER) feather = FOCUS_RING_MAX_FEATHER;
    g_focus_ring.feather = feather;
    focus_ring_log("set_feather", "feather=%.2f", feather);
    focus_ring_reissue_show_for_last_target("set_feather", true);
}

// NOTE: resolve inherit sentinels to final RGBA here — the payload applies
// wire values verbatim (no inherit logic payload-side).
static void focus_ring_resolve_layers(float base_r, float base_g, float base_b, float base_a,
                                           float *tint_r, float *tint_g, float *tint_b, float *tint_a,
                                           float *str_r,  float *str_g,  float *str_b,  float *str_a)
{
    *tint_r = base_r; *tint_g = base_g; *tint_b = base_b;
    *tint_a = base_a;

    if (g_focus_ring.inner_stroke_color_is_set) {
        *str_r = ((g_focus_ring.inner_stroke_color >> 16) & 0xff) / 255.0f;
        *str_g = ((g_focus_ring.inner_stroke_color >>  8) & 0xff) / 255.0f;
        *str_b = ( g_focus_ring.inner_stroke_color        & 0xff) / 255.0f;
    } else {
        *str_r = base_r; *str_g = base_g; *str_b = base_b;
    }
    *str_a = (g_focus_ring.inner_stroke_opacity >= 0.0f) ? g_focus_ring.inner_stroke_opacity : base_a;
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
static id g_focus_ring_accent_observer = nil;

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

static void focus_ring_refresh_accent(const char *trigger)
{
    float r = g_focus_ring.color_r, g = g_focus_ring.color_g, b = g_focus_ring.color_b;
    if (focus_ring_resolve_accent_rgb(&r, &g, &b)) {
        g_focus_ring.color_r = r;
        g_focus_ring.color_g = g;
        g_focus_ring.color_b = b;
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
    uint8_t r = (uint8_t)lround(g_focus_ring.color_r * 255.0f);
    uint8_t g = (uint8_t)lround(g_focus_ring.color_g * 255.0f);
    uint8_t b = (uint8_t)lround(g_focus_ring.color_b * 255.0f);
    return (0xFFu << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
}

bool focus_ring_get_color_is_auto(void)
{
    return g_focus_ring.color_mode == FOCUS_RING_COLOR_AUTO;
}

// NOTE: approximate accent hexes (not resolved via controlAccentColor); alpha forced 0xFF.
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
    focus_ring_accent_observer_remove();
    g_focus_ring.color_r = ((argb >> 16) & 0xFF) / 255.0f;
    g_focus_ring.color_g = ((argb >>  8) & 0xFF) / 255.0f;
    g_focus_ring.color_b = ((argb >>  0) & 0xFF) / 255.0f;
    focus_ring_log("set_color", "argb=0x%08x rgb=(%.2f,%.2f,%.2f)",
                   argb, g_focus_ring.color_r, g_focus_ring.color_g, g_focus_ring.color_b);
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

bool focus_ring_show_for_wid_at_rect_sync(uint32_t target_wid, CGRect target_rect, bool force_style);

// NOTE: ships full frames, not intersections — the payload clips per frame so
// the overlap keeps tracking an animated target. Pure SLS on g_connection (no
// g_window_manager / ts_alloc): safe on the focus_ring queue — the level/tag
// filters mirror space_window_list for that reason.
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

static inline bool focus_ring_rect_equal(CGRect a, CGRect b)
{
    const CGFloat e = 0.5f;
    CGFloat dx = a.origin.x    - b.origin.x;    if (dx < 0) dx = -dx;
    CGFloat dy = a.origin.y    - b.origin.y;    if (dy < 0) dy = -dy;
    CGFloat dw = a.size.width  - b.size.width;  if (dw < 0) dw = -dw;
    CGFloat dh = a.size.height - b.size.height; if (dh < 0) dh = -dh;
    return dx < e && dy < e && dw < e && dh < e;
}

// NOTE: runs only on g_focus_ring_dispatch_queue; force_style bypasses the
// VBL throttle and idempotent guard (config changes must always land).
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

    // NOTE: duplicate focus events re-fire SHOW with unchanged geometry outside
    // the VBL window; re-sending is a visible redraw. Safe: moves change the rect,
    // style changes force, and hide zeroes last_target_wid.
    if (!force_style &&
        target_wid == g_focus_ring.last_target_wid &&
        target_did == g_focus_ring.last_target_did &&
        focus_ring_rect_equal(target_rect, g_focus_ring.last_target_screen_rect)) {
        focus_ring_log("show_skip", "wid=%u reason=idempotent_rect_unchanged", target_wid);
        return true;
    }

    float radius;
    if (target_wid == g_focus_ring.last_target_wid && g_focus_ring.last_target_radius > 0.0f) {
        radius = g_focus_ring.last_target_radius;
    } else {
        radius = 0.0f;
        get_corner_radius_for_window(target_wid, &radius);
    }

    // NOTE: per-display refresh-interval throttle for same-wid bursts (drag);
    // wid/display changes and force_style bypass it.
    struct display_timing *dt = display_timing_get(target_did);
    uint64_t now_ns = focus_ring_now_ns();
    if (!force_style &&
        dt && dt->valid &&
        target_wid == g_focus_ring.last_target_wid &&
        target_did == g_focus_ring.last_send_did &&
        target_did == g_focus_ring.last_target_did &&
        g_focus_ring.last_send_ns > 0 &&
        now_ns - g_focus_ring.last_send_ns < dt->refresh_interval_ns) {
        focus_ring_log("throttled",
                       "wid=%u did=%u dt_ns=%llu interval_ns=%llu",
                       target_wid, target_did,
                       (unsigned long long)(now_ns - g_focus_ring.last_send_ns),
                       (unsigned long long)dt->refresh_interval_ns);
        g_focus_ring.last_target_wid         = target_wid;
        g_focus_ring.last_target_screen_rect = target_rect;
        g_focus_ring.last_target_did         = target_did;
        g_focus_ring.last_target_radius      = radius;
        return true;
    }

    focus_ring_log("sa_call", "wid=%u did=%u", target_wid, target_did);

    float tint_r, tint_g, tint_b, tint_a, str_r, str_g, str_b, str_a;
    focus_ring_resolve_layers(g_focus_ring.color_r, g_focus_ring.color_g,
                                   g_focus_ring.color_b, g_focus_ring.color_opacity,
                                   &tint_r, &tint_g, &tint_b, &tint_a, &str_r, &str_g, &str_b, &str_a);

    CGRect xray_rects[SA_FOCUS_RING_XRAY_MAX_RECTS];
    int    xray_count = 0;
    bool   xray_renders = (g_focus_ring.blur_radius == 0) || g_focus_ring.inner_stroke;
    if (g_focus_ring.xray && xray_renders) {
        CGRect band = CGRectInset(target_rect, -g_focus_ring.band_width, -g_focus_ring.band_width);
        xray_count = focus_ring_xray_overlap_rects(target_wid, band,
                                                   xray_rects, SA_FOCUS_RING_XRAY_MAX_RECTS);
    }

    bool ok = scripting_addition_focus_ring_show(target_wid,
                                                  target_rect.origin.x,
                                                  target_rect.origin.y,
                                                  target_rect.size.width,
                                                  target_rect.size.height,
                                                  radius,
                                                  g_focus_ring.band_width,
                                                  g_focus_ring.color_opacity,
                                                  g_focus_ring.color_r,
                                                  g_focus_ring.color_g,
                                                  g_focus_ring.color_b,
                                                  force_style,
                                                  g_focus_ring.blur_radius,
                                                  (g_focus_ring.blur_radius > 0) ? FOCUS_RING_STYLE_BLUR
                                                                                 : FOCUS_RING_STYLE_STROKE,
                                                  g_focus_ring.saturation,
                                                  g_focus_ring.brightness,
                                                  g_focus_ring.blend_mode,
                                                  g_focus_ring.inner_stroke,
                                                  g_focus_ring.inner_stroke_position,
                                                  g_focus_ring.inner_stroke_width,
                                                  g_focus_ring.bleed,
                                                  tint_r, tint_g, tint_b, tint_a,
                                                  str_r, str_g, str_b, str_a,
                                                  g_focus_ring.contrast,
                                                  g_focus_ring.feather,
                                                  g_focus_ring.fade_duration,
                                                  g_focus_ring.hue,
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
        if (cand == g_focus_ring.modal_skip_wid) continue;

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

// NOTE: SLS attachment cannot separate a real modal from a helper panel
// (Chrome's find bar carries a sheet's exact tags). Only the AX role walk of
// the parent's kAXChildren identifies an AXSheet/AXDrawer. SLS + AX only — safe off-main.
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
                if (cand == 0 || cand == g_focus_ring.modal_skip_wid) continue;

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

// NOTE: cache the resolved child — the sheet rides the parent's drag without
// emitting its own moves, so every parent WINDOW_MOVED re-resolves here; a
// fresh AX walk per move would stall the queue. modal_skip_wid: one-shot
// exclusion of a closing child.
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
    g_focus_ring.modal_skip_wid = 0;

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

// NOTE: classify only — the action (skip vs defer-to-settle) is per call site.
// Must run on the event thread (window_manager_find_window is unsafe on the
// focus_ring queue). check_animating costs an SLS round-trip; the explicit-
// rect path passes false because it paints mid-transform by design.
// (Stage thumbnails are not classified in this build.)
enum focus_ring_target_state {
    FOCUS_RING_TARGET_OK = 0,
    FOCUS_RING_TARGET_THUMBNAIL,
    FOCUS_RING_TARGET_MINIMIZED,
    FOCUS_RING_TARGET_ANIMATING,
};

static enum focus_ring_target_state focus_ring_target_eligibility(uint32_t wid, bool check_animating)
{
    if (wid == 0) return FOCUS_RING_TARGET_OK;
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

// NOTE: defer_when_animating=false is the settle resume — it must paint even
// if the display still reports animating (re-entering the defer re-arms the poll).
static bool focus_ring_show_for_wid_impl(uint32_t target_wid, bool defer_when_animating)
{
    if (!g_focus_ring.enabled) return false;

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
    // NOTE: never paint during a space slide — it resolves the mid-slide rect; the
    // transition end owns the settled re-show. Keep this gate ahead of the
    // animating-defer below (a slide also reports "animating"). Display-scoped.
    extern bool space_transition_active(void);
    extern bool space_transition_on_display(uint32_t did);
    if (space_transition_active() && space_transition_on_display(window_display_id(target_wid))) {
        focus_ring_log("show_skip", "wid=%u reason=space_transition_active", target_wid);
        return false;
    }
    if (state == FOCUS_RING_TARGET_ANIMATING) {
        extern uint32_t focus_ring_settle_arm_public(uint32_t did, uint32_t resume_wid);
        uint32_t did = window_display_id(target_wid);
        focus_ring_log("show_defer", "wid=%u reason=display_animating did=%u", target_wid, did);
        focus_ring_settle_arm_public(did, target_wid);
        return false;
    }
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    uint64_t my_epoch = focus_ring_bump_epoch();
    // NOTE: resolve the rect inside the deferred block — it must read post-coalesce geometry.
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

bool focus_ring_show_for_wid(uint32_t target_wid)
{
    return focus_ring_show_for_wid_impl(target_wid, true);
}

bool focus_ring_show_for_wid_settled(uint32_t target_wid)
{
    return focus_ring_show_for_wid_impl(target_wid, false);
}

// NOTE: no modal re-resolve — the node rect belongs to THIS managed window;
// retargeting would frame the unmanaged child instead.
bool focus_ring_show_for_wid_rect(uint32_t target_wid, CGRect rect)
{
    if (!g_focus_ring.enabled) return false;
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

void focus_ring_mc_ride_async(uint32_t wid)
{
    if (!wid) return;
    pthread_once(&g_focus_ring_dispatch_once, focus_ring_dispatch_init);
    dispatch_async(g_focus_ring_dispatch_queue, ^{
        scripting_addition_focus_ring_mc_ride(wid);
    });
}

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

// NOTE: the target check must run on the queue at drain time — show/hide order
// is only authoritative there; a pre-dispatch check reads stale state.
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

void focus_ring_reposition_for_wid(uint32_t wid)
{
    if (!g_focus_ring.enabled) return;
    if (wid == 0) return;
    if (wid != g_focus_ring.last_target_wid) return;
    focus_ring_show_for_wid(wid);
}

// NOTE: event-thread only (ts_alloc). SLSGetWindowBounds (natural bounds), not
// the rendered rect — transform-independent, and hugs constrained windows.
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
            dest_wid = 0;
        }
    }
    if (out_wid)    *out_wid    = dest_wid;
    if (out_rect)   *out_rect   = dest_rect;
    if (out_radius) *out_radius = dest_radius;
    return dest_wid != 0;
}

// NOTE: owns only the ALPHA reveal — the geometric ride is seeded on the
// space-animate wire. last_target_wid is zeroed so the settled re-show passes
// the idempotent-rect guard.
void focus_ring_space_switch(uint64_t out_sid, uint64_t in_sid, bool animated)
{
    if (!g_focus_ring.enabled) return;

    extern bool space_nav_observer_get_enabled(void);

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

    // NOTE: no land-time fade — the incoming ring rides in lit; a deferred reveal
    // would first snap it dark. No hide for the outgoing ring either: the slide
    // seed adopts it as an exit rider and parks it at settle.
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
    if (!g_focus_ring.desktop_enabled) {
        focus_ring_log("show_skip", "did=%u reason=desktop_disabled", did);
        return;
    }
    if (did == 0) return;
    if (__atomic_load_n(&g_focus_ring_drag_suppressed, __ATOMIC_RELAXED)) {
        focus_ring_log("show_skip", "did=%u reason=drag_suppressed", did);
        return;
    }
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
        float dt_width   = (g_focus_ring.desktop_width   >= 0.0f) ? g_focus_ring.desktop_width   : g_focus_ring.band_width;
        float dt_opacity = (g_focus_ring.desktop_opacity >= 0.0f) ? g_focus_ring.desktop_opacity : g_focus_ring.color_opacity;
        float dt_radius  = g_focus_ring.desktop_radius;
        float dt_topmrg  = g_focus_ring.desktop_top_margin;
        float dt_alpha   = (g_focus_ring.desktop_alpha   >= 0.0f) ? g_focus_ring.desktop_alpha   : g_focus_ring.window_alpha;
        int   dt_blur    = (g_focus_ring.desktop_blur    >= 0)    ? g_focus_ring.desktop_blur    : g_focus_ring.blur_radius;
        float dt_feather = (g_focus_ring.desktop_feather >= 0.0f) ? g_focus_ring.desktop_feather : g_focus_ring.feather;
        float dt_r = g_focus_ring.color_r, dt_g = g_focus_ring.color_g, dt_b = g_focus_ring.color_b;
        if (g_focus_ring.desktop_color_set) {
            dt_r = ((g_focus_ring.desktop_color >> 16) & 0xff) / 255.0f;
            dt_g = ((g_focus_ring.desktop_color >>  8) & 0xff) / 255.0f;
            dt_b = ( g_focus_ring.desktop_color        & 0xff) / 255.0f;
        }
        float dt_hue = g_focus_ring.hue,        dt_sat = g_focus_ring.saturation,
              dt_bri = g_focus_ring.brightness, dt_con = g_focus_ring.contrast;
        if (g_focus_ring.desktop_hsbc_set) {
            dt_hue = g_focus_ring.desktop_hsbc[0];
            dt_sat = g_focus_ring.desktop_hsbc[1];
            dt_bri = g_focus_ring.desktop_hsbc[2];
            dt_con = g_focus_ring.desktop_hsbc[3];
        }
        int dt_blend = (g_focus_ring.desktop_blend >= 0) ? g_focus_ring.desktop_blend
                                                         : g_focus_ring.blend_mode;
        int dt_style = (dt_blur > 0) ? FOCUS_RING_STYLE_BLUR : FOCUS_RING_STYLE_STROKE;

        CGRect rect = CGDisplayBounds(did);
        if (dt_topmrg > 0.0f) {
            rect.origin.y    += dt_topmrg;
            rect.size.height -= dt_topmrg;
        }

        // NOTE: one desktop click fans out to several show_for_display calls tens of
        // ms apart; window the dup-guard on fade_duration (a VBL interval is too
        // short). hide zeroes last_send_ns, so a re-show after hide always sends.
        double coalesce_ms = (g_focus_ring.fade_duration > 0.0f)
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
        focus_ring_resolve_layers(dt_r, dt_g, dt_b, dt_opacity,
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
            g_focus_ring.inner_stroke,
            g_focus_ring.inner_stroke_position,
            g_focus_ring.inner_stroke_width,
            g_focus_ring.bleed,
            tint_r, tint_g, tint_b, tint_a,
            str_r, str_g, str_b, str_a,
            dt_con,
            dt_feather,
            g_focus_ring.fade_duration,
            dt_hue,
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

// NOTE: repaint the tracked target so config changes land immediately;
// force_style also clears the payload's debug color latch.
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
