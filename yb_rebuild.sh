#!/bin/bash

case "$1" in
  rbsa)
    echo "🔄 Starting yabai rebuild and installation process..."
    echo "⏹️  Stopping yabai..."
    killall yabai

    echo "🗑️  Uninstalling scripting addition..."
    sudo bin/yabai --uninstall-sa

    echo "🔨 Cleaning and building..."
    make clean && make

    echo "📦 Installing scripting addition..."
    sudo bin/yabai --load-sa

    echo "✅ Build and installation complete!"
    echo ""

    read -p "🚀 Do you want to run 'bin/yabai --verbose' now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "🔍 Starting yabai in verbose mode..."
      /Users/jpatrolla/Playground/yabai/bin/yabai --verbose
    else
      echo "👍 Skipping verbose mode. You can start yabai manually with: bin/yabai"
    fi
    ;;

  rb)

    echo "⏹Stopping yabai..."
    pkill yabai
    killall yabai

    echo "Cleaning and building..."
    make clean && make

    echo "Rebuild complete!"
    echo ""

    read -p "Do you want to run 'bin/yabai --verbose' now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      echo "Starting yabai in verbose mode..."
      /Users/jpatrolla/Playground/yabai/bin/yabai --verbose
    else
      echo "Skipping verbose mode. You can start yabai manually with: bin/yabai"
    fi
    ;;

  *)
    echo "Usage: yb {rb|rbsa}"
    ;;
esac