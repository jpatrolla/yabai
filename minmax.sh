#!/usr/bin/env bash

# MinMax Window Clamping Script
# Clamps the MinMax Swift window to specific dimensions using yabai

# Configuration - adjust these values as needed
MIN_W=400; MIN_H=320  # Minimum width and height
MAX_W=400; MAX_H=320  # Maximum width and height

# Window identification options
WINDOW_TITLE="Min/Max Test Window"  # Match by window title
WINDOW_APP="MinMaxWindow"           # Or match by app name

# Function to log messages (optional)
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to find window by title or app name
find_target_window() {
    # Try to find by window title first
    local window_json=$(yabai -m query --windows | jq ".[] | select(.title == \"$WINDOW_TITLE\")")
    
    # If not found by title, try by app name
    if [ -z "$window_json" ] || [ "$window_json" = "null" ]; then
        window_json=$(yabai -m query --windows | jq ".[] | select(.app == \"$WINDOW_APP\")")
    fi
    
    echo "$window_json"
}

# Function to clamp window dimensions
clamp_window() {
    local target_window="$1"
    
    if [ -z "$target_window" ] || [ "$target_window" = "null" ]; then
        log_message "Target window not found"
        return 1
    fi
    
    # Extract current window properties
    local x=$(echo "$target_window" | jq -r '.frame.x')
    local y=$(echo "$target_window" | jq -r '.frame.y')
    local w=$(echo "$target_window" | jq -r '.frame.w')
    local h=$(echo "$target_window" | jq -r '.frame.h')
    local id=$(echo "$target_window" | jq -r '.id')
    
    # Convert to integers and clamp dimensions
    local cw=$w
    local ch=$h
    
    # Apply minimum constraints
    if (( $(echo "$cw < $MIN_W" | bc -l) )); then
        cw=$MIN_W
    fi
    if (( $(echo "$ch < $MIN_H" | bc -l) )); then
        ch=$MIN_H
    fi
    
    # Apply maximum constraints
    if (( $(echo "$cw > $MAX_W" | bc -l) )); then
        cw=$MAX_W
    fi
    if (( $(echo "$ch > $MAX_H" | bc -l) )); then
        ch=$MAX_H
    fi
    
    # Check if dimensions need to change
    if [ "$cw" = "$w" ] && [ "$ch" = "$h" ]; then
        log_message "Window dimensions already within bounds: ${w}x${h}"
        return 0
    fi
    
    log_message "Clamping window from ${w}x${h} to ${cw}x${ch}"
    
    # Apply the new dimensions
    yabai -m window "$id" --resize abs:"$cw":"$ch"
    
    # Optional: Keep the window position stable (uncomment if needed)
    # yabai -m window "$id" --move abs:"$x":"$y"
    
    log_message "Window successfully clamped to ${cw}x${ch}"
}

# Main execution
main() {
    # Check if yabai is available
    if ! command -v yabai &> /dev/null; then
        log_message "Error: yabai is not installed or not in PATH"
        exit 1
    fi
    
    # Check if jq is available
    if ! command -v jq &> /dev/null; then
        log_message "Error: jq is not installed or not in PATH"
        exit 1
    fi
    
    # Find and clamp the target window
    local target_window=$(find_target_window)
    clamp_window "$target_window"
}

# Run the script
main "$@"