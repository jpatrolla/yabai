#!/bin/bash

# Test script for frame-based animation POC

echo "🎬 Testing Frame-Based Animation POC"
echo "======================================"

# First, set the flag to enable frame-based animation
echo "Enabling frame-based animation..."
./bin/yabai -m config window_animation_frame_based_enabled on

# Set a reasonable animation duration
echo "Setting animation duration to 0.5 seconds..."
./bin/yabai -m config window_animation_duration 0.5

# Get a test window (focused window)
WINDOW_ID=$(./bin/yabai -m query --windows --window | jq -r '.id')
echo "Test window ID: $WINDOW_ID"

if [ "$WINDOW_ID" = "null" ] || [ -z "$WINDOW_ID" ]; then
    echo "❌ No focused window found. Please focus a window and try again."
    exit 1
fi

echo ""
echo "🚀 Testing animation (window will animate to different positions)"
echo "Press Ctrl+C to stop testing..."

# Test different positions to showcase the frame-based animation
positions=(
    "100:100:800:600"
    "200:150:700:500" 
    "50:50:900:700"
    "300:200:600:400"
)

for pos in "${positions[@]}"; do
    IFS=':' read -r x y w h <<< "$pos"
    echo "📱 Animating to position: ${x},${y} size: ${w}x${h}"
    
    # Use yabai's window resize command which should trigger our frame-based animation
    ./bin/yabai -m window --move abs:${x}:${y}
    sleep 1
    ./bin/yabai -m window --resize abs:${w}:${h}
    
    echo "   Animation completed. Waiting 2 seconds..."
    sleep 2
done

echo ""
echo "✅ Frame-based animation test completed!"
echo "💡 If you saw smooth transformations instead of proxy windows, the POC is working!"
