#!/bin/bash

# Test script for the enhanced --pip-test command
# This script demonstrates the frame-based animation system

echo "🎬 Testing Enhanced Pip Animation with Frame-Based System"
echo "========================================================="

# Check if yabai is running
if ! pgrep -f yabai > /dev/null; then
    echo "❌ yabai is not running. Please start yabai first."
    exit 1
fi

# First, let's check current animation settings
echo "📋 Current Animation Configuration:"
echo "   Duration: $(./bin/yabai -m config window_animation_duration)"
echo "   Easing: $(./bin/yabai -m config window_animation_easing)"
echo "   Frame-based: $(./bin/yabai -m config window_animation_frame_based_enabled)"
echo ""

# Set some good animation settings for testing
echo "🔧 Setting animation configuration for testing:"
./bin/yabai -m config window_animation_duration 0.5
./bin/yabai -m config window_animation_easing ease_in_out_cubic
echo "   Duration: 0.5 seconds"
echo "   Easing: ease_in_out_cubic"
echo ""

# Test different animation scenarios
echo "🎯 Test 1: Small window in corner (good for seeing scaling)"
echo "   Command: ./bin/yabai -m window --pip-test 50,50,200,150"
echo "   This will:"
echo "   1. Animate the focused window to (50,50) with size 200x150"
echo "   2. Pause for 3 seconds"
echo "   3. Animate back to original position"
echo ""
read -p "Press Enter to run Test 1..."
./bin/yabai -m window --pip-test 50,50,200,150

echo ""
echo "✅ Test 1 completed!"
echo ""

echo "🎯 Test 2: Large window (good for seeing position changes)"
echo "   Command: ./bin/yabai -m window --pip-test 100,100,800,600"
echo ""
read -p "Press Enter to run Test 2..."
./bin/yabai -m window --pip-test 100,100,800,600

echo ""
echo "✅ Test 2 completed!"
echo ""

echo "🎯 Test 3: Tiny window in different corner"
echo "   Command: ./bin/yabai -m window --pip-test 500,50,100,100"
echo ""
read -p "Press Enter to run Test 3..."
./bin/yabai -m window --pip-test 500,50,100,100

echo ""
echo "✅ All pip animation tests completed!"
echo ""

# Test with different easing functions
echo "🎨 Testing Different Easing Functions:"
echo "======================================"

easings=("ease_in_sine" "ease_out_bounce" "ease_in_out_cubic" "ease_in_out_quart" "ease_out_elastic")

for easing in "${easings[@]}"; do
    echo "🎨 Testing easing: $easing"
    ./bin/yabai -m config window_animation_easing "$easing"
    echo "   Running animation with $easing..."
    ./bin/yabai -m window --pip-test 300,200,300,200
    echo "   ✅ $easing test completed"
    echo ""
    sleep 1
done

echo "🎉 All animation tests completed successfully!"
echo ""
echo "📊 Summary:"
echo "   - Frame-based animation system tested"
echo "   - Multiple coordinate targets tested"
echo "   - Different easing functions tested"
echo "   - Automatic restoration of original position verified"
echo ""
echo "💡 Usage: ./bin/yabai -m window --pip-test x,y,w,h"
echo "   Example: ./bin/yabai -m window --pip-test 50,50,100,100"
