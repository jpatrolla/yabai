#!/bin/bash

# Test script for centralized anchoring system
# This tests that the centralized anchoring logic is being used instead of hardcoded movement logic

echo "🔗 Testing Centralized Anchoring System"
echo "======================================="

# Install the new binary
echo "Installing updated yabai binary..."
sudo ./bin/yabai --uninstall-sa 2>/dev/null || true
sudo ./bin/yabai --install-sa 
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist
sleep 2

echo ""
echo "📊 Testing centralized anchoring with frame-based animations..."

# Enable frame-based animations to test the new centralized logic
./bin/yabai -m config window_animation_frame_rate 30
./bin/yabai -m config window_animation_duration 1.0
./bin/yabai -m config window_animation_easing ease_out_quint

# Open test applications
echo "Opening test applications..."
open -n /System/Applications/TextEdit.app
sleep 1
open -n /System/Applications/Calculator.app  
sleep 1

# Test various operations that should use centralized anchoring
echo ""
echo "🔄 Testing window operations with centralized anchoring..."

echo "  • Testing window swap (should show centralized anchor calculations)..."
./bin/yabai -m window --swap west
sleep 2

echo "  • Testing window resize (should use stationary edge priority)..."
./bin/yabai -m window --resize left:-100:0
sleep 2

echo "  • Testing window split and stack (should prioritize stationary edges)..."
./bin/yabai -m window --split horizontal
sleep 1
./bin/yabai -m window --stack next
sleep 2

# Check logs for centralized anchoring messages
echo ""
echo "📋 Recent centralized anchoring log messages:"
echo "============================================="
log show --style syslog --predicate 'process == "yabai"' --last 30s 2>/dev/null | grep -E "(🔗|centralized|PRIORITY|stationary)" | tail -10

echo ""
echo "✅ Centralized anchoring test complete!"
echo ""
echo "Look for debug messages containing:"
echo "  • '🔗 Frame-sync: Window X centralized anchor=N'"
echo "  • '🔗 Frame-async: Window X centralized anchor=N'"  
echo "  • 'PRIORITY: [edges] are stationary -> anchor to stationary edge!'"
echo ""
echo "These indicate the centralized anchoring system is active."
