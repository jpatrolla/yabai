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
    printf("DEBUG: widget_get_window_icon called for window %u\n", window_id);
    
    // Get the window and its application first to get the app path
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window || !window->application) {
        printf("DEBUG: Window %u has no application associated yet\n", window_id);
        return NULL;
    }
    
    // Get the application path using proc_pidpathinfo
    static char app_path[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(window->application->pid, app_path, sizeof(app_path)) <= 0) {
        printf("DEBUG: Failed to get path for window %u (pid: %d)\n", window_id, window->application->pid);
        return NULL;
    }
    
    printf("DEBUG: Window %u -> App path: %s (PID: %d)\n", window_id, app_path, window->application->pid);
    
    // Convert executable path to app bundle path
    // Find .app/ in the path and truncate there to get the bundle path
    char bundle_path[PROC_PIDPATHINFO_MAXSIZE];
    strcpy(bundle_path, app_path);
    
    char *app_suffix = strstr(bundle_path, ".app/");
    if (app_suffix) {
        // Include the .app but exclude everything after it
        app_suffix[4] = '\0';  // Keep ".app" and null-terminate
        printf("DEBUG: Converted to bundle path: %s\n", bundle_path);
    } else {
        printf("DEBUG: No .app found in path, using original: %s\n", bundle_path);
    }
    
    // Check cache first - now by app bundle path instead of executable path
    for (int i = 0; i < icon_cache_size; i++) {
        if (icon_cache[i].app_path && strcmp(icon_cache[i].app_path, bundle_path) == 0) {
            printf("DEBUG: Found cached icon for app path %s at index %d\n", bundle_path, i);
            printf("DEBUG: 🎨 ICON REUSED - App: %s | Path: %s\n", (window->application->name ? window->application->name : "Unknown"), bundle_path);
            return icon_cache[i].icon;
        }
    }
    printf("DEBUG: No cached icon found for app path %s (cache has %d entries)\n", bundle_path, icon_cache_size);
    
    NSString *appPath = [NSString stringWithUTF8String:bundle_path];
    if (!appPath) {
        return NULL;
    }
    
    // Extract icon using NSWorkspace
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:appPath];
    if (!icon) {
        printf("DEBUG: NSWorkspace failed to get icon for bundle path: %s\n", bundle_path);
        return NULL;
    }
    
    printf("DEBUG: Got NSImage for bundle path %s, converting to CGImage\n", bundle_path);
    
    // Convert NSImage to CGImage
    NSData *imageData = [icon TIFFRepresentation];
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)imageData, NULL);
    if (!source) {
        printf("DEBUG: Failed to create CGImageSource\n");
        return NULL;
    }
    
    CGImageRef cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    
    if (cgImage) {
        printf("DEBUG: Successfully created CGImage for app path %s, adding to cache\n", bundle_path);
        printf("DEBUG: 🎨 ICON SAVED - App: %s | Path: %s\n", (window->application->name ? window->application->name : "Unknown"), bundle_path);
        // Add to cache
        icon_cache = realloc(icon_cache, (icon_cache_size + 1) * sizeof(icon_cache_entry));
        icon_cache[icon_cache_size].app_path = strdup(bundle_path);  // Store copy of bundle path
        icon_cache[icon_cache_size].icon = cgImage;
        icon_cache_size++;
        printf("DEBUG: Cache now has %d entries\n", icon_cache_size);
    } else {
        printf("DEBUG: Failed to create CGImage from source\n");
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
        printf("DEBUG: Could not get current space ID\n");
        return;
    }
    
    // Get window list for current space (exclude minimized windows)
    int temp_window_count = 0;
    uint32_t *temp_window_list = space_window_list(current_space_id, &temp_window_count, false);
    
    printf("DEBUG: Found %d windows in current space (ID: %llu)\n", temp_window_count, current_space_id);
    
    if (temp_window_list && temp_window_count > 0) {
        // Copy window IDs to our own allocated memory
        widget_window_ids = malloc(temp_window_count * sizeof(uint32_t));
        if (widget_window_ids) {
            memcpy(widget_window_ids, temp_window_list, temp_window_count * sizeof(uint32_t));
            widget_window_count = temp_window_count;
            
            printf("DEBUG: Window IDs: ");
            for (int i = 0; i < widget_window_count; i++) {
                printf("%u%s", widget_window_ids[i], (i < widget_window_count - 1) ? ", " : "");
            }
            printf("\n");
        } else {
            printf("DEBUG: Failed to allocate memory for %d window IDs\n", temp_window_count);
            widget_window_count = 0;
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
        printf("DEBUG: Too many windows (%d) for display height, starting from top\n", count);
        start_y = WIDGET_GAP; // Start from top with small margin
    }
    
    for (int i = 0; i < count; i++) {
        positions[i].x = center_x;
        positions[i].y = start_y + (i * (WIDGET_ICON_SIZE + WIDGET_GAP));
    }
}

// Helper function to get color components for widget color enum
static void widget_get_color_components(enum space_widget_color color, float *r, float *g, float *b, float *a)
{
    switch (color) {
        case SPACE_WIDGET_COLOR_RED:
            *r = 1.0f; *g = 0.0f; *b = 0.0f; *a = 1.0f;
            break;
        case SPACE_WIDGET_COLOR_BLUE:
            *r = 0.0f; *g = 0.0f; *b = 1.0f; *a = 1.0f;
            break;
        case SPACE_WIDGET_COLOR_WHITE:
            *r = 1.0f; *g = 1.0f; *b = 1.0f; *a = 0.8f;
            break;
        default:
            *r = 0.5f; *g = 0.5f; *b = 0.5f; *a = 1.0f;
            break;
    }
}

