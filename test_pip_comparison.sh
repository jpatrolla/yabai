#!/bin/bash

# Comprehensive test comparing regular vs forced PiP scaling
# This demonstrates the difference between normal and forced modes

echo "=== PiP Scaling Comparison Test ==="
echo "This test compares regular vs forced PiP scaling to demonstrate the transform check bypass"
echo

# Get the focused window ID
window_id=$(./bin/yabai -m query --windows --window | jq -r '.id')

if [ "$window_id" = "null" ] || [ -z "$window_id" ]; then
    echo "No focused window found. Please focus a window and try again."
    exit 1
fi

echo "Using window ID: $window_id"
echo

echo "=== TEST 1: Regular PiP Scaling (with transform checks) ==="
echo "This may block on transform comparisons if dimensions haven't been created yet"
./bin/yabai -m window --pip-test 100,100,300,200

echo
echo "Waiting 3 seconds before next test..."
sleep 3
echo

echo "=== TEST 2: FORCED PiP Scaling (bypasses transform checks) ==="
echo "This bypasses CGAffineTransformEqualToTransform checks and should always work"
./bin/yabai -m window --pip-test-forced 200,150,400,250

echo
echo "=== Test Summary ==="
echo "Regular Mode: Uses CGAffineTransformEqualToTransform checks"
echo "Forced Mode:  Bypasses transform checks in case 1 (move_pip)"
echo "The forced mode should resolve animation blocking issues!"
echo
echo "✅ PiP scaling comparison test completed!"
