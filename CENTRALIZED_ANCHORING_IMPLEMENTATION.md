# Centralized Anchoring System Implementation

## Overview

Successfully replaced all hardcoded anchoring logic with calls to the centralized `calculate_unified_anchor` function throughout the window animation system.

## Changes Made

### 1. Frame-Based Asynchronous Animation (`window_manager_animate_window_list_frame_based_async`)

**Before**: Complex hardcoded logic checking for swap operations, movement direction, and edge alignment

```c
// Old hardcoded logic
if (window_count == 2) {
    // Check if this is likely a swap operation
    bool is_swap = ((src_x < other_src_x && dst_x > other_dst_x) || ...);
    if (is_swap) {
        // Edge movement calculations
        float left_edge_movement = fabsf(src_x - dst_x);
        // ... manual anchor assignment
    } else {
        bool moves_right = (dst_x > src_x);
        bool moves_down = (dst_y > src_y);
        // ... manual anchor assignment based on movement
    }
}
```

**After**: Clean call to centralized system

```c
// Use centralized anchoring system for all animations
CGRect start_rect = context->animation_list[i].original_frame;
CGRect end_rect = CGRectMake(context->animation_list[i].x, context->animation_list[i].y,
                           context->animation_list[i].w, context->animation_list[i].h);

// Get the parent split if available from the window's node
enum window_node_split parent_split = SPLIT_NONE;
struct view *view = window_manager_find_managed_window(&g_window_manager, context->animation_list[i].window);
if (view && view->root) {
    struct window_node *node = view_find_window_node(view, context->animation_list[i].wid);
    if (node && node->parent) {
        parent_split = node->parent->split;
    }
}

// Use unified anchoring system
unified_anchor_info anchor = calculate_unified_anchor(start_rect, end_rect,
                                                    parent_split,
                                                    g_window_manager.window_animation_edge_threshold,
                                                    NULL);

// Set resize_anchor from centralized calculation
context->animation_list[i].resize_anchor = unified_anchor_to_legacy_resize_anchor(anchor);
```

### 2. Frame-Based Synchronous Animation (`window_manager_animate_window_frame_based`)

**Before**: Similar hardcoded logic duplicated from async version
**After**: Same centralized approach with proper view lookup

## Benefits

### 1. **Consistency**

- All animation types now use the same anchoring logic
- No more divergent behavior between different animation modes
- Centralized priority system (Bottom > Top > Left > Right) applied everywhere

### 2. **Maintainability**

- Single source of truth for anchoring decisions
- Easier to modify anchoring behavior across all animation types
- Reduced code duplication

### 3. **Advanced Features**

- **Stationary Edge Prioritization**: Automatically detects which edges don't move and anchors to them
- **Space Padding Integration**: Factors in view padding when determining edge relationships
- **BSP Tree Context**: Uses parent split information for smarter anchoring decisions
- **Configuration Override Support**: Respects force anchor settings and stacked window overrides

### 4. **Enhanced Debug Output**

- All animations now show centralized anchor calculations
- Debug messages indicate which system calculated the anchor
- Easier to troubleshoot anchoring issues

## Debug Messages

Look for these messages to verify the centralized system is working:

```
🔗 Frame-sync: Window 12345 centralized anchor=2 parent_split=1
🔗 Frame-async: Window 12345 centralized anchor=0 parent_split=0
🔗 Prioritizing stationary BOTTOM edge for anchoring
PRIORITY: BL are stationary -> anchor to stationary edge!
```

## Testing

Use the provided test script:

```bash
./test_centralized_anchoring.sh
```

This will:

1. Install the updated binary
2. Configure frame-based animations
3. Perform various window operations
4. Show debug output confirming centralized anchoring is active

## Technical Notes

- The centralized system receives parent split information from the BSP tree
- Frame-based animations pass `NULL` for the animation struct parameter
- Legacy resize anchor compatibility is maintained via `unified_anchor_to_legacy_resize_anchor()`
- View lookup is performed to get BSP tree context for better anchoring decisions

## Impact

This change ensures that all animations benefit from the sophisticated stationary edge prioritization system, providing more stable and predictable window animations across all scenarios.
