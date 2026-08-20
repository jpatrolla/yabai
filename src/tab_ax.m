#include "tab_ax.h"

extern AXError _AXUIElementGetWindow(AXUIElementRef ref, uint32_t *wid);

static void ax_copy_string(AXUIElementRef element, CFStringRef attribute, char *dst, size_t size)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return;
    if (!value) return;

    if (CFGetTypeID(value) == CFStringGetTypeID()) {
        CFStringGetCString(value, dst, size, kCFStringEncodingUTF8);
    }

    CFRelease(value);
}

static int ax_copy_int(AXUIElementRef element, CFStringRef attribute)
{
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess) return -1;
    if (!value) return -1;

    int result = -1;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        int number = 0;
        if (CFNumberGetValue(value, kCFNumberIntType, &number)) result = number;
    } else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue(value) ? 1 : 0;
    }

    CFRelease(value);
    return result;
}

static bool ax_element_frame(AXUIElementRef element, CGRect *frame)
{
    CFTypeRef position_ref = NULL;
    CFTypeRef size_ref = NULL;
    bool result = false;

    AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &position_ref);
    AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &size_ref);

    if (position_ref && size_ref) {
        result = AXValueGetValue(position_ref, kAXValueTypeCGPoint, &frame->origin) &&
                 AXValueGetValue(size_ref,     kAXValueTypeCGSize,  &frame->size);
    }

    if (position_ref) CFRelease(position_ref);
    if (size_ref)     CFRelease(size_ref);

    return result;
}

static AXUIElementRef tab_ax_find_group(AXUIElementRef window_ref)
{
    CFArrayRef children = NULL;
    if (AXUIElementCopyAttributeValue(window_ref, kAXChildrenAttribute, (CFTypeRef *) &children) != kAXErrorSuccess) return NULL;

    AXUIElementRef group = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(children) && !group; ++i) {
        AXUIElementRef child = CFArrayGetValueAtIndex(children, i);

        CFStringRef role = NULL;
        if (AXUIElementCopyAttributeValue(child, kAXRoleAttribute, (CFTypeRef *) &role) != kAXErrorSuccess) continue;
        if (CFEqual(role, kAXTabGroupRole)) group = (AXUIElementRef) CFRetain(child);
        CFRelease(role);
    }

    CFRelease(children);
    return group;
}

// NOTE: the AXTabGroup IS the NSTabBar view, and its hit-test area is exactly the region
// AppKit claims for a tab drop on an app that does not adopt NSTabDraggingWindowDestination —
// NSTabBar is the only AppKit view conforming to NSTabDraggingDestination.
bool tab_ax_bar_bounds(AXUIElementRef window_ref, CGRect *bounds)
{
    if (!window_ref) return false;

    AXUIElementRef group = tab_ax_find_group(window_ref);
    if (!group) return false;

    bool result = ax_element_frame(group, bounds);
    CFRelease(group);
    return result;
}

// NOTE: the bar's trailing "+" is an AXButton and not in AXTabs, so the count is the tab
// count exactly. Prefer GetAttributeValueCount over copying the array — one IPC, no CFArray.
static bool tab_ax_read(AXUIElementRef window_ref, struct tab_ax_info *info)
{
    info->count = -1;
    info->selected = 0;
    if (!window_ref) return false;

    AXUIElementRef group = tab_ax_find_group(window_ref);
    if (!group) return false;

    CFIndex count = 0;
    if (AXUIElementGetAttributeValueCount(group, kAXTabsAttribute, &count) == kAXErrorSuccess) info->count = (int) count;

    // NOTE: every tab button answers _AXUIElementGetWindow with the ANCHOR wid, so a
    // background tab cannot be identified this way — but the selected tab IS the anchor,
    // which makes this exact for the one tab a caller can act on.
    if (info->count > 0) {
        CFArrayRef tabs = NULL;
        if (AXUIElementCopyAttributeValue(group, kAXTabsAttribute, (CFTypeRef *) &tabs) == kAXErrorSuccess) {
            for (CFIndex i = 0; i < CFArrayGetCount(tabs) && !info->selected; ++i) {
                AXUIElementRef tab = CFArrayGetValueAtIndex(tabs, i);
                if (ax_copy_int(tab, kAXValueAttribute) > 0) _AXUIElementGetWindow(tab, &info->selected);
            }
            CFRelease(tabs);
        }
    }

    CFRelease(group);
    return info->count >= 0;
}

