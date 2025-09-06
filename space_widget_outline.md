# Yabai Space Widget Development - Architecture & Implementation Guide

## **Current State Summary**

The yabai space widget is a visual indicator showing window/space states as clickable icons in a vertical strip on the left edge of the screen. Currently implemented with:

- **✅ DYNAMIC WINDOW LIST**: Real-time window IDs from current space via `space_window_list()`
- **✅ AUTO-REFRESH INTEGRATION**: Plugged into space_indicator update system for real-time updates
- **✅ MEMORY MANAGEMENT**: Fixed crash by properly copying window IDs from yabai's temp storage
- **✅ LIVE WORKSPACE VIEW**: Successfully shows real windows, updates on space changes, handles window creation/destruction
- **✅ SPACE INDICATOR CONFIG SYSTEM**: Full configuration support for space_indicator with key-value pairs
- **Individual icon rendering**: Each icon logs its window ID and app title to console when rendered
- **Adaptive layout**: Handles variable number of windows, with overflow protection for tall spaces
- **Basic click detection**: Global system in `event_loop.c` that detects clicks on the entire widget area
- **Centralized event processing**: Uses yabai's existing CGEventTap → `event_loop.c` → widget-specific logic flow
- **✅ CLEANED UP**: Removed legacy color cycling functions and unused API compatibility stubs
- **✅ FIXED**: Resolved CFStringRef casting warnings and build issues

## **🎯 LATEST ADDITIONS - Space Indicator Configuration**

### **✅ Complete Config System Implementation**

Added full configuration support for `space_indicator` with key-value pair syntax:

```bash
# Configure space indicator with key-value pairs
yabai -m config space_indicator enabled=true indicator_height=12.0 position=top indicator_color=0xff00ff00

# Query current configuration
yabai -m config space_indicator
# Returns: enabled=true indicator_height=12.00 position=top indicator_color=0xff00ff00
```

### **✅ Configuration Options**

- **`enabled=<true|false>`**: Enable/disable the space indicator
- **`indicator_height=<FLOAT>`**: Height of the indicator bar (0.1-50.0 pixels)
- **`position=<top|bottom>`**: Position on screen (top or bottom edge)
- **`indicator_color=0xAARRGGBB`**: Color in hex format (with alpha channel)

### **✅ Implementation Details**

- **Enhanced struct**: `space_indicator_config` embedded in `space_indicator` struct
- **Config persistence**: Real-time application of config changes
- **Color support**: Proper RGBA extraction and application from hex values
- **Validation**: Input validation with error messages for invalid values
- **Default values**: White color (0xffffffff), 8.0px height, bottom position, disabled by default

### **✅ Technical Improvements**

- **Dynamic redraw**: `space_indicator_redraw()` function ensures color persists through animations
- **Config-aware updates**: All indicator operations respect configuration settings
- **Memory safety**: Proper initialization and error handling
- **Animation integration**: Color and size changes work seamlessly with existing animations

### **✅ Mission Control Enhancements**

Enhanced `space_manager_toggle_mission_control()` with proper cursor management:

```c
// Hide cursor when moving to Mission Control position
CGDisplayHideCursor(CGMainDisplayID());

// Show cursor when restoring position
CGDisplayShowCursor(CGMainDisplayID());
```

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
- **`src/space_indicator.c`**: ✅ **ENHANCED** - Space indicator with full config system and color management
- **`src/space_indicator.h`**: ✅ **ENHANCED** - Config struct and function declarations
- **`src/space_manager.c`**: ✅ **ENHANCED** - Config initialization and Mission Control cursor management
- **`src/message.c`**: ✅ **ENHANCED** - Config command parsing with key-value pair support
- **`src/event_loop.c`**: Global event processing with basic widget click detection
- **`test_widget.py`**: Testing utility (generates synthetic clicks)
- **`debug_widget.sh`**: Manual testing script

## **Key Constants & Variables**

