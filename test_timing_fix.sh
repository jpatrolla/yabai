#!/bin/bash

echo "🎬 Testing Frame Timing Fix"
echo "=========================="

echo ""
echo "Testing frame-based animation timing accuracy..."

# Test with different configurations
echo ""
echo "1. Standard animation (should now have accurate timing):"
./bin/yabai -m config window_animation_duration 1.0
./bin/yabai -m config window_animation_frame_rate 30.0
./bin/yabai -m config window_animation_fast_mode off
./bin/yabai -m config window_animation_frame_based_enabled on

echo "   Moving window to test timing..."
./bin/yabai -m window --move abs:100:100
sleep 2

echo ""
echo "2. Fast mode comparison (should still work but with different timing profile):"
./bin/yabai -m config window_animation_fast_mode on

echo "   Moving window in fast mode..."
./bin/yabai -m window --move abs:300:100
sleep 2

echo ""
echo "3. Higher frame rate test (should maintain accuracy):"
./bin/yabai -m config window_animation_frame_rate 60.0
./bin/yabai -m config window_animation_fast_mode off

echo "   Moving window at 60fps..."
./bin/yabai -m window --move abs:500:100
sleep 2

echo ""
echo "Check the debug output for timing accuracy!"
echo "Look for lines showing:"
echo "  - 'Frame timing: frame=X/Y, elapsed=Zms, target=Wms, sleep=Vms, drift=Ums'"
echo "  - 'Animation completed: expected=Xs, actual=Ys, accuracy=Z%, drift=Wms'"
echo ""
echo "The timing should now be much more accurate without fast_mode!"
