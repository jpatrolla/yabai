# Quick Animation Fixes

## If animations are erratic, try these in order:

### 1. Disable new features completely (go back to classic)

```bash
./bin/yabai -m config window_animation_two_phase_enabled off
./bin/yabai -m config window_animation_fade_enabled off
./bin/yabai -m config window_animation_duration 0.3
```

### 2. If classic works, try enabling two-phase with conservative settings

```bash
./bin/yabai -m config window_animation_two_phase_enabled on
./bin/yabai -m config window_animation_slide_ratio 0.8  # More slide, less resize
./bin/yabai -m config window_animation_fade_threshold 0.8  # Only for very large differences
```

### 3. Disable all animations temporarily

```bash
./bin/yabai -m config window_animation_duration 0.0
```

### 4. Test with minimal animation

```bash
./bin/yabai -m config window_animation_duration 0.1
./bin/yabai -m config window_animation_two_phase_enabled off
```

## Key Settings Explained:

- `window_animation_duration 0.0` = No animations
- `window_animation_two_phase_enabled off` = Classic stretching animation only
- `window_animation_slide_ratio 0.9` = 90% slide, 10% resize (less resizing)
- `window_animation_fade_threshold 0.9` = Only fade for 90%+ size differences

## Current Issue:

The two-phase detection might be too aggressive, or the transform math needs adjustment.
Start with classic animation and incrementally add features.
