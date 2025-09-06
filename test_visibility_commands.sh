#!/bin/bash

# Test script for the enhanced window visibility toggle functionality

echo "Testing window visibility toggle with on/off arguments..."

# Check if yabai is running
if ! pgrep -f yabai > /dev/null; then
    echo "Error: yabai is not running"
    exit 1
fi

echo "Available commands:"
echo "1. yabai -m window --toggle visibility       (toggle current state)"
echo "2. yabai -m window --toggle visibility on    (explicitly show)"  
echo "3. yabai -m window --toggle visibility off   (explicitly hide)"

echo ""
echo "Testing command syntax (replace with actual window focus):"

# Test 1: Basic toggle
echo "Test 1: Basic toggle"
echo "Command: ./bin/yabai -m window --toggle visibility"
# ./bin/yabai -m window --toggle visibility

# Test 2: Explicit show
echo "Test 2: Explicit show" 
echo "Command: ./bin/yabai -m window --toggle visibility on"
# ./bin/yabai -m window --toggle visibility on

# Test 3: Explicit hide
echo "Test 3: Explicit hide"
echo "Command: ./bin/yabai -m window --toggle visibility off"
# ./bin/yabai -m window --toggle visibility off

echo ""
echo "Note: Uncomment the actual command lines to test with a real window."
echo "Make sure you have a floating window focused before running the tests."
