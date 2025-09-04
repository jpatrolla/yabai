/*
 * Space Widget - Hidden Windows Indicator
 * 
 * Displays app icons for hidden/minimized/scratched windows in a vertical widget.
 * Features:
 * - Real app icon extraction and caching
 * - Event-driven updates on window state changes  
 * - Click detection for individual icon activation
 * - Filtering for hidden/minimized/scratched states only
 */

#include <Carbon/Carbon.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <libproc.h>
#include <Cocoa/Cocoa.h>
#include "space_widget.h"
#include "display_manager.h"
#include "workspace.h"
#include "space.h"
#include "space_manager.h"
#include "misc/extern.h"

extern struct display_manager g_display_manager;
extern int g_connection;

#define WIDGET_RADIUS 12.0f
#define WIDGET_GAP 8.0f
#define WIDGET_ICON_SIZE 44.0f

// Dynamic window list - will be populated with current space windows
static uint32_t *widget_window_ids = NULL;
static int widget_window_count = 0;

// Store original left padding to restore when no hidden windows
static int original_left_padding = -1; // -1 means not initialized

// Simple icon cache - cache by application path instead of window ID
typedef struct {
    char *app_path;
    CGImageRef icon;
} icon_cache_entry;

static icon_cache_entry *icon_cache = NULL;
static int icon_cache_size = 0;

typedef struct {
    float x;
    float y;
} widget_position;

// Helper function to get app icon for a window
static CGImageRef widget_get_window_icon(uint32_t window_id)
{
    // Get the window and its application first to get the app path
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window || !window->application) {
        return NULL;
    }
    
    // Get the application path using proc_pidpathinfo
    static char app_path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(window->application->pid, app_path, sizeof(app_path)) <= 0) {
        return NULL;
    }
    
    // Convert executable path to app bundle path
    // Find .app/ in the path and truncate there to get the bundle path
    char bundle_path[PROC_PIDPATHINFO_MAXSIZE];
    strcpy(bundle_path, app_path);
    
    char *app_suffix = strstr(bundle_path, ".app/");
    if (app_suffix) {
        // Include the .app but exclude everything after it
        app_suffix[4] = '\0';  // Keep ".app" and null-terminate
    }
    
    // Check cache first - now by app bundle path instead of executable path
    for (int i = 0; i < icon_cache_size; i++) {
        if (icon_cache[i].app_path && strcmp(icon_cache[i].app_path, bundle_path) == 0) {
            return icon_cache[i].icon;
        }
    }
    
    NSString *appPath = [NSString stringWithUTF8String:bundle_path];
    if (!appPath) {
        return NULL;
    }
    
    // Extract icon using NSWorkspace
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appPath];
    if (!icon) {
        return NULL;
    }
    
    // Convert NSImage to CGImage
    NSData *imageData = [icon TIFFRepresentation];
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
    if (!source) {
        return NULL;
    }
    
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    
    if (cgImage) {
        // Add to cache
        icon_cache = realloc(icon_cache, (icon_cache_size + 1) * sizeof(icon_cache_entry));
        icon_cache[icon_cache_size].app_path = strdup(bundle_path);  // Store copy of bundle path
        icon_cache[icon_cache_size].icon = cgImage;
        icon_cache_size++;
    }
    
    return cgImage;
}

