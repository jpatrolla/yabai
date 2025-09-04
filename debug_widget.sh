#!/bin/bash

echo "=== Space Widget Debug Test Suite ==="
echo

# Test 1: Check if widget is active
echo "1. Testing widget status..."
WIDGET_STATUS=$(bin/yabai -m query --widget)
echo "Widget status: $WIDGET_STATUS"
echo

# Test 2: Manual color cycling (bypasses click detection)
echo "2. Testing manual color cycling (bypasses clicks)..."
echo "Current state:"
bin/yabai -m query --widget

echo
echo "Triggering manual test cycle..."
MANUAL_TEST=$(bin/yabai -m query --widget-test)
echo "Manual test result: $MANUAL_TEST"

echo
echo "State after manual cycle:"
bin/yabai -m query --widget
echo

# Test 3: Click detection guidance
echo "3. Click detection test..."
echo "The widget should be visible at the bottom-left corner (60x60 pixels)"
echo
echo "Based on the yabai debug output, look for these messages when you click:"
echo "  - 'DEBUG: Mouse click at: X.XX, Y.YY'"
echo "  - 'DEBUG: Click contains point: YES' (if you hit the widget)"
echo "  - 'DEBUG: *** SPACE WIDGET CLICKED! ***' (if click detection works)"
echo "  - 'DEBUG: space_widget_cycle_color called' (if cycling works)"
echo
echo "Try clicking on the bottom-left widget now and watch the yabai terminal output!"
echo

# Test 4: Multiple manual cycles to verify all colors
echo "4. Testing full color cycle (manual)..."
echo "Starting color:"
bin/yabai -m query --widget

echo "Cycle 1:"
bin/yabai -m query --widget-test | jq -r '.new_color' 2>/dev/null || bin/yabai -m query --widget-test

echo "Cycle 2:"
bin/yabai -m query --widget-test | jq -r '.new_color' 2>/dev/null || bin/yabai -m query --widget-test

echo "Cycle 3 (should return to start):"
bin/yabai -m query --widget-test | jq -r '.new_color' 2>/dev/null || bin/yabai -m query --widget-test

echo
echo "If manual cycling works but clicks don't, the issue is in click detection."
echo "If manual cycling doesn't work, the issue is in color update logic."
