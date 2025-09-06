#!/bin/bash

echo "🔍 Testing Frame-Based Animation Debug"
echo "====================================="

# Build the project first
echo "Building yabai..."
make

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo "✅ Build successful!"
echo ""

# Enable frame-based animation
echo "🔧 Enabling frame-based animation..."
./bin/yabai -m config window_animation_frame_based_enabled true
./bin/yabai -m config window_animation_duration 2.0
./bin/yabai -m config window_animation_frame_rate 10
echo "✅ Frame-based animation enabled (2s duration, 10fps for easy observation)"

echo ""
echo "📊 Current animation settings:"
echo "  Frame-based: $(./bin/yabai -m config window_animation_frame_based_enabled)"
echo "  Duration:    $(./bin/yabai -m config window_animation_duration)s"
echo "  Frame rate:  $(./bin/yabai -m config window_animation_frame_rate)fps"
echo ""

echo "🔍 Testing single window animation..."
echo "Run this command in another terminal to test:"
echo "  ./bin/yabai -m window --resize left:50:0"
echo ""
echo "Look for debug output with these patterns:"
echo "  🎬🎬🎬🎬 FRAME-BASED SYNC - Animation started"
echo "  🎬 Starting frame-based animation - Animation beginning"
echo "  🎬 Frame X/Y: - Each animation frame"
echo "  🎬 Window X: src=... dst=... - Window parameters"
echo ""

echo "If you see 'Frame-based animation disabled' or no 🎬 output, the animation system isn't working."
echo "If you see frame output but no visual animation, the PiP calls might not be working."
echo ""
echo "🚨 To test, try resizing a window now and watch the console output!"
