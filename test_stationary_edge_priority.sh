#!/bin/bash

# Test script for the new stationary edge prioritization anchoring system
# This verifies that stationary edges take priority over other anchoring methods

echo "🔗 Testing Stationary Edge Prioritization Anchoring"
echo "===================================================="

# Install the new binary
echo "Installing updated yabai binary..."
sudo cp bin/yabai /usr/local/bin/yabai

# Restart yabai with frame-based animations enabled  
echo "Restarting yabai..."
yabai --restart-service

# Wait for yabai to start
sleep 3

# Configure for optimal testing
echo "Setting up test configuration..."
yabai -m config layout bsp
yabai -m config top_padding 20
yabai -m config bottom_padding 20  
yabai -m config left_padding 15
yabai -m config right_padding 15
yabai -m config window_gap 10

# Enable frame-based animations with detailed debug
yabai -m config window_animation_frame_based_enabled on
yabai -m config window_animation_duration 1.2
yabai -m config window_animation_frame_rate 30
yabai -m config window_animation_edge_threshold 8.0

echo "Configuration applied. Testing stationary edge prioritization..."
echo ""

echo "TEST 1: Bottom edge stationary (should prioritize bottom anchor)"
echo "---------------------------------------------------------------"
yabai -m window --resize top:0:-50
sleep 1.5

echo ""
echo "TEST 2: Top edge stationary (should prioritize top anchor)"  
echo "-----------------------------------------------------------"
yabai -m window --resize bottom:0:50
sleep 1.5

echo ""
echo "TEST 3: Left edge stationary (should prioritize left anchor)"
echo "------------------------------------------------------------"
yabai -m window --resize right:50:0
sleep 1.5

echo ""
echo "TEST 4: Right edge stationary (should prioritize right anchor)"
echo "--------------------------------------------------------------"
yabai -m window --resize left:-50:0
sleep 1.5

echo ""
echo "TEST 5: Bottom-left corner stationary (should prioritize corner)"
echo "----------------------------------------------------------------"
yabai -m window --resize top:0:-30 right:30:0
sleep 1.5

echo ""
echo "🔗 Stationary edge prioritization test completed!"
echo ""
echo "Expected behavior in debug output:"
echo "  ✅ 'PRIORITY: [B] edges are stationary -> anchor to stationary edge!'"
echo "  ✅ '🔗 Prioritizing stationary BOTTOM edge for anchoring'"
echo "  ✅ Edge priority order: Bottom > Top > Left > Right"
echo "  ✅ Stationary edges should override tree-based fallbacks"
echo ""
echo "Check the debug output for 'fdb ANCHORING ANALYSIS' sections to see"
echo "the new prioritization logic in action. Stationary edges should now"
echo "be the PRIMARY factor in anchor selection!"
