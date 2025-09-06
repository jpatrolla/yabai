#!/bin/bash

echo "🔧 Testing Animation Batching Fix"
echo "================================="

# Enable frame-based animation
echo "✅ Enabling frame-based animation..."
./bin/yabai -m config window_animation_frame_based_enabled on

# Set animation duration
echo "⏱️  Setting animation duration to 0.4s..."
./bin/yabai -m config window_animation_duration 0.4

# Check current focused window
WINDOW_ID=$(./bin/yabai -m query --windows --window | jq -r '.id // empty')

if [ -z "$WINDOW_ID" ]; then
    echo "❌ No focused window found. Please focus a window and try again."
    exit 1
fi

echo "🎯 Testing with window ID: $WINDOW_ID"
echo ""

echo "🧪 Test 1: Single resize command (should see one animation)"
echo "Running: yabai -m window --resize abs:600:400"
./bin/yabai -m window --resize abs:600:400

sleep 2

echo ""
echo "🧪 Test 2: Rapid double resize commands (should batch into one animation)"
echo "Running: yabai -m window --resize left:100:0 --resize right:100:0"
./bin/yabai -m window --resize left:100:0 --resize right:100:0

sleep 2

echo ""
echo "🧪 Test 3: Separate resize commands with delay (should see two animations)"
echo "Running first: yabai -m window --resize abs:700:500"
./bin/yabai -m window --resize abs:700:500
sleep 1
echo "Running second: yabai -m window --resize abs:800:600"
./bin/yabai -m window --resize abs:800:600

echo ""
echo "✅ Batching test completed!"
echo ""
echo "💡 Expected behavior:"
echo "   - Test 1: One smooth animation"
echo "   - Test 2: One combined animation (not two separate ones)"
echo "   - Test 3: Two separate animations with pause between"
echo ""
echo "Check the debug logs for 🎬 'Delaying animation to batch' messages."
