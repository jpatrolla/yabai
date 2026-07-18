#ifndef FOCUS_RING_H
#define FOCUS_RING_H

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <CoreGraphics/CGGeometry.h>

#define FOCUS_RING_DEFAULT_ENABLED  true
#define FOCUS_RING_DEFAULT_WIDTH    10.0f
// 0 = pure frost (color knobs inert), 1 = solid color band.
#define FOCUS_RING_DEFAULT_COLOR_OPACITY  1.0f
// NOTE: `alpha` rides the window's NORMAL alpha slot; show/hide fades ride the
// SYSTEM slot — the compositor multiplies the two, so they compose.
#define FOCUS_RING_DEFAULT_ALPHA    0.60f

// NOTE: desktop-ring overrides: -1 = inherit the main ring (color/hsbc use
// _set flags — 0 is a valid value). radius rounds the band's INNER edge (the
// ring renders inset, outer edge flush with the display); top_margin is an
// ABSOLUTE top inset (≈ menubar height to tuck below it).
#define FOCUS_RING_DESKTOP_DEFAULT_ENABLED    true
#define FOCUS_RING_DESKTOP_INHERIT            (-1.0f)
#define FOCUS_RING_DESKTOP_DEFAULT_WIDTH      FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_OPACITY    FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_RADIUS    16.0f
#define FOCUS_RING_DESKTOP_DEFAULT_TOP_MARGIN 0.0f
#define FOCUS_RING_DESKTOP_DEFAULT_ALPHA      FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_BLUR       (-1)
#define FOCUS_RING_DESKTOP_DEFAULT_FEATHER    FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_BLEND      (-1)

// NOTE: keep matching the payload's g_focus_ring_stroke_* initializers.
#define FOCUS_RING_DEFAULT_R        1.00f
#define FOCUS_RING_DEFAULT_G        1.00f
#define FOCUS_RING_DEFAULT_B        1.00f

// xray: recolor band segments overlapping other windows' frames. The overlap
// set refreshes only on a SHOW (a foreign window moving does not retrigger).
#define FOCUS_RING_DEFAULT_XRAY      false
#define FOCUS_RING_XRAY_DEFAULT_R    0.25f
#define FOCUS_RING_XRAY_DEFAULT_G    0.78f
#define FOCUS_RING_XRAY_DEFAULT_B    1.00f
#define FOCUS_RING_XRAY_DEFAULT_A    1.00f

enum focus_ring_color_mode {
    FOCUS_RING_COLOR_FIXED = 0,
    FOCUS_RING_COLOR_AUTO  = 1,
};

// NOTE: wire-only vestige — derived from blur radius to fill the SHOW wire's
// append-only `style` slot; the payload ignores it. Value 1 is retired; keep
// BLUR = 2.
enum focus_ring_style {
    FOCUS_RING_STYLE_STROKE = 0,
    FOCUS_RING_STYLE_BLUR   = 2,
};

// Modal (attached sheet/drawer) handling: off = frame the parent; follow =
// retarget to the child; clip = cut the child's rect from the band; both =
// follow + clip overlapping siblings.
enum focus_ring_modal_mode {
    FOCUS_RING_MODAL_OFF    = 0,
    FOCUS_RING_MODAL_FOLLOW = 1,
    FOCUS_RING_MODAL_CLIP   = 2,
    FOCUS_RING_MODAL_BOTH   = 3,
};
#define FOCUS_RING_DEFAULT_MODAL    FOCUS_RING_MODAL_FOLLOW

#define FOCUS_RING_MIN_WIDTH        0.0f
#define FOCUS_RING_MAX_WIDTH       32.0f

#define FOCUS_RING_DEFAULT_BLUR     15
#define FOCUS_RING_MAX_BLUR        64

// NOTE: bleed insets the band's inner edge INTO the window so the backdrop
// frosts the window's own edge pixels; > 0 also forces the ring above the
// target. Payload clamps per-window to keep the cutout positive.
#define FOCUS_RING_DEFAULT_BLEED    0.0f
#define FOCUS_RING_MIN_BLEED        0.0f
#define FOCUS_RING_MAX_BLEED       64.0f

