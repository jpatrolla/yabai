#!/usr/bin/env sh
# Colors the focus ring by the focused window's layout state.
# Subscribed to window_flags_changed (carries YABAI_WINDOW_STATE) and
# window_focused (does not — the jq ladder below derives it).

COLOR_PIP=0xffff6b6b
COLOR_STICKY=0xffffa94d
COLOR_FULLSCREEN_ZOOM=0xffb197fc
COLOR_PARENT_ZOOM=0xff74c0fc
COLOR_STACK=0xff63e6be
COLOR_MANAGED=0xffffffff
COLOR_DEFAULT=0xff868e96

CACHE="${TMPDIR:-/tmp}/yabai_focus_ring_color"

state="$YABAI_WINDOW_STATE"

if [ -z "$state" ]; then
    [ -z "$YABAI_WINDOW_ID" ] && exit 0
    state=$(yabai -m query --windows \
              is-pip,is-sticky,has-fullscreen-zoom,has-parent-zoom,stack-index,split-child \
              --window "$YABAI_WINDOW_ID" 2>/dev/null \
            | jq -r '
                if   ."is-pip"                then "pip"
                elif ."is-sticky"             then "sticky"
                elif ."has-fullscreen-zoom"   then "fullscreen_zoom"
                elif ."has-parent-zoom"       then "parent_zoom"
                elif (."stack-index" > 0)     then "stack"
                elif ."split-child" != "none" then "managed"
                else "default" end')
    [ -z "$state" ] && exit 0
fi

case "$state" in
    pip)             color=$COLOR_PIP ;;
    sticky)          color=$COLOR_STICKY ;;
    fullscreen_zoom) color=$COLOR_FULLSCREEN_ZOOM ;;
    parent_zoom)     color=$COLOR_PARENT_ZOOM ;;
    stack)           color=$COLOR_STACK ;;
    managed)         color=$COLOR_MANAGED ;;
    *)               color=$COLOR_DEFAULT ;;
esac

# focus_ring_set_color re-pushes the whole SHOW wire to the payload, so skip
# the write when the color is unchanged.
[ -f "$CACHE" ] && [ "$(cat "$CACHE")" = "$color" ] && exit 0

yabai -m config focus_ring_color "$color"
printf '%s' "$color" > "$CACHE"
