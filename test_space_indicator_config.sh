#!/bin/bash

echo "Testing space_indicator configuration..."

# Test setting enabled to true
echo "Setting enabled=true..."
./bin/yabai -m config space_indicator enabled=true

# Test setting indicator height
echo "Setting indicator_height=12.0..."
./bin/yabai -m config space_indicator indicator_height=12.0

# Test setting position to top
echo "Setting position=top..."
./bin/yabai -m config space_indicator position=top

# Test setting color
echo "Setting indicator_color=0xff00ff00..."
./bin/yabai -m config space_indicator indicator_color=0xff00ff00

# Test getting current config
echo "Getting current config:"
./bin/yabai -m config space_indicator

echo "Configuration test completed!"
