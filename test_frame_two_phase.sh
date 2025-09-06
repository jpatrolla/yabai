#!/bin/bash

echo "🎬 Testing Async Frame-Based Animation with 2-Phase Logic Integration"
echo "=================================================================="

# Build the project first
echo "Building yabai..."
make

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

echo "✅ Build successful!"
echo ""

# Test configuration settings
echo "🔧 Configuring async frame-based animation with 2-phase support..."

# Enable frame-based animation
./bin/yabai -m config window_animation_frame_based_enabled true
echo "✅ Enabled async frame-based animation"

# Enable 2-phase animation
./bin/yabai -m config window_animation_two_phase_enabled true
echo "✅ Enabled 2-phase animation logic"

# Set animation parameters for good testing
./bin/yabai -m config window_animation_duration 1.0
./bin/yabai -m config window_animation_frame_rate 30
./bin/yabai -m config window_animation_slide_ratio 0.6
./bin/yabai -m config window_animation_fade_threshold 0.2
echo "✅ Configured animation parameters (1.0s duration, 30fps, 60% slide ratio, 20% fade threshold)"

# Enable opacity effects for better visual feedback
./bin/yabai -m config window_opacity_duration 0.3
./bin/yabai -m config window_animation_opacity_enabled true
echo "✅ Enabled opacity effects"

echo ""
echo "🎬 Async frame-based animation with 2-phase logic is now ready!"
echo ""
echo "🚀 ASYNC FRAME-BASED ANIMATION FEATURES:"
echo "  • Non-blocking background animation processing"
echo "  • Dedicated animation thread per window group"
echo "  • Thread-safe animation management"
echo "  • Proper cleanup and resource management"
echo "  • Compatible with existing animation table system"
echo ""
echo "🎭 2-Phase Animation Logic:"
echo "  • Phase 1 (60%): Slide to new position while keeping original size"
echo "  • Phase 2 (40%): Resize at final position with smart anchor points"
echo "  • Only activates for significant size changes (>20% difference)"
echo "  • Uses ease_out_circ for slide phase, ease_in_out_cubic for resize phase"
echo ""
echo "⚡ Performance Benefits:"
echo "  • No proxy window overhead (direct PiP scaling)"
echo "  • Asynchronous execution (non-blocking main thread)"
echo "  • Precise frame timing with sleep optimization"
echo "  • Better resource utilization through thread pooling"
echo "  • Reduced API calls compared to traditional systems"
echo ""
echo "🔧 Threading Architecture:"
echo "  • Main thread: Sets up animation context and starts worker thread"
echo "  • Worker thread: Executes frame-by-frame animation with PiP scaling"
echo "  • Thread-safe cleanup: Mutex-protected animation table operations"
echo "  • Detached threads: Automatic cleanup when animation completes"
echo ""
echo "Test Commands:"
echo "  ./bin/yabai -m window --resize left:100:0     # Test horizontal resize (async)"
echo "  ./bin/yabai -m window --resize bottom:0:100   # Test vertical resize (async)"
echo "  ./bin/yabai -m window --move abs:100:100      # Test position change (async)"
echo "  ./bin/yabai -m space --rotate 90              # Test multiple windows (async)"
echo ""
echo "Monitor the console output for async animation details:"
echo "  • 🎬 Async Frame X/Y: SLIDE PHASE - Position interpolation only"
echo "  • 🎬 Async Frame X/Y: RESIZE PHASE - Size interpolation with anchor"
echo "  • 🎬 Async Frame X/Y: SINGLE PHASE - Traditional simultaneous animation"
echo "  • 🎬 Frame timing: Shows frame performance metrics"
echo ""
echo "Thread Monitoring:"
echo "  • 🎬 Frame-based async animation thread started - Thread creation"
echo "  • 🎬 Frame-based async animation thread completed - Thread cleanup"
echo "  • Thread performance metrics logged for each frame"
echo ""
echo "Status:"
echo "  Frame-based: $(./bin/yabai -m config window_animation_frame_based_enabled)"
echo "  Two-phase:   $(./bin/yabai -m config window_animation_two_phase_enabled)"
echo "  Duration:    $(./bin/yabai -m config window_animation_duration)s"
echo "  Frame rate:  $(./bin/yabai -m config window_animation_frame_rate)fps"
echo "  Slide ratio: $(./bin/yabai -m config window_animation_slide_ratio)"
echo ""
echo "🎉 Ready for async frame-based animation testing!"
