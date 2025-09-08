# Space Padding Integration with Edge Threshold

## Overview

The enhanced anchoring debug system now automatically factors in space padding when determining edge relationships for window animations. This provides more accurate edge detection for anchoring calculations.

## Changes Made

### 1. Enhanced `analyze_screen_edges` Function

**Before:**

```c
static screen_edge_info analyze_screen_edges(CGRect window_rect, uint32_t display_id) {
    // Used hardcoded threshold and raw screen bounds
    float edge_threshold = 19.0f;
    CGRect screen_bounds = display_bounds_constrained(display_id, false);
}
```

**After:**

```c
static screen_edge_info analyze_screen_edges(CGRect window_rect, uint32_t display_id, struct view *view) {
    // Uses configurable threshold and accounts for space padding
    float edge_threshold = g_window_manager.window_animation_edge_threshold;

    CGRect effective_bounds = screen_bounds;
    if (view) {
        effective_bounds.origin.x += view->left_padding;
        effective_bounds.origin.y += view->top_padding;
        effective_bounds.size.width -= (view->left_padding + view->right_padding);
        effective_bounds.size.height -= (view->top_padding + view->bottom_padding);
    }
}
```

### 2. Key Improvements

- **Space Padding Awareness**: Edge calculations now use effective screen bounds that account for configured space padding
- **Configurable Threshold**: Uses `g_window_manager.window_animation_edge_threshold` instead of hardcoded value
- **Accurate Edge Detection**: Windows touching the effective edges (after padding) are correctly identified

### 3. Enhanced Debug Output

The debug output now includes a new section showing space padding information:

```
fdb SPACE PADDING:
fdb   padding: T=20.0 B=20.0 L=15.0 R=15.0
fdb   edge_threshold: 10.0 pixels
fdb   effective_screen: x=1935.0 y=45.0 w=1850.0 h=1115.0
```

## Benefits

1. **More Accurate Anchoring**: Edge detection now respects the actual usable space bounds
2. **Consistent Behavior**: Window animations align with the visual layout boundaries
3. **Configurable Precision**: Edge threshold can be tuned via configuration
4. **Better Debugging**: Space padding values are visible in debug output

## Configuration

The edge threshold can be configured via:

```bash
# Set edge threshold to 10 pixels
yabai -m config window_animation_edge_threshold 10.0
```

Space padding affects the effective screen bounds:

```bash
yabai -m config top_padding 20
yabai -m config bottom_padding 20
yabai -m config left_padding 15
yabai -m config right_padding 15
```

## Example Scenario

With space padding configured as `T=20, B=20, L=15, R=15` and edge threshold `10px`:

- A window at `y=25` (5px from effective top edge) will be detected as touching the top edge
- A window at `y=35` (15px from effective top edge) will NOT be detected as touching the top edge
- The effective screen bounds are automatically calculated and used for all edge detection

This ensures that anchoring behavior is consistent with the visual layout and respects the configured space boundaries.
