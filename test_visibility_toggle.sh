#!/bin/bash

# Test script for the new window visibility toggle functionality

echo "Testing window visibility toggle..."

# Check if yabai is running
if ! pgrep -f yabai > /dev/null; then
    echo "Error: yabai is not running"
    exit 1
fi

# Test the new visibility toggle command
echo "Testing: yabai -m window --toggle visibility"

# This should toggle the visibility of the currently focused window
# (if it's a floating window)
./bin/yabai -m window --toggle visibility

if [ $? -eq 0 ]; then
    echo "✓ Command executed successfully"
else
    echo "✗ Command failed"
fi

echo "Test completed. Check if the focused floating window visibility was toggled."
