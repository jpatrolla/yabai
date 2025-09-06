#!/bin/bash

# Test script for the enhanced frame-based animation with AX API integration
# This script demonstrates the new window_animation_frame_rate configuration

echo "🎬 Testing Enhanced Frame-Based Animation with AX API"
echo "====================================================="

# Check if yabai is running
if ! pgrep -f yabai > /dev/null; then
    echo "❌ yabai is not running. Please start yabai first."
    exit 1
fi

# First, let's check current animation settings
echo "📋 Current Animation Configuration:"
echo "   Duration: $(./bin/yabai -m config window_animation_duration)"
echo "   Easing: $(./bin/yabai -m config window_animation_easing)"
echo "   Frame-based enabled: $(./bin/yabai -m config window_animation_frame_based_enabled)"
echo "   Frame rate: $(./bin/yabai -m config window_animation_frame_rate)"
echo ""

# Enable frame-based animation and set optimal settings
echo "🔧 Configuring animation settings for AX API testing:"
./bin/yabai -m config window_animation_frame_based_enabled on
./bin/yabai -m config window_animation_duration 0.6
./bin/yabai -m config window_animation_easing ease_in_out_cubic
echo "   ✅ Frame-based animation: enabled"
echo "   ✅ Duration: 0.6 seconds"
echo "   ✅ Easing: ease_in_out_cubic"
echo ""

# Test different frame rates
echo "🎯 Testing Different Frame Rates:"
echo "================================="

frame_rates=("10" "20" "30" "60")

for rate in "${frame_rates[@]}"; do
    echo "🎥 Testing ${rate} fps..."
    ./bin/yabai -m config window_animation_frame_rate "$rate"
    echo "   Frame rate set to: $(./bin/yabai -m config window_animation_frame_rate) fps"
    
    # Run animation test
    ./bin/yabai -m window --pip-test 100,100,400,300
    
    echo "   ✅ ${rate} fps test completed"
    echo ""
    sleep 1
done

echo "🔄 Performance Comparison Test:"
echo "==============================="

# Test low vs high frame rate for performance comparison
echo "🐌 Low frame rate (5 fps) - should be choppy but smooth:"
./bin/yabai -m config window_animation_frame_rate 5
./bin/yabai -m config window_animation_duration 1.0
./bin/yabai -m window --pip-test 50,50,200,150

echo ""
echo "🚀 High frame rate (60 fps) - should be very smooth:"
./bin/yabai -m config window_animation_frame_rate 60
./bin/yabai -m config window_animation_duration 1.0
./bin/yabai -m window --pip-test 400,200,300,250

echo ""
echo "⚡ Ultra-high frame rate (120 fps) - maximum smoothness:"
./bin/yabai -m config window_animation_frame_rate 120
./bin/yabai -m config window_animation_duration 0.8
./bin/yabai -m window --pip-test 200,300,500,400

echo ""
echo "📊 AX API vs SkyLight Comparison:"
echo "================================="
echo "The new frame-based animation now uses:"
echo "   • window_manager_move_window() - AX API positioning"
echo "   • window_manager_resize_window() - AX API resizing"
echo "   • Configurable frame rate (1-120 fps)"
echo "   • Better system integration"
echo "   • Proper window management hooks"
echo ""

# Restore reasonable defaults
echo "🔧 Restoring recommended settings:"
./bin/yabai -m config window_animation_frame_rate 30
./bin/yabai -m config window_animation_duration 0.4
./bin/yabai -m config window_animation_easing ease_in_out_cubic
echo "   ✅ Frame rate: 30 fps (balanced performance)"
echo "   ✅ Duration: 0.4 seconds"
echo "   ✅ Easing: ease_in_out_cubic"
echo ""

echo "🎉 Frame-Based Animation Testing Complete!"
echo ""
echo "💡 Configuration Summary:"
echo "   • window_animation_frame_based_enabled: on/off"
echo "   • window_animation_frame_rate: 1.0-120.0 (fps)"
echo "   • Lower frame rates = less CPU usage, choppier animation"
echo "   • Higher frame rates = more CPU usage, smoother animation"
echo "   • Recommended: 30 fps for balanced performance"
echo ""
echo "🚀 Example usage:"
echo "   ./bin/yabai -m config window_animation_frame_rate 30"
echo "   ./bin/yabai -m window --pip-test 100,100,300,200"
