#!/bin/bash

# Debug proxy window visibility issues
echo "🔍 Debugging proxy window visibility..."

# First, let's check if proxy windows are being created
echo "Checking for proxy windows in the system..."
yabai -m query --windows | jq '.[] | select(.pid == null or .app == "") | {id: .id, frame: .frame, level: .level, "is-floating": ."is-floating", "is-visible": ."is-visible", "is-minimized": ."is-minimized", opacity: .opacity}'

echo ""
echo "Checking SkyLight window list for proxy windows..."
# Check if we can see any proxy windows using SLS
python3 -c "
import subprocess
import json

# Get all windows from yabai
result = subprocess.run(['yabai', '-m', 'query', '--windows'], capture_output=True, text=True)
windows = json.loads(result.stdout)

# Look for potential proxy windows (windows with no app name or unusual properties)
proxy_candidates = []
for window in windows:
    if not window.get('app') or window.get('app') == '':
        proxy_candidates.append({
            'id': window['id'],
            'frame': window['frame'],
            'level': window.get('level', 'unknown'),
            'opacity': window.get('opacity', 'unknown'),
            'visible': window.get('is-visible', 'unknown'),
            'floating': window.get('is-floating', 'unknown')
        })

if proxy_candidates:
    print('Found potential proxy windows:')
    for proxy in proxy_candidates:
        print(f'  Window ID: {proxy[\"id\"]}')
        print(f'    Frame: {proxy[\"frame\"]}')
        print(f'    Level: {proxy[\"level\"]}')
        print(f'    Opacity: {proxy[\"opacity\"]}')
        print(f'    Visible: {proxy[\"visible\"]}')
        print(f'    Floating: {proxy[\"floating\"]}')
        print()
else:
    print('No potential proxy windows found')
"

echo ""
echo "Testing window resize to trigger proxy creation..."
echo "Resize a window to see if proxies are created..."

# Get a window to test with
TEST_WINDOW=$(yabai -m query --windows | jq -r '.[] | select(.app != "" and ."is-visible" == true and ."is-minimized" == false) | .id' | head -1)

if [ ! -z "$TEST_WINDOW" ]; then
    echo "Testing with window ID: $TEST_WINDOW"
    echo "Current window info:"
    yabai -m query --windows --window $TEST_WINDOW | jq '{id: .id, app: .app, frame: .frame}'
    
    echo ""
    echo "Triggering resize animation (this should create proxy windows)..."
    yabai -m window $TEST_WINDOW --resize abs:600:400
    sleep 0.5
    
    echo "Checking for proxy windows after resize..."
    yabai -m query --windows | jq '.[] | select(.pid == null or .app == "") | {id: .id, frame: .frame, opacity: .opacity, "is-visible": ."is-visible"}'
else
    echo "No suitable test window found"
fi
