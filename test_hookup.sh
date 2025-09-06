#!/bin/bash

echo "🔧 Testing Frame-Based Animation Hookup"
echo "======================================="

# Check if yabai is running
if ! pgrep -x "yabai" > /dev/null; then
    echo "❌ yabai is not running. Please start yabai first."
    exit 1
fi

# Enable frame-based animation
echo "✅ Enabling frame-based animation..."
./bin/yabai -m config window_animation_frame_based_enabled on

# Check if it's enabled
ENABLED=$(./bin/yabai -m config window_animation_frame_based_enabled)
echo "📊 Frame-based animation enabled: $ENABLED"

# Set animation duration
echo "⏱️  Setting animation duration to 0.5s..."
./bin/yabai -m config window_animation_duration 0.5

# Check current focused window
WINDOW_ID=$(./bin/yabai -m query --windows --window | jq -r '.id // empty')

if [ -z "$WINDOW_ID" ]; then
    echo "❌ No focused window found. Please focus a window and try again."
    exit 1
fi

echo "🎯 Testing with window ID: $WINDOW_ID"

echo ""
echo "🧪 Test 1: Single window animation (should show 🎬🎬🎬🎬 FRAME-BASED)"
echo "Running: yabai -m window --move abs:100:100"
./bin/yabai -m window --move abs:100:100

sleep 2

echo ""
echo "🧪 Test 2: BSP swap (should show 🎬🎬🎬🎬 FRAME-BASED LIST)"
echo "Running: yabai -m window --swap north"
./bin/yabai -m window --swap north

sleep 2

echo ""
echo "🧪 Test 3: Window resize (should show 🎬🎬🎬🎬 FRAME-BASED)"
echo "Running: yabai -m window --resize abs:800:600"
./bin/yabai -m window --resize abs:800:600

echo ""
echo "✅ Tests completed! Check the yabai logs for frame-based animation debug messages:"
echo "   🎬🎬🎬🎬 FRAME-BASED = Single window frame-based animation"
echo "   🎬🎬🎬🎬 FRAME-BASED LIST = Multi-window frame-based animation"
echo ""
echo "If you see proxy window creation instead, the hookup still needs work."
