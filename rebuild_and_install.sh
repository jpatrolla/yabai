#!/bin/bash

# Yabai rebuild and install script with advanced logic gates
echo "[INIT] Starting yabai rebuild and installation process..."

# Logic gate variables
KILL_SUCCESS=false
UNINSTALL_SUCCESS=false
BUILD_SUCCESS=false
INSTALL_SUCCESS=false

# Function to execute with logic gate
execute_step() {
    local step_name="$1"
    local command="$2"
    local required="$3"  # true/false - whether this step is required for continuation
    
    echo "[EXEC] $step_name"
    if eval "$command"; then
        echo "[OK]   $step_name - SUCCESS"
        return 0
    else
        echo "[FAIL] $step_name - FAILED"
        if [[ "$required" == "true" ]]; then
            echo "[HALT] Critical step failed. Stopping build process."
            exit 1
        else
            echo "[WARN] Non-critical step failed. Continuing..."
            return 1
        fi
    fi
}

# Step 1: Kill running yabai (non-critical)
if execute_step "Stop yabai" "killall yabai 2>/dev/null" "false"; then
    KILL_SUCCESS=true
fi

# Step 2: Uninstall scripting addition (non-critical, only if binary exists)
if [[ -f "bin/yabai" ]]; then
    if execute_step "Uninstall SA" "sudo bin/yabai --uninstall-sa" "false"; then
        UNINSTALL_SUCCESS=true
    fi
else
    echo "[INFO] No existing yabai binary found, skipping SA uninstall"
fi

# Step 3: Clean and build (CRITICAL)
if execute_step "Clean and build" "make clean && make" "true"; then
    BUILD_SUCCESS=true
fi

# Logic gate: Only install SA if build succeeded AND binary exists
if [[ "$BUILD_SUCCESS" == "true" && -f "bin/yabai" ]]; then
    # Step 4: Install scripting addition (critical only if build succeeded)
    if execute_step "Install SA" "sudo bin/yabai --load-sa" "true"; then
        INSTALL_SUCCESS=true
    fi
else
    if [[ "$BUILD_SUCCESS" == "false" ]]; then
        echo "[SKIP] Skipping SA installation due to build failure"
    else
        echo "[SKIP] Skipping SA installation - binary not found after build"
    fi
fi

# Final status report with logic gates
echo ""
echo "[STATUS] Build Process Summary:"
echo "================================"
[[ "$KILL_SUCCESS" == "true" ]] && echo "[OK]   Yabai stopped" || echo "[WARN] Yabai stop failed/skipped"
[[ "$UNINSTALL_SUCCESS" == "true" ]] && echo "[OK]   SA uninstalled" || echo "[WARN] SA uninstall failed/skipped"
[[ "$BUILD_SUCCESS" == "true" ]] && echo "[OK]   Build completed" || echo "[FAIL] Build failed"
[[ "$INSTALL_SUCCESS" == "true" ]] && echo "[OK]   SA installed" || echo "[FAIL] SA installation failed"

# Logic gate for final success determination
if [[ "$BUILD_SUCCESS" == "true" && "$INSTALL_SUCCESS" == "true" && -f "bin/yabai" ]]; then
    echo ""
    echo "[SUCCESS] Complete success! All critical steps passed."
    OVERALL_SUCCESS=true
elif [[ "$BUILD_SUCCESS" == "true" && -f "bin/yabai" ]]; then
    echo ""
    echo "[PARTIAL] Partial success: Build completed but SA installation failed."
    OVERALL_SUCCESS=false
elif [[ "$BUILD_SUCCESS" == "true" ]]; then
    echo ""
    echo "[ERROR] Build reported success but binary missing - build actually failed."
    OVERALL_SUCCESS=false
else
    echo ""
    echo "[ERROR] Build failed - cannot proceed."
    OVERALL_SUCCESS=false
fi

echo ""

# Logic gate for interactive prompt - only offer to run if build succeeded AND binary exists
if [[ "$BUILD_SUCCESS" == "true" && -f "bin/yabai" ]]; then
    # Ask if user wants to run yabai verbose
    read -p "[PROMPT] Do you want to run 'bin/yabai --verbose' now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "[LAUNCH] Starting yabai in verbose mode..."
        if [[ "$INSTALL_SUCCESS" == "true" ]]; then
            echo "[INFO] Running with scripting addition enabled"
        else
            echo "[WARN] Running without scripting addition (installation failed)"
        fi
        bin/yabai --verbose
    else
        echo "[SKIP] Skipping verbose mode. You can start yabai manually with: bin/yabai"
        if [[ "$INSTALL_SUCCESS" == "false" ]]; then
            echo "[NOTE] You may want to manually install SA later: sudo bin/yabai --load-sa"
        fi
    fi
elif [[ "$BUILD_SUCCESS" == "true" ]]; then
    echo "[ERROR] Build reported success but binary not found. Something went wrong."
    exit 1
else
    echo "[ERROR] Cannot run yabai - build failed. Fix build errors and try again."
    exit 1
fi

# Exit with appropriate code based on overall success
if [[ "$OVERALL_SUCCESS" == "true" ]]; then
    exit 0
else
    exit 1
fi