// NOTE: the bar hangs off the window that anchors the group, which is whichever tab is on
// screen — the app's focused window. A background tab publishes no bar of its own.
bool tab_ax_read_app(AXUIElementRef app_ref, struct tab_ax_info *info)
{
    info->count = -1;
    info->selected = 0;
    if (!app_ref) return false;

    AXUIElementRef window_ref = NULL;
    if (AXUIElementCopyAttributeValue(app_ref, kAXFocusedWindowAttribute, (CFTypeRef *) &window_ref) != kAXErrorSuccess) return false;

    bool result = tab_ax_read(window_ref, info);
    CFRelease(window_ref);
    return result;
}

// NOTE: AX hit-tests and AXPosition take top-left screen coords — the same origin
// CGEventGetLocation reports, so no flip anywhere below. Resolved once at MOUSE_DOWN and
// held: mid-gesture the cursor names whatever it is over now, not the control pressed.
static struct
{
    bool armed;
    bool secondary;
    uint32_t wid;
    bool tearoff_logged;
    bool has_bar_bounds;
    AXUIElementRef element;
    CGRect bar_bounds;
    CGPoint down_point;
    char role[64];
    char title[128];
} g_click_probe;

// NOTE: the press lands on whatever descendant of the bar is under it — tab button, close X,
// title text — and only the AXTabGroup ancestor carries the bar's own frame; matching one
// role would recognise a grab from the button alone and miss every other one.
static bool ax_probe_tab_bar_bounds(AXUIElementRef element, CGRect *bounds, int *count)
{
    AXUIElementRef node = (AXUIElementRef) CFRetain(element);
    bool result = false;

    *count = 0;
    for (int depth = 0; depth < 5; ++depth) {
        char role[64] = {0};
        ax_copy_string(node, kAXRoleAttribute, role, sizeof(role));
        if (strcmp(role, "AXTabGroup") == 0) {
            CFIndex tabs = 0;
            if (AXUIElementGetAttributeValueCount(node, kAXTabsAttribute, &tabs) == kAXErrorSuccess) *count = (int) tabs;
            result = ax_element_frame(node, bounds);
            break;
        }
        if (strcmp(role, "AXWindow") == 0) break;

        CFTypeRef parent = NULL;
        AXUIElementCopyAttributeValue(node, kAXParentAttribute, &parent);
        if (!parent) break;
        if (CFGetTypeID(parent) != AXUIElementGetTypeID()) { CFRelease(parent); break; }

        CFRelease(node);
        node = (AXUIElementRef) parent;
    }

    CFRelease(node);
    return result;
}

static void ax_probe_click_reset(void)
{
    if (g_click_probe.element) CFRelease(g_click_probe.element);
    memset(&g_click_probe, 0, sizeof(g_click_probe));
}

