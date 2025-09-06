#!/bin/bash

# Test script for yabai's new performance-focused animation toggles
# This script demonstrates how to configure yabai for different performance profiles

echo "=== Yabai Animation Performance Toggle Test ==="
echo

# Function to display current animation settings
show_current_settings() {
    echo "Current animation settings:"
    echo "  Duration: $(yabai -m config window_animation_duration)"
    echo "  Easing: $(yabai -m config window_animation_easing)"
    echo "  Blur enabled: $(yabai -m config window_animation_blur_enabled)"
    echo "  Shadows enabled: $(yabai -m config window_animation_shadows_enabled)"
    echo "  Opacity enabled: $(yabai -m config window_animation_opacity_enabled)"
    echo "  Opacity duration: $(yabai -m config window_opacity_duration)"
    echo "  Simplified easing: $(yabai -m config window_animation_simplified_easing)"
    echo "  Reduced resolution: $(yabai -m config window_animation_reduced_resolution)"
    echo "  Starting size: $(yabai -m config window_animation_starting_size)"
    echo "  Fast mode: $(yabai -m config window_animation_fast_mode)"
    echo "  Frame-based: $(yabai -m config window_animation_frame_based_enabled)"
    echo "  Frame rate: $(yabai -m config window_animation_frame_rate)"
    echo
}

# Function to test window animations
test_animation() {
    echo "Testing animation... (moving a window)"
    # Create a simple test by opening and positioning a window
    yabai -m rule --add app="^System Preferences$" manage=on
    open -a "System Preferences" 2>/dev/null || echo "Note: System Preferences not available for testing"
    sleep 1
    yabai -m window --toggle float 2>/dev/null || echo "No window available to test"
    sleep 1
    yabai -m window --toggle float 2>/dev/null || echo "Animation test completed"
    echo
}

echo "=== Profile 1: Default (Beautiful but slower) ==="
yabai -m config window_animation_duration 0.3
yabai -m config window_animation_easing 5  # ease_out_cubic
yabai -m config window_animation_blur_enabled off
yabai -m config window_animation_shadows_enabled on
yabai -m config window_animation_opacity_enabled on
yabai -m config window_animation_simplified_easing off
yabai -m config window_animation_reduced_resolution off
yabai -m config window_animation_starting_size 1.0
yabai -m config window_animation_fast_mode off
yabai -m config window_animation_frame_based_enabled off
show_current_settings

echo "Press Enter to test this profile..."
read -r
test_animation

echo "=== Profile 2: Performance (Faster, some visual trade-offs) ==="
yabai -m config window_animation_duration 0.15
yabai -m config window_animation_blur_enabled off
yabai -m config window_animation_shadows_enabled off
yabai -m config window_animation_simplified_easing on
yabai -m config window_animation_reduced_resolution on
show_current_settings

echo "Press Enter to test this profile..."
read -r
test_animation

echo "=== Profile 3: Fast Mode (Fastest, minimal effects) ==="
yabai -m config window_animation_fast_mode on  # This automatically sets other optimizations
show_current_settings

echo "Press Enter to test this profile..."
read -r
test_animation

echo "=== Profile 4: Frame-based PiP Animation (Smooth scaling approach) ==="
yabai -m config window_animation_fast_mode off
yabai -m config window_animation_frame_based_enabled on
yabai -m config window_animation_frame_rate 60.0
yabai -m config window_animation_duration 0.3
yabai -m config window_animation_starting_size 0.8  # Start at 80% size for nice effect
yabai -m config window_opacity_duration 0.2  # Enable opacity fade
show_current_settings

echo "Press Enter to test frame-based PiP animation with opacity fade..."
read -r
echo "Testing frame-based PiP animation (window scales within bounds with fade)..."
yabai -m --pip-test 100 100 800 600

echo
echo "=== Profile 6: Scale Effect Demo (Fun visual effects) ==="
yabai -m config window_animation_fast_mode off
yabai -m config window_animation_duration 0.4
yabai -m config window_animation_starting_size 0.3  # Windows start at 30% of target size
yabai -m config window_animation_easing 8  # ease_out_back for bounce effect
show_current_settings

echo "Press Enter to test scaling animation effect..."
read -r
test_animation

echo "=== Profile 7: Grow Effect (Windows start small) ==="
yabai -m config window_animation_starting_size 0.1  # Windows start at 10% of target size
yabai -m config window_animation_duration 0.5
show_current_settings

echo "Press Enter to test grow animation effect..."
read -r
test_animation

echo "=== Profile 8: Shrink Effect (Windows start large) ==="
yabai -m config window_animation_starting_size 1.5  # Windows start at 150% of target size
yabai -m config window_animation_duration 0.3
yabai -m config window_animation_easing 6  # ease_in_cubic for fast start
show_current_settings

echo "Press Enter to test shrink animation effect..."
read -r
test_animation

echo "=== Profile 5: Ultra-snappy (Disable animations entirely) ==="
yabai -m config window_animation_duration 0.0
show_current_settings

echo "Press Enter to test no animation..."
read -r
test_animation

echo "=== Configuration Examples ==="
echo
echo "For snappy performance, use:"
echo "  yabai -m config window_animation_fast_mode on"
echo
echo "For custom performance tuning:"
echo "  yabai -m config window_animation_shadows_enabled off"
echo "  yabai -m config window_animation_blur_enabled off"
echo "  yabai -m config window_animation_simplified_easing on"
echo "  yabai -m config window_animation_reduced_resolution on"
echo "  yabai -m config window_animation_duration 0.1"
echo
echo "For frame-based PiP animations (smooth scaling within bounds):"
echo "  yabai -m config window_animation_frame_based_enabled on"
echo "  yabai -m config window_animation_frame_rate 60.0"
echo "  yabai -m config window_animation_starting_size 0.5  # Creates grow effect"
echo
echo "For scale effects:"
echo "  yabai -m config window_animation_starting_size 0.5  # Start at 50% size"
echo "  yabai -m config window_animation_starting_size 0.1  # Grow from tiny"
echo "  yabai -m config window_animation_starting_size 1.5  # Shrink from large"
echo
echo "To disable specific effects:"
echo "  yabai -m config window_animation_opacity_enabled off"
echo "  yabai -m config window_animation_shadows_enabled off"
echo
echo "=== Test completed! ==="

# Restore reasonable defaults
echo "Restoring default settings..."
yabai -m config window_animation_duration 0.25
yabai -m config window_animation_fast_mode off
yabai -m config window_animation_frame_based_enabled off
yabai -m config window_animation_shadows_enabled on
yabai -m config window_animation_opacity_enabled on
yabai -m config window_animation_simplified_easing off
yabai -m config window_animation_reduced_resolution off
yabai -m config window_animation_starting_size 1.0
yabai -m config window_animation_blur_enabled off

echo "Default settings restored."
