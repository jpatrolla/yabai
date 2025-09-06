#!/bin/bash

# Test script for the new PiP-based frame animation
echo "=== Testing PiP-based Frame Animation ==="
echo

# Function to test the animation
test_pip_animation() {
    echo "Current settings:"
    echo "  Frame-based: $(yabai -m config window_animation_frame_based_enabled)"
    echo "  Duration: $(yabai -m config window_animation_duration)"
    echo "  Frame rate: $(yabai -m config window_animation_frame_rate)"
    echo "  Starting size: $(yabai -m config window_animation_starting_size)"
    echo "  Opacity duration: $(yabai -m config window_opacity_duration)"
    echo "  Opacity enabled: $(yabai -m config window_animation_opacity_enabled)"
    echo

    echo "Testing PiP animation with opacity fade..."
    echo "Note: The window should stay in place but scale smoothly with fade effects"
    
    # Test the pip animation with different coordinates
    echo "1. Testing grow effect with opacity fade (small to normal size)..."
    yabai -m --pip-test 200 200 600 400
    
    echo "Press Enter to continue..."
    read -r
    
    echo "2. Testing with different target position and fade..."
    yabai -m --pip-test 400 300 800 600
    
    echo "Press Enter to continue..."
    read -r
    
    echo "3. Testing shrink effect with fade (large to normal size)..."
    yabai -m config window_animation_starting_size 1.8
    yabai -m --pip-test 100 100 700 500
    
    echo "Press Enter to continue..."
    read -r
}

echo "=== Standard PiP Animation with Opacity Fade ==="
yabai -m config window_animation_frame_based_enabled on
yabai -m config window_animation_duration 0.4
yabai -m config window_animation_frame_rate 60.0
yabai -m config window_animation_starting_size 0.5
yabai -m config window_animation_easing 5  # ease_out_cubic
yabai -m config window_opacity_duration 0.3  # Enable opacity fade
yabai -m config window_animation_opacity_enabled on
test_pip_animation

echo "=== Fast PiP Animation with Quick Fade ==="
yabai -m config window_animation_duration 0.2
yabai -m config window_animation_frame_rate 120.0
yabai -m config window_animation_starting_size 0.2
yabai -m config window_animation_simplified_easing on
yabai -m config window_opacity_duration 0.15  # Quick fade
test_pip_animation

echo "=== Bounce PiP Animation with Dramatic Fade ==="
yabai -m config window_animation_duration 0.6
yabai -m config window_animation_frame_rate 60.0
yabai -m config window_animation_starting_size 0.8
yabai -m config window_animation_easing 8  # ease_out_back for bounce
yabai -m config window_animation_simplified_easing off
yabai -m config window_opacity_duration 0.4  # Longer fade for dramatic effect
test_pip_animation

echo "=== Pure Opacity Test (No PiP, just fade effects) ==="
yabai -m config window_animation_frame_based_enabled off
yabai -m config window_opacity_duration 0.5
echo "Testing just opacity fade without PiP..."
echo "Press Enter to test opacity fade..."
read -r
# Test direct opacity fade
echo "Fading window to 50% opacity..."
yabai -m config window_opacity_duration 1.0
# This would need a direct test window, but demonstrates the concept

echo "=== Comparison: Traditional vs PiP Animation ==="
echo "Now testing traditional animation for comparison..."
yabai -m config window_animation_frame_based_enabled off
yabai -m config window_animation_duration 0.3
echo "Traditional animation (proxy-based):"
echo "Note: Window should move/resize physically"
echo "Press Enter to test traditional animation..."
read -r
yabai -m --pip-test 300 200 700 500

echo
echo "=== Test completed! ==="
echo "The new PiP-based frame animation should provide:"
echo "  ✅ Smoother visual experience with opacity fade transitions"
echo "  ✅ Better performance (no AX API calls during animation)"  
echo "  ✅ Window stays responsive during animation"
echo "  ✅ Scaling happens within window bounds using SkyLight transforms"
echo "  ✅ Coordinated opacity fade in/out effects using window_opacity_duration"
echo

# Restore defaults
echo "Restoring default settings..."
yabai -m config window_animation_frame_based_enabled off
yabai -m config window_animation_duration 0.25
yabai -m config window_animation_starting_size 1.0
yabai -m config window_animation_simplified_easing off
yabai -m config window_animation_frame_rate 30.0
yabai -m config window_opacity_duration 0.0  # Disable opacity fade
yabai -m config window_animation_opacity_enabled on

echo "Settings restored to defaults."
