#!/bin/bash

echo "Testing space widget click functionality..."

# Query initial state
echo "Initial widget state:"
bin/yabai -m query --widget

echo ""
echo "The widget should now be 60x60 pixels at the bottom-left corner"
echo "To test the widget, click on the square at coordinates:"
echo "  X: 10-70 pixels from the left edge"  
echo "  Y: bottom 60 pixels of the screen"
echo ""
echo "After clicking, run this command again to see if the color changed:"
echo "bin/yabai -m query --widget"

echo ""
echo "The widget should cycle through: white -> red -> blue -> white"

# Test multiple clicks to cycle through colors
echo ""
echo "--- Testing Color Cycling ---"
echo "Current color:"
bin/yabai -m query --widget

echo ""
echo "Click on the widget now and then press Enter to check the color change..."
read -p "Press Enter after clicking the widget: " dummy

echo "Color after first click:"
bin/yabai -m query --widget

echo ""
echo "Click again and press Enter to see the next color..."
read -p "Press Enter after clicking the widget again: " dummy

echo "Color after second click:"  
bin/yabai -m query --widget
