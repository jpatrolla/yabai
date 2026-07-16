#ifndef FOCUS_RING_H
#define FOCUS_RING_H

// =========================================================================
// focus_ring — singular band-window focus indicator (PER_FOCUS)
// =========================================================================
// One Dock-cid-owned SLS window sized to the focused target + band
// padding, translated each animation frame inside the t3d batch's own
// transaction (SLSTransactionMoveWindowWithGroup) so the ring's position
// commits in the same compositor frame as the target's LB+T3D motion.
// Resizes go through SLSTransactionSetWindowShape + redraw on the small
// surface. Lifecycle is one-instance: created on first SHOW, destroyed on
// focus loss or HIDE.
//
// The ring is ONE window hosting two styled layers (FR-24):
//   band         — the frosted backdrop strip around the window, washed with
//                  focus_ring_color at focus_ring_color_opacity. blur_radius
//                  frosts what it samples (0 = unblurred; color_opacity 1.0
//                  = the classic solid ring). saturation/brightness/contrast/
//                  hue re-grade the sampled content; blend_mode composites the
//                  color wash over it.
//   inner stroke — a hard rounded-rect stroke hugging the band's inner edge
//                  (the window seam), on its own layer above or below the
//                  band. Color/opacity inherit the band's unless overridden.
//
// User-facing config:
//   yabai -m config focus_ring_enabled on|off
//   yabai -m config focus_ring_width <px>                 (band thickness)
//   yabai -m config focus_ring_color 0xAARRGGBB | auto | system
//                                                  (band color wash; auto/system
//                                                  track the macOS accent color)
//   yabai -m config focus_ring_color_opacity <0.0..1.0>   (band color wash alpha;
//                                                  0 = pure frost, 1 = solid color)
//   yabai -m config focus_ring_blur_radius <px>   (0 = off; gaussian blur of the
//                                                  content the band samples)
//   yabai -m config focus_ring_bleed <px>         (0 = off; band samples + frosts
//                                                  the window's own edge, bleeding
//                                                  it outward)
//   yabai -m config focus_ring_saturation <0.0..4.0>   (1.0 = unchanged frost)
//   yabai -m config focus_ring_brightness <-1.0..1.0>  (0.0 = unchanged frost)
//   yabai -m config focus_ring_contrast <0.0..4.0>     (1.0 = unchanged frost)
//   yabai -m config focus_ring_hue <0..360>            (degrees; 0 = unchanged)
//   yabai -m config focus_ring_blend_mode normal | multiply | screen | overlay |
//                                          darken | lighten | color-dodge |
//                                          color-burn | soft-light | hard-light |
//                                          difference | exclusion | hue |
//                                          saturation | color | luminosity
//                                                  (how the color wash blends
//                                                  over the frost)
//   yabai -m config focus_ring_feather <px>       (0 = off; blurs the band's alpha
//                                                  MASK so its edges soften instead
//                                                  of reading as sharp cutouts)
//   yabai -m config focus_ring_inner_stroke on|off
//   yabai -m config focus_ring_inner_stroke_position above | below
//                                                  (z-order of the stroke vs the band)
//   yabai -m config focus_ring_inner_stroke_width <px>
//   yabai -m config focus_ring_inner_stroke_opacity <0.0..1.0> | inherit
//                                                  (inherit = follow color_opacity)
//   yabai -m config focus_ring_inner_stroke_color 0xAARRGGBB | inherit
//                                                  (inherit = follow color)
//   yabai -m config focus_ring_alpha <0.0..1.0>   (whole-window translucency of the
//                                                  ring surface — dims band + stroke +
//                                                  frost together; composes with the
//                                                  per-layer opacities)
//
// The desktop ring (display-sized band when the desktop is focused), the
// FR-21 xray recolor, the FR-9 fade timing, and the modal-follow mode run on
// their compile-time defaults in this tree (see the FOCUS_RING_*_DEFAULT
// defines below) — they have no config keys.
//
// Daemon-side state (this module): enabled + style flags, last-target
// tracking, per-display VBL throttle, debug log emissions.
// =========================================================================

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <CoreGraphics/CGGeometry.h>

