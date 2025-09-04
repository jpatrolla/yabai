#include <Carbon/Carbon.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include "space_indicator.h"
#include "display.h"
#include "display_manager.h"
#include "space_manager.h"
#include "sa.h"
#include "misc/extern.h"
#include "misc/timer.h"
#include "misc/helpers.h"

extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern int g_connection;

#define ANIMATION_DURATION 0.1f  // 100ms animation

static void space_indicator_redraw(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    // Create drawing context and set color from config
    CGContextRef context = SLWindowContextCreate(g_connection, indicator->id, 0);
    if (context) {
        CGRect local_frame = {{0, 0}, {indicator->frame.size.width, indicator->frame.size.height}};
        
        // Extract RGBA from the color config (format: 0xAARRGGBB)
        float alpha = ((indicator->config.indicator_color >> 24) & 0xFF) / 255.0f;
        float red   = ((indicator->config.indicator_color >> 16) & 0xFF) / 255.0f;
        float green = ((indicator->config.indicator_color >> 8) & 0xFF) / 255.0f;
        float blue  = (indicator->config.indicator_color & 0xFF) / 255.0f;
        
        CGContextSetRGBFillColor(context, red, green, blue, alpha);
        SLSDisableUpdate(g_connection);
        CGContextFillRect(context, local_frame);
        CGContextFlush(context);
        SLSReenableUpdate(g_connection);
        CFRelease(context);
    }
}

void space_indicator_create(struct space_indicator *indicator)
{
    if (indicator->is_active || !indicator->config.enabled) return;
    
    // Get main display dimensions
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = display_bounds_constrained(did, false);
    
    // Calculate indicator dimensions
    int space_count = display_space_count(did);
    if (space_count <= 0) return;
    
    float indicator_width = display_frame.size.width / space_count;
    int current_space_index = space_manager_mission_control_index(g_space_manager.current_space_id);
    if (current_space_index < 1) current_space_index = 1;
    
    float x_position = (current_space_index - 1) * indicator_width;
    
    // Calculate y position based on config
    float y_position = indicator->config.position == 0 ? 
                       0 : // top
                       display_frame.size.height - indicator->config.indicator_height; // bottom
    
    // Create window frame
    indicator->frame = (CGRect) {
        .origin.x = x_position,
        .origin.y = y_position,
        .size.width = indicator_width,
        .size.height = indicator->config.indicator_height
    };
    
    // Initialize animation fields
    indicator->target_frame = indicator->frame;
    indicator->is_animating = false;
    indicator->animation_progress = 0.0f;
    indicator->animation_start_time = 0;
    
    // Create the indicator window
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&indicator->frame, &frame_region);
    
    uint64_t tags = (1ULL << 1) | (1ULL << 9);  // Sticky and floating
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();
    
    SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region, 13, &tags, 0, 0, 64, &indicator->id, NULL);
    CFRelease(empty_region);
    
    // Make the window sticky (appear on all spaces)
    scripting_addition_set_sticky(indicator->id, true);
    
    SLSSetWindowResolution(g_connection, indicator->id, 1.0f);
    SLSSetWindowOpacity(g_connection, indicator->id, 0);
    SLSSetWindowLevel(g_connection, indicator->id, CGWindowLevelForKey(kCGFloatingWindowLevelKey));
    
    // Order the window
    SLSOrderWindow(g_connection, indicator->id, 1, 0);
    
    CFRelease(frame_region);
    indicator->is_active = true;
    
    // Draw the indicator with the correct color
    space_indicator_redraw(indicator);
}

void space_indicator_destroy(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    SLSReleaseWindow(g_connection, indicator->id);
    indicator->id = 0;
    indicator->is_active = false;
}

