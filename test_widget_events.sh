#!/bin/bash

echo "Testing event-driven space widget updates and icon click detection..."
echo "This test demonstrates that the widget now updates reactively to window state changes"
echo "and can detect clicks on individual app icons."
echo ""

# Start yabai in the background
echo "Starting yabai in background..."
./bin/yabai --verbose &
YABAI_PID=$!

# Give yabai time to start
sleep 2

echo "Yabai started with PID: $YABAI_PID"
echo ""
echo "The widget should now be visible and showing app icons for hidden/minimized/scratched windows."
echo ""
echo "🎯 NEW FEATURE: Icon Click Detection & Window Activation"
echo "- Click on any app icon in the widget"
echo "- The console will log: '*** WINDOW ICON CLICKED *** Window ID: XXXXX'"
echo "- The window will be automatically:"
echo "  • Deminimized (if minimized)"
echo "  • Unhidden/shown using scripting_addition_order_window"
echo "  • Focused and raised to front"
echo "  • Application unhidden (if hidden)"
echo ""
echo "To test the event-driven updates:"
echo "1. Minimize a window (Cmd+M) - widget should update immediately"
echo "2. Hide an application (Cmd+H) - widget should update immediately" 
echo "3. Use space_manager floating window functions - widget should update immediately"
echo "4. Click on individual icons - window will be activated and brought to front!"
echo ""
echo "🎯 WINDOW ACTIVATION FEATURES:"
echo "✅ Automatic deminimization of minimized windows"
echo "✅ Unhiding/showing of hidden windows" 
echo "✅ Focus and raise window to front"
echo "✅ Application unhiding (if application was hidden)"
echo ""
echo "Before these optimizations, the widget:"
echo "- Only updated on space changes or manual refresh calls"
echo "- Had no individual icon click detection"
echo ""
echo "Now it updates on these events:"
echo "- EVENT_HANDLER_APPLICATION_HIDDEN"
echo "- EVENT_HANDLER_APPLICATION_VISIBLE" 
echo "- EVENT_HANDLER_WINDOW_MINIMIZED"
echo "- EVENT_HANDLER_WINDOW_DEMINIMIZED"
echo "- space_manager_hide_floating_windows_on_space()"
echo "- space_manager_show_floating_windows_on_space()"
echo "- space_manager_recover_floating_windows_on_space()"
echo ""
echo "🔥 Plus: Individual icon click detection with FULL WINDOW ACTIVATION!"
echo ""
echo "Press Enter to stop yabai and exit..."
read

# Kill yabai
echo "Stopping yabai..."
kill $YABAI_PID
wait $YABAI_PID 2>/dev/null

echo "Test complete!"
