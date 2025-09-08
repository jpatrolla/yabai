#!/bin/bash

# Test script for the centralized split-aware common-edge anchoring system
# This script tests the unified frame-based transition logic

echo "🧪 Testing Centralized Split-Aware Common-Edge Anchoring System"
echo "=================================================================="

# Ensure yabai is built with our centralized changes
echo "Building yabai with centralized anchoring system..."
make clean && make

if [ $? -ne 0 ]; then
    echo "❌ Build failed. Please fix compilation errors first."
    exit 1
fi

echo "✅ Build successful with centralized anchoring system!"

# Enable frame-based animations and two-phase mode
echo "Configuring animation settings for centralized system..."
./bin/yabai -m config window_animation_frame_based_enabled true
./bin/yabai -m config window_animation_two_phase_enabled true
./bin/yabai -m config window_animation_edge_threshold 5.0
./bin/yabai -m config window_animation_duration 0.5

echo "✅ Animation settings configured for centralized system"

echo ""
echo "🔍 Centralized System Testing Scenarios:"
echo "The new unified anchoring system provides:"
echo "  🎯 Single source of truth for all anchor calculations"
echo "  🧠 Smart operation detection (resize/move/mixed)"
echo "  🔗 Common edge preservation with priority-based selection" 
echo "  📐 Split-aware fallback logic"
echo "  🖥️  Multi-monitor handoff detection"
echo "  ⚙️  Configuration override support"
echo ""
echo "1. Open multiple terminal windows"
echo "2. Arrange them in different split configurations (horizontal/vertical)"
echo "3. Try the following operations and observe the unified anchoring behavior:"
echo ""
echo "   📏 Resize operations (unified anchor detection):"
echo "   - yabai -m window --resize left:-20:0"
echo "   - yabai -m window --resize right:20:0"
echo "   - yabai -m window --resize top:0:-20"
echo "   - yabai -m window --resize bottom:0:20"
echo ""
echo "   🔄 Move operations (common edge preservation):"
echo "   - yabai -m window --swap north"
echo "   - yabai -m window --swap south"
echo "   - yabai -m window --swap east"
echo "   - yabai -m window --swap west"
echo ""
echo "   📦 Layout changes (split-aware anchoring):"
echo "   - yabai -m space --layout bsp"
echo "   - yabai -m space --layout stack"
echo "   - yabai -m space --layout float"
echo ""
echo "💡 Watch the debug output in Console.app or via:"
echo "   log stream --predicate 'process == \"yabai\"' --level debug | grep '🔗'"
echo ""
echo "🔗 Look for centralized anchor debug messages:"
echo "   - '🔗 Window X: anchor(x,y) edges(T:X B:X L:X R:X) split:X op:type'"
echo "   - '🔗 Setup: Window X unified anchor=X legacy_anchor=X split=X'"
echo "   These show:"
echo "   - Unified anchor point coordinates"
echo "   - Common edge detection results (T/B/L/R)"
echo "   - Split type and operation classification"
echo "   - Legacy compatibility mapping"
echo ""
echo "Expected centralized behaviors:"
echo "- 🏗️  Consistent anchoring across all animation types"
echo "- 🎯 Priority-based edge selection (corners > edges > split-aware fallback)"
echo "- 🧠 Smart operation detection influences anchor choice"
echo "- 📐 Split context awareness (SPLIT_Y prefers top/bottom, SPLIT_X prefers left/right)"
echo "- 🖥️  Smooth multi-monitor transitions with automatic detection"
echo "- ⚙️  Configuration overrides work seamlessly"
echo "- 🔧 Legacy resize_anchor compatibility maintained"

# Test configuration overrides
echo ""
echo "🧪 Testing Configuration Overrides:"
echo "Test force anchor overrides:"
echo "  ./bin/yabai -m config window_animation_force_top_anchor true"
echo "  ./bin/yabai -m config window_animation_force_bottom_anchor true"
echo "  ./bin/yabai -m config window_animation_force_left_anchor true"  
echo "  ./bin/yabai -m config window_animation_force_right_anchor true"
echo ""
echo "Test edge threshold adjustments:"
echo "  ./bin/yabai -m config window_animation_edge_threshold 1.0   # Strict"
echo "  ./bin/yabai -m config window_animation_edge_threshold 10.0  # Loose"

# Optional: Start a simple test sequence
read -p "Start automated centralized system test? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🚀 Starting automated centralized system test..."
    
    # Open test windows
    echo "Opening test windows..."
    open -a Terminal &
    sleep 2
    open -a Terminal &
    sleep 2
    open -a Terminal &
    sleep 2
    
    # Setup BSP layout
    echo "Setting up BSP layout for split-aware testing..."
    ./bin/yabai -m space --layout bsp
    sleep 1
    
    # Test resize operations (should show unified anchor detection)
    echo "Testing resize operations with unified anchoring..."
    ./bin/yabai -m window --resize right:50:0
    sleep 1
    ./bin/yabai -m window --resize bottom:0:30
    sleep 1
    ./bin/yabai -m window --resize left:-30:0
    sleep 1
    
    # Test swap operations (should show common edge preservation)
    echo "Testing swap operations with edge preservation..."
    ./bin/yabai -m window --swap south
    sleep 1
    ./bin/yabai -m window --swap east
    sleep 1
    
    echo "✅ Automated centralized system test complete!"
    echo "Check debug logs to see unified anchor calculations in action."
fi

echo ""
echo "🏁 Centralized anchoring system test complete."
echo "   The new unified system provides consistent, predictable anchoring"
echo "   across all window operations with smart operation detection and"
echo "   split-aware fallback logic. Monitor debug output to verify behavior."
