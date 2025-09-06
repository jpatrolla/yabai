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
#include <time.h>
#include <libproc.h>
#include <Cocoa/Cocoa.h>
#include "space_widget.h"
#include "display_manager.h"
#include "display.h"
#include "workspace.h"
#include "space.h"
#include "space_manager.h"
#include "window_manager.h"
#include "sa.h"
#include "misc/extern.h"

extern struct display_manager g_display_manager;
extern int g_connection;

#define WIDGET_RADIUS 12.0f
#define WIDGET_GAP 8.0f
#define WIDGET_ICON_SIZE 88.0f
#define WIDGET_WIDTH 120.0f
// Rendering mode for the widget
typedef enum {
    WIDGET_RENDER_MODE_ICON = 0,
    WIDGET_RENDER_MODE_PIP = 1
} widget_render_mode;

// Global render mode - can be set via config
static widget_render_mode g_widget_render_mode = WIDGET_RENDER_MODE_PIP;

// Dynamic window list - will be populated with current space windows
static struct window **widget_windows = NULL;
static int widget_window_count = 0;

// Store original left padding to restore when no hidden windows
static int original_left_padding = -1; // -1 means not initialized

// PIP window tracking for cleanup
static uint32_t *pip_windows = NULL;
static int pip_window_count = 0;

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
    if (widget_windows) {
        // Clear widget visibility flags before rebuilding list
        for (int i = 0; i < widget_window_count; i++) {
            if (widget_windows[i] && widget_windows[i]->space_widget) {
                widget_windows[i]->space_widget->is_visible_in_widget = false;
                widget_windows[i]->space_widget->index = -1;
            }
        }
        free(widget_windows);
        widget_windows = NULL;
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
        struct window **filtered_windows = malloc(temp_window_count * sizeof(struct window *));
        int filtered_count = 0;
        
        // Filter for minimized, hidden, or scratched windows only
        for (int i = 0; i < temp_window_count; i++) {
            struct window *window = window_manager_find_window(&g_window_manager, temp_window_list[i]);
            if (!window || !window->space_widget) continue;
            
            bool is_minimized = window_check_flag(window, WINDOW_MINIMIZE);
            bool is_hidden = window->application->is_hidden || window_check_flag(window, WINDOW_HIDDEN);
            bool is_scratched = window_check_flag(window, WINDOW_SCRATCHED);
            
            if (is_minimized || is_hidden || is_scratched) {
                filtered_windows[filtered_count] = window;
                filtered_count++;
            }
        }
        
        if (filtered_count > 0) {
            // Allocate exact size needed and copy filtered results
            widget_windows = malloc(filtered_count * sizeof(struct window *));
            if (widget_windows) {
                memcpy(widget_windows, filtered_windows, filtered_count * sizeof(struct window *));
                widget_window_count = filtered_count;
                
                // Assign stable indices and mark as visible in widget
                for (int i = 0; i < widget_window_count; i++) {
                    if (widget_windows[i] && widget_windows[i]->space_widget) {
                        widget_windows[i]->space_widget->index = i; // Simple sequential indexing
                        widget_windows[i]->space_widget->is_visible_in_widget = true;
                        widget_windows[i]->space_widget->last_update_time = (uint64_t)time(NULL);
                    }
                }
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
// Also updates hit rectangles in window->space_widget
static void widget_layout_calculate_positions_and_hit_rects(widget_position *positions, int count, CGRect container_frame)
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
        
        // Update hit rectangle in window's space_widget data (flipped to match rendering)
        int window_index = count - 1 - i; // Flip to match rendering order
        if (window_index >= 0 && window_index < widget_window_count && 
            widget_windows[window_index] && widget_windows[window_index]->space_widget) {
            widget_windows[window_index]->space_widget->hit_rect = CGRectMake(
                container_frame.origin.x + positions[i].x,
                container_frame.origin.y + positions[i].y,
                WIDGET_ICON_SIZE,
                WIDGET_ICON_SIZE
            );
        }
    }
}

// Render helper function - generates rounded rectangle icons
static void widget_render_icon(CGContextRef context, widget_position position, struct window *window)
{
    CGRect rect = CGRectMake(position.x, position.y, WIDGET_ICON_SIZE, WIDGET_ICON_SIZE);
    CGPathRef path = CGPathCreateWithRoundedRect(rect, WIDGET_RADIUS, WIDGET_RADIUS, NULL);
    
    // Try to get the app icon
    CGImageRef icon = widget_get_window_icon(window->id);
    
    if (icon) {
        // Create clipping path for rounded rectangle
        CGContextSaveGState(context);
        CGContextAddPath(context, path);
        CGContextClip(context);
        
        // Ensure we're drawing with normal blend mode and full opacity
        CGContextSetBlendMode(context, kCGBlendModeNormal);
        CGContextSetAlpha(context, 1.0);
        
        // Draw the icon within the clipped rounded rectangle
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

// Helper function to track PIP windows for cleanup
static void widget_track_pip_window(uint32_t wid)
{
    // Check if already tracked
    for (int i = 0; i < pip_window_count; i++) {
        if (pip_windows[i] == wid) return;
    }
    
    // Add to tracking list
    pip_windows = realloc(pip_windows, (pip_window_count + 1) * sizeof(uint32_t));
    pip_windows[pip_window_count] = wid;
    pip_window_count++;
}

// Helper function to cleanup PIP windows that are no longer in the widget
static void widget_cleanup_pip_windows()
{
    if (!pip_windows || pip_window_count == 0) return;
    
    for (int i = 0; i < pip_window_count; i++) {
        uint32_t wid = pip_windows[i];
        
        // Check if this window is still in the current widget window list
        bool still_in_widget = false;
        for (int j = 0; j < widget_window_count; j++) {
            if (widget_windows[j] && widget_windows[j]->id == wid) {
                still_in_widget = true;
                break;
            }
        }
        
        if (!still_in_widget) {
            // Restore this window from PIP mode using the scripting addition
            scripting_addition_restore_pip(wid);
        }
    }
    
    // Clear the tracking list - we'll rebuild it for the current render
    if (pip_windows) {
        free(pip_windows);
        pip_windows = NULL;
    }
    pip_window_count = 0;
}

// Function to cleanup all PIP windows (for mode switching or widget destruction)
static void widget_cleanup_all_pip_windows(void)
{
    if (!pip_windows || pip_window_count == 0) return;
    
    for (int i = 0; i < pip_window_count; i++) {
        scripting_addition_restore_pip(pip_windows[i]);
    }
    
    if (pip_windows) {
        free(pip_windows);
        pip_windows = NULL;
    }
    pip_window_count = 0;
}

// Render PIP thumbnail function - shows actual window content as thumbnail
static void widget_render_pip(CGContextRef context, widget_position position, struct window *window)
{
    if (!window) return;
    
    // Track this window for PIP cleanup
    widget_track_pip_window(window->id);
    
    // Use the custom PIP function to render window content into the thumbnail area
    // For now, we'll use the widget position directly and let the PIP system handle coordinate conversion
    // TODO: We may need to adjust coordinates based on the actual widget window position
    extern struct space_manager g_space_manager;
    
    // Try to get better screen coordinates - the PIP system expects screen coordinates
    // For now, we'll use a simple approach and may need to refine this based on testing
    uint32_t main_display_id = display_manager_main_display_id();
    if (main_display_id) {
        CGRect display_bounds = display_bounds_constrained(main_display_id, false);
        
        // Position the PIP thumbnail in a consistent location on screen for the widget
        // We can adjust this based on where the widget actually appears
        float screen_x = display_bounds.origin.x; // Fixed offset from left edge
        float screen_y = position.y;
        
        // Use the actual widget icon size for consistency
        window_manager_set_window_pip_frame(&g_space_manager, window, 
                                          screen_x, screen_y, 
                                          WIDGET_ICON_SIZE, WIDGET_ICON_SIZE);
    }
}

// Helper function to render the widget content
static void widget_render_content(CGContextRef context, CGRect frame)
{
    if (!context) return;
    
    // Update window list from current space
    widget_update_window_list();
    
    // Cleanup PIP windows that are no longer in the widget (only for PIP mode)
    if (g_widget_render_mode == WIDGET_RENDER_MODE_PIP) {
        widget_cleanup_pip_windows();
    };
    
    // Only disable updates for widget drawing, not PIP positioning
    SLSDisableUpdate(g_connection);
    
    // Clear to transparent background
    CGRect local_frame = {{0, 0}, {frame.size.width, frame.size.height}};
    CGContextClearRect(context, local_frame);
    CGContextSetBlendMode(context, kCGBlendModeClear);
    CGContextFillRect(context, local_frame);
    CGContextSetBlendMode(context, kCGBlendModeNormal);
    
    // Re-enable updates before positioning PIP windows
    CGContextFlush(context);
    SLSReenableUpdate(g_connection);
    
    // Only render if we have windows
    if (widget_windows && widget_window_count > 0) {
        // Allocate positions array for current window count
        widget_position *positions = malloc(widget_window_count * sizeof(widget_position));
        if (positions) {
            widget_layout_calculate_positions_and_hit_rects(positions, widget_window_count, frame);
            
            
            for (int i = 0; i < widget_window_count; i++) {
                int render_index = i;  // was: widget_window_count - 1 - i
                if (widget_windows[render_index]) {
                    switch (g_widget_render_mode) {
                        case WIDGET_RENDER_MODE_ICON:
                            // Disable updates for icon drawing
                            SLSDisableUpdate(g_connection);
                            widget_render_icon(context, positions[i], widget_windows[render_index]);
                            CGContextFlush(context);
                            SLSReenableUpdate(g_connection);
                            break;
                        case WIDGET_RENDER_MODE_PIP:
                            // Don't disable updates for PIP - they need screen updates to be visible
                            widget_render_pip(context, positions[i], widget_windows[render_index]);
                            break;
                    }
                }
            }
            
            free(positions);
        }
    }
}

// Function to detect which icon was clicked based on mouse position
uint32_t space_widget_get_clicked_window_id(CGPoint click_point, CGRect widget_frame __attribute__((unused)))
{
    if (!widget_windows || widget_window_count <= 0) {
        return 0;
    }
    
    // Use cached hit rectangles for faster lookup
    for (int i = 0; i < widget_window_count; i++) {
        if (widget_windows[i] && widget_windows[i]->space_widget && 
            widget_windows[i]->space_widget->is_visible_in_widget) {
            
            CGRect hit_rect = widget_windows[i]->space_widget->hit_rect;
            
            if (CGRectContainsPoint(hit_rect, click_point)) {
                return widget_windows[i]->id;
            }
        }
    }
    
    return 0;
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
    
    // Create widget wide enough to fit icons plus padding (WIDGET_ICON_SIZE + padding)
    float widget_width = WIDGET_WIDTH; // Icon size plus padding on both sides
    CGRect frame = {{0, 0}, {widget_width, display_frame.size.height}};
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
            widget_render_content(context, frame);
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
    if (widget_windows) {
        // Clear widget visibility flags
        for (int i = 0; i < widget_window_count; i++) {
            if (widget_windows[i] && widget_windows[i]->space_widget) {
                widget_windows[i]->space_widget->is_visible_in_widget = false;
                widget_windows[i]->space_widget->index = -1;
            }
        }
        free(widget_windows);
        widget_windows = NULL;
        widget_window_count = 0;
    }
    
    // Clean up icon cache
    widget_cleanup_icon_cache();
    
    // Clean up any remaining PIP windows
    widget_cleanup_all_pip_windows();
    
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
        widget_render_content(context, frame);
        CFRelease(context);
    }
}

// Function to set the widget render mode
void space_widget_set_render_mode(int mode)
{
    if (mode >= 0 && mode < 2) {
        // If switching away from PIP mode, cleanup all PIP windows
        if (g_widget_render_mode == WIDGET_RENDER_MODE_PIP && mode != WIDGET_RENDER_MODE_PIP) {
            widget_cleanup_all_pip_windows();
        }
        g_widget_render_mode = (widget_render_mode)mode;
    }
}

// Function to get the current widget render mode
int space_widget_get_render_mode(void)
{
    return (int)g_widget_render_mode;
}
