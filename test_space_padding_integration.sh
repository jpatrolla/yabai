#!/bin/bash

# Test script for space padding integration with edge threshold
# This script verifies that space padding is correctly factored into edge detection

echo "🔧 Testing Space Padding Integration with Edge Threshold"
echo "========================================================"

# Install the new binary
echo "Installing updated yabai binary..."
sudo cp bin/yabai /usr/local/bin/yabai

# Restart yabai with frame-based animations enabled
echo "Restarting yabai..."
yabai --restart-service

# Wait for yabai to start
sleep 3

# Configure space padding to test the integration
echo "Setting up space padding for testing..."
yabai -m config layout bsp
yabai -m config top_padding 20
yabai -m config bottom_padding 20
yabai -m config left_padding 15
yabai -m config right_padding 15
yabai -m config window_gap 10

# Configure frame-based animations with a specific edge threshold
echo "Configuring frame-based animations..."
yabai -m config window_animation_frame_based_enabled on
yabai -m config window_animation_duration 1.0
yabai -m config window_animation_frame_rate 30
yabai -m config window_animation_edge_threshold 10.0

echo "Configuration applied:"
echo "  - Top padding: 20px"
echo "  - Bottom padding: 20px" 
echo "  - Left padding: 15px"
echo "  - Right padding: 15px"
echo "  - Edge threshold: 10px"
echo ""

echo "Testing edge detection with space padding..."
echo "1. Moving window to test edge calculations..."

# Test window resize that should trigger edge analysis
yabai -m window --resize left:-30:0
sleep 1

echo "2. Moving window to different position..."
yabai -m window --resize right:50:0
sleep 1

echo "3. Testing window swap..."
yabai -m window --swap east
sleep 1

echo ""
echo "🔧 Space padding integration test completed!"
echo ""
echo "Check the yabai logs for 'fdb SPACE PADDING' sections that should show:"
echo "  ✅ Space padding values: T=20.0 B=20.0 L=15.0 R=15.0"
echo "  ✅ Edge threshold: 10.0 pixels"
echo "  ✅ Effective screen bounds accounting for padding"
echo "  ✅ Distance calculations relative to effective bounds"
echo ""
echo "The edge detection should now properly account for the space padding"
echo "so windows touching the effective screen edges (after padding) are"
echo "correctly identified as touching edges for anchoring purposes."
