#!/bin/bash

echo "🧪 Testing Transaction-Aware PiP Scaling System"
echo "================================================"

# Install the new version
echo "📦 Installing updated yabai..."
./rebuild_and_install.sh

# Wait for yabai to restart
sleep 2

echo "⚙️  Testing frame-based async animation with transaction support..."

# Test 1: Simple BSP layout changes to trigger frame-based async animations
echo "📐 Creating test layout..."
/opt/homebrew/bin/yabai -m space --layout bsp

echo "🪟 Opening test windows..."
# Open a couple of test windows
open -a "TextEdit" 
sleep 1
open -a "Calculator"
sleep 1

echo "🎬 Triggering BSP layout changes to test transaction-aware animations..."

# These commands should trigger the async frame-based animation system with transactions
/opt/homebrew/bin/yabai -m window --ratio rel:0.1  # Should trigger resize animation
sleep 2

/opt/homebrew/bin/yabai -m window --ratio rel:-0.1  # Should trigger resize animation
sleep 2

echo "🔄 Testing window swapping..."
/opt/homebrew/bin/yabai -m window --swap west || echo "No window to west, that's OK"
sleep 2

echo "📊 Testing more complex operations..."
/opt/homebrew/bin/yabai -m window --ratio rel:0.2
sleep 1
/opt/homebrew/bin/yabai -m window --ratio rel:-0.2
sleep 2

echo "✅ Transaction-aware PiP animation tests completed!"
echo "📝 Check Console.app for transaction debug logs (search for 'FORCED+TX')"
echo "🎯 Look for logs containing 'Added transform to transaction' and 'PiP+TX'"

# Optional: Clean up
read -p "🧹 Close test windows? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    pkill "TextEdit" 2>/dev/null || true
    pkill "Calculator" 2>/dev/null || true
    echo "✨ Test windows closed."
fi

echo "🏁 Test complete!"
