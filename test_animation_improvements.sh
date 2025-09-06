#!/bin/bash

# Test script for the improved window animations in yabai
# This script demonstrates the new two-phase animation system

echo "🎬 Testing improved yabai window animations..."
echo ""

# Enable animations with default duration
echo "Setting up basic animation..."
./bin/yabai -m config window_animation_duration 0.5
./bin/yabai -m config window_animation_easing ease_out_circ

echo "✅ Basic animation enabled (0.5s, ease_out_circ)"
echo ""

# Test the new two-phase animation settings
echo "Configuring two-phase animation improvements..."

# Two-phase animation configuration
echo "🎭 Two-Phase Animation Settings:"
echo "  - Two-phase enabled: true (slide first, then resize)"
echo "  - Slide ratio: 0.6 (60% slide, 40% resize)"
echo "  - Fade threshold: 0.3 (apply when size difference > 30%)"
echo "  - Fade intensity: 0.4 (fade to 60% opacity during transition)"

./bin/yabai -m config window_animation_two_phase_enabled on
./bin/yabai -m config window_animation_slide_ratio 0.6
./bin/yabai -m config window_animation_fade_threshold 0.3
./bin/yabai -m config window_animation_fade_intensity 0.4
./bin/yabai -m config window_animation_fade_enabled on

echo ""
echo "🎯 Configuration complete! Now test the animation improvements:"
echo ""
echo "1. Open two windows of very different sizes (e.g., small terminal + large browser)"
echo "2. Use yabai to swap them: yabai -m window --swap [direction]"
echo "3. You should see:"
echo "   - Phase 1 (0-60%): Windows slide to new positions (keeping original size)"
echo "   - Phase 2 (60-100%): Windows smoothly resize to final size"
echo "   - Fade effect during animation for large size differences"
echo "   - No stretching or clipping artifacts!"
echo ""

# Display current settings
echo "📊 Current Animation Settings:"
echo "Duration: $(./bin/yabai -m config window_animation_duration)s"
echo "Easing: $(./bin/yabai -m config window_animation_easing)"
echo "Two-phase enabled: $(./bin/yabai -m config window_animation_two_phase_enabled)"
echo "Slide ratio: $(./bin/yabai -m config window_animation_slide_ratio)"
echo "Fade threshold: $(./bin/yabai -m config window_animation_fade_threshold)"
echo "Fade intensity: $(./bin/yabai -m config window_animation_fade_intensity)"
echo "Fade enabled: $(./bin/yabai -m config window_animation_fade_enabled)"

echo ""
echo "🔧 Tweaking Tips:"
echo "- Adjust slide_ratio (0.0-1.0) to control slide vs resize duration"
echo "  - Lower = more time resizing, higher = more time sliding"
echo "- Adjust fade_threshold (0.0-1.0) to control when fade effect applies"
echo "  - Lower = fade applies to smaller differences"
echo "- Adjust fade_intensity (0.0-1.0) for more/less dramatic fading"
echo "- Disable two-phase for classic stretching animation"
echo ""
echo "Example tweaks:"
echo "  # More slide, less resize (80% slide, 20% resize)"
echo "  yabai -m config window_animation_slide_ratio 0.8"
echo ""
echo "  # Apply fade to smaller size differences"
echo "  yabai -m config window_animation_fade_threshold 0.2"
echo ""
echo "  # Disable two-phase (classic stretching animation)"
echo "  yabai -m config window_animation_two_phase_enabled off"
echo ""
echo "  # Disable fade effect but keep two-phase animation"
echo "  yabai -m config window_animation_fade_enabled off"