// Helper function to get all windows in the current space
static void widget_update_window_list(void)
{
    // Free previous list if it exists
    if (widget_window_ids) {
        free(widget_window_ids);
        widget_window_ids = NULL;
        widget_window_count = 0;
    }
    
    // Get current space ID
    uint64_t current_space_id = space_manager_active_space();
    if (!current_space_id) {
        return;
    }
    
    // Get ALL window list for current space (including minimized windows)
    int temp_window_count = 0;
    uint32_t *temp_window_list = space_window_list(current_space_id, &temp_window_count, true);
    
    if (temp_window_list && temp_window_count > 0) {
        // Create temporary filtered list
        uint32_t *filtered_windows = malloc(temp_window_count * sizeof(uint32_t));
        int filtered_count = 0;
        
        // Filter for minimized, hidden, or scratched windows only
        for (int i = 0; i < temp_window_count; i++) {
            struct window *window = window_manager_find_window(&g_window_manager, temp_window_list[i]);
            if (!window) continue;
            
            bool is_minimized = window_check_flag(window, WINDOW_MINIMIZE);
            bool is_hidden = window->application->is_hidden;
            bool is_scratched = window_check_flag(window, WINDOW_SCRATCHED);
            
            if (is_minimized || is_hidden || is_scratched) {
                filtered_windows[filtered_count] = temp_window_list[i];
                filtered_count++;
            }
        }
        
        if (filtered_count > 0) {
            // Allocate exact size needed and copy filtered results
            widget_window_ids = malloc(filtered_count * sizeof(uint32_t));
            if (widget_window_ids) {
                memcpy(widget_window_ids, filtered_windows, filtered_count * sizeof(uint32_t));
                widget_window_count = filtered_count;
            }
        }
        
        free(filtered_windows);
    }
    
    // Update left padding based on whether we have hidden windows
    if (widget_window_count > 0) {
        // Store original padding if not already stored
        if (original_left_padding == -1) {
            original_left_padding = g_space_manager.left_padding;
        }
        
        // Hidden windows exist - set padding to accommodate widget (gap + icon + gap)
        int widget_padding = (int)(WIDGET_GAP + WIDGET_ICON_SIZE + WIDGET_GAP);
        space_manager_set_left_padding_for_all_spaces(&g_space_manager, widget_padding);
    } else {
        // No hidden windows - restore user's original left padding
        if (original_left_padding != -1) {
            space_manager_set_left_padding_for_all_spaces(&g_space_manager, original_left_padding);
        }
    }
    
    // Note: temp_window_list is managed by yabai's ts system, don't free it
}

// Widget layout icons helper - generates x,y coordinates for icons with WIDGET_GAP spacing
static void widget_layout_calculate_positions(widget_position *positions, int count, CGRect container_frame)
{
    if (count <= 0) return;
    
    float total_height = (count * WIDGET_ICON_SIZE) + ((count - 1) * WIDGET_GAP);
    float start_y = (container_frame.size.height - total_height) / 2.0f;
    float center_x = (container_frame.size.width - WIDGET_ICON_SIZE) / 2.0f;
    
    // Handle case where we have more icons than can fit vertically
    if (total_height > container_frame.size.height) {
        start_y = WIDGET_GAP; // Start from top with small margin
    }
    
    for (int i = 0; i < count; i++) {
        positions[i].x = center_x;
        positions[i].y = start_y + (i * (WIDGET_ICON_SIZE + WIDGET_GAP));
    }
}

// Function to detect which icon was clicked based on mouse position
uint32_t space_widget_get_clicked_window_id(CGPoint click_point, CGRect widget_frame)
{
    if (!widget_window_ids || widget_window_count <= 0) {
        return 0;
    }
    
    // Calculate icon positions using same logic as renderer
    widget_position *positions = malloc(widget_window_count * sizeof(widget_position));
    if (!positions) {
        return 0;
    }
    
    widget_layout_calculate_positions(positions, widget_window_count, widget_frame);
    
    // Check which icon (if any) contains the click point
    for (int i = 0; i < widget_window_count; i++) {
        CGRect icon_rect = {
            .origin = { positions[i].x, positions[i].y },
            .size = { WIDGET_ICON_SIZE, WIDGET_ICON_SIZE }
        };
        
        // Convert to absolute coordinates for comparison
        CGRect abs_icon_rect = {
            .origin = { 
                widget_frame.origin.x + icon_rect.origin.x,
                widget_frame.origin.y + icon_rect.origin.y 
            },
            .size = icon_rect.size
        };
        
        if (CGRectContainsPoint(abs_icon_rect, click_point)) {
            uint32_t window_id = widget_window_ids[i];
            free(positions);
            return window_id;
        }
    }
    
    free(positions);
    return 0;
}


// Render helper function - generates rounded rectangle icons
static void widget_render_icon(CGContextRef context, widget_position position, uint32_t window_id)
{
    
    CGRect rect = CGRectMake(position.x, position.y, WIDGET_ICON_SIZE, WIDGET_ICON_SIZE);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, WIDGET_RADIUS, WIDGET_RADIUS, NULL);
    
    // Try to get the app icon
    CGImageRef icon = widget_get_window_icon(window_id);
    
    if (icon) {
        
        
        // Draw the icon without clipping first to test
        CGContextSaveGState(context);
        
        // Ensure we're drawing with normal blend mode and full opacity
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        CGContextSetAlpha(context, 1.0);
        
        // Try drawing without clipping first to see if clipping is the issue
        CGContextDrawImage(context, rect, icon);  
        CGContextRestoreGState(context);
    } else {
        // Fallback: render black rounded rectangle for apps without icons
        CGContextSetRGBFillColor(context, 0, 0, 0, 0.8f);
        CGContextAddPath(context, path);
        CGContextFillPath(context);
    }
    
    CGPathRelease(path);
}