// Daemon-side default stroke width. The runtime value lives in g_focus_ring
// (see focus_ring.m) and is mutable via `yabai -m config focus_ring_width N`.
// Payload mirrors this in g_focus_ring_stroke_width (see focus_ring.inc.m);
// daemon stamps the current value on every SA SHOW so the two stay in sync.
#define FOCUS_RING_DEFAULT_ENABLED  true
#define FOCUS_RING_DEFAULT_WIDTH    10.0f
// Band color wash alpha. 0 = pure frost (the color knobs are visually inert
// until this is raised); 1 = solid color band (default — focus_ring_color is
// WYSIWYG out of the box; lower this to let the frost through).
#define FOCUS_RING_DEFAULT_COLOR_OPACITY  1.0f
// Whole-window translucency (`alpha` knob) — the ring window's NORMAL alpha
// slot. Distinct from COLOR_OPACITY (the band's color wash alpha); show/hide +
// fades ride the SYSTEM alpha slot, so the two compose multiplicatively.
#define FOCUS_RING_DEFAULT_ALPHA    0.60f

// FR-20: desktop-ring style overrides. The desktop ring (the display-sized ring
// shown when the desktop, not a window, is focused — target wid 0) is a separate
// visual state from the per-window ring, with its own width / radius / opacity /
// top-margin and an on/off sub-toggle (the ring shows only when
// focus_ring_enabled AND focus_ring_desktop are both on). Width and opacity use
// the -1 = inherit sentinel (fall back to focus_ring_width / focus_ring_color_opacity)
// so an unconfigured desktop ring matches the main ring. Radius has nothing to
// inherit (the per-window ring derives its radius from the window's own corner
// radius); it rounds the band's INNER edge (the ring renders inset, outer edge
// flush on the display boundary). The desktop ring frames the FULL display — top
// at the screen edge, behind the menubar; top-margin is an ABSOLUTE top-edge
// inset from the screen top (set ≈ menubar height to tuck the ring below it).
#define FOCUS_RING_DESKTOP_DEFAULT_ENABLED    true
#define FOCUS_RING_DESKTOP_INHERIT            (-1.0f)
#define FOCUS_RING_DESKTOP_DEFAULT_WIDTH      FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_OPACITY    FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_RADIUS    16.0f
#define FOCUS_RING_DESKTOP_DEFAULT_TOP_MARGIN 0.0f
// Further desktop-ring overrides: alpha / color / blur / hsbc / feather, all
// inherit-by-default. alpha/blur/feather use the <0 = inherit sentinel (blur
// is an int, so it gets its own -1 define); color and hsbc carry an is_set
// flag instead, since 0x000000 / 0.0 are valid explicit values. hsbc = the
// hue,saturation,brightness,contrast quad (one CSV knob).
#define FOCUS_RING_DESKTOP_DEFAULT_ALPHA      FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_BLUR       (-1)
#define FOCUS_RING_DESKTOP_DEFAULT_FEATHER    FOCUS_RING_DESKTOP_INHERIT
#define FOCUS_RING_DESKTOP_DEFAULT_BLEND      (-1)   // int sentinel; <0 = inherit blend_mode

// Default band color (0xffffffff — white). Stamped on every SA SHOW (the wire's
// legacy stroke_{r,g,b} slots plus the resolved tint); keep these matching the
// payload's g_focus_ring_stroke_{r,g,b} initializers so an unconfigured ring
// looks the same pre/post first SHOW.
#define FOCUS_RING_DEFAULT_R        1.00f
#define FOCUS_RING_DEFAULT_G        1.00f
#define FOCUS_RING_DEFAULT_B        1.00f