#define FOCUS_RING_DEFAULT_SATURATION  1.5f
#define FOCUS_RING_MIN_SATURATION      0.0f
#define FOCUS_RING_MAX_SATURATION      4.0f
#define FOCUS_RING_DEFAULT_BRIGHTNESS  0.5f
#define FOCUS_RING_MIN_BRIGHTNESS     -1.0f
#define FOCUS_RING_MAX_BRIGHTNESS      1.0f
#define FOCUS_RING_DEFAULT_CONTRAST    2.0f
#define FOCUS_RING_MIN_CONTRAST        0.0f
#define FOCUS_RING_MAX_CONTRAST        4.0f
#define FOCUS_RING_DEFAULT_HUE         5.0f
#define FOCUS_RING_MIN_HUE             0.0f
#define FOCUS_RING_MAX_HUE           360.0f

// NOTE: the ordinal IS the wire contract (payload mirrors an enum→CAFilter
// table): append at the end, never reorder.
enum focus_ring_blend_mode {
    FOCUS_RING_BLEND_NORMAL = 0,
    FOCUS_RING_BLEND_MULTIPLY,
    FOCUS_RING_BLEND_SCREEN,
    FOCUS_RING_BLEND_OVERLAY,
    FOCUS_RING_BLEND_DARKEN,
    FOCUS_RING_BLEND_LIGHTEN,
    FOCUS_RING_BLEND_COLOR_DODGE,
    FOCUS_RING_BLEND_COLOR_BURN,
    FOCUS_RING_BLEND_SOFT_LIGHT,
    FOCUS_RING_BLEND_HARD_LIGHT,
    FOCUS_RING_BLEND_DIFFERENCE,
    FOCUS_RING_BLEND_EXCLUSION,
    FOCUS_RING_BLEND_HUE,
    FOCUS_RING_BLEND_SATURATION,
    FOCUS_RING_BLEND_COLOR,
    FOCUS_RING_BLEND_LUMINOSITY,
    FOCUS_RING_BLEND_COUNT,
};
#define FOCUS_RING_DEFAULT_BLEND_MODE  FOCUS_RING_BLEND_NORMAL

// Inner stroke: a layer in the ring's own CA tree (no second window); position
// picks zPosition vs the band. NOTE: BELOW reads "stroke through frost" — the
// backdrop samples behind-WINDOW content, never sibling layers.
enum focus_ring_inner_stroke_position {
    FOCUS_RING_INNER_STROKE_ABOVE = 0,
    FOCUS_RING_INNER_STROKE_BELOW = 1,
};
#define FOCUS_RING_DEFAULT_INNER_STROKE           true
#define FOCUS_RING_DEFAULT_INNER_STROKE_POSITION  FOCUS_RING_INNER_STROKE_ABOVE
#define FOCUS_RING_DEFAULT_INNER_STROKE_WIDTH     6.0f
#define FOCUS_RING_MIN_INNER_STROKE_WIDTH         0.5f
#define FOCUS_RING_MAX_INNER_STROKE_WIDTH        32.0f

// feather: gaussianBlur on the band's alpha MASK — softens both edges; px, 0 = off.
#define FOCUS_RING_DEFAULT_FEATHER          0.0f
#define FOCUS_RING_MIN_FEATHER              0.0f
#define FOCUS_RING_MAX_FEATHER             64.0f

// NOTE: -1 opacity / unset color = inherit the band's. The daemon resolves
// final per-layer RGBA before the SHOW wire; the payload has no inherit logic.
#define FOCUS_RING_OPACITY_INHERIT               (-1.0f)
#define FOCUS_RING_DEFAULT_INNER_STROKE_OPACITY  FOCUS_RING_OPACITY_INHERIT

bool      focus_ring_get_enabled(void);
void      focus_ring_set_enabled(bool enabled);

float     focus_ring_get_width(void);
void      focus_ring_set_width(float width);
float     focus_ring_get_color_opacity(void);
void      focus_ring_set_color_opacity(float opacity);
float     focus_ring_get_alpha(void);
void      focus_ring_set_alpha(float alpha);

// Background-blur radius (px). Just one knob on the always-on backdrop band
// (0 = unblurred; the classic solid ring is the color wash at full alpha).
// Pushed to the payload on every SHOW alongside the other style fields; the
// payload masks the band via the CABackdropLayer's shape mask, center stays
// sharp.
int       focus_ring_get_blur_radius(void);
void      focus_ring_set_blur_radius(int radius);

