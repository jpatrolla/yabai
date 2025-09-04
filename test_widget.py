#!/usr/bin/env python3
import subprocess
import time
from Quartz import CGEventCreateMouseEvent, CGEventPost, kCGMouseButtonLeft, kCGEventLeftMouseDown, kCGEventLeftMouseUp, kCGHIDEventTap

def click_at_position(x, y):
    """Simulate a mouse click at the given position"""
    # Create mouse down event
    mouse_down = CGEventCreateMouseEvent(None, kCGEventLeftMouseDown, (x, y), kCGMouseButtonLeft)
    # Create mouse up event
    mouse_up = CGEventCreateMouseEvent(None, kCGEventLeftMouseUp, (x, y), kCGMouseButtonLeft)
    
    # Post the events
    CGEventPost(kCGHIDEventTap, mouse_down)
    time.sleep(0.01)  # Small delay between down and up
    CGEventPost(kCGHIDEventTap, mouse_up)

def query_widget():
    """Query the current widget status"""
    try:
        result = subprocess.run(['bin/yabai', '-m', 'query', '--widget'], 
                              capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        return f"Error: {e}"

if __name__ == "__main__":
    print("Testing space widget click functionality...")
    
    # Query initial state
    print("Initial widget state:", query_widget())
    
    # Click at position where widget should be (10, screen_height - 70)
    # For testing, let's assume a common screen height and click in the expected area
    click_x = 35  # Center of 60px widget at x=10
    click_y = 760  # Approximate position for 1440p display (1440 - 60 - 10 = 1370, but let's try different heights)
    
    print(f"Clicking at position ({click_x}, {click_y})...")
    click_at_position(click_x, click_y)
    
    time.sleep(0.1)  # Give time for the event to be processed
    
    # Query state after click
    print("Widget state after click:", query_widget())
    
    # Try another click to cycle through colors
    time.sleep(0.5)
    print(f"Clicking again at position ({click_x}, {click_y})...")
    click_at_position(click_x, click_y)
    
    time.sleep(0.1)
    print("Widget state after second click:", query_widget())