// FR-21: xray ring — recolor exactly the band pixels that overlap another
// window's frame. The daemon ships the overlapping windows' FULL screen frames
// on the SHOW wire (not precomputed intersections), so the payload's clipped
// re-stroke keeps tracking the visible intersection per-frame while the ring
// follows an animated target. Renders on the sharp (blur=0) band directly and
// on the frosted ring's inner_stroke overlay. Known limit: the rect set
// refreshes only on a SHOW — a foreign window moving doesn't retrigger until
// the next focus change / target move / config change.
#define FOCUS_RING_DEFAULT_XRAY      false
#define FOCUS_RING_XRAY_DEFAULT_R    0.25f
#define FOCUS_RING_XRAY_DEFAULT_G    0.78f
#define FOCUS_RING_XRAY_DEFAULT_B    1.00f
#define FOCUS_RING_XRAY_DEFAULT_A    1.00f

// focus_ring_color modes. AUTO tracks System Settings → Appearance → accent
// color live (re-resolved on the system accent-change notification); FIXED is
// a user-supplied 0xAARRGGBB constant.
enum focus_ring_color_mode {
    FOCUS_RING_COLOR_FIXED = 0,
    FOCUS_RING_COLOR_AUTO  = 1,
};

// focus_ring_style — WIRE-ONLY vestige. The value is derived at send time from
// the blur radius (0 = STROKE, > 0 = BLUR) purely to fill the SHOW wire's
// `style` slot (append-only contract), which the payload ignores since FR-24 —
// rendering is one path, driven by the blur radius itself. No daemon state, no
// config key. Value 1 (a retired GLOW style) is reserved; keep BLUR = 2.
enum focus_ring_style {
    FOCUS_RING_STYLE_STROKE = 0,
    FOCUS_RING_STYLE_BLUR   = 2,
};

// How the ring treats a modal / attached child window that sits over its parent
// (e.g. System Settings' "Keyboard Shortcuts" sheet). yabai-the-window-manager
// deliberately doesn't *manage* these, so the focus event resolves to the
// parent — but there's no reason the ring must be blind to the child.
//   off    — ignore children; ring frames the focused (parent) window as before.
//   follow — retarget the ring to the front-most attached child so it frames the
//            modal directly (daemon-side target re-resolution; no payload change).
//   clip   — keep the ring on the parent but cut the child's rect out of the band
//            so the ring never paints over the modal (payload geometry; see SHOW).
//   both   — follow into the child, and clip any other overlapping siblings.
enum focus_ring_modal_mode {
    FOCUS_RING_MODAL_OFF    = 0,
    FOCUS_RING_MODAL_FOLLOW = 1,
    FOCUS_RING_MODAL_CLIP   = 2,
    FOCUS_RING_MODAL_BOTH   = 3,
};
#define FOCUS_RING_DEFAULT_MODAL    FOCUS_RING_MODAL_FOLLOW

// Clamp range for user-set stroke width. No lower floor — a width of 0 simply
// yields an invisible ring; above 32 px the per-focus surface gets huge and the
// stroke looks more like a banner than a ring.
#define FOCUS_RING_MIN_WIDTH        0.0f
#define FOCUS_RING_MAX_WIDTH       32.0f

// Background-blur (vibrancy) radius applied to the framebuffer behind the
// band. 0 disables it (unblurred sample); the default is a 15px frost. Capped
// so a typo can't ask the compositor for an absurd Gaussian kernel.
#define FOCUS_RING_DEFAULT_BLUR     15
#define FOCUS_RING_MAX_BLUR        64

// Inner bleed — px the frosted band's INNER edge is pushed
// INWARD past the focused window's edge, so the band overlaps a strip of the
// window. With the ring ordered above the target, the backdrop's behind-window
// capture samples that strip (the window's own edge pixels) and frosts it, then
// the (smaller) cutout keeps the center sharp — the window content bleeds outward
// into the halo. 0 disables it (default — band sits entirely outside the window).
// Capped so a typo can't invert the cutout on small windows (payload also clamps
// per-window to keep the hole positive).
#define FOCUS_RING_DEFAULT_BLEED    0.0f
#define FOCUS_RING_MIN_BLEED        0.0f
#define FOCUS_RING_MAX_BLEED       64.0f

