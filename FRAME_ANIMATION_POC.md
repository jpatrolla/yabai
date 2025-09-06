# Frame-Based Animation POC

## Overview

This is a Proof of Concept (POC) implementation that replaces the complex hide/animate/swap proxy window workflow with direct frame-based scaling using your existing `do_window_scale_custom` infrastructure.

## How It Works

Instead of creating proxy windows and manipulating them through SkyLight, this approach:

1. **Intercepts each animation frame** during the interpolation process
2. **Feeds frame data directly to your scaling system** via `scripting_addition_animate_window_frame`
3. **Uses your existing `do_window_scale_custom` transform logic** to apply scaling and positioning
4. **Restores the window** to its final position after animation completes

## Key Components

### 1. New Opcode: `SA_OPCODE_WINDOW_ANIMATE_FRAME`

- Handles individual animation frames
- Takes source/destination geometry, progress, and anchor point
- Applies transforms directly to the real window

### 2. Frame-Based Animation Function: `window_manager_animate_window_frame_based`

- Replaces the proxy window animation loop
- Calculates frame-by-frame interpolation
- Uses your BSP tree analysis for intelligent anchor points

### 3. Configuration Option: `window_animation_frame_based_enabled`

- Allows switching between proxy and frame-based animation
- Disabled by default (POC safety)

## Advantages

✅ **No proxy windows** - Eliminates complex window creation/destruction
✅ **Reuses existing scaling infrastructure** - Leverages your proven transform logic  
✅ **Simpler state management** - No need to track proxy window lifecycles
✅ **Direct window manipulation** - More predictable behavior
✅ **Flexible anchor points** - Supports all your existing anchor logic

## Testing

```bash
# Enable frame-based animation
./bin/yabai -m config window_animation_frame_based_enabled on

# Set animation duration
./bin/yabai -m config window_animation_duration 0.5

# Test with BSP operations (swap, warp, resize)
./bin/yabai -m window --swap north
./bin/yabai -m window --warp south
./bin/yabai -m window --resize abs:800:600

# Run the test script
./test_frame_animation.sh
```

## POC Implementation Details

### Animation Frame Handler (`do_window_animate_frame`)

```objectivec
// Interpolates between source and destination geometry
float current_x = src_x + (dst_x - src_x) * progress;
float current_y = src_y + (dst_y - src_y) * progress;
float current_w = src_w + (dst_w - src_w) * progress;
float current_h = src_h + (dst_h - src_h) * progress;

// Calculates scaling and positioning transforms
CGAffineTransform scale = CGAffineTransformMakeScale(x_scale, y_scale);
CGAffineTransform transform = CGAffineTransformTranslate(scale, transform_x, transform_y);
SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
```

### Frame-Based Animation Loop

- 60 FPS frame timing
- Easing function support (reuses existing easing types)
- BSP-aware anchor point detection
- Clean restoration after animation

## Future Enhancements

If this POC proves successful, potential improvements:

1. **Asynchronous frame updates** using CVDisplayLink (like current system)
2. **Hardware-accelerated transforms** via Core Animation layers
3. **Adaptive frame rates** based on animation complexity
4. **Bulk animation optimization** for multiple windows
5. **Integration with Mission Control animations**

## Configuration

The POC adds one new configuration option:

- `window_animation_frame_based_enabled` (boolean, default: off)
  - `on`: Use frame-based scaling animation
  - `off`: Use traditional proxy window animation

This allows safe testing and easy fallback to the existing proven system.