void space_indicator_update(struct space_indicator *indicator, uint64_t sid)
{
    if (!indicator->is_active || !indicator->config.enabled) return;
    
    // Get display dimensions
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = display_bounds_constrained(did, false);
    
    // Calculate new position
    int space_count = display_space_count(did);
    if (space_count <= 0) return;
    
    float indicator_width = display_frame.size.width / space_count;
    int space_index = space_manager_mission_control_index(sid);
    if (space_index < 1) space_index = 1;
    
    float x_position = (space_index - 1) * indicator_width;
    
    // Calculate y position based on config
    float y_position = indicator->config.position == 0 ? 
                       0 : // top
                       display_frame.size.height - indicator->config.indicator_height; // bottom

    // Set target frame for animation
    CGRect new_target = {
        .origin.x = x_position,
        .origin.y = y_position,
        .size.width = indicator_width,
        .size.height = indicator->config.indicator_height
    };
    
    // Check if position actually changed
    if (fabs(indicator->target_frame.origin.x - new_target.origin.x) < 1.0f) {
        return; // No significant change, skip animation
    }
    
    // Store current position as starting point if not already animating
    if (!indicator->is_animating) {
        // Get current position from the window (in case it was moved by display changes)
        CGRect current_bounds;
        SLSGetWindowBounds(g_connection, indicator->id, &current_bounds);
        indicator->frame = current_bounds;
    }
    
    // Set new target and start animation
    indicator->target_frame = new_target;
    indicator->is_animating = true;
    indicator->animation_start_time = read_os_timer();
    
    // Start the animation
    space_indicator_animate_step(indicator);
}

void space_indicator_update_optimistic(struct space_indicator *indicator, uint64_t sid)
{
    if (!indicator->is_active || !indicator->config.enabled) return;
    
    // Get display dimensions
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = display_bounds_constrained(did, false);
    
    // Calculate new position
    int space_count = display_space_count(did);
    if (space_count <= 0) return;
    
    float indicator_width = display_frame.size.width / space_count;
    int space_index = space_manager_mission_control_index(sid);
    if (space_index < 1) space_index = 1;
    
    float x_position = (space_index - 1) * indicator_width;
    
    // Calculate y position based on config
    float y_position = indicator->config.position == 0 ? 
                       0 : // top
                       display_frame.size.height - indicator->config.indicator_height; // bottom

    // Set target frame for animation
    CGRect new_target = {
        .origin.x = x_position,
        .origin.y = y_position,
        .size.width = indicator_width,
        .size.height = indicator->config.indicator_height
    };
    
    // Check if position actually changed
    if (fabs(indicator->target_frame.origin.x - new_target.origin.x) < 1.0f) {
        return; // No significant change, skip animation
    }
    
    // Always start from current position for optimistic animation
    // Get current position from the window
    CGRect current_bounds;
    SLSGetWindowBounds(g_connection, indicator->id, &current_bounds);
    indicator->frame = current_bounds;
    
    // Set new target and start animation immediately (optimistic)
    indicator->target_frame = new_target;
    indicator->is_animating = true;
    indicator->animation_start_time = read_os_timer();
    
    // Start the animation
    space_indicator_animate_step(indicator);
}

void space_indicator_refresh(struct space_indicator *indicator)
{
    if (!indicator->is_active) return;
    
    space_indicator_update(indicator, g_space_manager.current_space_id);
    // Also redraw to apply any config changes
    space_indicator_redraw(indicator);
}

void space_indicator_animate_step(struct space_indicator *indicator)
{
    if (!indicator->is_animating) return;
    
    uint64_t current_time = read_os_timer();
    uint64_t elapsed = current_time - indicator->animation_start_time;
    float progress = (float)elapsed / (ANIMATION_DURATION * 1000000000ULL); // Convert to seconds
    
    if (progress >= 1.0f) {
        // Animation complete
        progress = 1.0f;
        indicator->is_animating = false;
        indicator->frame = indicator->target_frame;
    } else {
        // Interpolate position and width with easing
        float eased_progress = ease_in_cubic(progress);
        float start_x = indicator->frame.origin.x;
        float target_x = indicator->target_frame.origin.x;
        float start_width = indicator->frame.size.width;
        float target_width = indicator->target_frame.size.width;
        
        indicator->frame.origin.x = start_x + (target_x - start_x) * eased_progress;
        indicator->frame.size.width = start_width + (target_width - start_width) * eased_progress;
    }
    
    // Move and resize the window
    SLSMoveWindow(g_connection, indicator->id, &indicator->frame.origin);
    
    // Update window shape for width changes
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&indicator->frame, &frame_region);
    SLSSetWindowShape(g_connection, indicator->id, 0, 0, frame_region);
    CFRelease(frame_region);
    
    // Redraw the indicator with the correct color
    space_indicator_redraw(indicator);
    
    // Schedule next animation step if still animating
    if (indicator->is_animating) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            space_indicator_animate_step(indicator);
        });
    }
}