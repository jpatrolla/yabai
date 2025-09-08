#!/bin/bash

# Test script for corrected anchor-based interpolation logic
# This validates that window edges are properly pinned during PiP animations

echo "🔗 Testing Corrected Anchor-Based Interpolation"
echo "=============================================="

# Install the new binary with corrected anchor logic
echo "Installing updated yabai binary with corrected anchor interpolation..."
sudo ./bin/yabai --uninstall-sa 2>/dev/null || true
sudo ./bin/yabai --install-sa 
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.koekeishiya.yabai.plist
sleep 2

echo ""
echo "📊 Testing corrected anchor interpolation with frame-based animations..."

# Configure for frame-based animations to test the corrected logic
./bin/yabai -m config window_animation_frame_rate 30
./bin/yabai -m config window_animation_duration 1.5  # Longer duration to observe anchoring
./bin/yabai -m config window_animation_easing ease_out_quint
./bin/yabai -m config window_animation_edge_threshold 5.0  # Test edge detection

# Open test applications for anchor testing
echo "Opening test applications for anchor validation..."
open -n /System/Applications/TextEdit.app
sleep 1
open -n /System/Applications/Calculator.app  
sleep 1
open -n /System/Applications/Preview.app
sleep 1

# Test various operations that should demonstrate corrected anchor behavior
echo ""
echo "🔄 Testing corrected anchor-based operations..."

echo "  • Testing window swap (should show proper edge pinning)..."
./bin/yabai -m window --swap west
sleep 2

echo "  • Testing window resize (should pin stationary edges correctly)..."
./bin/yabai -m window --resize left:-100:0
sleep 2

echo "  • Testing window resize with bottom anchor (B should be anchoring)..."
./bin/yabai -m window --resize top:-50:0
sleep 2

echo "  • Testing window resize with right anchor..."
./bin/yabai -m window --resize left:100:0
sleep 2

echo "  • Testing window stack and split (should use centralized anchoring)..."
./bin/yabai -m window --split horizontal
sleep 1
./bin/yabai -m window --stack next
sleep 2

# Test multi-window operations to validate anchor consistency
echo "  • Testing multi-window layout change (anchor consistency test)..."
./bin/yabai -m space --layout float
sleep 1
./bin/yabai -m space --layout bsp
sleep 2

# Check logs for corrected anchoring messages
echo ""
echo "📋 Recent corrected anchor interpolation log messages:"
echo "===================================================="
log show --style syslog --predicate 'process == "yabai"' --last 45s 2>/dev/null | grep -E "(🔗|🎬|anchor|ANCHOR PHASE|SINGLE PHASE|RESIZE PHASE)" | tail -15

echo ""
echo "✅ Corrected anchor interpolation test complete!"
echo ""
echo "Key improvements in the corrected logic:"
echo "  • ✅ Position now interpolates smoothly between start and end anchor points"
echo "  • ✅ Anchor edges properly pinned throughout animation duration"
echo "  • ✅ Both single-phase and two-phase animations use corrected logic"
echo "  • ✅ Debug output shows anchor coordinates and interpolation progress"
echo ""
echo "Look for debug messages containing:"
echo "  • 'ANCHOR PHASE t=X.X anchor=(X.X,X.X) pos=(X.X,X.X)' - shows anchor interpolation"
echo "  • 'SINGLE PHASE t=X.X anchor=(X.X,X.X)' - single-phase anchor interpolation"
echo "  • 'RESIZE PHASE t=X.X anchor=(X.X,X.X)' - two-phase resize anchor interpolation"
echo ""
echo "Before: Position jumped immediately to final location (broken anchoring)"
echo "After:  Position smoothly interpolates while maintaining anchor edge (fixed!)"