// Band color adjustment + wash blend mode. Pushed to the payload on every SHOW
// alongside the other style fields; saturation/brightness/contrast/hue feed
// the backdrop's CAFilter chain, blend_mode the color-wash sublayer's
// compositingFilter.
float     focus_ring_get_saturation(void);
void      focus_ring_set_saturation(float saturation);
float     focus_ring_get_brightness(void);
void      focus_ring_set_brightness(float brightness);
float     focus_ring_get_contrast(void);
void      focus_ring_set_contrast(float contrast);
float     focus_ring_get_hue(void);
void      focus_ring_set_hue(float hue);
int       focus_ring_get_blend_mode(void);
void      focus_ring_set_blend_mode(int mode);

// Inner stroke (focus_ring_inner_stroke{,_position,_width}) — the hard stroke
// layer hugging the band's inner edge. Pushed to the payload on every SHOW
// alongside the other style fields.
bool      focus_ring_get_inner_stroke(void);
void      focus_ring_set_inner_stroke(bool enabled);
int       focus_ring_get_inner_stroke_position(void);
void      focus_ring_set_inner_stroke_position(int position);
float     focus_ring_get_inner_stroke_width(void);
void      focus_ring_set_inner_stroke_width(float width);

// Inner bleed (px). Pushed to the payload on every SHOW; when
// > 0 the payload insets the band's inner cutout inward by this many px AND forces
// the ring to order above the target so the overlapping strip samples the focused
// window's content. 0 = off (band stays outside the window, ring keeps its
// configured z-order).
float     focus_ring_get_bleed(void);
void      focus_ring_set_bleed(float bleed);

// Inner-stroke color / opacity, overriding the band's focus_ring_color /
// focus_ring_color_opacity. Opacity uses FOCUS_RING_OPACITY_INHERIT (-1) to
// mean "follow focus_ring_color_opacity"; the _inherit color setter clears the
// override back to focus_ring_color. get_color returns the override RGB packed
// as 0xAARRGGBB (alpha forced 0xff); _is_set reports whether the override is
// active. Resolved to final RGBA daemon-side before the SHOW wire (see
// focus_ring_show_for_wid).
float     focus_ring_get_inner_stroke_opacity(void);
void      focus_ring_set_inner_stroke_opacity(float opacity);  // -1 = inherit
uint32_t  focus_ring_get_inner_stroke_color(void);
bool      focus_ring_get_inner_stroke_color_is_set(void);
void      focus_ring_set_inner_stroke_color(uint32_t argb);
void      focus_ring_set_inner_stroke_color_inherit(void);

// Edge feather (px). Pushed to the payload on every SHOW; when > 0
// the payload sets a gaussianBlur CAFilter on the band's alpha mask so its edges
// soften. 0 = off (sharp band).
float     focus_ring_get_feather(void);
void      focus_ring_set_feather(float feather);

// get_color: RGB packed 0xAARRGGBB, alpha forced 0xff (wash alpha is the
// separate color_opacity). set_color leaves AUTO and tears down the accent observer.
uint32_t  focus_ring_get_color(void);
bool      focus_ring_get_color_is_auto(void);
void      focus_ring_set_color(uint32_t argb);
void      focus_ring_set_color_auto(void);

// Named accent presets → 0xAARRGGBB; false when `name` is not a preset.
bool      focus_ring_color_preset(const char *name, uint32_t *argb);

uint32_t  focus_ring_get_target_wid(void);

// Resolve the target's rect via SLS and redraw; defers to the settle while the display animates.
bool      focus_ring_show_for_wid(uint32_t target_wid);

// NOTE: settle-resume only — bypasses the animating-defer (the settle cap can
// elapse mid-motion; re-entering would re-arm the poll that called it).
bool      focus_ring_show_for_wid_settled(uint32_t target_wid);

// Redraw at an explicit rect — for managed windows whose live SLS rect is
// transform-tainted; caller passes the node rect.
bool      focus_ring_show_for_wid_rect(uint32_t target_wid, CGRect rect);

// Desktop ring (display-sized, wid recorded as 0). NOTE: wid 0 keeps the
// payload's t3d redraw filter from riding window animations.
void      focus_ring_show_for_display(uint32_t did);

