#!/bin/bash

# Animation troubleshooting script
echo "🔧 Animation Troubleshooting Guide"
echo "=================================="
echo ""

# First, let's disable the new features and test basic animation
echo "1. Testing basic animation (classic mode)..."
./bin/yabai -m config window_animation_duration 0.3
./bin/yabai -m config window_animation_easing ease_out_circ
./bin/yabai -m config window_animation_two_phase_enabled off
./bin/yabai -m config window_animation_fade_enabled off

echo "✅ Classic animation enabled (0.3s)"
echo "   Test window swapping now. If this works well, continue to step 2."
echo ""
echo "2. Press ENTER to enable two-phase animation (simplified)..."
read -p ""

./bin/yabai -m config window_animation_two_phase_enabled on
./bin/yabai -m config window_animation_slide_ratio 0.7
echo "✅ Two-phase animation enabled (70% slide, 30% resize)"
echo "   Test window swapping now. Animation should be smoother for size differences."
echo ""
echo "3. Press ENTER to add fade effect..."
read -p ""

./bin/yabai -m config window_animation_fade_enabled on
./bin/yabai -m config window_animation_fade_threshold 0.4
./bin/yabai -m config window_animation_fade_intensity 0.3
echo "✅ Fade effect enabled (threshold: 0.4, intensity: 0.3)"
echo "   Test again. Large size differences should now fade during animation."
echo ""

echo "📊 Final Configuration:"
echo "Duration: $(./bin/yabai -m config window_animation_duration)s"
echo "Easing: $(./bin/yabai -m config window_animation_easing)"
echo "Two-phase: $(./bin/yabai -m config window_animation_two_phase_enabled)"
echo "Slide ratio: $(./bin/yabai -m config window_animation_slide_ratio)"
echo "Fade enabled: $(./bin/yabai -m config window_animation_fade_enabled)"
echo "Fade threshold: $(./bin/yabai -m config window_animation_fade_threshold)"
echo "Fade intensity: $(./bin/yabai -m config window_animation_fade_intensity)"

echo ""
echo "🎯 If animations are still problematic:"
echo "- Try disabling two-phase: yabai -m config window_animation_two_phase_enabled off"
echo "- Try shorter duration: yabai -m config window_animation_duration 0.2"
echo "- Try different easing: yabai -m config window_animation_easing ease_in_out_cubic"
echo ""
echo "💡 For debugging, you can disable all animations:"
echo "- yabai -m config window_animation_duration 0.0"
