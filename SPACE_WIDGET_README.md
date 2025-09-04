# Space Widget Proof of Concept

This is a proof of concept implementation of a custom widget component for yabai that demonstrates:

1. **Visual Component**: A 60x60 pixel square rendered at the bottom-left corner of the screen
2. **Interactive**: Clickable widget that cycles through colors (white → red → blue → white)
3. **Integration**: Proper integration with yabai's architecture similar to the space indicator
4. **API**: Query interface to check widget status

## Files Created

- `src/space_widget.h` - Header file defining the widget structure and functions
- `src/space_widget.c` - Implementation of the widget functionality
- `test_widget.sh` - Simple test script to verify functionality

## Files Modified

- `src/space_manager.c` - Added widget initialization and global variable
- `src/event_loop.c` - Added mouse click detection for the widget
- `src/manifest.m` - Added space_widget.c to the build
- `src/message.c` - Added `--widget` query command

## How it Works

### Initialization

The widget is initialized in `space_manager_begin()` alongside the space indicator, creating:

- A 60x60 pixel CoreGraphics window
- Color array with white, red, and blue colors
- Proper window positioning at bottom-left corner with margins

### Mouse Interaction

The widget intercepts mouse clicks in `event_loop.c` MOUSE_DOWN handler:

- Checks if click coordinates fall within widget bounds
- Cycles through colors when clicked
- Updates the visual representation immediately

### Rendering

Uses CoreGraphics to:

- Create a floating window above all other content
- Set appropriate window level and stickiness
- Render solid colors with smooth transitions

## Usage

### Build

```bash
make clean
make
```

### Query Widget Status

```bash
bin/yabai -m query --widget
```

Returns JSON with current state:

```json
{ "active": true, "color": "white" }
```

### Test Interaction

1. Look for the 60x60 white square at bottom-left of screen
2. Click on it to cycle through colors
3. Run query command to verify color changes

## Architecture Notes

The component follows yabai's existing patterns:

1. **Separation of Concerns**: Widget logic separated into its own files
2. **Global State**: Uses global widget instance like space_indicator
3. **Event Integration**: Hooks into existing mouse event pipeline
4. **Query API**: Extends message.c query system
5. **Build Integration**: Added to manifest.m for compilation

This demonstrates how to extend yabai with custom UI components that can:

- Render visual elements
- Handle user interaction
- Integrate with the query/command system
- Maintain state across space changes

## Future Extensions

This proof of concept could be extended to:

- Display space-specific data/colors
- Support configuration via config file
- Add more visual states or animations
- Respond to space change events
- Support multiple widgets or positioning options
