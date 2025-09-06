#!/bin/bash

# Yabai rebuild and install script
echo "🔄 Starting yabai rebuild and installation process..."

# Kill running yabai
echo "⏹️  Stopping yabai..."
killall yabai

# Uninstall scripting addition
echo "🗑️  Uninstalling scripting addition..."
sudo bin/yabai --uninstall-sa

# Clean and build
echo "🔨 Cleaning and building..."
make clean && make

# Install scripting addition
echo "📦 Installing scripting addition..."
sudo bin/yabai --load-sa

echo "✅ Build and installation complete!"
echo ""

# Ask if user wants to run yabai verbose
read -p "🚀 Do you want to run 'bin/yabai --verbose' now? (y/n): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "🔍 Starting yabai in verbose mode..."
    bin/yabai --verbose
else
    echo "👍 Skipping verbose mode. You can start yabai manually with: bin/yabai"
fi
