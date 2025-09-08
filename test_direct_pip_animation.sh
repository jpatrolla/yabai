#!/bin/bash

# Test script for direct PiP scripting addition animation
echo "🎯 Testing Direct PiP Scripting Addition Animation"
echo "================================================="

# Install the updated binary with direct PiP animation test
echo "Installing updated yabai binary with direct PiP animation..."
sudo ./bin/yabai --uninstall-sa 2>/dev/null || true
sudo ./bin/yabai --install-sa 
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist
sleep 2

echo ""
echo "📊 Testing direct PiP scripting addition with manual tweening..."

echo "Opening test application..."
open -n /System/Applications/TextEdit.app
sleep 2

echo ""
echo "🔄 Running direct PiP animation tests..."

echo "  • Test 1: Small resize (800x600 -> 400x300)"
echo "    This bypasses all yabai animation systems and uses scripting addition directly"
./bin/yabai -m window --pip-test 100,100,400,300
sleep 1

echo ""
echo "  • Test 2: Large resize (current -> 600x400)"  
echo "    Should show smooth manual tweening without BSP interference"
./bin/yabai -m window --pip-test 200,150,600,400
sleep 1

echo ""
echo "  • Test 3: Position change (current -> 50x50 same size)"
echo "    Testing position-only animation"
./bin/yabai -m window --pip-test 50,50,800,600
sleep 1

# Check logs for direct PiP messages
echo ""
echo "📋 Recent direct PiP animation log messages:"
echo "==========================================="
log show --style syslog --predicate 'process == "yabai"' --last 30s 2>/dev/null | grep -E "(🎬|CREATE PiP|MOVE PiP|RESTORE PiP|Sending.*scale)" | tail -15

echo ""
echo "✅ Direct PiP animation test complete!"
echo ""
echo "Key features of this test:"
echo "  • ✅ Uses scripting_addition_scale_window_custom_mode directly"
echo "  • ✅ Manual tweening with ease-out-cubic easing"
echo "  • ✅ 30 frames at 33ms each (~30fps)"
echo "  • ✅ 1 second pause at target position"
echo "  • ✅ Animate back to original position"
echo "  • ✅ Completely bypasses yabai animation system"
echo "  • ✅ No BSP layout interference possible"
echo ""
echo "Animation sequence:"
echo "  1. CREATE PiP at original position"
echo "  2. MOVE PiP through interpolated frames (30 frames to target)"
echo "  3. PAUSE at target position (1 second)"
echo "  4. MOVE PiP through interpolated frames (30 frames back to original)"
echo "  5. RESTORE PiP (removes PiP effect)"
echo ""
echo "This demonstrates how the original proxy system works - the real window"
echo "never moves during animation, only the visual PiP representation moves!"
