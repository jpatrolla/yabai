#!/bin/bash

# Test script for enhanced anchoring debug output
# This script tests the new comprehensive anchoring analysis debug messages

echo "🔗 Testing Enhanced Anchoring Debug Output"
echo "=========================================="

# Install the new binary
echo "Installing new yabai binary..."
sudo cp bin/yabai /usr/local/bin/yabai

# Restart yabai with frame-based animations enabled
echo "Restarting yabai with frame-based animations..."
yabai --restart-service

# Wait for yabai to start
sleep 2

# Enable frame-based animations
yabai -m config window_animation_frame_based_enabled on
yabai -m config window_animation_duration 0.8
yabai -m config window_animation_frame_rate 30

echo "Configuration applied. Testing window operations..."

# Test various window operations to trigger anchoring analysis
echo "1. Testing window resize (should show edge analysis)..."
yabai -m window --resize left:-50:0

sleep 1

echo "2. Testing window swap (should show tree position analysis)..."
yabai -m window --swap east

sleep 1

echo "3. Testing window move to different space (should show multi-monitor analysis)..."
# Get current space and move to next
current_space=$(yabai -m query --spaces --space | jq '.index')
next_space=$((current_space + 1))
if [ $next_space -le $(yabai -m query --spaces | jq '. | length') ]; then
    yabai -m window --space $next_space
fi

sleep 1

echo "4. Testing window movement within space..."
yabai -m window --warp north

echo ""
echo "🔗 Enhanced anchoring debug test completed!"
echo "Check the yabai logs or console output for the detailed anchoring analysis."
echo ""
echo "The new debug output should show:"
echo "  ✅ Screen edge relationships (which edges touch screen boundaries)"
echo "  ✅ Tree position analysis (BSP tree location and split types)"
echo "  ✅ Edge movement analysis (which edges are stationary vs moving)"
echo "  ✅ Anchoring recommendations based on the analysis"
echo ""
echo "If you see 'fdb ANCHORING ANALYSIS' sections with detailed breakdowns,"
echo "the enhanced debug system is working correctly!"