// Helper function to clean up icon cache
static void widget_cleanup_icon_cache(void)
{
    for (int i = 0; i < icon_cache_size; i++) {
        if (icon_cache[i].icon) {
            CGImageRelease(icon_cache[i].icon);
        }
        if (icon_cache[i].app_path) {
            free(icon_cache[i].app_path);
        }
    }
    if (icon_cache) {
        free(icon_cache);
        icon_cache = NULL;
        icon_cache_size = 0;
    }
}

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
        
        // Draw all icons using the helper functions
        CGContextRef context = SLWindowContextCreate(g_connection, widget->id, 0);
        if (context) {
            // Update window list from current space
            widget_update_window_list();
            
            SLSDisableUpdate(g_connection);
            
            // Clear to transparent background
            CGRect local_frame = {{0, 0}, {frame.size.width, frame.size.height}};
            CGContextClearRect(context, local_frame);
            CGContextSetBlendMode(context, kCGBlendModeClear);
            CGContextFillRect(context, local_frame);
            CGContextSetBlendMode(context, kCGBlendModeNormal);
            
            // Only render if we have windows
            if (widget_window_ids && widget_window_count > 0) {
                // Allocate positions array for current window count
                widget_position *positions = malloc(widget_window_count * sizeof(widget_position));
                if (positions) {
                    widget_layout_calculate_positions(positions, widget_window_count, frame);
                    
                    // Render each icon using the dynamic window ID array
                    for (int i = 0; i < widget_window_count; i++) {
                        widget_render_icon(context, positions[i], widget_window_ids[i]);
                    }
                    
                    free(positions);
                }
            }
            
            CGContextFlush(context);
            SLSReenableUpdate(g_connection);
            
            CFRelease(context);
        }
        
        SLSOrderWindow(g_connection, widget->id, 1, 0);
    }

    CFRelease(frame_region);
    
    // Don't populate window list immediately - let window manager finish initializing first
    // The list will be populated on the first space change or manual refresh
    
    widget->is_active = true;
}

void space_widget_destroy(struct space_widget *widget)
{
    if (!widget->is_active) return;
    
    if (widget->id) {
        SLSReleaseWindow(g_connection, widget->id);
        widget->id = 0;
    }
    
    // Clean up dynamic window list
    if (widget_window_ids) {
        free(widget_window_ids);
        widget_window_ids = NULL;
        widget_window_count = 0;
    }
    
    // Clean up icon cache
    widget_cleanup_icon_cache();
    
    widget->is_active = false;
}

void space_widget_refresh(struct space_widget *widget)
{
    if (!widget->is_active) return;
    
    // Get display frame
    uint32_t did = display_manager_main_display_id();
    CGRect display_frame = display_bounds_constrained(did, false);
    CGRect frame = {{0, 0}, {WIDGET_GAP + WIDGET_ICON_SIZE + WIDGET_GAP, display_frame.size.height}};

    // Redraw the widget with updated window list
    CGContextRef context = SLWindowContextCreate(g_connection, widget->id, 0);
    if (context) {
        // Update window list from current space
        widget_update_window_list();
        
        SLSDisableUpdate(g_connection);
        
        // Clear to transparent background
        CGRect local_frame = {{0, 0}, {frame.size.width, frame.size.height}};
        CGContextClearRect(context, local_frame);
        CGContextSetBlendMode(context, kCGBlendModeClear);
        CGContextFillRect(context, local_frame);
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        
        // Only render if we have windows
        if (widget_window_ids && widget_window_count > 0) {
            // Allocate positions array for current window count
            widget_position *positions = malloc(widget_window_count * sizeof(widget_position));
            if (positions) {
                widget_layout_calculate_positions(positions, widget_window_count, frame);
                
                // Render each icon using the dynamic window ID array
                for (int i = 0; i < widget_window_count; i++) {
                    widget_render_icon(context, positions[i], widget_window_ids[i]);
                }
                
                free(positions);
            }
        }
        
        CGContextFlush(context);
        SLSReenableUpdate(g_connection);
        
        CFRelease(context);
    }
}
