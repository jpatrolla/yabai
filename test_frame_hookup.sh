#!/bin/bash

echo "=== Checking current animation configuration ==="
yabai -m config window_animation_frame_based_enabled

echo ""
echo "=== Enabling frame-based animation ==="
yabai -m config window_animation_frame_based_enabled on

echo ""
echo "=== Verifying frame-based animation is enabled ==="
yabai -m config window_animation_frame_based_enabled

echo ""
echo "=== Testing single window animation ==="
echo "Opening Terminal window for testing..."
open -a Terminal

sleep 2

echo "Getting current window info..."
WINDOW_ID=$(yabai -m query --windows --window | jq -r '.id')
echo "Target window ID: $WINDOW_ID"

echo ""
echo "=== Performing test animation (resize) ==="
echo "This should use frame-based animation, not proxies"
yabai -m window $WINDOW_ID --resize right:100:0

echo ""
echo "=== Check the debug output in Console.app for frame-based animation messages ==="
echo "Look for: 🎬 Starting frame-based animation"
echo "Should NOT see: 🟨🟨🟨🟨 CLASSIC"