void ax_probe_click_target(CGPoint point, bool secondary, bool native_tabbable)
{
    ax_probe_click_reset();
    if (!native_tabbable) return;

    static AXUIElementRef systemwide;
    if (!systemwide) systemwide = AXUIElementCreateSystemWide();

    uint64_t arrive_ns = read_os_timer();

    AXUIElementRef element = NULL;
    if (AXUIElementCopyElementAtPosition(systemwide, point.x, point.y, &element) != kAXErrorSuccess) return;
    if (!element) return;

    snprintf(g_click_probe.role,  sizeof(g_click_probe.role),  "?");
    snprintf(g_click_probe.title, sizeof(g_click_probe.title), "?");
    ax_copy_string(element, kAXRoleAttribute,  g_click_probe.role,  sizeof(g_click_probe.role));
    ax_copy_string(element, kAXTitleAttribute, g_click_probe.title, sizeof(g_click_probe.title));

    g_click_probe.armed      = true;
    g_click_probe.secondary  = secondary;
    g_click_probe.down_point = point;

    // NOTE: the hit element carries the wid of the tab it belongs to even when that tab is not
    // on screen yet — the one naming of the grabbed window available before the click swaps it.
    g_click_probe.wid            = ax_window_id(element);

    int tab_count = 0;
    g_click_probe.has_bar_bounds = ax_probe_tab_bar_bounds(element, &g_click_probe.bar_bounds, &tab_count);

    debug("AX_CLICK_TARGET: role=%s title=\"%s\" wid=%u button=%s at=%.0f,%.0f tabs=%d bar=(%.0f,%.0f %.0fx%.0f) probe_us=%llu\n",
          g_click_probe.role, g_click_probe.title, ax_window_id(element),
          secondary ? "right" : "left", point.x, point.y, tab_count,
          g_click_probe.bar_bounds.origin.x, g_click_probe.bar_bounds.origin.y,
          g_click_probe.bar_bounds.size.width, g_click_probe.bar_bounds.size.height,
          (read_os_timer() - arrive_ns) / 1000);

    g_click_probe.element = (AXUIElementRef) CFRetain(element);
    CFRelease(element);
}

void ax_probe_click_drag(CGPoint point)
{
    if (!g_click_probe.armed)          return;
    if (!g_click_probe.has_bar_bounds) return;
    if (g_click_probe.secondary)       return;
    if (g_click_probe.tearoff_logged)  return;

    if (CGRectContainsPoint(g_click_probe.bar_bounds, point)) return;

    g_click_probe.tearoff_logged = true;

    // NOTE: for a NON-selected tab _AXUIElementGetWindow answers the window hosting the bar
    // until AppKit materializes the tab's own window, so the mouse-down read names the tab that
    // stays. By the bar exit the swap has landed. Keep the old id if the element declines.
    uint32_t torn_wid = g_click_probe.element ? ax_window_id(g_click_probe.element) : 0;
    if (torn_wid && torn_wid != g_click_probe.wid) {
        debug("%s: grabbed wid %d -> %d\n", __FUNCTION__, g_click_probe.wid, torn_wid);
        g_click_probe.wid = torn_wid;
    }

    debug("AX_ANTICIPATE_TEAROFF: title=\"%s\" at=%.0f,%.0f bar=(%.0f,%.0f %.0fx%.0f) dx=%.0f dy=%.0f arrive_ns=%llu\n",
          g_click_probe.title, point.x, point.y,
          g_click_probe.bar_bounds.origin.x, g_click_probe.bar_bounds.origin.y,
          g_click_probe.bar_bounds.size.width, g_click_probe.bar_bounds.size.height,
          point.x - g_click_probe.down_point.x, point.y - g_click_probe.down_point.y,
          read_os_timer());
}

bool ax_probe_click_was_tab(void)
{
    return g_click_probe.has_bar_bounds;
}

bool ax_probe_click_in_bar(CGPoint point)
{
    return g_click_probe.has_bar_bounds && CGRectContainsPoint(g_click_probe.bar_bounds, point);
}

uint32_t ax_probe_click_wid(void)
{
    return g_click_probe.has_bar_bounds ? g_click_probe.wid : 0;
}

// NOTE: leaving the bar with a tab grabbed IS the tear — true before AppKit orders anything
// out, and it names no window, so a mid-gesture hand-off cannot invalidate it. Latched: a tab
// dragged back re-merges rather than tearing off, so the drop side cancels on containment.
bool ax_probe_click_torn(void)
{
    return g_click_probe.tearoff_logged;
}

void ax_probe_click_end(void)
{
    g_click_probe.armed = false;
    if (g_click_probe.element) { CFRelease(g_click_probe.element); g_click_probe.element = NULL; }
}
