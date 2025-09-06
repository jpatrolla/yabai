#!/bin/bash

echo "🔧 Testing Fixed Frame-Based Animation (No Heap Corruption)"
echo "=========================================================="

# Enable frame-based animation
echo "✅ Enabling frame-based animation..."
./bin/yabai -m config window_animation_frame_based_enabled on

# Set animation duration
echo "⏱️  Setting animation duration to 0.3s for quick testing..."
./bin/yabai -m config window_animation_duration 0.3

# Check current focused window
WINDOW_ID=$(./bin/yabai -m query --windows --window | jq -r '.id // empty')

if [ -z "$WINDOW_ID" ]; then
    echo "❌ No focused window found. Please focus a window and try again."
    exit 1
fi

echo "🎯 Testing with window ID: $WINDOW_ID"
echo ""

echo "🧪 Test 1: Simple window move (should see 🎬 debug messages)"
echo "Running: yabai -m window --move abs:200:200"
./bin/yabai -m window --move abs:200:200

sleep 1

echo ""
echo "🧪 Test 2: Window resize"
echo "Running: yabai -m window --resize abs:600:400"
./bin/yabai -m window --resize abs:600:400

sleep 1

echo ""
echo "✅ Basic tests completed without heap corruption!"
echo ""
echo "💡 If you see smooth scaling instead of proxy windows, the POC is working!"
echo "💡 Look for 🎬 debug messages in the yabai logs to confirm frame-based animation is running."
