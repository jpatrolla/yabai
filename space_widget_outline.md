# Yabai Space Widget Development - Architecture & Implementation Guide

## **Current State Summary**

The yabai space widget is a visual indicator showing window/space states as clickable icons in a vertical strip on the left edge of the screen. Currently implemented with:

- **✅ DYNAMIC WINDOW LIST**: Real-time window IDs from current space via `space_window_list()`
- **✅ AUTO-REFRESH INTEGRATION**: Plugged into space_indicator update system for real-time updates
- **✅ MEMORY MANAGEMENT**: Fixed crash by properly copying window IDs from yabai's temp storage
- **✅ LIVE WORKSPACE VIEW**: Successfully shows real windows, updates on space changes, handles window creation/destruction
- **Individual icon rendering**: Each icon logs its window ID and app title to console when rendered
- **Adaptive layout**: Handles variable number of windows, with overflow protection for tall spaces
- **Basic click detection**: Global system in `event_loop.c` that detects clicks on the entire widget area
- **Centralized event processing**: Uses yabai's existing CGEventTap → `event_loop.c` → widget-specific logic flow
- **✅ CLEANED UP**: Removed legacy color cycling functions and unused API compatibility stubs
- **✅ FIXED**: Resolved CFStringRef casting warnings and build issues

## **Target Architecture (Next Phase)**

### **Event Flow Design**

```
User Click → CGEventTap → event_loop.c MOUSE_DOWN → space_widget_get_clicked_icon() → space_widget_handle_icon_interaction()
```

### **Key Functions to Implement**

**In `space_widget.c`:**

```c
// Icon hit detection - returns icon index or -1 if no hit
int space_widget_get_clicked_icon(struct space_widget *widget, CGPoint point);

// Handle specific icon interactions (click, focus window, etc.)
void space_widget_handle_icon_interaction(struct space_widget *widget, int icon_index, CGPoint point);

// Future: drag operations
void space_widget_handle_icon_drag(struct space_widget *widget, int icon_index, CGPoint start, CGPoint current);
```

**In `event_loop.c` MOUSE_DOWN handler enhancement:**

```c
if (g_space_widget.is_active) {
    int clicked_icon = space_widget_get_clicked_icon(&g_space_widget, point);
    if (clicked_icon >= 0) {
        space_widget_handle_icon_interaction(&g_space_widget, clicked_icon, point);
        goto out; // Consume the event
    }
}
```

## **Current File Structure**

- **`src/space_widget.c`**: Widget rendering, layout helpers, window ID array
- **`src/space_widget.h`**: Widget struct definitions and function declarations
- **`src/event_loop.c`**: Global event processing with basic widget click detection
- **`test_widget.py`**: Testing utility (generates synthetic clicks)
- **`debug_widget.sh`**: Manual testing script

## **Key Constants & Variables**

```c
#define WIDGET_GAP 8.0f
#define WIDGET_ICON_SIZE 44.0f

// Dynamic window list - populated from current space
static uint32_t *widget_window_ids = NULL;
static int widget_window_count = 0;
extern struct space_widget g_space_widget;
```

## **Current Helper Functions**

- **`widget_update_window_list()`**: Dynamically fetches windows from current space via `space_window_list()`
- **`space_widget_refresh()`**: Redraws widget with updated window list from current space
- **`widget_layout_calculate_positions()`**: Calculates x,y coordinates for variable number of icons with overflow handling
- **`widget_render_icon()`**: Renders individual icons with logging
- **`widget_get_app_title()`**: Retrieves window titles via SLS API
- **`widget_log_window_info()`**: Console logging for debugging

## **Refresh Integration Points** ✅ WORKING

The widget automatically refreshes in response to workspace changes:

- **`SPACE_CHANGED` event**: ✅ Updates when switching between spaces
- **`space_manager_focus_space()`**: ✅ Updates on successful space focus
- **`WINDOW_CREATED` event**: ✅ Updates when new windows appear in current space
- **`WINDOW_DESTROYED` event**: ✅ Updates when windows are removed

## **Development Priorities** - Next Phase

1. **✅ READY: Individual icon click detection** (infrastructure in place, just need hit testing)
2. **Icon-specific actions** (window focus, space switching, etc.)
3. **Enhanced interaction logging** (which icon was clicked)
4. **Future: Drag-and-drop** between icons
5. **Future: Window filtering** (by app type, window state, etc.)

## **Success Metrics** ✅ ACHIEVED

- **Real-time window tracking**: Widget shows actual windows from current space
- **Live updates**: Space changes immediately reflect new window sets
- **Memory safety**: No crashes during space switching or window changes
- **Performance**: Smooth updates without noticeable lag
- **Debug visibility**: Full logging of window operations and state changes

## **Integration Points**

- **Window Manager**: `window_manager_find_window()`, `window_manager_focus_window_in_direction()`
- **Space Manager**: `space_manager_focus_space()`, `window_space()`
- **Event System**: Existing CGEventTap in `mouse_handler.c` → `event_loop.c` flow

## **Questions for Implementation**

- Should clicking an icon focus the window, switch to its space, or both?
- How to handle invalid/closed window IDs gracefully?
- Visual feedback for icon interactions (hover states, click animations)?

---

**Use this document to maintain context across sessions and guide implementation toward the individual icon interaction architecture.**
