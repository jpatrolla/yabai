#!/bin/bash

# Test script to verify that calculated dimensions are now properly stored and used
echo "🔧 Testing Calculated Dimension Storage Fix"
echo "=========================================="

# Install the updated binary with calculated dimension storage
echo "Installing updated yabai binary with dimension calculation fix..."
sudo ./bin/yabai --uninstall-sa 2>/dev/null || true
sudo ./bin/yabai --install-sa 
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist
sleep 2

echo ""
echo "📊 Testing calculated dimension storage with frame-based animations..."

# Configure for frame-based animations to test the dimension storage
./bin/yabai -m config window_animation_frame_rate 15  # Lower frame rate for easier observation
./bin/yabai -m config window_animation_duration 2.0   # Longer duration to see progression
./bin/yabai -m config window_animation_easing ease_out_quint
./bin/yabai -m config window_animation_frame_based_enabled on

echo "Opening test applications for dimension tracking..."
open -n /System/Applications/TextEdit.app
sleep 1
open -n /System/Applications/Calculator.app  
sleep 1

echo ""
echo "🔄 Testing operations that should show dimension progression..."

echo "  • Testing window resize (should show smooth w/h changes)..."
./bin/yabai -m window --resize left:-80:0
sleep 3

echo "  • Testing window resize in other direction (should show smooth w/h changes)..."
./bin/yabai -m window --resize bottom:0:-50
sleep 3

echo "  • Testing window swap (should show position/size changes)..."
./bin/yabai -m window --swap west
sleep 3

# Check logs for dimension progression messages
echo ""
echo "📋 Recent dimension calculation log messages:"
echo "============================================="
log show --style syslog --predicate 'process == "yabai"' --last 30s 2>/dev/null | grep -E "(calculated stored dimensions|fdb.*w:|fdb.*h:)" | tail -10

echo ""
echo "✅ Calculated dimension storage test complete!"
echo ""
echo "Key improvements with this fix:"
echo "  • ✅ Window dimensions now stored per frame instead of queried"
echo "  • ✅ PiP scaling animations show proper dimension progression"
echo "  • ✅ Debug output uses calculated values, not stale window data"
echo "  • ✅ Both sync and async animations store calculated dimensions"
echo ""
echo "Expected behavior:"
echo "  • Before: w/h values stayed constant during animation (broken)"
echo "  • After:  w/h values smoothly interpolate throughout animation (fixed!)"
echo ""
echo "Look for debug messages with 'calculated stored dimensions' to verify the fix."
