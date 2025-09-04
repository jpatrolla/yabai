#include <Carbon/Carbon.h>
#include "space_widget.h"
#include "display_manager.h"
#include "workspace.h"
#include "misc/extern.h"

extern struct display_manager g_display_manager;
extern int g_connection;

#define WIDGET_RADIUS 12.0f

void space_widget_create(struct space_widget *widget)
{
    if (widget->is_active) return;
    
    // Get display frame to create full height region
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = display_bounds_constrained(did, false);
    
    // Create 50px wide region starting from (0,0), full height
    CGRect frame = {{0, 0}, {50, display_frame.size.height}};
    widget->frame = frame;
    
    // Create the window region
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&frame, &frame_region);
    
    if (!widget->id) {
        uint64_t tags = (1ULL << 1) | (1ULL << 9);
        CFTypeRef empty_region = CGRegionCreateEmptyRegion();
        SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region, 13, &tags, 0, 0, 64, &widget->id, NULL);
        CFRelease(empty_region);

        // Make the window sticky (appear on all spaces)  
        scripting_addition_set_sticky(widget->id, true);
        
        sls_window_disable_shadow(widget->id);
        SLSSetWindowResolution(g_connection, widget->id, 1.0f);
        SLSSetWindowOpacity(g_connection, widget->id, 0); // Make window non-opaque
        SLSSetWindowAlpha(g_connection, widget->id, 1.0f); // Make window fully opaque for drawing
        SLSSetWindowLevel(g_connection, widget->id, CGWindowLevelForKey(kCGFloatingWindowLevelKey));
        
        // Draw rounded rectangle
        CGContextRef context = SLWindowContextCreate(g_connection, widget->id, 0);
        if (context) {
            // Calculate rectangle position - centered in the region
            float rect_width = 44.0f;
            float rect_height = 44.0f;
            float rect_x = (60.0f - rect_width) / 2.0f;
            float rect_y = (display_frame.size.height - rect_height) / 2.0f;
            
            CGRect rect = CGRectMake(rect_x, rect_y, rect_width, rect_height);
            
            SLSDisableUpdate(g_connection);
            
            // Clear to transparent background
            CGRect local_frame = {{0, 0}, {frame.size.width, frame.size.height}};
            CGContextClearRect(context, local_frame);
            CGContextSetBlendMode(context, kCGBlendModeClear);
            CGContextFillRect(context, local_frame);
            CGContextSetBlendMode(context, kCGBlendModeNormal);
            
            // Draw rounded rectangle with 50% red
            CGPathRef path = CGPathCreateWithRoundedRect(rect, WIDGET_RADIUS, WIDGET_RADIUS, NULL);
            CGContextSetRGBFillColor(context, 1.0f, 0.0f, 0.0f, 1.0f);
            CGContextAddPath(context, path);
            CGContextFillPath(context);
            
            CGContextFlush(context);
            SLSReenableUpdate(g_connection);
            
            CGPathRelease(path);
            CFRelease(context);
        }
        
        SLSOrderWindow(g_connection, widget->id, 1, 0);
    }

    CFRelease(frame_region);
    widget->is_active = true;
}

void space_widget_destroy(struct space_widget *widget)
{
    if (!widget->is_active) return;
    
    if (widget->id) {
        SLSReleaseWindow(g_connection, widget->id);
        widget->id = 0;
    }
    widget->is_active = false;
}

// Placeholder functions to maintain API compatibility
void space_widget_cycle_color(struct space_widget *widget) { }
void space_widget_update_color(struct space_widget *widget) { }
void space_widget_test_cycle(struct space_widget *widget) { }
void space_widget_set_color_for_space(struct space_widget *widget, uint64_t space_id, enum space_widget_color color) { }
void space_widget_load_color_for_space(struct space_widget *widget, uint64_t space_id) { }
