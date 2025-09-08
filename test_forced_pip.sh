#!/bin/bash

# Test script for forced PiP scaling that bypasses transform checks
# This will test the new do_window_scale_forced function 

echo "=== Testing Forced PiP Scaling ==="
echo "This test uses the new forced mode that bypasses CGAffineTransformEqualToTransform checks"
echo

# Get the focused window ID
window_id=$(./bin/yabai -m query --windows --window | jq -r '.id')

if [ "$window_id" = "null" ] || [ -z "$window_id" ]; then
    echo "No focused window found. Please focus a window and try again."
    exit 1
fi

echo "Using window ID: $window_id"
echo

# Test 1: Create PiP using forced mode (bypasses transform check)
echo "Test 1: Creating PiP using FORCED mode..."
./bin/yabai -m window --create-pip-forced --x 100 --y 100 --w 300 --h 200

echo "Waiting 2 seconds..."
sleep 2

# Test 2: Move PiP using forced mode
echo "Test 2: Moving PiP using FORCED mode..."
./bin/yabai -m window --move-pip-forced --x 200 --y 150

echo "Waiting 2 seconds..."
sleep 2

# Test 3: Move PiP again using forced mode  
echo "Test 3: Moving PiP again using FORCED mode..."
./bin/yabai -m window --move-pip-forced --x 300 --y 200

echo "Waiting 2 seconds..."
sleep 2

# Test 4: Restore from PiP using forced mode
echo "Test 4: Restoring from PiP using FORCED mode..."
./bin/yabai -m window --restore-pip-forced

echo "Forced PiP scaling test complete!"
echo
echo "This test demonstrates the new forced scaling that:"
echo "- Bypasses CGAffineTransformEqualToTransform checks in mode 1"
echo "- Should allow PiP updates even when dimensions haven't been created yet"
echo "- Provides enhanced logging to track transform comparison issues"
