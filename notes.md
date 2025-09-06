What is animation_connection?
animation_connection is a dedicated SkyLight connection created specifically for handling window animations. Here's how it works:

Creation (line 645 and throughout):
This creates a new connection to the WindowServer that's separate from the main g_connection.

Purpose: It's used to create and manipulate window proxy objects during animations. When yabai animates windows (like when moving/resizing them), it:

Creates transparent proxy windows that show a snapshot of the real window
Moves/scales these proxies smoothly
Then swaps the real window to the final position
Usage in animation flow:

Jankyborders Communication
The communication with jankyborders happens through a different mechanism - Mach ports:

The Relationship
animation_connection: Handles the actual window animation rendering
jankyborders notification: Tells jankyborders about window changes so it can update borders accordingly
They work together but are separate systems:

Animation connection creates/moves proxy windows for smooth animations
Jankyborders is notified about these changes (events 1325, 1326, etc.) so it can update border positions
The animation_connection is purely for WindowServer operations, not for IPC with jankyborders
The separation makes sense because:

Window animations need direct WindowServer access for performance
Jankyborders runs as a separate process and needs IPC (Mach ports) for communication
Multiple animation connections can exist simultaneously for parallel animations
