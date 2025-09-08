#!/bin/bash

# Test script to verify BSP layout conflict prevention during animations
echo "🛡️  Testing BSP Layout Conflict Prevention"
echo "=========================================="

# Install the updated binary with BSP conflict prevention
echo "Installing updated yabai binary with BSP layout conflict prevention..."
sudo ./bin/yabai --uninstall-sa 2>/dev/null || true
sudo ./bin/yabai --install-sa 
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist
sleep 2

echo ""
echo "📊 Testing BSP layout interference prevention..."

# Configure for clear testing of the conflict resolution
./bin/yabai -m config window_animation_frame_rate 10   # Slower frame rate for clearer observation
./bin/yabai -m config window_animation_duration 3.0   # Longer duration to see if conflicts are prevented
./bin/yabai -m config window_animation_easing ease_out_quint
./bin/yabai -m config window_animation_frame_based_enabled on

echo "Opening test applications for BSP conflict testing..."
open -n /System/Applications/TextEdit.app
sleep 1
open -n /System/Applications/Calculator.app  
sleep 1
open -n /System/Applications/Preview.app
sleep 1

# Ensure BSP layout
./bin/yabai -m space --layout bsp
sleep 1

echo ""
echo "🔄 Testing operations that previously caused position jumps..."

echo "  • Testing window resize with BSP conflict prevention..."
echo "    (This should now show smooth positioning without jumps)"
./bin/yabai -m window --resize left:-100:0
sleep 4  # Wait for animation to complete

echo "  • Testing window resize in opposite direction..."
echo "    (BSP layout should not interfere during animation)"
./bin/yabai -m window --resize right:100:0
sleep 4

echo "  • Testing bottom anchor resize (previously problematic)..."
echo "    (Bottom edge should stay pinned, no Y position jumps)"
./bin/yabai -m window --resize top:0:-80
sleep 4

echo "  • Testing window swap during animation prevention..."
./bin/yabai -m window --swap west
sleep 4

# Check logs for BSP conflict prevention messages
echo ""
echo "📋 Recent BSP conflict prevention log messages:"
echo "==============================================="
log show --style syslog --predicate 'process == "yabai"' --last 45s 2>/dev/null | grep -E "(🎬.*Blocking|🛡️|VIEW UPDATE|view_flush|animating window)" | tail -15

echo ""
echo "✅ BSP layout conflict prevention test complete!"
echo ""
echo "Key improvements with this fix:"
echo "  • ✅ BSP layout updates blocked while windows are animating"
echo "  • ✅ No more competing animations fighting each other"  
echo "  • ✅ Y positioning should be smooth without jumps"
echo "  • ✅ Bottom edge anchoring now works correctly"
echo "  • ✅ Pending layout updates processed after animation completion"
echo ""
echo "Expected behavior changes:"
echo "  • Before: Y position jumps during resize (BSP interference)"
echo "  • After:  Smooth Y position interpolation (BSP blocked during animation)"
echo ""
echo "Look for debug messages:"
echo "  • 'Blocking view_flush for view X - windows are currently animating'"
echo "  • 'Blocking view_update for view X - windows are currently animating'"
echo "  • 'Processing pending view update for view X after animation completion'"
