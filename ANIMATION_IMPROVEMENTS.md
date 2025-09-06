# Animation Improvements Analysis

## Current Proxy-Based Approach Issues:

1. **SLSSetWindowClipShape Limitations**:

   - Only supports rectangular clipping regions
   - Cannot specify clipping origin/direction precisely
   - Clipping affects entire window, not just animation
   - No smooth animated clipping transitions

2. **Proxy Window Overhead**:
   - Memory intensive (stores window captures)
   - Complex setup/teardown logic
   - Performance impact for large windows
   - Visual artifacts with certain content types

## Better Approach: Direct Window Animation

### Phase 1: Pure Position Animation (0-60% of animation)

- Use `SLSSetWindowTransform` with translation only
- Windows slide to new positions maintaining original size
- No stretching, no proxy windows needed
- Smooth, natural movement

### Phase 2: Direct Resize (60-100% of animation)

- Use window manager's `window_manager_resize_window()`
- Or direct `SLSSetWindowTransform` with scale
- Windows smoothly transition to final size at final position
- Clean, efficient resize

### Key Benefits:

1. **No proxy windows**: Much better performance
2. **No clipping artifacts**: Windows actually resize
3. **System integration**: Works with native window management
4. **Simpler code**: Less complex logic, easier to maintain
5. **Better visual quality**: No stretching or clipping artifacts

### Implementation Strategy:

- Modify existing animation system to detect window swaps
- For swaps with significant size differences, use two-phase approach
- Otherwise, fall back to current single-phase animation
- Add configuration controls for phase timing and thresholds

This approach leverages the strengths of the SLS system (smooth transforms) while avoiding its limitations (clipping control).
