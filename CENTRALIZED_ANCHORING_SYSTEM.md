# Centralized Split-Aware Common-Edge Anchoring System

## Overview

This implementation provides a unified anchoring system for window animations in yabai that replaces all previous anchor calculation methods. The system automatically detects the optimal anchor point for window transitions based on split context, common edges, operation type, and configuration overrides.

## Key Features

### 1. **Unified Anchor Calculation**

- Single source of truth: `calculate_unified_anchor()` function
- Replaces multiple legacy functions with one comprehensive system
- Handles all edge cases and fallback scenarios

### 2. **Smart Operation Detection**

- **Resize**: Size changes significantly larger than position changes
- **Translate**: Position changes significantly larger than size changes
- **Mixed**: Balanced changes in both position and size

### 3. **Split-Aware Anchoring**

- **SPLIT_Y (Horizontal splits)**: Prefers top/bottom edge anchoring
- **SPLIT_X (Vertical splits)**: Prefers left/right edge anchoring
- **SPLIT_NONE**: Uses center or corner anchoring

### 4. **Common Edge Preservation**

Priority-based edge detection with configurable threshold:

1. **Corner anchors**: Two common edges (top-left, top-right, bottom-left, bottom-right)
2. **Edge anchors**: Single common edge (top, bottom, left, right)
3. **Split fallback**: Uses split context when no common edges found

### 5. **Configuration Override Support**

- Force anchor overrides: top, bottom, left, right
- Stacked window overrides: separate settings for top/bottom stacked windows
- Edge threshold: configurable pixel tolerance for edge detection

### 6. **Multi-Monitor Handling**

- Automatic detection of monitor boundary crossings
- Special easing for smooth transitions between displays
- Distance-based heuristics for monitor detection

### 7. **Constraint Enforcement**

- Minimum size constraints (100px width, 50px height)
- Container bounds enforcement (display bounds)
- Rounding and edge case handling

## Architecture

### Core Data Structures

```c
typedef enum {
    WINDOW_OPERATION_RESIZE,
    WINDOW_OPERATION_TRANSLATE,
    WINDOW_OPERATION_MIXED
} window_operation_type;

typedef struct {
    bool has_common_top, has_common_bottom;
    bool has_common_left, has_common_right;
    float anchor_x, anchor_y;              // Absolute coordinates
    window_operation_type operation_type;
    bool use_split_fallback;
    bool crosses_monitors;
    int legacy_resize_anchor;              // For compatibility
} unified_anchor_info;
```

### Main Functions

1. **`calculate_unified_anchor()`** - Main anchor calculation
2. **`interpolate_with_unified_anchor()`** - Anchor-based interpolation
3. **`detect_operation_type()`** - Classify the window operation
4. **`detect_monitor_crossing()`** - Check for multi-monitor transitions
5. **`unified_anchor_to_legacy_resize_anchor()`** - Legacy compatibility

## Integration Points

### Animation Thread

- Two-phase animations: Separate slide and resize phases with unified anchoring
- Single-phase animations: Direct unified anchor interpolation
- Monitor handoff detection and special easing

### Setup Phase

- Unified anchor calculation for all windows
- Legacy compatibility mapping
- Debug logging and diagnostics

## Configuration

### Relevant Settings

- `window_animation_edge_threshold`: Pixel tolerance for edge detection (default: 5.0)
- `window_animation_force_*_anchor`: Override anchor detection
- `window_animation_override_stacked_*`: Special handling for stacked windows
- `window_animation_two_phase_enabled`: Enable two-phase animations

## Debug Output

The system provides comprehensive debug logging:

- `🔗 Window X: anchor(x,y) edges(T:X B:X L:X R:X) split:X op:type`
- Operation types: "resize", "move", "mixed"
- Monitor crossing detection
- Split context and fallback usage

## Benefits

### 1. **Consistency**

- Single calculation method eliminates contradictions
- Predictable behavior across all animation scenarios

### 2. **Maintainability**

- One function to update instead of multiple legacy methods
- Clear separation of concerns and responsibilities

### 3. **Extensibility**

- Easy to add new anchor strategies
- Modular design allows for future enhancements

### 4. **Performance**

- Optimized calculations with minimal redundancy
- Efficient operation type detection

### 5. **Compatibility**

- Maintains legacy resize_anchor compatibility
- Seamless integration with existing animation code

## Migration

All previous anchor calculation functions have been removed:

- ❌ `analyze_edge_constraints()`
- ❌ `constraints_to_anchor()`
- ❌ `calculate_resize_anchor_enhanced()`
- ❌ `calculate_resize_anchor()`
- ❌ `calculate_common_edge_anchor()`
- ✅ `calculate_unified_anchor()` (replaces all above)

## Testing

Use the provided test script to verify anchoring behavior:

```bash
./test_split_aware_anchoring.sh
```

Watch debug logs for anchor calculations:

```bash
log stream --predicate 'process == "yabai"' --level debug | grep "🔗"
```

## Future Enhancements

- Dynamic anchor adjustment based on window content
- Learning-based anchor prediction
- User-defined anchor preferences per application
- Advanced container-aware constraint handling
