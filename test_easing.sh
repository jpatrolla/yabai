#!/bin/bash

echo "🎨 Testing Easing Functions in Frame-Based Animation"
echo "=================================================="

# Enable frame-based animation
echo "✅ Enabling frame-based animation..."
./bin/yabai -m config window_animation_frame_based_enabled on

# Set animation duration
echo "⏱️  Setting animation duration to 0.6s for easing visibility..."
./bin/yabai -m config window_animation_duration 0.6

# Check current focused window
WINDOW_ID=$(./bin/yabai -m query --windows --window | jq -r '.id // empty')

if [ -z "$WINDOW_ID" ]; then
    echo "❌ No focused window found. Please focus a window and try again."
    exit 1
fi

echo "🎯 Testing with window ID: $WINDOW_ID"
echo ""

# List of easing functions to test
easing_functions=(
    "ease_in_sine:0"
    "ease_out_sine:1"
    "ease_in_out_sine:2"
    "ease_in_quad:3"
    "ease_out_quad:4"
    "ease_in_out_quad:5"
    "ease_in_cubic:6"
    "ease_out_cubic:7"
    "ease_in_out_cubic:8"
)

positions=(
    "100:100:600:400"
    "300:150:700:500"
    "150:200:650:450"
    "250:100:750:550"
    "200:250:600:350"
    "350:175:680:480"
    "175:125:720:420"
    "275:225:640:460"
    "225:175:700:500"
)

for i in "${!easing_functions[@]}"; do
    IFS=':' read -r name value <<< "${easing_functions[$i]}"
    IFS=':' read -r x y w h <<< "${positions[$i]}"
    
    echo "🧪 Testing ${name} (value: ${value})"
    echo "   Setting easing: yabai -m config window_animation_easing ${value}"
    ./bin/yabai -m config window_animation_easing ${value}
    
    echo "   Animating to: ${x},${y} ${w}x${h}"
    ./bin/yabai -m window --move abs:${x}:${y}
    sleep 0.1
    ./bin/yabai -m window --resize abs:${w}:${h}
    
    echo "   ✅ ${name} animation completed"
    sleep 1.5
    echo ""
done

# Reset to a nice default
echo "🔄 Resetting to ease_out_cubic (default feel)"
./bin/yabai -m config window_animation_easing 7
./bin/yabai -m window --move abs:200:150
sleep 0.1
./bin/yabai -m window --resize abs:800:600

echo ""
echo "✅ Easing function test completed!"
echo ""
echo "💡 You should have seen different animation feels:"
echo "   - ease_in_*: Slow start, fast end"
echo "   - ease_out_*: Fast start, slow end (most natural)"
echo "   - ease_in_out_*: Slow start and end, fast middle"
echo "   - *_sine: Gentle curves"
echo "   - *_quad: Moderate curves" 
echo "   - *_cubic: Strong curves"
echo ""
echo "🎬 Check debug logs for frame timing: 't=linear mt=eased'"
