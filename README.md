## About

This is a fork of [yabai](https://github.com/koekeishiya/yabai) that swaps the built-in window-frame animator for a custom Core Animation&ndash;driven engine, and adds animated space transitions and a focus ring.

It is my first C project &mdash; a learning exercise built on top of
koekeishiya's work. For installation, configuration, and full usage, refer to the
[upstream yabai repository](https://github.com/koekeishiya/yabai) and its
[wiki](https://github.com/koekeishiya/yabai/wiki). **This README documents only
what is different here.**

## Requirements and Caveats

> :warning: **Use at your own risk.** This has only ever been built and run on a
> single machine:
>
> - **Mac mini (2023), Apple M2 Pro**
> - **Dual-display setup**
> - **macOS Tahoe 26.5**
>
> It has not been tested on any other hardware, display configuration, or macOS
> version. Expect rough edges &mdash; or outright breakage &mdash; anywhere else.

In addition to yabai's normal setup, the animation features require:

- **System Integrity Protection partially disabled** &mdash; so the scripting
  addition can be injected into `Dock.app`.
- **Screen Recording permission** &mdash; granted to yabai.

Without both, the animations will not run. See the
[upstream wiki](https://github.com/koekeishiya/yabai/wiki) for SIP and permission
setup.

While running, the daemon keeps a `/usr/bin/log stream` child process alive to
observe Dock's Mission Control transitions &mdash; seeing it in the process list
is expected.

## Install

There are no packaged releases &mdash; build from source:

```bash
git clone https://github.com/jpatrolla/yabai-staging.git
cd yabai-staging
make install                          # release build -> ./bin/yabai
sudo cp ./bin/yabai /usr/local/bin/   # or anywhere on your PATH
```

Then load the scripting addition and start the service, exactly like stock
yabai (SIP setup and the sudoers entry are covered by the
[upstream wiki](https://github.com/koekeishiya/yabai/wiki/Disabling-System-Integrity-Protection)):

```bash
sudo yabai --load-sa
yabai --start-service
```

**Switching from stock yabai (or rebuilding):** the scripting addition shipped
here is versioned differently from upstream's. Run `sudo yabai --reload-sa`
once to force the installed payload to be replaced and re-injected in a single
pass (`--load-sa` alone would need two passes).

## Main Features

#### Window-frame animation engine
Replaces yabai's CVDisplayLink proxy-swap animator with a Core-Animation-pump engine (LockedBounds + Transform3D + Accessibility). Windows glide when retiled or resized instead of snapping. See the `window_animation_*` levers below.

#### Animated space transitions
An adjacent, same-display space slide, a direction-aware fullscreen "abyss" backdrop crossfade, and a menubar crossfade. See the `space_animation_*` levers below.

#### Focus ring
A ring that follows the focused window and rides space slides. On by default; a frosted band with an overlaid stroke. See the `focus_ring_*` levers below.

## Smaller Features

#### Window-server focus resolution
"Which window is focused?" is asked of the window server, not the app: a rich SLS window query &mdash; z-ordered, sticky/hidden/minimized windows excluded server-side, scoped to the process that actually holds key focus &mdash; resolves the focused window per space. Stock yabai's Accessibility read lags under fast focus churn, can answer with a window on another space, and goes silent when native tabs switch; a raw "topmost window on the space" heuristic can be hijacked by an overlay panel and can never say "nothing is focused". The same resolution decides where focus lands: switching to a space refocuses the window last used there (else its topmost eligible window), and closing an app's last window on a space advances focus instead of stranding it. Always on; `focus_unify` below additionally lets it drive yabai's tracked focus state.

#### Mission Control thumbnail strip
`space --toggle mission-control` can reveal Mission Control's spaces thumbnail strip on open, gated by the `mission_control_thumbnails_enabled` config (or forced for one invocation with `space --toggle mission-control-thumbnails`).

#### Directional focus for floating windows
`window --focus north|east|south|west` now resolves by window geometry when the BSP walk comes up empty, so it works for floating windows (and float/stack spaces), not just managed ones. Cross-display hops and edge wrap-around are opt-in &mdash; see `window_focus_inter_display` and `window_focus_wrap` below.

#### Screen-capture helper
`yabai -m capture start|stop|status|stitch` records a window, a display, or every display to HEVC video under `~/Movies`, and can stitch per-display recordings into one clip. Run `yabai -m capture help` for the full reference.

## Multi-display

Developed and daily-driven on a dual-display rig, so multi-display behavior is a
first-class concern:

#### Space-slide edge guard
A space slide nudges and stops at a display edge instead of walking across to the next display. See `multi_display_edge_guard` below.

<details>
<summary>Example</summary>

Spaces 1&ndash;3 on the left display, 4&ndash;6 on the right, focused on space 3:

- **stock yabai:** `space --focus next` walks to space 4 on the *right* display &mdash; keyboard focus and the active display silently switch monitors.
- **guard on:** space 3 nudges against the edge and springs back &mdash; a visible "end of this display's spaces" cue; focus stays where you were working.

</details>

#### Empty-display focus
`display --focus` on an empty display lands via its tracked desktop window, so focus resolves correctly on spaces with no windows &mdash; the no-window corner of the window-server focus resolution above.

#### Display targeting for bare space switches
Which display a bare `space --focus prev|next` acts on is configurable: `mouse` targets the display under the cursor; `smart` does so only when the last focus change came from the mouse, so keyboard-driven focus keeps the active display. See `mission_control_target_display` below.

#### Per-display animation timing
Each display's refresh timing (ProMotion and VRR included) is cached and paces the animations on that display, so a mixed-refresh setup animates every display at its native rate.

#### Cross-display directional focus
The directional-focus extension above can hop to the closest window on the display in that direction &mdash; opt-in via `window_focus_inter_display`.

## Configuration

Every lever below is an addition on top of stock yabai. Animations are **off by
default** &mdash; set a duration to enable them.

```bash
# Window-frame animation (engine is off until duration > 0)
yabai -m config window_animation_duration      0.25            # seconds; 0.0 = instant (default)
yabai -m config window_animation_easing        ease_out_circ   # see https://easings.net
yabai -m config window_animation_min_opacity   0.85            # fade floor -> 1.0; 1.0 disables fade (default)
yabai -m config window_animation_ax_wake       on              # wake Chromium/Electron lazy AX tree (default on)

# Window-frame animation — advanced presentation levers
yabai -m config window_animation_policy        true_resize     # true_resize | jello (mesh-warp resize presentation)
yabai -m config window_animation_warp_cover    off             # off | proxy | lb_warp; cover instant (non-animated) placements
yabai -m config window_animation_cover_fade    0.25            # proxy cover fade-out (s)
yabai -m config window_animation_warp_min_ms   100             # lb_warp mesh tween (ms); 0 = snap

# Space transitions
yabai -m config space_animation_duration       0.25            # seconds; 0.0 = instant switch (default)
yabai -m config multi_display_edge_guard       on              # stop slide at a display edge (default off = stock walk)
yabai -m config space_animation_enter_delay    0.0             # delay (s) before the incoming space starts sliding
yabai -m config space_animation_exit_delay     0.0             # delay (s) before the outgoing space starts sliding
yabai -m config space_animation_fade           off             # master: cross-fade windows over the slide (default off)
yabai -m config space_animation_fade_enter     on              # fade the incoming side (with the master on; default on)
yabai -m config space_animation_fade_exit      on              # fade the outgoing side (with the master on; default on)
yabai -m config space_animation_fade_enter_delay auto          # auto | seconds (auto = track the slide)
yabai -m config space_animation_fade_exit_delay  auto          # auto | seconds (auto = track the slide)
yabai -m config space_animation_fade_enter_dur   auto          # auto | seconds (auto = track the slide duration)
yabai -m config space_animation_fade_exit_dur    auto          # auto | seconds (auto = track the slide duration)

# Mission Control
yabai -m config expose_animation_duration      -1              # MC enter/exit tween (s); 0 = instant, < 0 = native (default)
yabai -m config mission_control_target_display default         # default | mouse | smart — display a bare `space --focus prev|next` acts on

# Focus plumbing
yabai -m config window_focus_method            ax              # ax | sls (raise via WindowServer; falls back to ax)
yabai -m config focus_unify                    off             # adopt WindowServer key-focus changes AX misses, e.g. native tabs (default off)

# Focus ring (unlike the animations, this is ON by default)
yabai -m config focus_ring_enabled             on              # master on/off (default on)
yabai -m config focus_ring_color               0xffffffff      # 0xAARRGGBB | auto | system (default white; auto/system track the macOS accent color)
yabai -m config focus_ring_width               10              # band thickness in px (default 10)
yabai -m config focus_ring_alpha               0.60            # whole-ring translucency 0.0..1.0 (default 0.60)
yabai -m config focus_ring_opacity             0.0             # hard stroke/tint wash alpha 0.0..1.0 (default 0.0 = off)
yabai -m config focus_ring_animate             on              # ease the band on focus change / space switch; live tracking stays instant (default on)

# Frosted-band styling — focus_ring_blur_radius drives the look: 0 = a sharp solid stroke,
# > 0 = a frosted band (the style is inferred from this radius; there is no separate style key).
yabai -m config focus_ring_blur_radius         15              # frost blur radius in px; 0 = sharp stroke (default 15)
yabai -m config focus_ring_blur_bleed          0               # px; sample + frost the window's own edge outward (default 0 = off)
yabai -m config focus_ring_blur_feather        0               # px; soften the band mask's edges (default 0 = off)
yabai -m config focus_ring_blur_saturation     1.5             # 0.0..4.0; 1.0 = unchanged frost (default 1.5)
yabai -m config focus_ring_blur_brightness     0.5             # -1.0..1.0; 0.0 = unchanged frost (default 0.5)
yabai -m config focus_ring_blur_contrast       2.0             # 0.0..4.0; 1.0 = unchanged frost (default 2.0)
yabai -m config focus_ring_blur_hue            5               # 0..360 degrees; 0 = unchanged frost (default 5)
yabai -m config focus_ring_blur_color          inherit         # 0xAARRGGBB | inherit (frost tint; inherit = focus_ring_color)
yabai -m config focus_ring_blur_opacity        inherit         # 0.0..1.0 | inherit (frost tint alpha; inherit = focus_ring_opacity)
yabai -m config focus_ring_blend_mode          color-dodge     # tint-over-frost blend; values below (default color-dodge)
# focus_ring_blend_mode values: normal multiply screen overlay darken lighten color-dodge
#   color-burn soft-light hard-light difference exclusion hue saturation color luminosity

# Hard stroke overlaid on the frosted band
yabai -m config focus_ring_blur_stroke          on             # overlay a crisp stroke on the frosted band (default on)
yabai -m config focus_ring_blur_stroke_position above          # above | below the frosted band (default above)
yabai -m config focus_ring_blur_stroke_width    6              # stroke thickness in px, independent of the band (default 6)
yabai -m config focus_ring_blur_stroke_color    inherit        # 0xAARRGGBB | inherit (inherit = focus_ring_color)
yabai -m config focus_ring_blur_stroke_opacity  inherit        # 0.0..1.0 | inherit (inherit = focus_ring_opacity)

# Mission Control thumbnail strip
yabai -m config mission_control_thumbnails_enabled off         # reveal MC's spaces thumbnail strip on open (default off)
yabai -m space --toggle mission-control-thumbnails             # force the strip on for one invocation, regardless of config

# Directional focus (window --focus north|east|south|west)
# Floating-window focus on the current space works out of the box; these extend it:
yabai -m config window_focus_inter_display     off             # cross to the display in that direction (default off)
yabai -m config window_focus_wrap              off             # wrap to the opposite edge when nothing is in that direction (default off)
```

Every key above (and everything inherited from stock yabai) is documented in
this repo's [configuration reference](doc/yabai.asciidoc).

## Attribution and License

Built on [yabai](https://github.com/koekeishiya/yabai) by
[@koekeishiya](https://github.com/koekeishiya), licensed under the
[MIT License](LICENSE.txt). All upstream copyright and license notices are
preserved.