void      focus_ring_hide(void);

// Ride a space switch. `animated` = yabai-driven slide (fade-in per
// fade_duration); native/snap switches pass false → instant reveal.
void      focus_ring_space_switch(uint64_t out_sid, uint64_t in_sid, bool animated);

// NOTE: caller/event thread ONLY (ts_alloc arena is single-threaded). Resolves
// the destination space's focused window + natural rect + radius; false = no
// parkable target.
bool      focus_ring_resolve_dest(uint64_t in_sid, uint32_t *out_wid, CGRect *out_rect, float *out_radius);

// FR-9 fade lever: fade the ring in as it rides the animated space slide.
// FR-22: fade on/off is inferred from the duration (0 = off) — there is no
// separate fade boolean.
#define FOCUS_RING_DEFAULT_FADE_DURATION  0.25f  // seconds; 0 = off (also paces the space-switch fade)

// NOTE: focus-change shows defer this long; a superseding intent (epoch) drops
// the intermediate — absorbs the stale-sibling focus bounce into one reveal.
// Adds at most this latency to a single focus change.
#define FOCUS_RING_DEFAULT_COALESCE_MS    16.0f  // ~1 frame @60Hz; 8ms let a rare bounce through
#define FOCUS_RING_MIN_COALESCE_MS        0.0f
#define FOCUS_RING_MAX_COALESCE_MS        64.0f

// FR-9 fade DELAY: seconds from the start of an animated space switch before the
// ring fade-in fires. 0 = fade DURING the slide; negative = auto = track
// space_animation_duration (fade begins as the slide settles); positive = fixed
// defer. The fade ticks on the shared ca_clock pump (AC-7), buffering into the
// SAME per-VBL transaction as the cross-fade animator, so fading during the
// slide cannot clash with its commits. A defer widens the window in which a
// rapid follow-up switch supersedes the deferred reveal (ring never lands) and
// lets the captured dest_rect go stale (ring lands misaligned) — defer only if
// you deliberately want the fade to begin after the slide settles.
// FR-22: default is auto (-1); an explicit value (including 0) overrides.
#define FOCUS_RING_DEFAULT_FADE_DELAY     (-1.0f)  // auto = track space_animation_duration

// NOTE: values mirror the payload's focus_ease() — keep the two in sync.
enum focus_ring_easing {
    FOCUS_RING_EASE_LINEAR     = 0,   // t
    FOCUS_RING_EASE_SMOOTHSTEP = 1,   // 3t^2 - 2t^3  (ease-in-out)
    FOCUS_RING_EASE_IN_QUAD    = 2,   // t^2          (ease-in)
    FOCUS_RING_EASE_OUT_EXPO   = 3,   // 1 - 2^(-10t) (ease-out)
};
#define FOCUS_RING_DEFAULT_EASING  FOCUS_RING_EASE_IN_QUAD
// True while a deferred animated-switch fade owns the ring reveal — space_transition_finish
// checks this so its instant re-show doesn't slam the ring opaque mid-fade.
bool      focus_ring_deferred_fade_pending(void);

// Hide only if `wid` is still the committed target when the block drains — a
// concurrent focus change keeps its ring. Use from destroy/minimize paths.
void      focus_ring_hide_for_wid(uint32_t wid, const char *reason);

// Re-park on wid's current rect only if it is still the committed target. Event thread only.
void      focus_ring_reposition_for_wid(uint32_t wid);

// While on, shows skip the coalesce defer so the ring tracks an OS drag at VBL rate.
void      focus_ring_set_drag_follow(bool on);

// NOTE: rides the serial queue so the flip lands AFTER a just-enqueued show —
// a direct SA set_visible would race ahead of the async reposition.
void      focus_ring_set_visible_async(bool visible);

// Arm the payload's MC transform mirror; same queue, so it lands after the show sends.
void      focus_ring_mc_ride_async(uint32_t wid);

// MC-enter counterpart: ride the band out to the thumbnail while fading, then park hidden.
void      focus_ring_mc_enter_ride_async(uint32_t wid);

// Verbose-gated debug log; one timestamped line per call, per-tree file under /tmp.
void      focus_ring_log(const char *source, const char *fmt, ...)
              __attribute__((format(printf, 2, 3)));

#endif
