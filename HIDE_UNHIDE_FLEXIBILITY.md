# Hide/Unhide Commands Flexibility Update

## Changes Made

### Enhanced Command Flexibility

Updated the `--hide` and `--unhide` commands to support optional window selectors, making them consistent with other window commands like `--focus`, `--close`, etc.

### Command Usage Examples

#### Basic Usage (Acting Window)

```bash
yabai -m window --hide          # Hide currently focused window
yabai -m window --unhide        # Unhide currently focused window
```

#### With Window Selectors

```bash
# By window ID
yabai -m window --hide 1234
yabai -m window --unhide 1234

# By direction
yabai -m window --hide west
yabai -m window --unhide east

# By stack position
yabai -m window --hide stack.next
yabai -m window --unhide stack.prev

# By application
yabai -m window --hide $(yabai -m query --windows --app Safari | jq '.[0].id')
```

### Implementation Details

1. **Window Selector Parsing**: Both commands now use `parse_window_selector(rsp, &message, acting_window, true)` to handle optional selectors

2. **Fallback Behavior**: If no selector is provided, commands fall back to `acting_window` (currently focused window)

3. **Error Handling**: Consistent error reporting when neither selector nor acting window can be found

4. **Exception List Updated**: Added both commands to the list of commands that can work without `acting_window` being pre-set

### Behavior Consistency

The hide/unhide commands now follow the same pattern as:

- `--focus [selector]`
- `--close [selector]`
- `--minimize [selector]`
- `--deminimize [selector]`

### Benefits

- **Flexibility**: Can target specific windows without changing focus
- **Scripting**: Better automation capabilities for hiding/showing specific windows
- **Consistency**: Unified command interface across all window operations
- **Backward Compatibility**: Existing usage patterns continue to work

### Files Modified

- `/Users/jpatrolla/Playground/yabai/src/message.c` - Enhanced command parsing and selector support

### Compilation Status

✅ Successfully compiles without errors (only unrelated warnings remain)
