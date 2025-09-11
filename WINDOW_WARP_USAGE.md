# Window Warp Mesh - Wobbly Window Effects

This implementation provides a 16x16 CGPoint warp mesh system for creating wobbly window effects using `SLSSetWindowWarp`.

## Features

- **16x16 mesh grid** automatically sized to desktop/window dimensions
- **Multiple effect types**: wobble, ripple, and custom effects
- **Real-time animation** with time-based parameters
- **Easy-to-use API** with convenience functions

## Available Functions

### Core Function

```c
bool scripting_addition_warp_window(uint32_t wid, int effect_type, float time, float intensity, float center_x, float center_y);
```

### Convenience Functions

```c
// Reset window to normal (no warp)
bool scripting_addition_reset_window_warp(uint32_t wid);

// Apply wobble effect
bool scripting_addition_wobble_window(uint32_t wid, float time, float intensity);

// Apply ripple effect from center point
bool scripting_addition_ripple_window(uint32_t wid, float time, float intensity, float center_x, float center_y);
```

## Effect Types

### 0 - Reset (No Effect)

Resets the window to a perfectly regular mesh grid, removing any warp effects.

```c
scripting_addition_reset_window_warp(window_id);
```

### 1 - Wobble Effect

Creates a wobbly, jelly-like effect using multiple sine waves.

```c
float time = 0.0f;
float intensity = 20.0f; // Pixels of displacement
while (animating) {
    time += 0.1f; // Increment for animation
    scripting_addition_wobble_window(window_id, time, intensity);
    usleep(16000); // ~60 FPS
}
```

### 2 - Ripple Effect

Creates ripples emanating from a center point, like dropping a stone in water.

```c
float time = 0.0f;
float intensity = 30.0f;
float center_x = window_center_x; // Ripple center
float center_y = window_center_y;

while (animating) {
    time += 0.15f;
    scripting_addition_ripple_window(window_id, time, intensity, center_x, center_y);
    usleep(16000); // ~60 FPS
}
```

## Example Usage

### Simple Wobble Animation Loop

```c
#include "sa.h"

void animate_wobble_window(uint32_t window_id, float duration) {
    float time = 0.0f;
    float end_time = duration;
    float intensity = 25.0f;

    while (time < end_time) {
        scripting_addition_wobble_window(window_id, time, intensity);

        time += 0.1f;
        usleep(16000); // ~60 FPS
    }

    // Reset to normal
    scripting_addition_reset_window_warp(window_id);
}
```

### Interactive Ripple on Mouse Click

```c
void handle_mouse_click(uint32_t window_id, float click_x, float click_y) {
    float time = 0.0f;
    float intensity = 40.0f;

    for (int frame = 0; frame < 120; frame++) { // 2 seconds at 60fps
        time = frame * 0.05f;
        scripting_addition_ripple_window(window_id, time, intensity, click_x, click_y);
        usleep(16000);
    }

    scripting_addition_reset_window_warp(window_id);
}
```

## Technical Details

### Mesh Grid

- **Size**: 16x16 points (256 total points)
- **Automatic scaling** to window/desktop dimensions
- **Memory efficient** with stack-allocated arrays

### Performance

- **Optimized calculations** using fast trigonometric functions
- **Minimal overhead** with efficient mesh generation
- **Smooth animation** at 60+ FPS

### Coordinate System

- **Window-relative coordinates** for center points
- **Automatic bounds checking** to prevent invalid coordinates
- **Pixel-perfect positioning** with floating-point precision

## Integration Notes

- Uses `SLSSetWindowWarp` private API for mesh deformation
- Compatible with existing yabai window management
- Can be combined with other window effects (scaling, opacity, etc.)
- Thread-safe implementation with atomic operations

## Troubleshooting

### Common Issues

1. **Window not warping**: Ensure the window ID is valid and visible
2. **Jerky animation**: Check frame rate timing and reduce calculation complexity
3. **Effect too subtle**: Increase intensity parameter gradually

### Performance Tips

- Use lower intensity values for better performance
- Consider reducing update frequency for background animations
- Reset warp when switching between different effects