// Band color adjustment — CAFilter colorSaturate /
// colorBrightness applied over the sampled frosted content. Identity is
// saturation 1.0 / brightness 0.0; the defaults bake the showcase style (saturated,
// brightened frost composited over the window edge via the color-dodge blend).
#define FOCUS_RING_DEFAULT_SATURATION  1.5f
#define FOCUS_RING_MIN_SATURATION      0.0f
#define FOCUS_RING_MAX_SATURATION      4.0f
#define FOCUS_RING_DEFAULT_BRIGHTNESS  0.5f
#define FOCUS_RING_MIN_BRIGHTNESS     -1.0f
#define FOCUS_RING_MAX_BRIGHTNESS      1.0f
// CAFilter colorContrast over the sampled frosted content. 1.0 = identity;
// < 1 flattens, > 1 deepens the frost's contrast. Default deepens to 2.0.
#define FOCUS_RING_DEFAULT_CONTRAST    2.0f
#define FOCUS_RING_MIN_CONTRAST        0.0f
#define FOCUS_RING_MAX_CONTRAST        4.0f
// CAFilter colorHueRotate over the sampled frosted content. Degrees (converted to
// radians payload-side). 0 = identity; rotates the frost's hue around the color
// wheel — wraps at 360. Default nudges 5°.
#define FOCUS_RING_DEFAULT_HUE         5.0f
#define FOCUS_RING_MIN_HUE             0.0f
#define FOCUS_RING_MAX_HUE           360.0f

// focus_ring_blend_mode — the CAFilter compositingFilter set on the band's
// color-wash sublayer, controlling how the ring color blends over the frosted
// blur beneath it. NORMAL clears the filter (default source-over).
// The payload mirrors this enum -> CAFilter type-string table, so the integer
// ordinal IS the wire contract: append new modes at the END, never reorder.
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
// NORMAL by default so focus_ring_color renders literally. color-dodge (the old
// showcase default) brightens the frost but blows any hue toward white over
// bright content — opt back in per-config.
#define FOCUS_RING_DEFAULT_BLEND_MODE  FOCUS_RING_BLEND_NORMAL

// focus_ring_inner_stroke — overlay a hard rounded-rect stroke hugging the
// band's inner edge (the window seam) so the band reads brighter / more
// defined. Not a true inset stroke of the window — it lives on its own layer
// in the ring's CA tree (no second window); position selects its zPosition vs
// the band.
//   ABOVE — crisp stroke composited over the band (clean defined edge).
//   BELOW — stroke under the band, seen translucently through the frost (softer).
// NB: the backdrop samples behind-WINDOW content, not sibling layers, so BELOW is
// "stroke through frost", not a true gaussian blur of the stroke.
enum focus_ring_inner_stroke_position {
    FOCUS_RING_INNER_STROKE_ABOVE = 0,
    FOCUS_RING_INNER_STROKE_BELOW = 1,
};
#define FOCUS_RING_DEFAULT_INNER_STROKE           true
#define FOCUS_RING_DEFAULT_INNER_STROKE_POSITION  FOCUS_RING_INNER_STROKE_ABOVE
#define FOCUS_RING_DEFAULT_INNER_STROKE_WIDTH     6.0f
#define FOCUS_RING_MIN_INNER_STROKE_WIDTH         0.5f
#define FOCUS_RING_MAX_INNER_STROKE_WIDTH        32.0f

// focus_ring_feather — soften the band's edges. The band's shape is an
// even-odd rounded-rect alpha MASK on the backdrop; setting a gaussianBlur
// CAFilter on that mask layer blurs its alpha, so the band's outer and inner
// edges feather instead of reading as sharp cutouts (the "gradient mask /
// feather selection" idiom — black→white falloff at the edges). The value is
// the blur radius in px. 0 = off (sharp edges, default).
#define FOCUS_RING_DEFAULT_FEATHER          0.0f
#define FOCUS_RING_MIN_FEATHER              0.0f
#define FOCUS_RING_MAX_FEATHER             64.0f

// Discrete-transition ease — easing the ring's band on DISCRETE transitions
// (focus change, space switch, config change) via Core Animation's implicit
// actions is a payload-internal path with no config key: it runs on the
// compile-time defaults in focus_ring.inc.m (g_focus_ring_animate — off in
// this tree — and g_focus_ring_animate_duration). Continuous tracking (the
// t3d-batch lockstep redraw during a live drag/resize) always passes
// animated=false so the band stays glued to the window — an implicit animation
// there would make it trail.

