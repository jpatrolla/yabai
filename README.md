## About

This is a fork of [yabai](https://github.com/asmvik/yabai), showcasing a refactored window animation engine and a few other features/fixes that I thought were improvements.

It is my first C project &mdash; a learning exercise built on top of
asmvik's work. While I've done my best to minimise the slop, my real-world
C / low-level programming experience &mdash; and the best-practice set that
comes with it &mdash; is practically zero. Pair that with undocumented APIs and
even Claude is going to make mistakes. If you're reading or judging this code,
your safest bet is to take it as a prototype. Suggestions and feedback are very
welcome &mdash; feel free to open an issue.

## Requirements and Caveats

> :warning: **Use at your own risk.** This has only ever been built and run on a
> single machine:
>
> - **Mac mini (2023), Apple M2 Pro**
> - **Dual-display setup** &mdash; panels at 60 Hz and 144 Hz; ProMotion / variable-refresh displays untested
> - **macOS Tahoe 26.5**
> - **SIP disabling required**
>
> It has not been tested on any other hardware, display configuration, or macOS
> version. Expect rough edges &mdash; or outright breakage &mdash; anywhere else.

## Installation

For installation, configuration, and full usage, refer to the
[upstream yabai repository](https://github.com/asmvik/yabai) and its
[wiki](https://github.com/asmvik/yabai/wiki). **This README documents only
what is different here.**

<details>
<summary>Installation instructions</summary>

There are no packaged releases &mdash; build from source:

```bash
git clone https://github.com/jpatrolla/yabai.git
cd yabai
make install                          # release build -> ./bin/yabai
sudo cp ./bin/yabai /usr/local/bin/   # or anywhere on your PATH
```

Then load the scripting addition and start the service, exactly like stock
yabai (SIP setup and the sudoers entry are covered by the
[upstream wiki](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)):

```bash
sudo yabai --load-sa
yabai --start-service
```

**Switching from stock yabai (or rebuilding):** the scripting addition shipped
here is versioned differently from upstream's. Run `sudo yabai --reload-sa`
once to force the installed payload to be replaced and re-injected in a single
pass (`--load-sa` alone would need two passes).

</details>

<details>
<summary>Minimal config example</summary>

A few lines in your `yabairc` switch the animations on &mdash; the focus ring
is already on out of the box. This is the minimal config the fork is tested
and demoed with:

```bash
# Load the scripting addition (stock yabai preamble; use the full path to the
# binary if it is not on root's PATH)
yabai -m signal --add event=dock_did_restart action="sudo yabai --load-sa"
sudo yabai --load-sa

yabai -m config window_animation_duration      0.6             # windows glide on retile/resize
yabai -m config window_animation_easing        ease_out_expo
yabai -m config space_animation_duration       0.6             # animated space switches
yabai -m config space_focus_target_display     smart

# margins (stock yabai levers; shape managed bsp/stack layouts)
yabai -m config top_padding                    10
yabai -m config bottom_padding                 15
yabai -m config left_padding                   15
yabai -m config right_padding                  15
yabai -m config window_gap                     15
```

</details>

<details>
<summary>Full/extensive config levers</summary>

Every lever below is an addition on top of stock yabai. Animations are **off by
default** &mdash; set a duration to enable them.

```bash
# Window-frame animation (engine is off until duration > 0)
yabai -m config window_animation_duration      0.25            # seconds; 0.0 = instant (default)
yabai -m config window_animation_easing        ease_out_circ   # see https://easings.net
yabai -m config window_animation_min_opacity   0.85            # fade floor -> 1.0; 1.0 disables fade (default)
yabai -m config window_animation_ax_wake       on              # wake Chromium/Electron lazy AX tree (default on)

# Window-frame animation — advanced presentation levers
yabai -m config window_animation_policy        true_resize     # true_resize | lb_only (bounds-only presentation, no transform)

# Space transitions
yabai -m config space_animation_duration       0.25            # seconds; 0.0 = instant switch (default)
yabai -m config space_animation_gap            0               # points of floor showing between the spaces mid-slide (0..500; default 0)
yabai -m config space_animation_easing         ease_out_expo   # linear | smoothstep | ease_in | ease_out_expo (default ease_out_expo)
yabai -m config contain_space_focus_per_display on             # keep a defaulted space --focus on the current display (default on; off = stock walk)
yabai -m config space_animation_enter_delay    0.0             # delay (s) before the incoming space starts sliding
yabai -m config space_animation_exit_delay     0.0             # delay (s) before the outgoing space starts sliding
yabai -m config space_animation_animate_wallpaper off          # on = each wallpaper rides its own space; off = wallpaper floor stays put (default off)

# Mission Control
yabai -m config expose_animation_duration      -1              # MC enter/exit tween (s); 0 = instant, < 0 = native (default)
yabai -m config space_focus_target_display default             # default | mouse | smart — display a bare `space --focus prev|next` acts on

# Focus plumbing

# Focus ring (unlike the animations, this is ON by default)
# The ring is one frosted band around the focused window, washed with a color,
# plus an optional hard "inner stroke" hugging the window seam on its own layer.
yabai -m config focus_ring_enabled             on              # master on/off (default on)
yabai -m config focus_ring_width               10              # band thickness in px (default 10)
yabai -m config focus_ring_color               0xffffffff      # band color: 0xAARRGGBB | auto | system | a named accent (blue, red, ...); auto/system track the macOS accent (default white)
yabai -m config focus_ring_color_opacity       1.0             # band color wash alpha 0.0..1.0; 1 = solid color (default), 0 = pure frost
yabai -m config focus_ring_alpha               0.60            # whole-ring translucency 0.0..1.0; dims band + stroke + frost together (default 0.60)

# Band styling — these shape the frost, which shows through wherever
# color_opacity < 1.0. blur_radius is the only knob that genuinely blurs: it
# frosts what the band samples behind the window (0 = unblurred).
yabai -m config focus_ring_blur_radius         15              # frost blur radius in px (default 15)
yabai -m config focus_ring_bleed               0               # px; sample + frost the window's own edge outward (default 0 = off)
yabai -m config focus_ring_feather             0               # px; soften the band mask's edges (default 0 = off)
yabai -m config focus_ring_saturation          1.5             # 0.0..4.0; 1.0 = unchanged frost (default 1.5)
yabai -m config focus_ring_brightness          0.5             # -1.0..1.0; 0.0 = unchanged frost (default 0.5)
yabai -m config focus_ring_contrast            2.0             # 0.0..4.0; 1.0 = unchanged frost (default 2.0)
yabai -m config focus_ring_hue                 5               # 0..360 degrees; 0 = unchanged frost (default 5)
yabai -m config focus_ring_blend_mode          normal          # color-wash-over-frost blend; values below (default normal — color-dodge etc. blow bright hues toward white)
# focus_ring_blend_mode values: normal multiply screen overlay darken lighten color-dodge
#   color-burn soft-light hard-light difference exclusion hue saturation color luminosity

# Inner stroke — a crisp stroke on its own layer, hugging the band's inner edge (the window seam)
yabai -m config focus_ring_inner_stroke          on            # overlay the stroke (default on)
yabai -m config focus_ring_inner_stroke_position above         # above | below the band (default above)
yabai -m config focus_ring_inner_stroke_width    6             # stroke thickness in px, independent of the band (default 6)
yabai -m config focus_ring_inner_stroke_color    inherit       # 0xAARRGGBB | a named accent | inherit (inherit = focus_ring_color)
yabai -m config focus_ring_inner_stroke_opacity  inherit       # 0.0..1.0 | inherit (inherit = focus_ring_color_opacity)

# Mission Control spaces strip
yabai -m config mission_control_always_show_spaces_strip_enabled off  # reveal MC's spaces thumbnail strip on open (default off)
yabai -m space --toggle mission-control-show-strip                    # force the strip on for one invocation, regardless of config

# Directional focus (window --focus north|east|south|west)
yabai -m config window_focus_for_floating_enabled on           # resolve floating windows / float+stack spaces by geometry when the BSP walk misses (default on)
yabai -m config window_focus_inter_display     off             # cross to the display in that direction (default off)
yabai -m config window_focus_wrap              off             # wrap to the opposite edge when nothing is in that direction (default off)
```

Every key above (and everything inherited from stock yabai) is documented in
this repo's [configuration reference](doc/yabai.asciidoc).

</details>

## Main Features

#### Window-frame animation engine
Replaces yabai's proxy-swap animator (CVDisplayLink) with a Core Animation&ndash;driven engine (CADisplayLink) that simulates a true resize, so windows glide when retiled or resized instead of snapping. Refer to the `window_animation_*` config levers.

#### Animated space transitions
Space animations built from the ground up to be fully customisable: adjacent spaces slide across the display as whole spaces &mdash; windows, menubar backdrop and fullscreen chrome ride along &mdash; over a persistent wallpaper floor that fills the gap between them. Driven by the `space_animation_*` config levers.

<details>
<summary>Three starting points</summary>

```bash
# 1 — stock yabai: the default instant switch (animations off)
yabai -m config space_animation_duration   0.0

# 2 — closest to the native macOS slide
yabai -m config space_animation_duration   0.8
yabai -m config space_animation_animate_wallpaper on       # each wallpaper rides its own space
yabai -m config space_animation_easing     ease_out_expo

# 3 — spaces sliding over a static wallpaper
yabai -m config space_animation_duration   0.6
yabai -m config space_animation_animate_wallpaper off      # wallpaper floor holds still (default)
yabai -m config space_animation_gap        40              # let the floor show between the spaces
yabai -m config space_animation_easing     ease_out_expo
```

</details>

#### Focus ring
A built-in borders replacement, fully integrated with the window animations &mdash; the ring rides alongside them. On by default; refer to the `focus_ring_*` config levers.

## Smaller features/fixes

#### Window-server focus resolution
The "which window is focused?" logic is refactored onto the window server's `SLSWindowQuery*` + `SLPSGetKeyFocusProcess` SPIs instead of Accessibility &mdash; a richer, faster, z-ordered query scoped to the process that actually holds key focus, and it drives yabai's tracked focus state. It stays reliable under fast focus churn and when native tabs switch, where the Accessibility read lags or goes silent. The same resolution decides where focus lands: switching to a space refocuses the window last used there (else its topmost eligible window), and closing an app's last window on a space advances focus instead of stranding it. Always on.

#### Mission Control spaces strip
`space --toggle mission-control` can reveal Mission Control's spaces thumbnail strip on open, gated by the `mission_control_always_show_spaces_strip_enabled` config (or forced for one invocation with `space --toggle mission-control-show-strip`).

#### Directional focus for floating windows
`window --focus north|east|south|west` resolves by window geometry when the BSP walk comes up empty, so it works for floating windows (and float/stack spaces), not just managed ones &mdash; on by default; set `window_focus_for_floating_enabled` off for the stock managed-only walk. Two further opt-in extensions (both default off): `window_focus_inter_display` hops to the closest window on the display in that direction, and `window_focus_wrap` wraps to the farthest window in the opposite direction when nothing lies that way.

#### Space operations on macOS Tahoe
Space creation, destruction, and moves run through SkyLight SPIs (`SLSSpaceCreate`, `SLSSpaceDestroy`, and a managed-space move transaction) instead of the version-pinned byte-pattern scans and handrolled assembly the stock scripting addition relies on &mdash; so `space --create|--destroy|--move|--display` keep working across macOS updates, Tahoe included, without per-release offset patches.

## Multi-display enhancements/fixes

#### Contained space switching
`contain_space_focus_per_display` fixes an issue where `space --focus next|prev` unexpectedly focuses spaces on other displays. Enabled (the default), it contains space switches to the active display: at the edge of its spaces the current space animates a gentle nudge instead of crossing over. Set it off for the stock global walk.

#### Empty-display focus
`display --focus` now works on empty displays / spaces with no windows. As a byproduct, switching between spaces with no windows is fixed too.

#### Display targeting for bare space switches
Which display a bare `space --focus prev|next` acts on is configurable: `mouse` targets the display under the cursor; `smart` does so only when the last focus change came from the mouse, so keyboard-driven focus keeps the active display. Refer to the `space_focus_target_display` config lever.

#### Per-display animation timing
Each display's refresh timing is cached and paces the animations on that display, so a mixed-refresh setup animates every display at its native rate. Developed on 60 Hz and 144 Hz panels; ProMotion / variable-refresh displays read the same timing path but are untested.

## Attribution and License

Built on [yabai](https://github.com/asmvik/yabai) by
[@asmvik](https://github.com/asmvik), licensed under the
[MIT License](LICENSE.txt). All upstream copyright and license notices are
preserved.
