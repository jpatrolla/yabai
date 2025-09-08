# Stationary Edge Prioritization Anchoring System

## Overview

The anchoring logic has been updated to prioritize stationary (common) edges as the primary factor in anchor selection. This ensures that when any edge remains fixed between start and end positions, that stationary edge becomes the anchor point.

## New Priority System

### 1. Highest Priority: Corner Anchors (Multiple Stationary Edges)

When two edges are stationary, use the corner where they meet:

- **Top + Left** → Top-left corner anchor (0)
- **Top + Right** → Top-right corner anchor (1)
- **Bottom + Left** → Bottom-left corner anchor (2)
- **Bottom + Right** → Bottom-right corner anchor (3)

### 2. Second Priority: Single Stationary Edges

When only one edge is stationary, anchor to that edge with priority order:

**Priority Order: Bottom > Top > Left > Right**

- **Bottom edge stationary** → Bottom-center anchor (highest priority)
- **Top edge stationary** → Top-center anchor
- **Left edge stationary** → Left-center anchor
- **Right edge stationary** → Right-center anchor

### 3. Fallback: Split-Aware Logic

Only when NO edges are stationary, fall back to tree-based anchoring based on split direction and operation type.

## Code Changes

### Updated `calculate_unified_anchor` Function

```c
// NEW PRIORITY SYSTEM: Prioritize stationary edges over everything else
// Count stationary edges for priority ranking
int stationary_edge_count = 0;
if (anchor.has_common_top) stationary_edge_count++;
if (anchor.has_common_bottom) stationary_edge_count++;
if (anchor.has_common_left) stationary_edge_count++;
if (anchor.has_common_right) stationary_edge_count++;

// HIGHEST PRIORITY: Multiple stationary edges (corners)
if (anchor.has_common_top && anchor.has_common_left) {
    // Top-left corner
} else if (anchor.has_common_bottom && anchor.has_common_right) {
    // etc...
}
// SECOND PRIORITY: Single stationary edges with order Bottom > Top > Left > Right
else if (anchor.has_common_bottom) {
    // Bottom edge - highest single-edge priority
    debug("🔗 Prioritizing stationary BOTTOM edge for anchoring");
} else if (anchor.has_common_top) {
    // Top edge
    debug("🔗 Prioritizing stationary TOP edge for anchoring");
} // etc...
```

### Enhanced Debug Output

The debug system now clearly shows when stationary edge prioritization is active:

```
fdb RECOMMENDATIONS:
fdb   - PRIORITY: [B] edges are stationary -> anchor to stationary edge!
fdb   - Edge priority order: Bottom > Top > Left > Right
```

## Why This Matters

### Before: Inconsistent Anchoring

- Anchoring logic could ignore stationary edges in favor of tree-based fallbacks
- Window animations might not respect the natural "fixed points" of the transition
- Visual inconsistency in how windows appeared to grow/shrink

### After: Stationary Edge Priority

- **Visual Correctness**: Windows anchor to their naturally fixed edges
- **Predictable Behavior**: Stationary edges always take precedence
- **Better UX**: Animations look more natural and intuitive

## Example Scenarios

### Scenario 1: Bottom Edge Stationary

```
Start: x=100 y=100 w=400 h=300
End:   x=100 y=50  w=400 h=400
```

- Bottom edge Y coordinate: 400 → 450 (moves)
- Top edge Y coordinate: 100 → 50 (moves)
- **Left edge X coordinate: 100 → 100 (STATIONARY)**
- Right edge X coordinate: 500 → 500 (STATIONARY)

**Result**: Should anchor to left edge (stationary), but if both left AND right are stationary, should check top/bottom priority.

### Scenario 2: Bottom Edge Only Stationary

```
Start: x=100 y=100 w=400 h=300
End:   x=150 y=50  w=400 h=350
```

- **Bottom edge Y coordinate: 400 → 400 (STATIONARY)**
- Top edge Y coordinate: 100 → 50 (moves)
- Left edge X coordinate: 100 → 150 (moves)
- Right edge X coordinate: 500 → 550 (moves)

**Result**: Anchor to bottom edge (bottom-center anchor) - highest single-edge priority.

## Testing

Use the provided test script to verify the new behavior:

```bash
./test_stationary_edge_priority.sh
```

The script tests various scenarios and shows debug output demonstrating the prioritization logic in action.

## Configuration

Edge detection threshold (affects what's considered "stationary"):

```bash
yabai -m config window_animation_edge_threshold 8.0
```

Lower values = stricter stationary edge detection  
Higher values = more lenient stationary edge detection