// Inner-stroke color / opacity overrides. Each INHERITS the band's
// focus_ring_color / focus_ring_color_opacity until explicitly set, so an
// unconfigured stroke matches the band. Opacity uses the sentinel -1 = inherit;
// color carries a separate "is set" flag. The daemon resolves both to final
// per-layer RGBA before the SHOW wire, so the payload just applies them (no
// inherit logic payload-side).
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

// Band color. get_color returns the current RGB packed as 0xAARRGGBB with
// alpha forced to 0xff (the wash alpha is the separate focus_ring_color_opacity).
// set_color switches to FIXED mode and tears down any accent observer;
// set_color_auto switches to AUTO mode, resolves the accent now, and installs
// the live accent-change observer. Both reissue SHOW for the current target.
uint32_t  focus_ring_get_color(void);
bool      focus_ring_get_color_is_auto(void);
void      focus_ring_set_color(uint32_t argb);
void      focus_ring_set_color_auto(void);

// FR-22: resolve a named accent preset (blue/purple/pink/red/orange/yellow/green/
// grey) to 0xAARRGGBB. Returns false if `name` is not a preset. Consulted by the
// variadic config parser before the hex/auto parse, for every color-valued key.
bool      focus_ring_color_preset(const char *name, uint32_t *argb);

uint32_t  focus_ring_get_target_wid(void);

// Resolve the target's screen-space rect via SLS, then redraw. Defers to the unified
// settle (FR-1) when the target's display is mid-animation, so an in-flight rect is
// never painted; the settle re-resolves and reveals once motion ends.
bool      focus_ring_show_for_wid(uint32_t target_wid);

// Settle-resume variant — call ONLY from the unified settle poll's resume. Same as
// focus_ring_show_for_wid but BYPASSES the animating-defer: by the time the settle
// resumes, the ring must paint even if the display still reports animating (the
// 0.5s settle cap can elapse mid-motion). Re-entering the defer from here would
// re-arm the poll that called it. Thumbnail/minimized still apply.
bool      focus_ring_show_for_wid_settled(uint32_t target_wid);

// Redraw at an explicit rect (no SLS resolve). For managed BSP windows whose
// live SLS rect is transform-tainted (drag-warp spring-back) — caller passes the
// node rect. Same guards as focus_ring_show_for_wid.
bool      focus_ring_show_for_wid_rect(uint32_t target_wid, CGRect rect);

// Show the ring as a display-sized rectangle (desktop-click target). The rect
// is the desktop config's bounds (full display, top tucked below the menubar);
// the payload renders the wid==0 ring INSET (band grows inward from the rect,
// the inverse of the window ring's outward band). radius defaults to 0; wid is
// recorded as 0 so payload's t3d-batch redraw filter (wid == target_wid) won't
// ride window animations.
void      focus_ring_show_for_display(uint32_t did);

void      focus_ring_hide(void);

// FR-9: ride a space switch. anticipate ON => vanish the outgoing space's parked
// ring and reveal the incoming space's (rides in with the slide as a managed-
// space member); OFF => legacy hide+reshow. out_sid/in_sid are the source and
// destination managed space ids. `animated` = the yabai-driven slide: only then
// is the incoming ring faded in (when focus_ring_fade is on) over
// focus_ring_fade_duration; native/snap pass false → instant reveal.
void      focus_ring_space_switch(uint64_t out_sid, uint64_t in_sid, bool animated);

// SPA-17: resolve the destination space's focused window + natural rect + corner
// radius (the geometry the focus ring parks on). Shared by focus_ring_space_switch
// and the animated slide seed (space_manager ships it on the SPACE_ANIMATE wire so
// the ring rides the slide as a geo-rider). Returns false / *out_wid=0 when there's
// no parkable target. MUST run on the caller/event thread (ts_alloc arena).
bool      focus_ring_resolve_dest(uint64_t in_sid, uint32_t *out_wid, CGRect *out_rect, float *out_radius);