// Helper function to get app title from window ID
static char* widget_get_app_title(uint32_t window_id)
{
    CFTypeRef app_name = NULL;
    char* app_title = NULL;
    
    // Try to get the window's title first
    if (SLSCopyWindowProperty(g_connection, window_id, CFSTR("kCGSWindowTitle"), &app_name) == kCGErrorSuccess && app_name) {
        CFStringRef title_string = (CFStringRef)app_name;
        CFIndex length = CFStringGetLength(title_string);
        CFIndex max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
        app_title = malloc(max_size);
        
        if (app_title && CFStringGetCString(title_string, app_title, max_size, kCFStringEncodingUTF8)) {
            CFRelease(app_name);
            return app_title;
        }
        
        if (app_title) {
            free(app_title);
            app_title = NULL;
        }
        CFRelease(app_name);
    }
    
    // Fallback: return a copy of "Unknown App"
    app_title = malloc(12);
    if (app_title) {
        strcpy(app_title, "Unknown App");
    }
    return app_title;
}

// Helper function to log window ID and app title
static void widget_log_window_info(uint32_t window_id, int index)
{
    char* app_title = widget_get_app_title(window_id);
    printf("Widget Icon [%d]: Window ID=%u, App Title='%s'\n", index, window_id, app_title ? app_title : "Unknown");
    
    if (app_title) {
        free(app_title);
    }
}

// Helper function to get color based on window ID (for visual distinction)
static enum space_widget_color widget_get_color_for_window(uint32_t window_id)
{
    // Use a simple hash to assign colors based on window ID
    switch (window_id % 3) {
        case 0: return SPACE_WIDGET_COLOR_RED;
        case 1: return SPACE_WIDGET_COLOR_BLUE;
        case 2: return SPACE_WIDGET_COLOR_WHITE;
        default: return SPACE_WIDGET_COLOR_WHITE;
    }
}

// Render helper function - generates rounded rectangle icons
static void widget_render_icon(CGContextRef context, widget_position position, uint32_t window_id, int index)
{
    // Log the window information to console
    widget_log_window_info(window_id, index);
    
    CGRect rect = CGRectMake(position.x, position.y, WIDGET_ICON_SIZE, WIDGET_ICON_SIZE);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, WIDGET_RADIUS, WIDGET_RADIUS, NULL);
    
    // Try to get the app icon
    CGImageRef icon = widget_get_window_icon(window_id);
    
    if (icon) {
        printf("DEBUG: Successfully got icon for window %u, drawing it\n", window_id);
        printf("DEBUG: 🖼️  DRAWING ICON - CGImage dimensions: %zux%zu, Drawing rect: (%.1f,%.1f,%.1f,%.1f)\n", 
               CGImageGetWidth(icon), CGImageGetHeight(icon), 
               rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        
        // Draw the icon without clipping first to test
        CGContextSaveGState(context);
        
        // Ensure we're drawing with normal blend mode and full opacity
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        CGContextSetAlpha(context, 1.0);
        
        // Try drawing without clipping first to see if clipping is the issue
        printf("DEBUG: About to call CGContextDrawImage (no clipping)...\n");
        CGContextDrawImage(context, rect, icon);
        printf("DEBUG: CGContextDrawImage completed (no clipping)\n");
        
        CGContextRestoreGState(context);
        printf("DEBUG: ✅ Icon drawing completed for window %u (no clipping test)\n", window_id);
    } else {
        printf("DEBUG: No icon found for window %u, using colored rectangle\n", window_id);
        printf("DEBUG: 🎨 FALLBACK DRAWING - Using colored rectangle for window %u\n", window_id);
        // Fallback to colored rectangle if no icon found
        enum space_widget_color color = widget_get_color_for_window(window_id);
        float r, g, b, a;
        widget_get_color_components(color, &r, &g, &b, &a);
        
        CGContextSetRGBFillColor(context, r, g, b, a);
        CGContextAddPath(context, path);
        CGContextFillPath(context);
        printf("DEBUG: ✅ Colored rectangle drawing completed for window %u\n", window_id);
    }
    
    CGPathRelease(path);
}

// Helper function to clean up icon cache
static void widget_cleanup_icon_cache(void)
{
    printf("DEBUG: 🧹 CLEANING UP ICON CACHE - %d entries:\n", icon_cache_size);
    for (int i = 0; i < icon_cache_size; i++) {
        if (icon_cache[i].app_path) {
            printf("DEBUG:   [%d] %s\n", i, icon_cache[i].app_path);
        }
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
                        widget_render_icon(context, positions[i], widget_window_ids[i], i);
                    }
                    
                    free(positions);
                } else {
                    printf("DEBUG: Failed to allocate positions array for %d windows\n", widget_window_count);
                }
            } else {
                printf("DEBUG: No windows found in current space - widget will be empty\n");
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
    CGRect frame = {{0, 0}, {50, display_frame.size.height}};
    
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
                    widget_render_icon(context, positions[i], widget_window_ids[i], i);
                }
                
                free(positions);
            } else {
                printf("DEBUG: Failed to allocate positions array for %d windows\n", widget_window_count);
            }
        } else {
            printf("DEBUG: No windows found in current space - widget will be empty\n");
        }
        
        CGContextFlush(context);
        SLSReenableUpdate(g_connection);
        
        CFRelease(context);
    }
}