```c
// Space Widget
#define WIDGET_GAP 8.0f
#define WIDGET_ICON_SIZE 44.0f

// Space Indicator - ✅ CONFIGURABLE
struct space_indicator_config {
    bool enabled;
    float indicator_height;     // Configurable 0.1-50.0
    int position;              // 0=top, 1=bottom
    uint32_t indicator_color;  // 0xAARRGGBB format
};

// Dynamic window list - populated from current space
static uint32_t *widget_window_ids = NULL;
static int widget_window_count = 0;
extern struct space_widget g_space_widget;
extern struct space_indicator g_space_indicator; // ✅ WITH CONFIG
```

## **Current Helper Functions**

- **`widget_update_window_list()`**: Dynamically fetches windows from current space via `space_window_list()`
- **`space_widget_refresh()`**: Redraws widget with updated window list from current space
- **`widget_layout_calculate_positions()`**: Calculates x,y coordinates for variable number of icons with overflow handling
- **`widget_render_icon()`**: Renders individual icons with logging
- **`widget_get_app_title()`**: Retrieves window titles via SLS API
- **`widget_log_window_info()`**: Console logging for debugging

### **✅ NEW: Space Indicator Functions**

- **`space_indicator_create()`**: Creates indicator with config-driven dimensions and colors
- **`space_indicator_redraw()`**: Redraws indicator with current config colors (fixes color persistence)
- **`space_indicator_update()`**: Updates indicator position with config-aware positioning
- **`space_indicator_refresh()`**: Applies config changes and redraws
- **`parse_key_value_pair()`**: Parses config arguments (enabled=true, color=0xff00ff00, etc.)

### **✅ NEW: Mission Control Enhancements**

- **`space_manager_toggle_mission_control()`**: Enhanced with proper cursor hiding/showing
- **`CGDisplayHideCursor()`**: Hides cursor when entering Mission Control
- **`CGDisplayShowCursor()`**: Shows cursor when exiting Mission Control

## **Refresh Integration Points** ✅ WORKING

The widget automatically refreshes in response to workspace changes:

- **`SPACE_CHANGED` event**: ✅ Updates when switching between spaces
- **`space_manager_focus_space()`**: ✅ Updates on successful space focus
- **`WINDOW_CREATED` event**: ✅ Updates when new windows appear in current space
- **`WINDOW_DESTROYED` event**: ✅ Updates when windows are removed

## **Development Priorities** - Next Phase

### **✅ COMPLETED**

1. **Space Indicator Configuration System** - Full key-value config support
2. **Color Persistence Fix** - Indicator maintains color through animations and updates
3. **Mission Control Cursor Management** - Proper cursor hiding/showing during MC transitions
4. **Config Validation** - Input validation with helpful error messages

### **🎯 CURRENT PRIORITIES**

1. **Individual icon click detection** (infrastructure in place, just need hit testing)
2. **Icon-specific actions** (window focus, space switching, etc.)
3. **Enhanced interaction logging** (which icon was clicked)

### **🔮 FUTURE ENHANCEMENTS**

4. **Drag-and-drop** between icons
5. **Window filtering** (by app type, window state, etc.)
6. **Space Widget Configuration** - Apply same config system to space_widget
7. **Advanced Indicator Features** - Multiple indicators, per-display configuration

## **Success Metrics** ✅ ACHIEVED

### **Core Functionality**

- **Real-time window tracking**: Widget shows actual windows from current space
- **Live updates**: Space changes immediately reflect new window sets
- **Memory safety**: No crashes during space switching or window changes
- **Performance**: Smooth updates without noticeable lag
- **Debug visibility**: Full logging of window operations and state changes

### **✅ NEW: Configuration System**

- **Complete config coverage**: All space_indicator properties configurable
- **Runtime configuration**: Changes apply immediately without restart
- **Persistent colors**: Indicator color maintained through all operations
- **Validation**: Comprehensive input validation with helpful error messages
- **Backward compatibility**: Default values preserve existing behavior

### **✅ NEW: User Experience**

- **Intuitive syntax**: Key-value pairs match yabai's existing config patterns
- **Visual feedback**: Immediate visual changes when config is modified
- **Cursor management**: Clean cursor behavior during Mission Control transitions
- **Error handling**: Clear error messages for invalid configurations

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
