#ifndef TAB_AX_H
#define TAB_AX_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>

// NOTE: the native-tab bar as AX exposes it — an AXTabGroup whose AXTabs are one
// AXRadioButton per tab. It is the only tab-group surface macOS publishes: SLS knows
// nothing of tabs, and a hidden tab's server-side frame goes stale when its group moves.

struct tab_ax_info
{
    int count;          // tabs in the bar, -1 when the window has no tab bar
    uint32_t selected;  // wid of the tab on screen, 0 when not asked for / unknown
};

bool tab_ax_bar_bounds(AXUIElementRef window_ref, CGRect *bounds);
bool tab_ax_read_app(AXUIElementRef app_ref, struct tab_ax_info *info);

// The click probe: one AX hit-test at MOUSE_DOWN names what was pressed and caches the tab
// bar's frame, and the gesture is then read off that latch — a tab riding AppKit's drag proxy
// is not a window yabai places, so nothing downstream may re-hit-test mid-gesture.
void ax_probe_click_target(CGPoint point, bool secondary, bool native_tabbable);
void ax_probe_click_drag(CGPoint point);
bool ax_probe_click_was_tab(void);
bool ax_probe_click_torn(void);
bool ax_probe_click_in_bar(CGPoint point);
uint32_t ax_probe_click_wid(void);
void ax_probe_click_end(void);

#endif