// FR-9 fade lever: fade the ring in as it rides the animated space slide.
// FR-22: fade on/off is inferred from the duration (0 = off) — there is no
// separate fade boolean.
#define FOCUS_RING_DEFAULT_FADE_DURATION  0.25f  // seconds (focus-change crossfade + FR-9 space-switch fade); 0 = off

// Focus-change COALESCE window (ms). A focus-CHANGE ring show (focus_ring_show_for_wid)
// is deferred this long before its SA send; if a newer focus intent supersedes it
// within the window (epoch bump), the intermediate is dropped and never paints.
// This absorbs the stale same-space sibling kCGSWindowIsVisible (815) "bounce"
// (click focuses B, a lagged 815 briefly resolves to the previous front window,
// then re-corrects to B) into a single reveal — no visible double-crossfade. The
// epoch already guarantees the FINAL target is correct; this only suppresses the
// transient. 0 = off (immediate send). A single (non-bounce) focus change incurs at
// most this much latency before the ring moves.
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

// FR-9 fade easing. Applied to the ALPHA channel in the payload's fade tick.
// ease_out_expo (matching the slide's POSITION curve) front-loads alpha so hard
// the ring pops in rather than fades — the default ease-in quad stays faint
// early and fills in as the slide settles. Keep these values in sync with
// payload focus_ease() (focus_ring.inc.m).
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

// Conditional hide for a window that's going away (destroy / minimize). Only
// clears the ring if `wid` is still the committed target when the block drains
// on the focus_ring serial queue, so it can't wipe a ring that a concurrent
// focus change has already moved to a surviving window. Use this instead of
// focus_ring_hide() from destroy/minimize paths. `reason` is a static string
// (a literal) folded into the hide/hide_skip log line.
void      focus_ring_hide_for_wid(uint32_t wid, const char *reason);

// Live-follow reposition: re-park the ring on `wid`'s current rect, but only if
// `wid` is still the committed target (a background-window move/resize can't
// steal the ring). Event-thread only (called from WINDOW_MOVED / WINDOW_RESIZED).
void      focus_ring_reposition_for_wid(uint32_t wid);

// Float/unmanaged-drag follow-mode. While on, focus_ring_show_for_wid bypasses
// the coalesce defer so the ring tracks an OS-driven window drag at VBL rate
// (vs. the BSP path, which hides the ring via focus_ring_drag_begin). Wired from
// the kCGSWorkspacesWindowDragDidStart/DidEnd handler for non-BSP windows.
void      focus_ring_set_drag_follow(bool on);

// Toggle overlay alpha (0/1) on the focus_ring serial queue rather than
// inline. Callers that want the visibility flip to land AFTER a just-enqueued
// focus_ring_show_for_wid() (e.g. the Mission-Control-exit resume, so the ring
// reveals at the re-resolved rect, not the stale one) must use this — a direct
// scripting_addition_focus_ring_set_visible() would race ahead of the async
// reposition.
void      focus_ring_set_visible_async(bool visible);

// MC-exit ring ride: arm the payload's MC-mode transform mirror on `wid` so the ring
// band rides the window's live CGSGetWindowTransform3D from thumbnail back to full on
// Mission-Control exit. Enqueued on the SAME serial queue as the show/visibility sends
// so it lands after them; the payload's mirror re-checks visible + target each VBL, so
// exact ordering vs the 16ms coalesce is not load-bearing. No-op for wid 0.
void      focus_ring_mc_ride_async(uint32_t wid);

// MC-ENTER counterpart: ride the ring OUT (band full->thumbnail) while fading it to 0 as
// the window enters Mission Control, then park it hidden. Replaces the plain snap-hide on
// MC enter. Same serial queue. No-op for wid 0.
void      focus_ring_mc_enter_ride_async(uint32_t wid);

// Debug log helper. Writes one timestamped line per call to the per-tree log
// under /tmp/logs/yabai/ (verbose-gated).
void      focus_ring_log(const char *source, const char *fmt, ...)
              __attribute__((format(printf, 2, 3)));

#endif
