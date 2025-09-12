#include "window_manager.h"
#include "sa.h"
#include "view.h"
#include "misc/log.h"
#include <sys/_types/_u_int16_t.h>
#include <sys/qos.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>

// CVDisplayLink callback for frame synchronization
static CVReturn display_link_sync_callback(CVDisplayLinkRef displayLink, 
                                         const CVTimeStamp *now __attribute__((unused)),
                                         const CVTimeStamp *outputTime __attribute__((unused)), 
                                         CVOptionFlags flagsIn __attribute__((unused)), 
                                         CVOptionFlags *flagsOut __attribute__((unused)), 
                                         void *displayLinkContext) {
    // Set the sync flag through the context pointer
    if (displayLinkContext) {
        *(volatile bool *)displayLinkContext = true;
    }
    CVDisplayLinkStop(displayLink);
    return kCVReturnSuccess;
}

// Asynchronous frame setting for zoomed windows
typedef struct {
    struct window *window;
    float x, y, w, h;
    uint32_t delay_ms;
} delayed_frame_data;

static void *delayed_frame_setter_thread(void *data) {
    delayed_frame_data *frame_data = (delayed_frame_data *)data;
    
    // Wait for the specified delay
    if (frame_data->delay_ms > 0) {
        usleep(frame_data->delay_ms * 1000); // Convert ms to microseconds
    }
    
    // Set the window frame
    window_manager_set_window_frame(frame_data->window, 
                                   frame_data->x, 
                                   frame_data->y, 
                                   frame_data->w, 
                                   frame_data->h);
    
    // Clean up
    free(frame_data);
    return NULL;
}

static void window_manager_set_window_frame_async_delayed(struct window *window, 
                                                         float x, float y, float w, float h, 
                                                         uint32_t delay_ms) {
    delayed_frame_data *frame_data = malloc(sizeof(delayed_frame_data));
    if (!frame_data) {
        // If malloc fails, fall back to immediate setting
        window_manager_set_window_frame(window, x, y, w, h);
        return;
    }
    
    frame_data->window = window;
    frame_data->x = x;
    frame_data->y = y;
    frame_data->w = w;
    frame_data->h = h;
    frame_data->delay_ms = delay_ms;
    
    pthread_t delayed_thread;
    if (pthread_create(&delayed_thread, NULL, delayed_frame_setter_thread, frame_data) == 0) {
        // Detach the thread so it cleans up automatically
        pthread_detach(delayed_thread);
    } else {
        // If thread creation fails, fall back to immediate setting
        window_manager_set_window_frame(window, x, y, w, h);
        free(frame_data);
    }
}

// Debug/Log System for Animation
// 
// This debug system allows selective logging of animation-related components.
// To enable debug output, ensure DEBUG is set to true.
// To control which components are logged, modify DEBUG_COMPONENTS string to include:
//   - "pinned anchors" - logs anchor point calculations and pinning operations
//   - "coordinates" - logs window positions, movements, and coordinate calculations
//
// Usage examples:
//   log        general
//   log_a      anchors
//   log_p      coordinates
//
#define DEBUG true
#define DEBUG_COMPONENTS "pinned anchors, coordinates"

#ifdef DEBUG
#define LOG(fmt, ...) fprintf(stderr, "[ANCHORS] " fmt "\n", ##__VA_ARGS__)
#else
#define LOG(fmt, ...) do {} while(0)
#endif

// Helper macros for specific debug components
#define log_a(fmt, ...) do { \
    if (DEBUG && strstr(DEBUG_COMPONENTS, "pinned anchors")) { \
        LOG("PINNED_ANCHORS: " fmt, ##__VA_ARGS__); \
    } \
} while(0)

#define log_p(fmt, ...) do { \
    if (DEBUG && strstr(DEBUG_COMPONENTS, "coordinates")) { \
        LOG("COORDINATES: " fmt, ##__VA_ARGS__); \
    } \
} while(0)

extern mach_port_t g_bs_port;
extern uint8_t *g_event_bytes;
extern struct event_loop g_event_loop;
extern void *g_workspace_context;
extern struct process_manager g_process_manager;
extern struct mouse_state g_mouse_state;
extern double g_cv_host_clock_frequency;

void push_janky_update(uint32_t code, const void *payload, size_t size) ;
static TABLE_HASH_FUNC(hash_wm)
{
    return *(uint32_t *) key;
}

static TABLE_COMPARE_FUNC(compare_wm)
{
    return *(uint32_t *) key_a == *(uint32_t *) key_b;
}

static inline void window_manager_raise_top(uint32_t wid)
{
    /* kCGSOrderAbove == 1 */
    SLSOrderWindow(g_connection, wid, 1, 0);
}

bool window_manager_is_window_eligible(struct window *window)
{
    bool result = window->is_root && (window_is_real(window) || window_check_rule_flag(window, WINDOW_RULE_MANAGED));
    return result;
}

void window_manager_query_window_rules(FILE *rsp)
{
    TIME_FUNCTION;

    fprintf(rsp, "[");
    for (int i = 0; i < buf_len(g_window_manager.rules); ++i) {
        struct rule *rule = &g_window_manager.rules[i];
        rule_serialize(rsp, rule, i);
        if (i < buf_len(g_window_manager.rules) - 1) fprintf(rsp, ",");
    }
    fprintf(rsp, "]\n");
}

void window_manager_query_windows_for_spaces(FILE *rsp, uint64_t *space_list, int space_count, uint64_t flags)
{
    TIME_FUNCTION;

    int window_count = 0;
    uint32_t *window_list = space_window_list_for_connection(space_list, space_count, 0, &window_count, true);

    fprintf(rsp, "[");
    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_manager_find_window(&g_window_manager, window_list[i]);
        if (window) window_serialize(rsp, window, flags); else window_nonax_serialize(rsp, window_list[i], flags);
        if (i < window_count - 1) fprintf(rsp, ",");
    }
    fprintf(rsp, "]\n");
}

void window_manager_query_windows_for_display(FILE *rsp, uint32_t did, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count = 0;
    uint64_t *space_list = display_space_list(did, &space_count);
    window_manager_query_windows_for_spaces(rsp, space_list, space_count, flags);
}

void window_manager_query_windows_for_displays(FILE *rsp, uint64_t flags)
{
    TIME_FUNCTION;

    int display_count = 0;
    uint32_t *display_list = display_manager_active_display_list(&display_count);

    int space_count = 0;
    uint64_t *space_list = NULL;

    for (int i = 0; i < display_count; ++i) {
        int count;
        uint64_t *list = display_space_list(display_list[i], &count);
        if (!list) continue;

        //
        // NOTE(koekeishiya): display_space_list(..) uses a linear allocator,
        // and so we only need to track the beginning of the first list along
        // with the total number of spaces that have been allocated.
        //

        if (!space_list) space_list = list;
        space_count += count;
    }

    window_manager_query_windows_for_spaces(rsp, space_list, space_count, flags);
}

bool window_manager_rule_matches_window(struct rule *rule, struct window *window, char *window_title, char *window_role, char *window_subrole)
{
    int regex_match_app = rule_check_flag(rule, RULE_APP_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_APP_VALID), &rule->app_regex, window->application->name) == regex_match_app) return false;

    int regex_match_title = rule_check_flag(rule, RULE_TITLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_TITLE_VALID), &rule->title_regex, window_title) == regex_match_title) return false;

    int regex_match_role = rule_check_flag(rule, RULE_ROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_ROLE_VALID), &rule->role_regex, window_role) == regex_match_role) return false;

    int regex_match_subrole = rule_check_flag(rule, RULE_SUBROLE_EXCLUDE) ? REGEX_MATCH_YES : REGEX_MATCH_NO;
    if (regex_match(rule_check_flag(rule, RULE_SUBROLE_VALID), &rule->subrole_regex, window_subrole) == regex_match_subrole) return false;

    return true;
}

void window_manager_apply_manage_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects)
{
    if (effects->manage == RULE_PROP_ON) {
        window_set_rule_flag(window, WINDOW_RULE_MANAGED);
        window_manager_make_window_floating(sm, wm, window, false, true);
    } else if (effects->manage == RULE_PROP_OFF) {
        window_clear_rule_flag(window, WINDOW_RULE_MANAGED);
        window_manager_make_window_floating(sm, wm, window, true, true);
    }
    
}

void window_manager_apply_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects)
{
    debug("Applying rule to window %d with title: %s VALUE: %d\n", window->id, window_title_ts(window), effects->min_width);
    
    // Example usage of the new debug system for animations
    log_p("Window %d initial position: x=%.2f, y=%.2f", window->id, window->frame.origin.x, window->frame.origin.y);
    log_a("Processing anchoring rules for window %d", window->id);
    LOG("Rule application started for window %d", window->id);

    if (effects->sid || effects->did) {
        if (!window_is_fullscreen(window) && !space_is_fullscreen(window_space(window->id))) {
            uint64_t sid = effects->sid ? effects->sid : display_space_id(effects->did);
            window_manager_send_window_to_space(sm, wm, window, sid, true);
            if (rule_effects_check_flag(effects, RULE_FOLLOW_SPACE) || effects->fullscreen == RULE_PROP_ON) {
                space_manager_focus_space(sid);
            }
        }
    }

    if (effects->sticky == RULE_PROP_ON) {
        window_manager_make_window_sticky(sm, wm, window, true);
    } else if (effects->sticky == RULE_PROP_OFF) {
        window_manager_make_window_sticky(sm, wm, window, false);
    }

    if (effects->mff == RULE_PROP_ON) {
        window_set_rule_flag(window, WINDOW_RULE_MFF);
        window_set_rule_flag(window, WINDOW_RULE_MFF_VALUE);
    } else if (effects->mff == RULE_PROP_OFF) {
        window_set_rule_flag(window, WINDOW_RULE_MFF);
        window_clear_rule_flag(window, WINDOW_RULE_MFF_VALUE);
    }

    if (rule_effects_check_flag(effects, RULE_LAYER)) {
        window_manager_set_window_layer(window, effects->layer);
    }

    if (rule_effects_check_flag(effects, RULE_OPACITY) && in_range_ii(effects->opacity, 0.0f, 1.0f)) {
        window->opacity = effects->opacity;
        window_manager_set_opacity(wm, window, effects->opacity);
    }

    if (effects->fullscreen == RULE_PROP_ON) {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanTrue);
        window_set_rule_flag(window, WINDOW_RULE_FULLSCREEN);
    }

    if (effects->scratchpad) {
        char *scratchpad = string_copy(effects->scratchpad);
        if (!window_manager_set_scratchpad_for_window(wm, window, scratchpad)) {
            free(scratchpad);
        }
    }
    if (rule_effects_check_flag(effects, RULE_EFFECTS_MIN_WIDTH)) {
        window->min_width = effects->min_width;
    }
    if (effects->grid[0] != 0 && effects->grid[1] != 0) {
        window_manager_apply_grid(sm, wm, window, effects->grid[0], effects->grid[1], effects->grid[2], effects->grid[3], effects->grid[4], effects->grid[5]);
    }

   debug("MIN_WIDTH %d \n", window->min_width);
    debug("EFFECTS %d \n", effects);
}

void window_manager_apply_manage_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules)
{
    bool match = false;
    struct rule_effects effects = {0};

    for (int i = 0; i < buf_len(wm->rules); ++i) {
        if (one_shot_rules || !rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) {
            if (window_manager_rule_matches_window(&wm->rules[i], window, window_title, window_role, window_subrole)) {
                if (wm->rules[i].effects.manage == RULE_PROP_ON) {
                    if (!rule_check_flag(&wm->rules[i], RULE_ROLE_VALID)    && !string_equals(window_role   , "AXWindow"))         continue;
                    if (!rule_check_flag(&wm->rules[i], RULE_SUBROLE_VALID) && !string_equals(window_subrole, "AXStandardWindow")) continue;
                }

                match = true;
                rule_combine_effects(&wm->rules[i].effects, &effects);

                if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) rule_set_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE);
            }
        }
    }

    if (match) window_manager_apply_manage_rule_effects_to_window(sm, wm, window, &effects);
}

void window_manager_apply_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules)
{
    bool match = false;
    struct rule_effects effects = {0};

    for (int i = 0; i < buf_len(wm->rules); ++i) {
        if (one_shot_rules || !rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) {
            if (window_manager_rule_matches_window(&wm->rules[i], window, window_title, window_role, window_subrole)) {
                if (!window_check_rule_flag(window, WINDOW_RULE_MANAGED)) {
                    if (!rule_check_flag(&wm->rules[i], RULE_ROLE_VALID)    && !string_equals(window_role   , "AXWindow"))         continue;
                    if (!rule_check_flag(&wm->rules[i], RULE_SUBROLE_VALID) && !string_equals(window_subrole, "AXStandardWindow")) continue;
                }

                match = true;
                rule_combine_effects(&wm->rules[i].effects, &effects);

                if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT)) rule_set_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE);
            }
        }
    }
    
    if (match) window_manager_apply_rule_effects_to_window(sm, wm, window, &effects);
}

void window_manager_set_focus_follows_mouse(struct window_manager *wm, enum ffm_mode mode)
{
    mouse_handler_end(&g_mouse_state);

    if (mode == FFM_DISABLED) {
        mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK);
    } else {
        mouse_handler_begin(&g_mouse_state, MOUSE_EVENT_MASK_FFM);
    }

    wm->ffm_mode = mode;
}

void window_manager_set_window_opacity_enabled(struct window_manager *wm, bool enabled)
{
    wm->enable_window_opacity = enabled;
    table_for (struct window *window, wm->window, {
        if (window_manager_is_window_eligible(window)) {
            window_manager_set_opacity(wm, window, enabled ? window->opacity : 1.0f);
        }
    })
}

void window_manager_center_mouse(struct window_manager *wm, struct window *window)
{
    if (window_check_rule_flag(window, WINDOW_RULE_MFF)) {
        if (!window_check_rule_flag(window, WINDOW_RULE_MFF_VALUE)) {
            return;
        }
    } else {
        if (!wm->enable_mff) {
            return;
        }
    }

    CGPoint cursor;
    SLSGetCurrentCursorLocation(g_connection, &cursor);
    if (CGRectContainsPoint(window->frame, cursor)) return;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    CGPoint center = {
        window->frame.origin.x + window->frame.size.width / 2,
        window->frame.origin.y + window->frame.size.height / 2
    };

    CGRect bounds = CGDisplayBounds(did);
    if (!CGRectContainsPoint(bounds, center)) return;

    CGWarpMouseCursorPosition(center);
}

bool window_manager_should_manage_window(struct window *window)
{
    debug("Checking if we should manage window %d with title: %s\n", window->id, window_title_ts(window));
    if (window_check_flag(window, WINDOW_HIDDEN)) {debug("Window is hidden, returning false\n"); return false;}
    if (!window->is_root)                           return false;
    if (window_check_flag(window, WINDOW_FLOAT))    return false;
    if (window_is_sticky(window->id))               return false;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return false;
    if (window_check_flag(window, WINDOW_SCRATCHED))return false;
    if (window->application->is_hidden)             return false;

    return (window_is_standard(window) && window_level_is_standard(window) && window_can_move(window)) || window_check_rule_flag(window, WINDOW_RULE_MANAGED);
}

struct view *window_manager_find_managed_window(struct window_manager *wm, struct window *window)
{
    return table_find(&wm->managed_window, &window->id);
}

void window_manager_remove_managed_window(struct window_manager *wm, uint32_t wid)
{
    table_remove(&wm->managed_window, &wid);
    uint64_t sid = window_space(wid);
    struct view *view = space_manager_find_view(&g_space_manager, sid);
    if (!view) return;
    debug("sweeping at window_manager_remove_managed_window %d\n", view->sid);
    window_manager_sweep_stacks(view,  wm);
}

void window_manager_add_managed_window(struct window_manager *wm, struct window *window, struct view *view)
{
    if (view->layout == VIEW_FLOAT) return;
    table_add(&wm->managed_window, &window->id, view);
    window_manager_purify_window(wm, window);
    if (!view) return;
    debug("sweeping at window_manager_add_managed_window %d\n", view->sid);
    window_manager_sweep_stacks(view,  wm);
}

enum window_op_error window_manager_adjust_window_ratio(struct window_manager *wm, struct window *window, int type, float ratio)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    switch (type) {
    case TYPE_REL: {
        node->parent->ratio = clampf_range(node->parent->ratio + ratio, 0.1f, 0.9f);
    } break;
    case TYPE_ABS: {
        node->parent->ratio = clampf_range(ratio, 0.1f, 0.9f);
    } break;
    }

    window_node_update(view, node->parent);

    if (space_is_visible(view->sid)) {
        window_node_flush(node->parent);
    } else {
        view_set_flag(view, VIEW_IS_DIRTY);
    }

    return WINDOW_OP_ERROR_SUCCESS;
}


enum window_op_error window_manager_auto_layout_window(struct window_manager *wm, struct window *window, int direction, float ratio)
{
    TIME_FUNCTION;

    bool is_managed = window_manager_find_managed_window(wm, window) != NULL;
    debug("[AUTO_LAYOUT] %s is %s\n", window->application->name, is_managed ? "managed" : "not managed");

    if (is_managed) {
        struct view *view = window_manager_find_managed_window(wm, window);
        struct window_node *node = view->root;
        if (!node || !node->left || !node->right) {
            debug("[AUTO_LAYOUT] Root node is incomplete — skipping.\n");
            return WINDOW_OP_ERROR_SUCCESS;
        }

        enum window_node_split split = node->split;
        debug("[AUTO_LAYOUT] Root split = %s\n", (split == SPLIT_X ? "SPLIT_X" : "SPLIT_Y"));

        float current = node->ratio;
        float rounded = roundf(current * 100) / 100.0f;

        // Determine if we're adjusting in the relevant axis.
        bool x_direction = (direction == DIR_WEST || direction == DIR_EAST);
        bool y_direction = (direction == DIR_NORTH || direction == DIR_SOUTH);

        bool is_valid_direction = (split == SPLIT_X && y_direction) || (split == SPLIT_Y && x_direction);
        // if ratio > .5 perform a
         // check for any windows that have a min_width attribute

        if (is_valid_direction) {
            debug("[AUTO_LAYOUT] Current ratio: %.2f | Target ratio: %.2f\n", rounded, ratio);

            bool shrink = (x_direction && direction == DIR_WEST) || (y_direction && direction == DIR_SOUTH);
            bool should_cycle = false; // TODO: make configurable per call

            float step = ratio;
            if (step <= 0.0f || step >= 1.0f) step = 0.2f;

            int max_steps = (int)(1.0f / step)- 1;
            float base_ratio = step;

            // Generate nearest stepped index
            int current_index = (int)((current + (step / 2.0f)) / step);
            int target_index = shrink ? current_index - 1 : current_index + 1;

            debug("[AUTO_LAYOUT] current: %d\n", current_index);

            if (target_index < 1 || target_index > max_steps) {
                if (should_cycle) {
                    if(current == base_ratio){
                        target_index = max_steps;
                    } else{
                        target_index = 1;
                    }
                } else {
                    debug("[AUTO_LAYOUT] At edge, skipping ratio adjustment.\n");
                    return WINDOW_OP_ERROR_SUCCESS;
                }
            }

            float next_ratio = roundf(target_index * step * 100) / 100.0f;
            debug("[AUTO_LAYOUT] target ratio: %.2f\n, target_index:  %d", next_ratio, target_index);

            node->ratio = next_ratio;
            view_update(view);
            view_flush(view);
            return WINDOW_OP_ERROR_SUCCESS;
        } else {
            debug("[AUTO_LAYOUT] Direction does not match root split — skipping.\n");
            return WINDOW_OP_ERROR_INVALID_OPERATION;
        }
    } else {
        // floating window logic
        // todo: sides, tops, corners center

        //screen_width = wm->screen.frame.size.width;
        //screen_height = wm->screen.frame.size.height;
        //// space padding
        //// convert ratio to pixel values
        //// (screen width - padding)*ratio
        //float padding = 0.0f; // TODO: get actual padding values
        //float target_width = (screen_width - padding) * ratio;
        //float target_height = (screen_height - padding) * ratio;
        //// target x,y
        //// if ratio =< .5, move window
        
        //// else: Calculate cycle sizes + coords
        //// logic for sides (w based)
        //// logic for tops (h based)
        //// logic for corners (w,h based)
        //// logic for center

       
        //debug("[AUTO_LAYOUT] Not yet implemented for unmanaged windows.\n");
        return WINDOW_OP_ERROR_SUCCESS;
    }
}

enum window_op_error window_manager_move_window_relative(struct window_manager *wm, struct window *window, int type, float dx, float dy)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    if (type == TYPE_REL) {
        dx += window->frame.origin.x;
        dy += window->frame.origin.y;
    }

    window_manager_animate_window((struct window_capture) { .window = window, .x = dx, .y = dy, .w = window->frame.size.width, .h = window->frame.size.height });
    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_resize_window_relative_internal(struct window *window, CGRect frame, int direction, float dx, float dy, bool animate)
{
    TIME_FUNCTION;

    int x_mod = (direction & HANDLE_LEFT) ? -1 : (direction & HANDLE_RIGHT)  ? 1 : 0;
    int y_mod = (direction & HANDLE_TOP)  ? -1 : (direction & HANDLE_BOTTOM) ? 1 : 0;

    float fw = max(1, frame.size.width  + dx * x_mod);
    float fh = max(1, frame.size.height + dy * y_mod);
    float fx = (direction & HANDLE_LEFT) ? frame.origin.x + frame.size.width  - fw : frame.origin.x;
    float fy = (direction & HANDLE_TOP)  ? frame.origin.y + frame.size.height - fh : frame.origin.y;

    if (animate) {
        window_manager_animate_window((struct window_capture) { .window = window, .x = fx, .y = fy, .w = fw, .h = fh });
    } else {
        AX_ENHANCED_UI_WORKAROUND(window->application->ref, {
            window_manager_move_window(window, fx, fy);
            window_manager_resize_window(window, fw, fh);
        });
    }
}

enum window_op_error window_manager_resize_window_relative(struct window_manager *wm, struct window *window, int direction, float dx, float dy, bool animate)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        if (direction == HANDLE_ABS) return WINDOW_OP_ERROR_INVALID_OPERATION;

        struct window_node *node = view_find_window_node(view, window->id);
        if (!node) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

        struct window_node *x_fence = NULL;
        struct window_node *y_fence = NULL;

        if (direction & HANDLE_TOP)    x_fence = window_node_fence(node, DIR_NORTH);
        if (direction & HANDLE_BOTTOM) x_fence = window_node_fence(node, DIR_SOUTH);
        if (direction & HANDLE_LEFT)   y_fence = window_node_fence(node, DIR_WEST);
        if (direction & HANDLE_RIGHT)  y_fence = window_node_fence(node, DIR_EAST);
        if (!x_fence && !y_fence)      return WINDOW_OP_ERROR_INVALID_DST_NODE;

        if (y_fence) {
            float sr = y_fence->ratio + (float) dx / (float) y_fence->area.w;
            y_fence->ratio = clampf_range(sr, 0.1f, 0.9f);
        }

        if (x_fence) {
            float sr = x_fence->ratio + (float) dy / (float) x_fence->area.h;
            x_fence->ratio = clampf_range(sr, 0.1f, 0.9f);
        }

        view_update(view);
        view_flush(view);
    } else {
        if (direction == HANDLE_ABS) {
            if (animate) {
                window_manager_animate_window((struct window_capture) { .window = window, .x = window->frame.origin.x, .y = window->frame.origin.y, .w = dx, .h = dy });
            } else {
                AX_ENHANCED_UI_WORKAROUND(window->application->ref, { window_manager_resize_window(window, dx, dy); });
            }
        } else {
            window_manager_resize_window_relative_internal(window, window_ax_frame(window), direction, dx, dy, animate);
        }
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_move_window(struct window *window, float x, float y)
{
    printf("window_manager_move_window\n");
    
    // Debug logging for window movement/coordinates
    log_p("Moving window %d from (%.2f, %.2f) to (%.2f, %.2f)", 
                   window->id, window->frame.origin.x, window->frame.origin.y, x, y);
    LOG("Window move operation initiated for window %d", window->id);
    
    CGPoint position = CGPointMake(x, y);
    CFTypeRef position_ref = AXValueCreate(kAXValueTypeCGPoint, (void *) &position);
    if (!position_ref) return;

    AXUIElementSetAttributeValue(window->ref, kAXPositionAttribute, position_ref);
    CFRelease(position_ref);
    
    log_p("Window %d position updated to (%.2f, %.2f)", window->id, x, y);
    
    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (view) {
       debug("sweeping at window_manager_move_window %llu\n", view->sid);
       window_manager_sweep_stacks(view, &g_window_manager);
   }

}


void window_manager_resize_window(struct window *window, float width, float height)
{
    // Enforce a minimum width on resize.
    // Priority: per‑window rule (`window->min_width`) falls back to 500 px.
    float min_w = window->min_width ? (float) window->min_width : 500.0f;
    if(min_w > 0.0)  {debug("MIN WIDTH %d current width: %.0f f\n",min_w, width);}

    if (width < min_w) {
        width = min_w;
    }
    CGSize size = CGSizeMake(width, height);
    CFTypeRef size_ref = AXValueCreate(kAXValueTypeCGSize, (void *) &size);
    if (!size_ref) return;

    AXUIElementSetAttributeValue(window->ref, kAXSizeAttribute, size_ref);
    CFRelease(size_ref);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
static inline void window_manager_notify_jankyborders(struct window_animation *animation_list, int animation_count, uint32_t event, bool skip, bool wait)
{
    mach_port_t port;
    if (g_bs_port && bootstrap_look_up(g_bs_port, "git.felix.jbevent", &port) == KERN_SUCCESS) {
        struct {
            uint32_t event;
            uint32_t count;
            uint32_t proxy_wid[512];
            uint32_t real_wid[512];
        } data = { event, 0 };

        for (int i = 0; i < animation_count; ++i) {
            if (skip && __atomic_load_n(&animation_list[i].skip, __ATOMIC_RELAXED)) continue;

            data.proxy_wid[data.count] = animation_list[i].proxy.id;
            data.real_wid[data.count]  = animation_list[i].wid;

            ++data.count;
        }

        mach_send(port, &data, sizeof(data));
        if (wait) usleep(20000);
    }
}
#pragma clang diagnostic pop

static void window_manager_create_window_proxy(int animation_connection, float alpha, struct window_proxy *proxy)
{
    if (!proxy->image) return;
    CFTypeRef frame_region;
    CGSNewRegionWithRect(&proxy->frame, &frame_region);
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();

    uint64_t tags = 1ULL << 46;
    if(alpha < 1.0f){
        // Create transparent window for windows with opacity
        SLSNewWindow(animation_connection, 2, 0, 0, frame_region, &proxy->id);
    }else{
        // Create opaque window for fully opaque windows (existing behavior)
        SLSNewWindowWithOpaqueShapeAndContext(animation_connection, 2, frame_region, empty_region, 13|(1 << 18), &tags, 0, 0, 64, &proxy->id, NULL);
    }
    
    SLSSetWindowOpacity(animation_connection, proxy->id, 0);
    
    // Use reduced resolution for performance if enabled
    float resolution = (g_window_manager.window_animation_reduced_resolution || g_window_manager.window_animation_fast_mode) ? 1.0f : 2.0f;
    SLSSetWindowResolution(animation_connection, proxy->id, resolution);
    
    // Apply alpha only if opacity animations are enabled
    float final_alpha = g_window_manager.window_animation_opacity_enabled && !g_window_manager.window_animation_fast_mode ? alpha : 1.0f;
    SLSSetWindowAlpha(animation_connection, proxy->id, final_alpha);
    
    SLSSetWindowLevel(animation_connection, proxy->id, proxy->level);
    SLSSetWindowSubLevel(animation_connection, proxy->id, proxy->sub_level);
    
    proxy->context = SLWindowContextCreate(animation_connection, proxy->id, 0);
    CGRect frame = { {0, 0}, proxy->frame.size };
    CGContextClearRect(proxy->context, frame);
    CGContextDrawImage(proxy->context, frame, proxy->image);
    CGContextFlush(proxy->context);
    CFRelease(frame_region);
    CFRelease(empty_region);
}

 void window_manager_destroy_window_proxy(int animation_connection, struct window_proxy *proxy)
{
    if (proxy->image) {
        CFRelease(proxy->image);
        proxy->image = NULL;
    }

    if (proxy->context) {
        CGContextRelease(proxy->context);
        proxy->context = NULL;
    }

    if (proxy->id) {
        SLSReleaseWindow(animation_connection, proxy->id);
        proxy->id = 0;
    }
}

static void *window_manager_build_window_proxy_thread_proc(void *data)
{
    struct window_animation *animation = data;

    float alpha = 1.0f;
    SLSGetWindowAlpha(animation->cid, animation->wid, &alpha);
    animation->proxy.level = window_level(animation->wid);
    animation->proxy.sub_level = window_sub_level(animation->wid);
    SLSGetWindowBounds(animation->cid, animation->wid, &animation->proxy.frame);
    
    // Apply starting size multiplier if configured (for scaling animation effect)
    if (g_window_manager.window_animation_starting_size != 1.0f) {
        float size_multiplier = g_window_manager.window_animation_starting_size;
        float target_w = animation->w;
        float target_h = animation->h;
        
        // Calculate the starting size based on target size and multiplier
        float starting_w = target_w * size_multiplier;
        float starting_h = target_h * size_multiplier;
        
        // Center the scaled starting size within the original position
        float center_x = animation->proxy.frame.origin.x + animation->proxy.frame.size.width / 2.0f;
        float center_y = animation->proxy.frame.origin.y + animation->proxy.frame.size.height / 2.0f;
        
        animation->proxy.frame.origin.x = center_x - starting_w / 2.0f;
        animation->proxy.frame.origin.y = center_y - starting_h / 2.0f;
        animation->proxy.frame.size.width = starting_w;
        animation->proxy.frame.size.height = starting_h;
        
        debug("🎬 Applied starting size multiplier %.2f: target=%.0fx%.0f starting=%.0fx%.0f", 
              size_multiplier, target_w, target_h, starting_w, starting_h);
    }
    
    animation->proxy.tx = animation->proxy.frame.origin.x;
    animation->proxy.ty = animation->proxy.frame.origin.y;
    animation->proxy.tw = animation->proxy.frame.size.width;
    animation->proxy.th = animation->proxy.frame.size.height;

    CFArrayRef image_array = SLSHWCaptureWindowList(animation->cid, &animation->wid, 1, (1 << 11) | (1 << 8));
    if (image_array) {
        animation->proxy.image = alpha == 1.0f
                               ? (CGImageRef) CFRetain(CFArrayGetValueAtIndex(image_array, 0))
                               : cgimage_restore_alpha((CGImageRef) CFArrayGetValueAtIndex(image_array, 0));
        CFRelease(image_array);
    } else {
        animation->proxy.image = NULL;
    }

    window_manager_create_window_proxy(animation->cid, alpha, &animation->proxy);
    return NULL;
}

static inline float calculate_size_difference_ratio(float src_w, float src_h, float dst_w, float dst_h)
{
    float src_area = src_w * src_h;
    float dst_area = dst_w * dst_h;
    float area_diff = fabsf(dst_area - src_area);
    float max_area = fmaxf(src_area, dst_area);
    return max_area > 0.0f ? area_diff / max_area : 0.0f;
}

static inline float calculate_aspect_difference(float src_w, float src_h, float dst_w, float dst_h)
{
    float src_aspect = src_h > 0.0f ? src_w / src_h : 1.0f;
    float dst_aspect = dst_h > 0.0f ? dst_w / dst_h : 1.0f;
    return fabsf(dst_aspect - src_aspect) / fmaxf(src_aspect, dst_aspect);
}

// debug strucs
typedef struct {
    bool touches_top;
    bool touches_bottom;
    bool touches_left;
    bool touches_right;
    float distance_to_top;
    float distance_to_bottom;
    float distance_to_left;
    float distance_to_right;
    char position_desc[64];
} screen_edge_info;

// Tree position analysis structure
typedef struct {
    bool is_root;
    bool is_leaf;
    bool is_left_child;
    bool is_right_child;
    int depth;
    int total_siblings;
    int sibling_index;
    enum window_node_split parent_split;
    enum window_node_split node_split;
    char tree_path[128];
    char position_desc[64];
} tree_position_info;

// Analyze window's relationship to screen edges
static screen_edge_info analyze_screen_edges(CGRect window_rect, uint32_t display_id, struct view *view) {
    screen_edge_info info = {0};
    
    CGRect screen_bounds = display_bounds_constrained(display_id, false);
    
    // Factor in space padding when calculating effective screen bounds
    CGRect effective_bounds = screen_bounds;
    if (view) {
        effective_bounds.origin.x += view->left_padding;
        effective_bounds.origin.y += view->top_padding;
        effective_bounds.size.width -= (view->left_padding + view->right_padding);
        effective_bounds.size.height -= (view->top_padding + view->bottom_padding);
    }
    
    // Use configured edge threshold
    float edge_threshold = g_window_manager.window_animation_edge_threshold;
    
    // Calculate distances to effective edges (accounting for space padding)
    info.distance_to_top = window_rect.origin.y - effective_bounds.origin.y;
    info.distance_to_bottom = (effective_bounds.origin.y + effective_bounds.size.height) - (window_rect.origin.y + window_rect.size.height);
    info.distance_to_left = window_rect.origin.x - effective_bounds.origin.x;
    info.distance_to_right = (effective_bounds.origin.x + effective_bounds.size.width) - (window_rect.origin.x + window_rect.size.width);
    
    // Determine edge touches using threshold
    info.touches_top = info.distance_to_top <= edge_threshold;
    info.touches_bottom = info.distance_to_bottom <= edge_threshold;
    info.touches_left = info.distance_to_left <= edge_threshold;
    info.touches_right = info.distance_to_right <= edge_threshold;
    
    // Create position description
    if (info.touches_top && info.touches_left) {
        strcpy(info.position_desc, "screen-top-left");
    } else if (info.touches_top && info.touches_right) {
        strcpy(info.position_desc, "screen-top-right");
    } else if (info.touches_bottom && info.touches_left) {
        strcpy(info.position_desc, "screen-bottom-left");
    } else if (info.touches_bottom && info.touches_right) {
        strcpy(info.position_desc, "screen-bottom-right");
    } else if (info.touches_top) {
        strcpy(info.position_desc, "screen-top");
    } else if (info.touches_bottom) {
        strcpy(info.position_desc, "screen-bottom");
    } else if (info.touches_left) {
        strcpy(info.position_desc, "screen-left");
    } else if (info.touches_right) {
        strcpy(info.position_desc, "screen-right");
    } else {
        strcpy(info.position_desc, "screen-center");
    }
    
    return info;
}

// Analyze window's position in BSP tree
static tree_position_info analyze_tree_position(struct window *window) {
    tree_position_info info = {0};
    strcpy(info.tree_path, "unknown");
    strcpy(info.position_desc, "unknown");
    
    if (!window) return info;
    
    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (!view) {
        strcpy(info.position_desc, "floating");
        return info;
    }
    
    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) {
        strcpy(info.position_desc, "not-in-tree");
        return info;
    }
    
    // Analyze node properties
    info.is_leaf = (!node->left && !node->right);
    info.is_root = (!node->parent);
    info.node_split = node->split;
    
    // Count siblings and find index
    if (node->parent) {
        info.is_left_child = (node->parent->left == node);
        info.is_right_child = (node->parent->right == node);
        info.parent_split = node->parent->split;
        info.total_siblings = 2; // BSP tree always has 2 children
        info.sibling_index = info.is_left_child ? 0 : 1;
    }
    
    // Calculate depth and build path
    struct window_node *current = node;
    info.depth = 0;
    char path[128] = "";
    
    while (current->parent) {
        char direction = (current->parent->left == current) ? 'L' : 'R';
        char split_char = (current->parent->split == SPLIT_X) ? 'X' : 'Y';
        
        char segment[8];
        snprintf(segment, sizeof(segment), "%c%c", split_char, direction);
        
        if (strlen(path) > 0) {
            char temp[128];
            strcpy(temp, path);
            snprintf(path, sizeof(path), "%s.%s", segment, temp);
        } else {
            strcpy(path, segment);
        }
        
        current = current->parent;
        info.depth++;
    }
    
    strcpy(info.tree_path, strlen(path) > 0 ? path : "root");
    
    // Create position description
    if (info.is_root) {
        strcpy(info.position_desc, "tree-root");
    } else if (info.is_leaf) {
        if (info.parent_split == SPLIT_X) {
            strcpy(info.position_desc, info.is_left_child ? "leaf-left-of-vsplit" : "leaf-right-of-vsplit");
        } else {
            strcpy(info.position_desc, info.is_left_child ? "leaf-above-hsplit" : "leaf-below-hsplit");
        }
    } else {
        if (info.node_split == SPLIT_X) {
            strcpy(info.position_desc, "internal-vsplit");
        } else {
            strcpy(info.position_desc, "internal-hsplit");
        }
    }
    
    return info;
}

// Analyze window positioning within BSP tree structure - REMOVED FOR CLEAN REFERENCE
// This function was part of the enhanced animation system
// static inline void analyze_window_position(struct window *window, struct window_animation *animation) { ... }

// ============================================================================
// CENTRALIZED SPLIT-AWARE COMMON-EDGE ANCHORING SYSTEM
// ============================================================================
// This is the single source of truth for all anchoring logic in animations.
// It replaces all previous anchor calculation methods with a unified approach.
// todo: [] identify edge cases / issues with current logic
// [] poc using scale + transactions
// todo: [] determine final logic + streamline
// todo: [] cleanup

typedef enum {
    WINDOW_OPERATION_RESIZE,
    WINDOW_OPERATION_TRANSLATE,
    WINDOW_OPERATION_MIXED
} window_operation_type;

typedef struct {
    bool has_common_top;
    bool has_common_bottom;
    bool has_common_left;
    bool has_common_right;
    float anchor_x, anchor_y; // Fixed anchor point in absolute coordinates
    window_operation_type operation_type;
    bool use_split_fallback;
    bool crosses_monitors;
    
    // Legacy compatibility
    int legacy_resize_anchor; // 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
} unified_anchor_info;

// Detect the primary type of window operation
static window_operation_type detect_operation_type(CGRect start_rect, CGRect end_rect) {
    float position_change = sqrtf(powf(end_rect.origin.x - start_rect.origin.x, 2) + 
                                  powf(end_rect.origin.y - start_rect.origin.y, 2));
    float size_change = fabs(end_rect.size.width - start_rect.size.width) + 
                        fabs(end_rect.size.height - start_rect.size.height);
    
    if (size_change > position_change * 2.0f) {
        return WINDOW_OPERATION_RESIZE;
    } else if (position_change > size_change * 2.0f) {
        return WINDOW_OPERATION_TRANSLATE;
    } else {
        return WINDOW_OPERATION_MIXED;
    }
}

// Check if transition crosses monitor boundaries
static bool detect_monitor_crossing(CGRect start_rect, CGRect end_rect) {
    float distance = sqrtf(powf(end_rect.origin.x - start_rect.origin.x, 2) + 
                          powf(end_rect.origin.y - start_rect.origin.y, 2));
    return distance > 1000.0f; // Configurable threshold for monitor boundary detection
}

// todo: actually centralise all the logic
// MAIN CENTRALIZED ANCHORING FUNCTION
// This is the single function that calculates anchor information for all animations
static unified_anchor_info calculate_unified_anchor(CGRect start_rect, CGRect end_rect, 
                                                   enum window_node_split parent_split, 
                                                   float edge_threshold,
                                                   struct window_animation *animation) {
    unified_anchor_info anchor = {0};
    
    // Detect operation characteristics
    anchor.operation_type = detect_operation_type(start_rect, end_rect);
    anchor.crosses_monitors = detect_monitor_crossing(start_rect, end_rect);
    
    // Check for force overrides from configuration (highest priority)
    if (g_window_manager.window_animation_force_top_anchor) {
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width / 2.0f;
        anchor.anchor_y = start_rect.origin.y;
        anchor.has_common_top = true;
        anchor.legacy_resize_anchor = 0;
        return anchor;
    }
    if (g_window_manager.window_animation_force_bottom_anchor) {
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width / 2.0f;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height;
        anchor.has_common_bottom = true;
        anchor.legacy_resize_anchor = 2;
        return anchor;
    }
    if (g_window_manager.window_animation_force_left_anchor) {
        anchor.anchor_x = start_rect.origin.x;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height / 2.0f;
        anchor.has_common_left = true;
        anchor.legacy_resize_anchor = 0;
        return anchor;
    }
    if (g_window_manager.window_animation_force_right_anchor) {
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height / 2.0f;
        anchor.has_common_right = true;
        anchor.legacy_resize_anchor = 1;
        return anchor;
    }
    
    // Check for stacked window overrides - DISABLED FOR CLEAN REFERENCE
    // These checks used fields that were removed from the simplified window_animation structure
    /*
    if (animation && g_window_manager.window_animation_override_stacked_top && animation->is_stacked_top) {
        anchor.legacy_resize_anchor = g_window_manager.window_animation_stacked_top_anchor;
        switch (anchor.legacy_resize_anchor) {
            case 0: anchor.anchor_x = start_rect.origin.x; anchor.anchor_y = start_rect.origin.y; break;
            case 1: anchor.anchor_x = start_rect.origin.x + start_rect.size.width; anchor.anchor_y = start_rect.origin.y; break;
            case 2: anchor.anchor_x = start_rect.origin.x; anchor.anchor_y = start_rect.origin.y + start_rect.size.height; break;
            case 3: anchor.anchor_x = start_rect.origin.x + start_rect.size.width; anchor.anchor_y = start_rect.origin.y + start_rect.size.height; break;
        }
        return anchor;
    }
    if (animation && g_window_manager.window_animation_override_stacked_bottom && animation->is_stacked_bottom) {
        anchor.legacy_resize_anchor = g_window_manager.window_animation_stacked_bottom_anchor;
        switch (anchor.legacy_resize_anchor) {
            case 0: anchor.anchor_x = start_rect.origin.x; anchor.anchor_y = start_rect.origin.y; break;
            case 1: anchor.anchor_x = start_rect.origin.x + start_rect.size.width; anchor.anchor_y = start_rect.origin.y; break;
            case 2: anchor.anchor_x = start_rect.origin.x; anchor.anchor_y = start_rect.origin.y + start_rect.size.height; break;
            case 3: anchor.anchor_x = start_rect.origin.x + start_rect.size.width; anchor.anchor_y = start_rect.origin.y + start_rect.size.height; break;
        }
        return anchor;
    }
    */
    
    // Check for common edges within threshold (core anchoring logic)
    anchor.has_common_top = fabs(start_rect.origin.y - end_rect.origin.y) <= edge_threshold;
    anchor.has_common_bottom = fabs((start_rect.origin.y + start_rect.size.height) - (end_rect.origin.y + end_rect.size.height)) <= edge_threshold;
    anchor.has_common_left = fabs(start_rect.origin.x - end_rect.origin.x) <= edge_threshold;
    anchor.has_common_right = fabs((start_rect.origin.x + start_rect.size.width) - (end_rect.origin.x + end_rect.size.width)) <= edge_threshold;
    
    // NEW PRIORITY SYSTEM: Prioritize stationary edges over everything else
    // If any edge is stationary, that should be the primary anchor consideration
    
    // Count stationary edges for priority ranking
    //int stationary_edge_count = 0;
    //if (anchor.has_common_top) stationary_edge_count++;
    //if (anchor.has_common_bottom) stationary_edge_count++;
    //if (anchor.has_common_left) stationary_edge_count++;
    //if (anchor.has_common_right) stationary_edge_count++;
    
    // HIGHEST PRIORITY: Multiple stationary edges (corners)
    if (anchor.has_common_top && anchor.has_common_left) {
        anchor.anchor_x = start_rect.origin.x;
        anchor.anchor_y = start_rect.origin.y;
        anchor.legacy_resize_anchor = 0;
    } else if (anchor.has_common_top && anchor.has_common_right) {
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width;
        anchor.anchor_y = start_rect.origin.y;
        anchor.legacy_resize_anchor = 1;
    } else if (anchor.has_common_bottom && anchor.has_common_left) {
        anchor.anchor_x = start_rect.origin.x;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height;
        anchor.legacy_resize_anchor = 2;
    } else if (anchor.has_common_bottom && anchor.has_common_right) {
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height;
        anchor.legacy_resize_anchor = 3;
    } 
    // SECOND PRIORITY: Single stationary edges - these should take precedence over fallback logic
    // Order of priority: Bottom > Top > Left > Right (most stable to least stable)
    else if (anchor.has_common_bottom) {
        // Bottom edge is stationary - anchor there (highest single-edge priority)
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width / 2.0f;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height;
        anchor.legacy_resize_anchor = 2;
        debug("🔗 Prioritizing stationary BOTTOM edge for anchoring");
    } else if (anchor.has_common_top) {
        // Top edge is stationary - anchor there  
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width / 2.0f;
        anchor.anchor_y = start_rect.origin.y;
        anchor.legacy_resize_anchor = 0;
        debug("🔗 Prioritizing stationary TOP edge for anchoring");
    } else if (anchor.has_common_left) {
        // Left edge is stationary - anchor there
        anchor.anchor_x = start_rect.origin.x;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height / 2.0f;
        anchor.legacy_resize_anchor = 0;
        debug("🔗 Prioritizing stationary LEFT edge for anchoring");
    } else if (anchor.has_common_right) {
        // Right edge is stationary - anchor there
        anchor.anchor_x = start_rect.origin.x + start_rect.size.width;
        anchor.anchor_y = start_rect.origin.y + start_rect.size.height / 2.0f;
        anchor.legacy_resize_anchor = 1;
        debug("🔗 Prioritizing stationary RIGHT edge for anchoring");
    } else {
        // No common edges - use split-aware fallback with operation type consideration
        anchor.use_split_fallback = true;
        
        if (anchor.operation_type == WINDOW_OPERATION_TRANSLATE) {
            // For pure translations, use center anchoring to maintain shape
            anchor.anchor_x = start_rect.origin.x + start_rect.size.width / 2.0f;
            anchor.anchor_y = start_rect.origin.y + start_rect.size.height / 2.0f;
            anchor.legacy_resize_anchor = 0;
        } else if (anchor.operation_type == WINDOW_OPERATION_RESIZE && parent_split != SPLIT_NONE) {
            // For resizes, use split-aware anchoring
            switch (parent_split) {
                case SPLIT_Y: // Horizontal split - prefer top/bottom edges
                    if (start_rect.origin.y < end_rect.origin.y) {
                        // Growing/moving down - anchor to top
                        anchor.anchor_x = start_rect.origin.x;
                        anchor.anchor_y = start_rect.origin.y;
                        anchor.legacy_resize_anchor = 0;
                    } else {
                        // Growing/moving up - anchor to bottom
                        anchor.anchor_x = start_rect.origin.x;
                        anchor.anchor_y = start_rect.origin.y + start_rect.size.height;
                        anchor.legacy_resize_anchor = 2;
                    }
                    break;
                case SPLIT_X: // Vertical split - prefer left/right edges
                    if (start_rect.origin.x < end_rect.origin.x) {
                        // Growing/moving right - anchor to left
                        anchor.anchor_x = start_rect.origin.x;
                        anchor.anchor_y = start_rect.origin.y;
                        anchor.legacy_resize_anchor = 0;
                    } else {
                        // Growing/moving left - anchor to right
                        anchor.anchor_x = start_rect.origin.x + start_rect.size.width;
                        anchor.anchor_y = start_rect.origin.y;
                        anchor.legacy_resize_anchor = 1;
                    }
                    break;
                default:
                    // Single window or unknown - anchor to center
                    anchor.anchor_x = start_rect.origin.x + start_rect.size.width / 2.0f;
                    anchor.anchor_y = start_rect.origin.y + start_rect.size.height / 2.0f;
                    anchor.legacy_resize_anchor = 0;
                    break;
            }
        } else {
            // Mixed operation or fallback - use traditional logic
            float height_change = fabs(end_rect.size.height - start_rect.size.height);
            float width_change = fabs(end_rect.size.width - start_rect.size.width);
            
            if (height_change > width_change * 2.0f) {
                // Primarily height change
                if (fabs(start_rect.origin.y - end_rect.origin.y) < 5.0f) {
                    anchor.anchor_x = start_rect.origin.x;
                    anchor.anchor_y = start_rect.origin.y;
                    anchor.legacy_resize_anchor = 0;
                } else {
                    anchor.anchor_x = start_rect.origin.x;
                    anchor.anchor_y = start_rect.origin.y + start_rect.size.height;
                    anchor.legacy_resize_anchor = 2;
                }
            } else if (width_change > height_change * 2.0f) {
                // Primarily width change
                if (fabs(start_rect.origin.x - end_rect.origin.x) < 5.0f) {
                    anchor.anchor_x = start_rect.origin.x;
                    anchor.anchor_y = start_rect.origin.y;
                    anchor.legacy_resize_anchor = 0;
                } else {
                    anchor.anchor_x = start_rect.origin.x + start_rect.size.width;
                    anchor.anchor_y = start_rect.origin.y;
                    anchor.legacy_resize_anchor = 1;
                }
            } else {
                // Default to top-left
                anchor.anchor_x = start_rect.origin.x;
                anchor.anchor_y = start_rect.origin.y;
                anchor.legacy_resize_anchor = 0;
            }
        }
    }
    
    return anchor;
}

// Removed unused interpolate_with_unified_anchor function

// Removed unused unified_anchor_to_legacy_resize_anchor function



#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static CVReturn window_manager_animate_window_list_thread_proc(CVDisplayLinkRef link, const CVTimeStamp *now, const CVTimeStamp *output_time, CVOptionFlags flags, CVOptionFlags *flags_out, void *data)
{
    struct window_animation_context *context = data;
    int animation_count = context->animation_count;

    uint64_t current_clock = output_time->hostTime;
    if (!context->animation_clock) context->animation_clock = now->hostTime;

    double t = (double)(current_clock - context->animation_clock) / (double)(context->animation_duration * g_cv_host_clock_frequency);
    if (t <= 0.0) t = 0.0f;
    if (t >= 1.0) t = 1.0f;

    float mt;
    switch (context->animation_easing) {
#define ANIMATION_EASING_TYPE_ENTRY(value) case value##_type: mt = value(t); break;
        ANIMATION_EASING_TYPE_LIST
#undef ANIMATION_EASING_TYPE_ENTRY
    }

    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;

        CGAffineTransform transform = CGAffineTransformMakeTranslation(-context->animation_list[i].proxy.tx, -context->animation_list[i].proxy.ty);
        CGAffineTransform scale = CGAffineTransformMakeScale(context->animation_list[i].proxy.frame.size.width / context->animation_list[i].proxy.tw, context->animation_list[i].proxy.frame.size.height / context->animation_list[i].proxy.th);
        SLSSetWindowTransform(context->animation_connection, context->animation_list[i].proxy.id, CGAffineTransformConcat(transform, scale));

        float alpha = 0.0f;
        SLSGetWindowAlpha(context->animation_connection, context->animation_list[i].wid, &alpha);
        if (alpha != 0.0f) SLSSetWindowAlpha(context->animation_connection, context->animation_list[i].proxy.id, alpha);
    }

    if (t != 1.0f) goto out;

    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    SLSDisableUpdate(context->animation_connection);
    window_manager_notify_jankyborders(context->animation_list, context->animation_count, 1326, true, true);
    scripting_addition_swap_window_proxy_out(context->animation_list, context->animation_count);
    for (int i = 0; i < animation_count; ++i) {
        if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;

        table_remove(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
        window_manager_destroy_window_proxy(context->animation_connection, &context->animation_list[i].proxy);

    }
    SLSReenableUpdate(context->animation_connection);
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);

    SLSReleaseConnection(context->animation_connection);
    free(context->animation_list);
    free(context);

    CVDisplayLinkStop(link);
    CVDisplayLinkRelease(link);

out:
    return kCVReturnSuccess;
}
#pragma clang diagnostic pop

void window_manager_animate_window_list_async(struct window_capture *window_list, int window_count)
{
    struct window_animation_context *context = malloc(sizeof(struct window_animation_context));

    SLSNewConnection(0, &context->animation_connection);
    context->animation_count    = window_count;
    context->animation_list     = malloc(window_count * sizeof(struct window_animation));
    context->animation_duration = g_window_manager.window_animation_duration;
    context->animation_easing   = g_window_manager.window_animation_easing;
    context->animation_clock    = 0;

    int thread_count = 0;
    pthread_t *threads = ts_alloc_list(pthread_t, window_count);

    TIME_BODY(window_manager_animate_window_list_async___prep_proxies, {
    SLSDisableUpdate(context->animation_connection);
    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    for (int i = 0; i < window_count; ++i) {
        context->animation_list[i].window = window_list[i].window;
        context->animation_list[i].wid    = window_list[i].window->id;
        context->animation_list[i].x      = window_list[i].x;
        context->animation_list[i].y      = window_list[i].y;
        context->animation_list[i].w      = window_list[i].w;
        context->animation_list[i].h      = window_list[i].h;
        context->animation_list[i].cid    = context->animation_connection;
        context->animation_list[i].skip   = false;
        memset(&context->animation_list[i].proxy, 0, sizeof(struct window_proxy));

        struct window_animation *existing_animation = table_find(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
        if (existing_animation) {
            __atomic_store_n(&existing_animation->skip, true, __ATOMIC_RELEASE);

            context->animation_list[i].proxy.frame.origin.x    = (int)(existing_animation->proxy.tx);
            context->animation_list[i].proxy.frame.origin.y    = (int)(existing_animation->proxy.ty);
            context->animation_list[i].proxy.frame.size.width  = (int)(existing_animation->proxy.tw);
            context->animation_list[i].proxy.frame.size.height = (int)(existing_animation->proxy.th);
            context->animation_list[i].proxy.tx                = (int)(existing_animation->proxy.tx);
            context->animation_list[i].proxy.ty                = (int)(existing_animation->proxy.ty);
            context->animation_list[i].proxy.tw                = (int)(existing_animation->proxy.tw);
            context->animation_list[i].proxy.th                = (int)(existing_animation->proxy.th);
            context->animation_list[i].proxy.level             = existing_animation->proxy.level;
            context->animation_list[i].proxy.sub_level         = existing_animation->proxy.sub_level;
            context->animation_list[i].proxy.image             = existing_animation->proxy.image
                                                               ? (CGImageRef) CFRetain(existing_animation->proxy.image)
                                                               : NULL;
            __asm__ __volatile__ ("" ::: "memory");

            float alpha = 1.0f;
            SLSGetWindowAlpha(context->animation_connection, context->animation_list[i].wid, &alpha);
            window_manager_create_window_proxy(context->animation_connection, alpha, &context->animation_list[i].proxy);
            window_manager_notify_jankyborders(&context->animation_list[i], 1, 1325, true, false);
            window_manager_notify_jankyborders(existing_animation, 1, 1326, false, false);

            CFTypeRef transaction = SLSTransactionCreate(context->animation_connection);
            SLSTransactionOrderWindowGroup(transaction, context->animation_list[i].proxy.id, 1, context->animation_list[i].wid);
            SLSTransactionSetWindowSystemAlpha(transaction, existing_animation->proxy.id, 0);
            SLSTransactionCommit(transaction, 0);
            CFRelease(transaction);

            table_remove(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
            window_manager_destroy_window_proxy(existing_animation->cid, &existing_animation->proxy);
        } else {
            pthread_t thread;
            if (pthread_create(&thread, NULL, &window_manager_build_window_proxy_thread_proc, &context->animation_list[i]) == 0) {
                threads[thread_count++] = thread;
            } else {
                window_manager_build_window_proxy_thread_proc(&context->animation_list[i]);
            }
        }

        table_add(&g_window_manager.window_animations_table, &context->animation_list[i].wid, &context->animation_list[i]);
    }
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);
    });

    TIME_BODY(window_manager_animate_window_list_async___wait_for_threads, {
    for (int i = 0; i < thread_count; ++i) {
        pthread_join(threads[i], NULL);
    }
    });

    TIME_BODY(window_manager_animate_window_list_async___swap_proxy_in, {
    scripting_addition_swap_window_proxy_in(context->animation_list, context->animation_count);
    });

    TIME_BODY(window_manager_animate_window_list_async___notify_jb, {
    window_manager_notify_jankyborders(context->animation_list, context->animation_count, 1325, true, false);
    });

    TIME_BODY(window_manager_animate_window_list_async___set_frame, {
    for (int i = 0; i < window_count; ++i) {
        window_manager_set_window_frame(context->animation_list[i].window, context->animation_list[i].x, context->animation_list[i].y, context->animation_list[i].w, context->animation_list[i].h);
    }
    });

    CVDisplayLinkRef link;
    SLSReenableUpdate(context->animation_connection);
    CVDisplayLinkCreateWithActiveCGDisplays(&link);
    CVDisplayLinkSetOutputCallback(link, window_manager_animate_window_list_thread_proc, context);
    CVDisplayLinkStart(link);
}

// Animation rectangle structure for storing x, y, w, h values
typedef struct {
    float x, y, w, h;
} a_rect;

// Animation data structure for pip-based animations
typedef struct {
    struct window_capture capture;
    CGRect original_frame;
    int anchor_point;
    bool is_two_phase;
    float original_w, original_h;
    int resize_anchor;
    float size_ratio;
    // New rectangle-based coordinate system
    a_rect start;      // Starting position and size
    a_rect end;        // Target position and size  
    a_rect current;    // Current interpolated position and size
    // Legacy fields (can be deprecated later)
    float calculated_w, calculated_h;
    float calculated_x, calculated_y;
    bool needs_proxy;
    struct window_proxy proxy;
    bool proxy_created;
    float proxy_fade_end;
} pip_anmxn;

// Forward declarations for pip functions
static bool pip_check_req(struct window_capture *window_list, int window_count);
static void pip_prep_windows(struct window_capture *window_list, int window_count, pip_anmxn *anmxn);
static void pip_calc_anchor_points(int window_count, pip_anmxn *anmxn, 
                                   double t, float mt, int easing, int frame, int total_frames,
                                   CFTypeRef frame_transaction);

// pip-based animation context structure
struct window_frame_animation_context {
    int animation_connection;
    int animation_count;
    struct window_frame_animation *animation_list;
    pip_anmxn *pip_data;  // Added for pip-based animation alignment
    double animation_duration;
    int animation_easing;
    float animation_frame_rate;
    uint64_t animation_clock;
    pthread_t animation_thread;
    bool animation_running;
};

// pip-based animation data structure
struct window_frame_animation {
    struct window *window;
    uint32_t wid;
    float x, y, w, h;
    CGRect original_frame;
    bool is_two_phase;
    float original_w, original_h;
    int resize_anchor;
    float size_ratio;
    bool skip;
    // Store calculated dimensions per frame (since PiP doesn't change actual window size)
    float calculated_w, calculated_h;
    float calculated_x, calculated_y;
};

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static void *window_manager_animate_window_list_pip_thread_proc(void *data)
{
    struct window_frame_animation_context *context = data;
    int animation_count = context->animation_count;
    pip_anmxn *anmxn = context->pip_data;
    
    log_a("🎬 pip-based async animation thread started for %d windows", animation_count);
    
    // Animation parameters
    double duration = context->animation_duration;
    int easing = context->animation_easing;
    float frame_rate = context->animation_frame_rate;
    
    // Calculate frame timing
    int total_frames = (int)(duration * frame_rate);
    if (total_frames < 2) total_frames = 2; // Minimum 2 frames
    if (total_frames > 120) total_frames = 120; // Maximum 120 frames (2 seconds at 60fps)
    
    double frame_duration = duration / total_frames;
    
    log_a("🎬 Async frame animation: duration=%.1fs, frame_rate=%.1f fps, total_frames=%d, frame_duration=%.3fs", 
          duration, frame_rate, total_frames, frame_duration);
    
    context->animation_clock = mach_absolute_time();
    
    for (int frame = 0; frame <= total_frames && context->animation_running; ++frame) {
        double t = (double)frame / (double)total_frames;
        if (t > 1.0) t = 1.0;


        // todo: migrate animation over to a scripting addition function for true transaction batching
        // I realise it would much better if we animated the windows with
        // scripting addition for true transaction batching
        // Better animation control with the SLS APIs
        
        CFTypeRef frame_transaction = SLSTransactionCreate(g_connection);
        
        float mt;
        if (g_window_manager.window_animation_simplified_easing || g_window_manager.window_animation_fast_mode) {
            // Use linear interpolation for simplified/fast mode
            mt = t;
        } else {
            switch (easing) {
            #define ANIMATION_EASING_TYPE_ENTRY(value) case value##_type: mt = value(t); break;
                            ANIMATION_EASING_TYPE_LIST
            #undef ANIMATION_EASING_TYPE_ENTRY
                default: mt = t; // Linear fallback
            }
        }


        pip_calc_anchor_points(animation_count, anmxn, t, mt, easing, frame, total_frames, frame_transaction);

        for (int i = 0; i < animation_count; ++i) {
            if (__atomic_load_n(&context->animation_list[i].skip, __ATOMIC_RELAXED)) continue;
            
            // Use the new a_rect coordinate system
            float sx = anmxn[i].start.x;    float sy = anmxn[i].start.y;    float sw = anmxn[i].start.w;    float sh = anmxn[i].start.h;
            float ex = anmxn[i].end.x;      float ey = anmxn[i].end.y;      float ew = anmxn[i].end.w;      float eh = anmxn[i].end.h;
            float cx = anmxn[i].current.x;  float cy = anmxn[i].current.y;  float cw = anmxn[i].current.w;  float ch = anmxn[i].current.h;
            
            // Handle opacity fading if enabled
            float opacity_fade_duration = g_window_manager.window_opacity_duration;
            bool use_opacity_fade = (opacity_fade_duration > 0.0f) && g_window_manager.window_animation_opacity_enabled;
            
            float fade_t = 1.0f;
            SLSGetWindowAlpha(g_connection, anmxn[i].capture.window->id, &fade_t);

            log_a("fdb async start (x=%.1f y=%.1f w=%.1f h=%.1f) current: (x=%.1f y=%.1f w=%.1f h=%.1f) end: (x=%.1f y=%.1f w=%.1f h=%.1f) frame %d/%d t=%.3f mt=%.3f fade_t=%.3f\n",
                  sx, sy, sw, sh,
                  cx, cy, cw, ch,
                  ex, ey, ew, eh,
                  frame, total_frames, t, mt, fade_t);

            if (frame == 0) {
               
                // skip setting frame if window is zoomed or if start and end are identical
                struct view *view = window_manager_find_managed_window(&g_window_manager, anmxn[i].capture.window);
                if (view) {
                    struct window_node *node = view_find_window_node(view, anmxn[i].capture.window->id);
                    if (node && !node->zoom) {
                        window_manager_set_window_frame(anmxn[i].capture.window, ex, ey, ew, eh);
                    } else {
                        // For zoomed windows, set the frame asynchronously with a delay to avoid AX API race condition
                        // This prevents the window from briefly appearing at its final position before animation
                        // The animation can continue immediately while the frame setting happens in the background
                        window_manager_set_window_frame_async_delayed(anmxn[i].capture.window, ex, ey, ew, eh, 200); // 200ms delay
                    }
                }
                
                // mode 0: initial frame/setup pip
                scripting_addition_anim_window_pip_mode( 
                    anmxn[i].capture.window->id, 0,
                    sx, sy, sw, sh,
                    cx, cy, cw, ch,
                    ex, ey, ew, eh,
                    fade_t, mt,  // duration (0 = immediate)
                    anmxn[i].proxy.id,
                    anmxn[i].resize_anchor,
                    0  // meta - placeholder for now
                );  
            } else if (frame == total_frames) {
                // mode 2: final frome/restore pip
                scripting_addition_anim_window_pip_mode(
                    anmxn[i].capture.window->id, 2,
                    sx,sy,sw,sh,
                    cx,cy,cw,ch,
                    ex,ey,ew,eh,
                    fade_t, mt,
                    anmxn[i].proxy.id,
                    anmxn[i].resize_anchor,
                    0  // meta - placeholder for now
                );
            } else {
                // mode 1 = update pip
                scripting_addition_anim_window_pip_mode(
                    anmxn[i].capture.window->id, 1,
                    sx,sy,sw,sh,
                    cx,cy,cw,ch,
                    ex,ey,ew,eh,
                    fade_t, mt,
                    anmxn[i].proxy.id,
                    anmxn[i].resize_anchor,
                    0  // meta - placeholder for now
                );
            }
        } // End of window loop
        
        // Commit the frame transaction for all windows at once
        SLSTransactionCommit(frame_transaction, 0);
        CFRelease(frame_transaction);
        
        // Wait for next frame (unless this is the last frame)
        if (frame < total_frames && context->animation_running) {
            usleep((useconds_t)(frame_duration * 1000000));
        }
    }
    
    // Clean up (aligned with sync version)
    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    for (int i = 0; i < animation_count; ++i) {
        // Remove from animation table
        table_remove(&g_window_manager.window_animations_table, &anmxn[i].capture.window->id);

        // Clean up proxy windows
        if (anmxn[i].needs_proxy && anmxn[i].proxy_created && anmxn[i].proxy.id != 0) {
            window_manager_destroy_window_proxy(g_connection, &anmxn[i].proxy);
            anmxn[i].proxy_created = false;
        }
        // NOTE: Removed window_manager_set_window_frame call to prevent flicker   
    }
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);
    
    // Free context
    free(context->animation_list);
    free(context->pip_data);
    free(context);
    
    log_a("🎬 pip-based async animation thread completed");
    return NULL;
}
#pragma clang diagnostic pop

void window_manager_animate_window_list_pip_async(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;
    
    log_a("🎬 Starting pip-based ASYNC animation for %d windows (frame_rate=%.1f fps)", 
          window_count, g_window_manager.window_animation_frame_rate);
    
    if (!pip_check_req(window_list, window_count)) {
        // Fallback to immediate positioning for all windows if animation not required
        for (int i = 0; i < window_count; ++i) {
            window_manager_set_window_frame(window_list[i].window, 
                                          window_list[i].x, 
                                          window_list[i].y, 
                                          window_list[i].w, 
                                          window_list[i].h);
        }
        return;
    }
    
    // Check if any of these windows are already being animated
    for (int i = 0; i < window_count; ++i) {
        if (table_find(&g_window_manager.window_animations_table, &window_list[i].window->id)) {
            log_a("🎬 Window %d already animating, skipping pip-based async animation", window_list[i].window->id);
            // Fallback to immediate positioning for all windows
            for (int j = 0; j < window_count; ++j) {
                window_manager_set_window_frame(window_list[j].window, 
                                              window_list[j].x, 
                                              window_list[j].y, 
                                              window_list[j].w, 
                                              window_list[j].h);
            }
            return;
        }
    }

    static uint64_t last_animation_time = 0;
    
    uint64_t current_time = mach_absolute_time();
    uint64_t time_diff = current_time - last_animation_time;
    double time_diff_ms = (double)time_diff / (double)g_cv_host_clock_frequency * 1000.0;
    
    // If another animation was triggered very recently, delay this one slightly
    if (time_diff_ms < 100.0 && last_animation_time > 0) {
        usleep(100000); // Wait 100ms to see if more commands are coming
    }
    
    // Create animation context with pip_anmxn data structure
    struct window_frame_animation_context *context = malloc(sizeof(struct window_frame_animation_context));
    context->animation_count = window_count;
    context->animation_list = malloc(window_count * sizeof(struct window_frame_animation));
    context->pip_data = malloc(window_count * sizeof(pip_anmxn));
    context->animation_duration = g_window_manager.window_animation_duration;
    context->animation_easing = g_window_manager.window_animation_easing;
    context->animation_frame_rate = g_window_manager.window_animation_frame_rate;
    context->animation_clock = 0;
    context->animation_running = true;
    
    // Initialize and prepare animation data using pip_prep_windows
    pip_prep_windows(window_list, window_count, context->pip_data);
    
    // Mark windows as animating and copy basic data
    pthread_mutex_lock(&g_window_manager.window_animations_lock);
    for (int i = 0; i < window_count; ++i) {
        context->animation_list[i].window = window_list[i].window;
        context->animation_list[i].wid = window_list[i].window->id;
        context->animation_list[i].x = window_list[i].x;
        context->animation_list[i].y = window_list[i].y;
        context->animation_list[i].w = window_list[i].w;
        context->animation_list[i].h = window_list[i].h;
        context->animation_list[i].skip = false;
        
        // Add a dummy entry to prevent duplicate animations
        static struct window_animation dummy_animation = {0};
        table_add(&g_window_manager.window_animations_table, &window_list[i].window->id, &dummy_animation);
    }
    pthread_mutex_unlock(&g_window_manager.window_animations_lock);
    
    // Create and start the animation thread
    if (pthread_create(&context->animation_thread, NULL, window_manager_animate_window_list_pip_thread_proc, context) != 0) {
        log_a("🎬 Failed to create pip-based async animation thread, falling back to immediate positioning");
        
        // Clean up and fallback to immediate positioning
        pthread_mutex_lock(&g_window_manager.window_animations_lock);
        for (int i = 0; i < window_count; ++i) {
            table_remove(&g_window_manager.window_animations_table, &context->animation_list[i].wid);
            window_manager_set_window_frame(context->animation_list[i].window, 
                                          context->animation_list[i].x, 
                                          context->animation_list[i].y, 
                                          context->animation_list[i].w, 
                                          context->animation_list[i].h);
        }
        pthread_mutex_unlock(&g_window_manager.window_animations_lock);
        
        free(context->animation_list);
        free(context->pip_data);
        free(context);
        return;
    }
    
    // Detach the thread so it can clean up itself
    pthread_detach(context->animation_thread);
}

static bool pip_check_req(struct window_capture *window_list, int window_count)
{
    // Check if any of these windows are already being animated
    for (int i = 0; i < window_count; ++i) {
        if (table_find(&g_window_manager.window_animations_table, &window_list[i].window->id)) {
            log_a("🎬 Window %d already animating, skipping animation", window_list[i].window->id);
            return false;
        }
    }
    
    // Check if any windows actually need to move/resize before starting animation
    float movement_threshold = 1.0f; // pixels
    
    for (int i = 0; i < window_count; ++i) {
        CGRect curr_frame;
        SLSGetWindowBounds(g_connection, window_list[i].window->id, &curr_frame);
        
        float x_diff = fabsf(curr_frame.origin.x - window_list[i].x);
        float y_diff = fabsf(curr_frame.origin.y - window_list[i].y);
        float w_diff = fabsf(curr_frame.size.width - window_list[i].w);
        float h_diff = fabsf(curr_frame.size.height - window_list[i].h);
        
        if (x_diff > movement_threshold || y_diff > movement_threshold || 
            w_diff > movement_threshold || h_diff > movement_threshold) {
            return true; // Animation needed
        }
    }
    
    log_a("🎬 No animation needed - all windows already in target positions");
    return false; // No animation needed
}
static void pip_debug(struct window_capture *window_list, int window_count, const char* function, int index, CGRect original_frame)
{
    if(strcmp(function, "bounds") == 0){
       // DEBUG: Compare original bounds vs target bounds for left-side window diagnosis
        debug("🎯 Window %d bounds comparison:", window_list[index].window->id);
        debug("    Original: x=%.1f y=%.1f w=%.1f h=%.1f", 
              original_frame.origin.x, original_frame.origin.y,
              original_frame.size.width, original_frame.size.height);
        debug("    Target:   x=%.1f y=%.1f w=%.1f h=%.1f", 
              window_list[index].x, window_list[index].y, window_list[index].w, window_list[index].h);
        debug("    X diff: %.1f Y diff: %.1f W diff: %.1f H diff: %.1f",
              fabsf(original_frame.origin.x - window_list[index].x),
              fabsf(original_frame.origin.y - window_list[index].y),
              fabsf(original_frame.size.width - window_list[index].w),
              fabsf(original_frame.size.height - window_list[index].h)); 
    }
    
}
static void pip_prep_windows(struct window_capture *window_list, int window_count, pip_anmxn *anmxn)
{
        // Prepare animation data and mark windows as animating
    for (int i = 0; i < window_count; ++i) {
        anmxn[i].capture = window_list[i];
        SLSGetWindowBounds(g_connection, window_list[i].window->id, &anmxn[i].original_frame);
        pip_debug(window_list, window_count, "bounds", i, anmxn[i].original_frame);
        // Store original dimensions for 2-phase logiec
        anmxn[i].original_w = anmxn[i].original_frame.size.width;
        anmxn[i].original_h = anmxn[i].original_frame.size.height;

        anmxn[i].size_ratio = calculate_size_difference_ratio(
            anmxn[i].original_w, anmxn[i].original_h,
            window_list[i].w, window_list[i].h
        );


        // Use centralized anchoring system for all animations
        CGRect start_rect = anmxn[i].original_frame;
        CGRect end_rect = CGRectMake(window_list[i].x, window_list[i].y, window_list[i].w, window_list[i].h);
        
        // Get the parent split if available from the window's node
        enum window_node_split parent_split = SPLIT_NONE;
        struct view *view = window_manager_find_managed_window(&g_window_manager, anmxn[i].capture.window);
        if (view && view->root) {
            struct window_node *node = view_find_window_node(view, window_list[i].window->id);
            if (node && node->parent) {
                parent_split = node->parent->split;
            }
        }
        
        // Use unified anchoring system
        unified_anchor_info anchor = calculate_unified_anchor(start_rect, end_rect,
                                                            parent_split,
                                                            g_window_manager.window_animation_edge_threshold,
                                                            NULL); // No animation struct for pip-based
        
        // Set resize_anchor from centralized calculation
        anmxn[i].resize_anchor = anchor.legacy_resize_anchor;

        // Assign anchor_point to the calculated resize_anchor value
        anmxn[i].anchor_point = anmxn[i].resize_anchor;

        // Initialize new a_rect coordinate system
        anmxn[i].start.x = anmxn[i].original_frame.origin.x;
        anmxn[i].start.y = anmxn[i].original_frame.origin.y;
        anmxn[i].start.w = anmxn[i].original_frame.size.width;
        anmxn[i].start.h = anmxn[i].original_frame.size.height;
        
        anmxn[i].end.x = window_list[i].x;
        anmxn[i].end.y = window_list[i].y;
        anmxn[i].end.w = window_list[i].w;
        anmxn[i].end.h = window_list[i].h;
        
        // Initialize current to start position
        anmxn[i].current = anmxn[i].start;

        // Initialize calculated dimensions with original frame values (legacy compatibility)
        anmxn[i].calculated_x = anmxn[i].original_frame.origin.x;
        anmxn[i].calculated_y = anmxn[i].original_frame.origin.y;
        anmxn[i].calculated_w = anmxn[i].original_frame.size.width;
        anmxn[i].calculated_h = anmxn[i].original_frame.size.height;

        // Initialize proxy system
        float size_threshold = 5.0f; // Minimum size change to warrant proxy (pixels)
        bool size_changes = (fabsf(anmxn[i].original_frame.size.width - window_list[i].w) > size_threshold ||
                            fabsf(anmxn[i].original_frame.size.height - window_list[i].h) > size_threshold);
        
        anmxn[i].needs_proxy = size_changes;
        memset(&anmxn[i].proxy, 0, sizeof(struct window_proxy));
        anmxn[i].proxy_created = false;
        anmxn[i].proxy_fade_end = g_window_manager.window_animation_fade_threshold; // Fade out proxy during first quarter of animation

        // Add a dummy entry to window_animations_table to prevent duplicate animations
        static struct window_animation dummy_animation = {0};
        table_add(&g_window_manager.window_animations_table, &window_list[i].window->id, &dummy_animation);
    }
    
    // Create screenshot proxies for windows that need them
    for (int i = 0; i < window_count; ++i) {
        if (!anmxn[i].needs_proxy) continue;        
        // Create a real proxy window using existing infrastructure
        uint32_t window_id = anmxn[i].capture.window->id;
        
        // Get window properties for proxy
        SLSGetWindowBounds(g_connection, window_id, &anmxn[i].proxy.frame);
        anmxn[i].proxy.level = window_level(window_id);
        anmxn[i].proxy.sub_level = window_sub_level(window_id);

        float alpha = 1.0f;
        SLSGetWindowAlpha(g_connection, window_id, &alpha);
        window_manager_create_window_proxy(g_connection, 0, &anmxn[i].proxy);
        
        if (anmxn[i].proxy.id != 0) anmxn[i].proxy_created = true;
        if (!anmxn[i].proxy_created) {
            anmxn[i].needs_proxy = false; // Disable proxy for this window
        }
    }

}
static void pip_calc_anchor_points(int window_count, pip_anmxn *anmxn, 
                                  double t, float mt, int easing, int frame, int total_frames,
                                  CFTypeRef frame_transaction)
{
    log_a("Calculating anchor points for %d windows, frame %d/%d, t=%.4f", 
                       window_count, frame, total_frames, t);
    
    for (int i = 0; i < window_count; ++i) {
            // Use the new a_rect coordinate system
            float sx = anmxn[i].start.x;
            float sy = anmxn[i].start.y;
            float sw = anmxn[i].start.w;
            float sh = anmxn[i].start.h;
            
            log_p("Window %d start position: (%.2f, %.2f) size: %.2f x %.2f", 
                           i, sx, sy, sw, sh);
            
            float ex = anmxn[i].end.x;
            float ey = anmxn[i].end.y;
            float ew = anmxn[i].end.w;
            float eh = anmxn[i].end.h;
            
            log_p("Window %d end position: (%.2f, %.2f) size: %.2f x %.2f", 
                           i, ex, ey, ew, eh);
            
            float cx, cy, cw, ch;
            float slide_duration = g_window_manager.window_animation_slide_ratio;
                float slide_t = t / slide_duration;
                
                float slide_mt;
                if (g_window_manager.window_animation_simplified_easing || g_window_manager.window_animation_fast_mode) {
                    slide_mt = slide_t; // Linear for simplified/fast mode
                } else {
                    // Apply the same easing function configured for animations
                    switch (easing) {
    #define ANIMATION_EASING_TYPE_ENTRY(value) case value##_type: slide_mt = value(slide_t); break;
                        ANIMATION_EASING_TYPE_LIST
    #undef ANIMATION_EASING_TYPE_ENTRY
                        default: slide_mt = slide_t; // Linear fallback
                    }
                }

                cx = sx + (ex - sx) * slide_mt;
                cy = sy + (ey - sy) * slide_mt;
                cw = anmxn[i].original_w;
                ch = anmxn[i].original_h;
                
                log_p("Window %d calculated position: (%.2f, %.2f) size: %.2f x %.2f", 
                               i, cx, cy, cw, ch);
                
                // Store calculated dimensions for this frame (slide phase)
                anmxn[i].calculated_x = cx;
                anmxn[i].calculated_y = cy;
                anmxn[i].calculated_w = cw;
                anmxn[i].calculated_h = ch;

                float interp_mt =  mt;

                cw = anmxn[i].original_w + (ew - anmxn[i].original_w) * interp_mt;
                ch = anmxn[i].original_h + (eh - anmxn[i].original_h) * interp_mt;
                
                log_a("Window %d anchor interpolation: mt=%.4f, final size: %.2f x %.2f", 
                                  i, interp_mt, cw, ch);
                
                // IMPROVED: Stationary edge pinning with proper anchor-based position interpolation
                
                // Detect which edges are stationary (should be pinned)
                float edge_threshold = 2.0f; // Increased from 1.0f - BSP coordinates might have small rounding differences
                bool top_edge_stationary = fabsf(sy - ey) <= edge_threshold;
                bool bottom_edge_stationary = fabsf((sy + sh) - (ey + eh)) <= edge_threshold;
                bool left_edge_stationary = fabsf(sx - ex) <= edge_threshold;
                bool right_edge_stationary = fabsf((sx + sw) - (ex + ew)) <= edge_threshold;
                
                // DEBUG: Enhanced edge detection logging
                    log_a("fdb🔍 Edge Detection for Window %d:\n", anmxn[i].capture.window->id);
                    log_a("fdb    Top: sy=%.1f ey=%.1f diff=%.1f stationary=%s\n", 
                          sy, ey, fabsf(sy - ey), top_edge_stationary ? "YES" : "NO");
                    log_a("fdb    Bottom: start_bottom=%.1f end_bottom=%.1f diff=%.1f stationary=%s\n", 
                          sy + sh, ey + eh, fabsf((sy + sh) - (ey + eh)), bottom_edge_stationary ? "YES" : "NO");
                    log_a("fdb    Left: sx=%.1f ex=%.1f diff=%.1f stationary=%s\n", 
                          sx, ex, fabsf(sx - ex), left_edge_stationary ? "YES" : "NO");
                    log_a("fdb    Right: start_right=%.1f end_right=%.1f diff=%.1f stationary=%s\n", 
                          sx + sw, ex + ew, fabsf((sx + sw) - (ex + ew)), right_edge_stationary ? "YES" : "NO");
                    log_a("fdb    Threshold: %.1f pixels\n", edge_threshold);
                
                // Calculate position using stationary edge pinning
                if (top_edge_stationary && left_edge_stationary) {
                    // Pin top-left corner
                    cx = sx;
                    cy = sy;
                    log_a("🔒 Pinning top-left corner: (%.1f,%.1f)", cx, cy);
                } else if (top_edge_stationary && right_edge_stationary) {
                    // Pin top-right corner
                    cx = sx + sw - cw;
                    cy = sy;
                    log_a("🔒 Pinning top-right corner: (%.1f,%.1f)", cx, cy);
                } else if (bottom_edge_stationary && left_edge_stationary) {
                    // Pin bottom-left corner
                    cx = sx;
                    cy = sy + sh - ch;
                    log_a("🔒 Pinning bottom-left corner: (%.1f,%.1f)", cx, cy);
                } else if (bottom_edge_stationary && right_edge_stationary) {
                    // Pin bottom-right corner
                    cx = sx + sw - cw;
                    cy = sy + sh - ch;
                    log_a("🔒 Pinning bottom-right corner: (%.1f,%.1f)", cx, cy);
                } else if (top_edge_stationary) {
                    // Pin top edge, interpolate X position
                    cy = sy;
                    cx = sx + (ex - sx) * interp_mt;
                    log_a("🔒 Pinning top edge: Y=%.1f, X=%.1f (interpolated)", cy, cx);
                } else if (bottom_edge_stationary) {
                    // Pin bottom edge, interpolate X position
                    cy = sy + sh - ch;
                    cx = sx + (ex - sx) * interp_mt;
                    log_a("🔒 Pinning bottom edge: Y=%.1f, X=%.1f (interpolated)", cy, cx);
                } else if (left_edge_stationary) {
                    // Pin left edge, interpolate Y position
                    cx = sx;
                    cy = sy + (ey - sy) * interp_mt;
                    log_a("🔒 Pinning left edge: X=%.1f, Y=%.1f (interpolated)", cx, cy);
                } else if (right_edge_stationary) {
                    // Pin right edge, interpolate Y position
                    cx = sx + sw - cw;
                    cy = sy + (ey - sy) * interp_mt;
                    log_a("🔒 Pinning right edge: X=%.1f, Y=%.1f (interpolated)", cx, cy);
                } else {
                    // No stationary edges - use traditional anchor-based interpolation
                    log_a("🔄 Using anchor-based interpolation (anchor=%d)", anmxn[i].resize_anchor);
                    float start_anchor_x, start_anchor_y, end_anchor_x, end_anchor_y;
                    
                    switch (anmxn[i].resize_anchor) {
                        case 0: // top-left anchor
                            start_anchor_x = sx;
                            start_anchor_y = sy;
                            end_anchor_x = ex;
                            end_anchor_y = ey;
                            break;
                        case 1: // top-right anchor
                            start_anchor_x = sx + sw;
                            start_anchor_y = sy;
                            end_anchor_x = ex + ew;
                            end_anchor_y = ey;
                            break;
                        case 2: // bottom-left anchor
                            start_anchor_x = sx;
                            start_anchor_y = sy + sh;
                            end_anchor_x = ex;
                            end_anchor_y = ey + eh;
                            break;
                        case 3: // bottom-right anchor
                            start_anchor_x = sx + sw;
                            start_anchor_y = sy + sh;
                            end_anchor_x = ex + ew;
                            end_anchor_y = ey + eh;
                            break;
                        default:
                            start_anchor_x = sx;
                            start_anchor_y = sy;
                            end_anchor_x = ex;
                            end_anchor_y = ey;
                            break;
                    }
                    
                    // Interpolate the anchor point position
                    float current_anchor_x = start_anchor_x + (end_anchor_x - start_anchor_x) * interp_mt;
                    float current_anchor_y = start_anchor_y + (end_anchor_y - start_anchor_y) * interp_mt;
                    
                    // Calculate window position based on interpolated anchor and current size
                    switch (anmxn[i].resize_anchor) {
                        case 0: // top-left anchor
                            cx = current_anchor_x;
                            cy = current_anchor_y;
                            break;
                        case 1: // top-right anchor
                            cx = current_anchor_x - cw;
                            cy = current_anchor_y;
                            break;
                        case 2: // bottom-left anchor
                            cx = current_anchor_x;
                            cy = current_anchor_y - ch;
                            break;
                        case 3: // bottom-right anchor
                            cx = current_anchor_x - cw;
                            cy = current_anchor_y - ch;
                            break;
                        default:
                            cx = current_anchor_x;
                            cy = current_anchor_y;
                            break;
                    }
                    char *title = window_title_ts(anmxn[i].capture.window);
                
                struct application *app = anmxn[i].capture.window
                                          ? anmxn[i].capture.window->application
                                          : NULL;
                char *app_name = app ? app->name : NULL;
                const char *anchor_label;
                switch (anmxn[i].anchor_point) {
                    case 0: anchor_label = "top-left";     break;
                    case 1: anchor_label = "top-right";    break;
                    case 2: anchor_label = "bottom-left";  break;
                    case 3: anchor_label = "bottom-right"; break;
                    default: anchor_label = "unknown";     break;
                }
                
                // Get display ID for this window
                uint32_t display_id = display_manager_point_display_id((CGPoint){sx + sw/2, sy + sh/2});
                
                // Get view for space padding information
                struct view *view = window_manager_find_managed_window(&g_window_manager, anmxn[i].capture.window);
                
                // Analyze screen edge relationships for start and end positions
                CGRect start_rect = CGRectMake(sx, sy, sw, sh);
                CGRect end_rect = CGRectMake(ex, ey, ew, eh);
                screen_edge_info start_edges = analyze_screen_edges(start_rect, display_id, view);
                screen_edge_info end_edges = analyze_screen_edges(end_rect, display_id, view);
                
                // Analyze tree position
                tree_position_info tree_info = analyze_tree_position(anmxn[i].capture.window);
                
                // Calculate operation type details
                float size_change = fabsf((ew * eh) - (sw * sh)) / (sw * sh);
                float position_change = sqrtf(powf(ex - sx, 2) + powf(ey - sy, 2));
                float aspect_change = calculate_aspect_difference(sw, sh, ew, eh);
                
                // Determine which edges are moving/stationary
                bool top_edge_moves = fabsf(sy - ey) > 1.0f;
                bool bottom_edge_moves = fabsf((sy + sh) - (ey + eh)) > 1.0f;
                bool left_edge_moves = fabsf(sx - ex) > 1.0f;
                bool right_edge_moves = fabsf((sx + sw) - (ex + ew)) > 1.0f;
                
                // Build edge movement description
                char edge_movement[128] = "";
                char stationary_edges[64] = "";
                char moving_edges[64] = "";
                
                if (!top_edge_moves) strcat(stationary_edges, "T");
                else strcat(moving_edges, "T");
                if (!bottom_edge_moves) strcat(stationary_edges, "B");
                else strcat(moving_edges, "B");
                if (!left_edge_moves) strcat(stationary_edges, "L");
                else strcat(moving_edges, "L");
                if (!right_edge_moves) strcat(stationary_edges, "R");
                else strcat(moving_edges, "R");

                snprintf(edge_movement, sizeof(edge_movement), "stationary=[%s] moving=[%s]", 
                        strlen(stationary_edges) > 0 ? stationary_edges : "none",
                        strlen(moving_edges) > 0 ? moving_edges : "none");
                
                log_a("fdb ======================================================================\n"
                       "fdb ANCHORING ANALYSIS: %s -> %s\n"
                       "fdb ======================================================================\n"
                       "fdb GEOMETRY:\n"
                       "fdb   start: x: %-5.1f y: %-5.1f w: %-5.1f h: %-5.1f\n"
                       "fdb   end:   x: %-5.1f y: %-5.1f w: %-5.1f h: %-5.1f\n"
                       "fdb   size_change: %.1f%% position_change: %.1fpx aspect_change: %.3f\n"
                       "fdb\n"
                       "fdb CURRENT ANCHOR: %s (index=%d)\n"
                       "fdb EDGE MOVEMENT: %s\n"
                       "fdb\n"
                       "fdb SCREEN EDGES (START):\n"
                       "fdb   position: %s\n"
                       "fdb   touches: %s%s%s%s\n"
                       "fdb   distances: T=%.1f B=%.1f L=%.1f R=%.1f\n"
                       "fdb\n"
                       "fdb SCREEN EDGES (END):\n"
                       "fdb   position: %s\n"
                       "fdb   touches: %s%s%s%s\n"
                       "fdb   distances: T=%.1f B=%.1f L=%.1f R=%.1f\n"
                       "fdb\n"
                       "fdb TREE POSITION:\n"
                       "fdb   layout: %s\n"
                       "fdb   path: %s (depth=%d)\n"
                       "fdb   node_split: %s parent_split: %s\n"
                       "fdb   child_position: %s%s\n"
                       "fdb\n"
                       "fdb SPACE PADDING:\n"
                       "fdb   padding: T=%.1f B=%.1f L=%.1f R=%.1f\n"
                       "fdb   edge_threshold: %.1f pixels\n"
                       "fdb   effective_screen: x=%.1f y=%.1f w=%.1f h=%.1f\n"
                       "fdb\n"
                       "fdb RECOMMENDATIONS:\n"
                       "fdb   - PRIORITY: %s edges are stationary -> anchor to stationary edge!\n"
                       "fdb   - Edge priority order: Bottom > Top > Left > Right\n"
                       "fdb   - Tree position suggests %s-based anchoring\n"
                       "fdb   - Screen position indicates %s anchor preference\n"
                       "fdb   - Space padding factored into edge detection\n"
                       "fdb ======================================================================\n",
                       (app_name ? app_name : "Unknown"),
                       (title ? title : "Unknown"),
                       sx, sy, sw, sh,
                       ex, ey, ew, eh,
                       size_change * 100.0f, position_change, aspect_change,
                       anchor_label, anmxn[i].anchor_point,
                       edge_movement,
                       start_edges.position_desc,
                       start_edges.touches_top ? "T" : "",
                       start_edges.touches_bottom ? "B" : "",
                       start_edges.touches_left ? "L" : "",
                       start_edges.touches_right ? "R" : "",
                       start_edges.distance_to_top, start_edges.distance_to_bottom,
                       start_edges.distance_to_left, start_edges.distance_to_right,
                       end_edges.position_desc,
                       end_edges.touches_top ? "T" : "",
                       end_edges.touches_bottom ? "B" : "",
                       end_edges.touches_left ? "L" : "",
                       end_edges.touches_right ? "R" : "",
                       end_edges.distance_to_top, end_edges.distance_to_bottom,
                       end_edges.distance_to_left, end_edges.distance_to_right,
                       tree_info.position_desc,
                       tree_info.tree_path, tree_info.depth,
                       tree_info.node_split == SPLIT_X ? "vertical" : 
                       tree_info.node_split == SPLIT_Y ? "horizontal" : "none",
                       tree_info.parent_split == SPLIT_X ? "vertical" : 
                       tree_info.parent_split == SPLIT_Y ? "horizontal" : "none",
                       tree_info.is_left_child ? "left-child" : "",
                       tree_info.is_right_child ? "right-child" : "",
                       view ? view->top_padding : 0.0f,
                       view ? view->bottom_padding : 0.0f,
                       view ? view->left_padding : 0.0f,
                       view ? view->right_padding : 0.0f,
                       g_window_manager.window_animation_edge_threshold,
                       view ? (display_bounds_constrained(display_id, false).origin.x + view->left_padding) : 0.0f,
                       view ? (display_bounds_constrained(display_id, false).origin.y + view->top_padding) : 0.0f,
                       view ? (display_bounds_constrained(display_id, false).size.width - view->left_padding - view->right_padding) : 0.0f,
                       view ? (display_bounds_constrained(display_id, false).size.height - view->top_padding - view->bottom_padding) : 0.0f,
                       strlen(stationary_edges) > 0 ? stationary_edges : "no",
                       tree_info.parent_split == SPLIT_X ? "horizontal" : "vertical",
                       start_edges.touches_left && start_edges.touches_top ? "top-left" :
                       start_edges.touches_right && start_edges.touches_top ? "top-right" :
                       start_edges.touches_left && start_edges.touches_bottom ? "bottom-left" :
                       start_edges.touches_right && start_edges.touches_bottom ? "bottom-right" :
                       start_edges.touches_top ? "top" :
                       start_edges.touches_bottom ? "bottom" :
                       start_edges.touches_left ? "left" :
                       start_edges.touches_right ? "right" : "center");
                }
                
                // Store calculated dimensions for this frame (legacy compatibility)
                anmxn[i].calculated_x = cx;
                anmxn[i].calculated_y = cy;
                anmxn[i].calculated_w = cw;
                anmxn[i].calculated_h = ch;
                
                // Store current frame values in the new a_rect structure
                anmxn[i].current.x = cx;
                anmxn[i].current.y = cy;
                anmxn[i].current.w = cw;
                anmxn[i].current.h = ch;
        }
}
void window_manager_animate_window_pip(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;
    
    debug("🎬 Starting pip-based animation for %d windows (frame_rate=%.1f fps)\n", 
          window_count, g_window_manager.window_animation_frame_rate);
    
    if (!pip_check_req(window_list, window_count)) {
        // Fallback to immediate positioning for all windows if animation not required
        for (int i = 0; i < window_count; ++i) {
            window_manager_set_window_frame(window_list[i].window, 
                                          window_list[i].x, 
                                          window_list[i].y, 
                                          window_list[i].w, 
                                          window_list[i].h);
        }
        return;
    }
    
    static uint64_t last_animation_time = 0;
    
    uint64_t current_time = mach_absolute_time();
    uint64_t time_diff = current_time - last_animation_time;
    double time_diff_ms = (double)time_diff / (double)g_cv_host_clock_frequency * 1000.0;
    
    // If another animation was triggered very recently, delay this one slightly
    if (time_diff_ms < 100.0 && last_animation_time > 0) {
        usleep(100000); // Wait 100ms to see if more commands are coming
    }
    
    // Declare animation data structure for this function
    pip_anmxn anmxn[window_count];
    
    // Initialize and prepare animation data
    pip_prep_windows(window_list, window_count, anmxn);
    
    // Animation parameters
    double duration = g_window_manager.window_animation_duration;
    int easing = g_window_manager.window_animation_easing;
    float frame_rate = g_window_manager.window_animation_frame_rate;
    
    // Calculate frame timing
    int total_frames = (int)(duration * frame_rate);
    if (total_frames < 2) total_frames = 2; // Minimum 2 frames
    if (total_frames > 120) total_frames = 120; // Maximum 120 frames (2 seconds at 60fps)
    
    double frame_duration = duration / total_frames;
    
    
    for (int frame = 0; frame <= total_frames; ++frame) {
        double t = (double)frame / (double)total_frames;
        if (t > 1.0) t = 1.0;
         CFTypeRef frame_transaction = SLSTransactionCreate(g_connection);
        float mt;
        if (g_window_manager.window_animation_simplified_easing || g_window_manager.window_animation_fast_mode) {
            // Use linear interpolation for simplified/fast mode
            mt = t;
        } else {
            switch (easing) {
            #define ANIMATION_EASING_TYPE_ENTRY(value) case value##_type: mt = value(t); break;
                            ANIMATION_EASING_TYPE_LIST
            #undef ANIMATION_EASING_TYPE_ENTRY
                default: mt = t; // Linear fallback
            }
        }

        pip_calc_anchor_points(window_count, anmxn, t, mt, easing, frame, total_frames, frame_transaction);

        for (int i = 0; i < window_count; ++i) {
            // Use the new a_rect coordinate system
            uint32_t wid = anmxn[i].capture.window->id;
            float sx = anmxn[i].start.x;    float sy = anmxn[i].start.y;    float sw = anmxn[i].start.w;    float sh = anmxn[i].start.h;
            float ex = anmxn[i].end.x;      float ey = anmxn[i].end.y;      float ew = anmxn[i].end.w;      float eh = anmxn[i].end.h;
            float cx = anmxn[i].current.x;  float cy = anmxn[i].current.y;  float cw = anmxn[i].current.w;  float ch = anmxn[i].current.h;
            
            // Handle opacity fading if enabled
            float opacity_fade_duration = g_window_manager.window_opacity_duration;
            bool use_opacity_fade = (opacity_fade_duration > 0.0f) && g_window_manager.window_animation_opacity_enabled;
            
            float fade_t = 1.0f;
            SLSGetWindowAlpha(g_connection, wid, &fade_t);

            debug("fdb start (x=%.1f y=%.1f w=%.1f h=%.1f) current: (x=%.1f y=%.1f w=%.1f h=%.1f) end: (x=%.1f y=%.1f w=%.1f h=%.1f) frame %d/%d t=%.3f mt=%.3f fade_t=%.3f\n",
                  sx, sy, sw, sh,
                  cx, cy, cw, ch,
                  ex, ey, ew, eh,
                  frame, total_frames, t, mt, fade_t);
            SLSTransactionSetWindowAlpha(frame_transaction, wid, 0.0);
            window_manager_set_opacity(&g_window_manager, anmxn[i].capture.window, 0.0); // Ensure starting opacity is correct
            if (frame == 0) {
                // position window to destination before the animation
                //window_manager_set_opacity(&g_window_manager, anmxn[i].capture.window, 0.0); // Ensure starting opacity is correct
                //scripting_addition_order_window(anmxn[i].capture.window->id, 0, 0);
                //scripting_addition_order_window(anmxn[i].proxy.id, 0, 0);
                window_manager_set_window_frame(anmxn[i].capture.window, ex, ey, ew, eh);

                // mode 0: initial frame/setup pip
                scripting_addition_anim_window_pip_mode( 
                    anmxn[i].capture.window->id, 0,
                    sx, sy, sw, sh,
                    cx, cy, cw, ch,
                    ex, ey, ew, eh,
                    fade_t, mt,  // duration (0 = immediate)
                    anmxn[i].proxy.id,
                    anmxn[i].resize_anchor,
                    0  // meta - placeholder for now
                );  
            } else if( frame == 1){
                //scripting_addition_order_window(anmxn[i].capture.window->id, 1, 0);
                //scripting_addition_order_window(anmxn[i].proxy.id, 1, 0);
            } else if (frame == total_frames) {
                // mode 2: final frome/restore pip
                scripting_addition_anim_window_pip_mode(
                    anmxn[i].capture.window->id, 2,
                    sx,sy,sw,sh,
                    cx,cy,cw,ch,
                    ex,ey,ew,eh,
                    fade_t, mt,
                    anmxn[i].proxy.id,
                    anmxn[i].resize_anchor,
                    0  // meta - placeholder for now
                );
            } else {
                // mode 1 = update pip
                //window_manager_set_opacity(&g_window_manager, anmxn[i].capture.window, 0.0); // Ensure starting opacity is correct
                scripting_addition_anim_window_pip_mode(
                    anmxn[i].capture.window->id, 1,
                    sx,sy,sw,sh,
                    cx,cy,cw,ch,
                    ex,ey,ew,eh,
                    fade_t, mt,
                    anmxn[i].proxy.id,
                    anmxn[i].resize_anchor,
                    0  // meta - placeholder for now
                );
            }
        } // End of window loop
        
        // Commit the frame transaction for all windows at once
        SLSTransactionCommit(frame_transaction, 0);
        CFRelease(frame_transaction);
        
        // Wait for next frame (unless this is the last frame)
        if (frame < total_frames) {
            usleep((useconds_t)(frame_duration * 1000000));
        }
    }
    
    // Clean up
    for (int i = 0; i < window_count; ++i) {

        table_remove(&g_window_manager.window_animations_table, &anmxn[i].capture.window->id);

        // Clean up proxy windows
        if (anmxn[i].needs_proxy && anmxn[i].proxy_created && anmxn[i].proxy.id != 0) {
            
            window_manager_destroy_window_proxy(g_connection, &anmxn[i].proxy);
            anmxn[i].proxy_created = false;
        }
        // NOTE: Removed window_manager_set_window_frame call to prevent flicker   
    }
}

void window_manager_animate_window_list(struct window_capture *window_list, int window_count)
{
    TIME_FUNCTION;

    if (g_window_manager.window_animation_duration) {
        if (g_window_manager.window_animation_pip_enabled) {
            //if(g_window_manager.window_animation_pip_async_enabled){
                debug("pip async");
                // async still wip until animation sequence locked in
                window_manager_animate_window_list_pip_async(window_list, window_count);
            //} else {
                //window_manager_animate_window_pip(window_list, window_count);
            //} 
        } else {
            debug("fdb CLASSIC LIST %d windows\n", window_count);
            window_manager_animate_window_list_async(window_list, window_count);
        }
    } else {
        for (int i = 0; i < window_count; ++i) {
            window_manager_set_window_frame(window_list[i].window, window_list[i].x, window_list[i].y, window_list[i].w, window_list[i].h);
        }
    }
}

void window_manager_animate_window(struct window_capture capture)
{
    TIME_FUNCTION;

    if (g_window_manager.window_animation_duration) {

        if (g_window_manager.window_animation_pip_enabled) {
            //debug("fdb pip-based SINGLE WINDOW %d window\n", window_count);
            //if(g_window_manager.window_animation_pip_async_enabled){
            //    debug("fdb WARNING: Async flag is ignored for pip-based animations\n");
            //} else {
            window_manager_animate_window_list_pip_async(&capture, 1);
            //}
        } else {
            window_manager_animate_window_list(&capture, 1);
        }
    } else {
        window_manager_set_window_frame(capture.window, capture.x, capture.y, capture.w, capture.h);
    }
}

void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height)
{
    //
    // NOTE(koekeishiya): Attempting to check the window frame cache to prevent unnecessary movement and resize calls to the AX API
    // is not reliable because it is possible to perform operations that should be applied, at a higher rate than the AX API events
    // are received, causing our cache to become out of date and incorrectly guard against some changes that **should** be applied.
    // This causes the window layout to **not** be modified the way we expect.
    //
    // A possible solution is to use the faster CG window notifications, as they are **a lot** more responsive, and can be used to
    // track changes to the window frame in real-time without delay.
    //

    //push_jankyborders_stack(1325, window->id, stack_count, stack_index );

    if (window && window->id &&
        window_manager_find_managed_window(&g_window_manager, window)) {
        struct view *view =
            window_manager_find_managed_window(&g_window_manager, window);
        struct window_node *node = view_find_window_node(view, window->id);  
            if (node && node->window_count > 1) {
                uint32_t left_padding = 0;
                x += left_padding;
                //y = node->area.y;
                width -= left_padding;
                //height = node->area.h;
            }
    }

    AX_ENHANCED_UI_WORKAROUND(window->application->ref, {
        // NOTE(koekeishiya): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.

        window_manager_resize_window(window, width, height);

        window_manager_move_window(window, x, y);

        // NOTE(koekeishiya): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
        window_manager_resize_window(window, width, height);
    });
}

void window_manager_set_purify_mode(struct window_manager *wm, enum purify_mode mode)
{
    wm->purify_mode = mode;
    table_for (struct window *window, wm->window, {
        if (window_manager_is_window_eligible(window)) {
            window_manager_purify_window(wm, window);
        }
    })
}

bool window_manager_set_opacity(struct window_manager *wm, struct window *window, float opacity)
{
    if (opacity == 0.0f) {
        if (wm->enable_window_opacity) {
            opacity = window->id == wm->focused_window_id ? wm->active_window_opacity : wm->normal_window_opacity;
        } else {
            opacity = 1.0f;
        }
    }

    return scripting_addition_set_opacity(window->id, opacity, wm->window_opacity_duration);
}

void window_manager_set_window_opacity(struct window_manager *wm, struct window *window, float opacity)
{
    if (!wm->enable_window_opacity)                 return;
    if (!window_manager_is_window_eligible(window)) return;
    if (window->opacity != 0.0f)                    return;

    window_manager_set_opacity(wm, window, opacity);
}

void window_manager_set_menubar_opacity(struct window_manager *wm, float opacity)
{
    wm->menubar_opacity = opacity;
    SLSSetMenuBarInsetAndAlpha(g_connection, 0, 1, opacity);
}

void window_manager_set_active_window_opacity(struct window_manager *wm, float opacity)
{
    wm->active_window_opacity = opacity;
    struct window *window = window_manager_focused_window(wm);
    if (window) window_manager_set_window_opacity(wm, window, wm->active_window_opacity);
}

void window_manager_set_normal_window_opacity(struct window_manager *wm, float opacity)
{
    wm->normal_window_opacity = opacity;
    table_for (struct window *window, wm->window, {
        if (window->id == wm->focused_window_id) continue;
        if (window_manager_is_window_eligible(window)) {
            window_manager_set_window_opacity(wm, window, wm->normal_window_opacity);
        }
    })
}

void window_manager_adjust_layer(struct window *window, int layer)
{
    debug("[LAYER] Adjusting layer for window %d to %d\n", window->id, layer);
    if (window->layer != LAYER_AUTO) return;

    scripting_addition_set_layer(window->id, layer);
}

bool window_manager_set_window_layer(struct window *window, int layer)
{
    int parent_layer = layer;
    int child_layer = layer;
    debug("[LAYER] Setting layer for window %d to %d\n", window->id, layer);
    if (layer == LAYER_AUTO) {
        debug("[LAYER] Layer is set to AUTO for window %d\n", window->id);
        parent_layer = window_manager_find_managed_window(&g_window_manager, window) ? LAYER_BELOW : LAYER_NORMAL;
        child_layer = LAYER_NORMAL;
    }

    window->layer = layer;
    bool result = scripting_addition_set_layer(window->id, parent_layer);
    if (!result) return false;

    CFArrayRef window_list = SLSCopyAssociatedWindows(g_connection, window->id);
    if (!window_list) return result;

    int window_count = CFArrayGetCount(window_list);
    CFTypeRef query = SLSWindowQueryWindows(g_connection, window_list, window_count);
    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);

    int relation_count = 0;
    uint32_t parent_list[window_count];
    uint32_t child_list[window_count];

    while (SLSWindowIteratorAdvance(iterator)) {
        parent_list[relation_count] = SLSWindowIteratorGetParentID(iterator);
        child_list[relation_count] = SLSWindowIteratorGetWindowID(iterator);
        ++relation_count;
    }

    int check_count = 1;
    uint32_t check_list[window_count];
    check_list[0] = window->id;

    for (int i = 0; i < check_count; ++i) {
        for (int j = 0; j < window_count; ++j) {
            if (parent_list[j] != check_list[i]) continue;
            scripting_addition_set_layer(child_list[j], child_layer);
            check_list[check_count++] = child_list[j];
        }
    }

    CFRelease(query);
    CFRelease(iterator);
    CFRelease(window_list);

    return result;
}

void window_manager_purify_window(struct window_manager *wm, struct window *window)
{
    int value;

    if (wm->purify_mode == PURIFY_DISABLED) {
        value = 1;
    } else if (wm->purify_mode == PURIFY_MANAGED) {
        value = window_manager_find_managed_window(wm, window) ? 0 : 1;
    } else /*if (wm->purify_mode == PURIFY_ALWAYS) */ {
        value = 0;
    }

    if (scripting_addition_set_shadow(window->id, value)) {
        if (value) {
            window_set_flag(window, WINDOW_SHADOW);
        } else {
            window_clear_flag(window, WINDOW_SHADOW);
        }
    }
}

int window_manager_find_rank_of_window_in_list(uint32_t wid, uint32_t *window_list, int window_count)
{
    for (int i = 0, rank = 0; i < window_count; ++i) {
        if (window_list[i] == wid) {
            return rank;
        } else {
            ++rank;
        }
    }

    return INT_MAX;
}

struct window *window_manager_find_window_on_space_by_rank_filtering_window(struct window_manager *wm, uint64_t sid, int rank, uint32_t filter_wid)
{
    int count;
    uint32_t *window_list = space_window_list(sid, &count, false);
    if (!window_list) return NULL;

    struct window *result = NULL;
    for (int i = 0, j = 0; i < count; ++i) {
        if (window_list[i] == filter_wid) continue;

        struct window *window = window_manager_find_window(wm, window_list[i]);
        if (!window) continue;

        if (++j == rank) {
            result = window;
            break;
        }
    }

    return result;
}

static inline bool window_manager_window_connection_is_jankyborders(int window_cid)
{
    static char process_name[PROC_PIDPATHINFO_MAXSIZE];

    pid_t window_pid = 0;
    SLSConnectionGetPID(window_cid, &window_pid);
    proc_name(window_pid, process_name, sizeof(process_name));

    return strcmp(process_name, "borders") == 0;
}
static void refresh_node_order(struct window_node *n, uint64_t sid)
{
    int wc = 0;
    uint32_t *wl = space_window_list(sid, &wc, false);
    if (!wl) return;

    int k = 0;
    for (int i = 0; i < wc && k < n->window_count; ++i) {
        for (int j = 0; j < n->window_count; ++j) {
            if (wl[i] == n->window_list[j]) {
                n->window_order[k++] = wl[i];
                break;
            }
        }
    }
}
void stack_pass_begin(struct window_manager *wm)
{
    wm->stack_gen++;
}

void stack_mark_member(struct window_manager *wm,
                                     uint32_t wid,
                                     uint32_t stack_id,
                                     int index,
                                     int len,
                                     uint32_t top_wid)
{
    struct stack_state *s = table_find(&wm->stack_state, &wid);

    bool is_topmost = (wid == top_wid) ? true : false;

    debug("😵😵😵😵 WID:%d, IS_TOPMOST: %d, STACK_INDEX: %d/%d\n", wid, is_topmost, index, len);
    
    struct yb_stack_update msg = {
        .wid      = wid,
        .index    = index,
        .len      = len,
        .is_topmost = is_topmost,
    };
    //if(s){
    //    s->topmost_wid = top_wid; // update topmost wid
    //    //if(is_topmost){
    //    //    s->topmost_wid = wid;
    //        debug("[🟦 Topmost window in stack %d is now %d]\n", stack_id, wid);
    //    //}
    //}
    // If we don't have a stack state for this window, create one
    // this is a new stack
    if (!s) {
        /* allocate on the heap so it outlives this function */
        debug("[🟥 No stack state found for window %d]\n", wid);
        struct stack_state *rec = malloc(sizeof(struct stack_state));
        rec->wid      = wid;
        rec->stack_id = stack_id;
        rec->index    = index;
        rec->len      = len;
        rec->gen      = wm->stack_gen;
        rec->in_stack = true;
        rec->topmost_wid = top_wid; // update topmost wid
        msg.index     = index;
        msg.len       = len;
        msg.is_topmost = is_topmost;
        debug("[🟥 Adding stack state for window %d. stack_id: %d, index: %d/%d] is_topmost: %d\n", wid, stack_id, index, len, is_topmost);
        table_add(&wm->stack_state, &wid, rec);
        push_janky_update(1337, &msg, sizeof(msg)); // ← STACK-ENTER
       
        return;
    }

    s->gen = wm->stack_gen;           // mark seen this pass
   
    // If this window is marked as not in stack, 
    if (!s->in_stack) {               // re-entered
        s->in_stack = true;
        s->stack_id = stack_id;
        s->index    = index;
        s->len      = len;
        s->is_topmost = is_topmost;
        s->topmost_wid = top_wid;      // update topmost wid
        msg.index   = index;
        msg.len     = len;
        msg.is_topmost = is_topmost;
        debug("[🟩 wid:%d still in stack_id: %d, index: %d/%d] is_topmost: %d\n", wid, stack_id, index, len, is_topmost);
        push_janky_update(1338, &msg, sizeof(msg));
        return;
    }

    // still stacked – check for reorder/len change

    if (s->topmost_wid != top_wid || s->len != (uint32_t)len) {
        s->index = index;
        s->len   = len;
        s->topmost_wid = top_wid;
        msg.index     = index;
        msg.len    = len;
        debug("[🟨 wid:%d reordered in stack_id: %d, index: %d/%d] is_topmost: %d\n", wid, stack_id, index, len, is_topmost);
        push_janky_update(1339, &msg, sizeof(msg));   // ← STACK-REORDER
    }
if(s){
    if(s->topmost_wid){
        debug("[ STACK TOPMOST: %d]\n", s->topmost_wid);
    }
    };
}

//static void log_real_vs_cached_order(struct window_node *n, uint64_t sid)
//{
//    int real_count = 0;
//    uint32_t *real = space_window_list(sid, &real_count, false);
//    if (!real) {
//        debug("[ORDER]  !! space_window_list returned NULL\n");
//        return;
//    }

//    debug("[ORDER]  -- WindowServer order for this space --");
//    for (int i = 0; i < real_count; ++i) {
//        for (int j = 0; j < n->window_count; ++j) {
//            if (real[i] == n->window_list[j]) {
//                debug("[ORDER]    pos %d ⇒ wid %u  (cached idx %d)",
//                      i, real[i], j);
//                break;
//            }
//        }
//    }
//}

void window_manager_sweep_stacks(struct view *view,
                                        struct window_manager *wm)
{
    if (!view || !view->root) return;
    debug("[🥞 STACK] Sweeping stacks for view %p\n", view);
    stack_pass_begin(wm);

    // Depth-first walk of all nodes in the view
    struct window_node *stack[64];
    int top = 0;
    if (view->root) stack[top++] = view->root;
    while (top) {
        struct window_node *n = stack[--top];

        if (window_node_is_leaf(n) && n->window_count > 1) {
            /* Determine the true front‑most window for this stack:
               the first (smallest‑index) entry from wl[] that belongs
               to n->window_list. */
            int wc = 0;
            uint32_t *wl = space_window_list(view->sid, &wc, false);
            uint32_t top_wid = 0;
            if (wl && wc) {
                for (int i = 0; i < wc && !top_wid; ++i) {
                    for (int j = 0; j < n->window_count; ++j) {
                        if (wl[i] == n->window_list[j]) {
                            top_wid = wl[i];
                            break;          /* stop at first match */
                        }
                    }
                }
            }

            /* Fallback: use cached order[0] if we somehow didn’t find one. */
            if (!top_wid) top_wid = n->window_order[0];

            uint32_t stack_id = top_wid;   /* keep existing semantics */

            /* Walk members once, using the pre‑computed top_wid. */
            for (int j = 0; j < n->window_count; ++j) {
                stack_mark_member(wm,
                                  n->window_order[j],
                                  stack_id,
                                  j + 1,
                                  n->window_count,
                                  top_wid);
            }
        }
        if (n->right) stack[top++] = n->right;
        if (n->left ) stack[top++] = n->left;
    }
    stack_pass_end(wm);
}
// src/window_manager.c
void stack_pass_end(struct window_manager *wm)
{

    
    struct yb_stack_update msg;
    /* Iterate over every cached stack_state record */
    debug("[🥞 STACK] Ending stack pass \n");
    table_for (struct stack_state *s, wm->stack_state, {
        /* Was in a stack last pass, but not seen this pass? */
        if (!s) return;
        if (s->in_stack && s->gen != wm->stack_gen) {
            s->in_stack = false;
            msg.wid      = s->wid;
            msg.index    = 0;
            push_janky_update(1340, &msg, sizeof(msg));
            debug("[🥞 STACK] Window %u left stack %u at index %u/%u\n",
                  s->wid, s->stack_id, s->index, s->len);
        }

    });


}
struct window *window_manager_find_window_at_point_filtering_window(struct window_manager *wm, CGPoint point, uint32_t filter_wid)
{
    CGPoint window_point;
    uint32_t window_id;
    int window_cid;

    SLSFindWindowAndOwner(g_connection, filter_wid, -1, 0, &point, &window_point, &window_id, &window_cid);
    if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);

    if (window_manager_window_connection_is_jankyborders(window_cid)) {
        SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
        if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
    }

    return window_manager_find_window(wm, window_id);
}

struct window *window_manager_find_window_at_point(struct window_manager *wm, CGPoint point)
{
    CGPoint window_point;
    uint32_t window_id;
    int window_cid;

    SLSFindWindowAndOwner(g_connection, 0, 1, 0, &point, &window_point, &window_id, &window_cid);
    if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);

    if (window_manager_window_connection_is_jankyborders(window_cid)) {
        SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
        if (g_connection == window_cid) SLSFindWindowAndOwner(g_connection, window_id, -1, 0, &point, &window_point, &window_id, &window_cid);
    }

    return window_manager_find_window(wm, window_id);
}

struct window *window_manager_find_window_below_cursor(struct window_manager *wm)
{
    CGPoint cursor;
    SLSGetCurrentCursorLocation(g_connection, &cursor);
    return window_manager_find_window_at_point(wm, cursor);
}

struct window *window_manager_find_closest_managed_window_in_direction(struct window_manager *wm, struct window *window, int direction)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    struct window_node *closest = view_find_window_node_in_direction(view, node, direction);
    if (!closest) return NULL;

    // Check if it's a stacked node
    struct window *w;
    struct window_node *n = closest;
    
    if (n->window_count > 1) {
        w = window_manager_find_topmost_window_in_stack(wm, n);
        if (w) return w;
    }
    return window_manager_find_window(wm, n->window_order[0]);
}

struct window *window_manager_find_topmost_window_in_stack(struct window_manager *wm, struct window_node *node)
{
    if (!node || node->window_count <= 1) return NULL;

    // Use the first window’s stack_state to fetch the topmost WID
    struct stack_state *s = table_find(&wm->stack_state, &node->window_order[0]);
    if (s && s->topmost_wid) {
        return window_manager_find_window(wm, s->topmost_wid);
    }

    // Fallback to first window if no stack state is found
    return window_manager_find_window(wm, node->window_order[0]);
}

struct window *window_manager_find_prev_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    struct window_node *prev = window_node_find_prev_leaf(node);
    if (!prev) return NULL;

    return window_manager_find_window(wm, prev->window_order[0]);
}

struct window *window_manager_find_next_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    struct window_node *next = window_node_find_next_leaf(node);
    if (!next) return NULL;

    return window_manager_find_window(wm, next->window_order[0]);
}

struct window *window_manager_find_first_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *first = window_node_find_first_leaf(view->root);
    if (!first) return NULL;

    return window_manager_find_window(wm, first->window_order[0]);
}

struct window *window_manager_find_last_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *last = window_node_find_last_leaf(view->root);
    if (!last) return NULL;

    return window_manager_find_window(wm, last->window_order[0]);
}

struct window *window_manager_find_recent_managed_window(struct window_manager *wm)
{
    struct window *window = window_manager_find_window(wm, wm->last_window_id);
    if (!window) return NULL;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    return window;
}

struct window *window_manager_find_prev_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    for (int i = 1; i < node->window_count; ++i) {
        if (node->window_list[i] == window->id) {
            return window_manager_find_window(wm, node->window_list[i-1]);
        }
    }

    return NULL;
}

struct window *window_manager_find_next_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    for (int i = 0; i < node->window_count - 1; ++i) {
        if (node->window_list[i] == window->id) {
            return window_manager_find_window(wm, node->window_list[i+1]);
        }
    }

    return NULL;
}

struct window *window_manager_find_first_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    return node->window_count > 1 ? window_manager_find_window(wm, node->window_list[0]) : NULL;
}

struct window *window_manager_find_last_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    return node->window_count > 1 ? window_manager_find_window(wm, node->window_list[node->window_count-1]) : NULL;
}

struct window *window_manager_find_recent_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    return node->window_count > 1 ? window_manager_find_window(wm, node->window_order[1]) : NULL;
}

struct window *window_manager_find_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window, int index)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return NULL;

    return node->window_count > 1 && in_range_ii(index, 1, node->window_count) ? window_manager_find_window(wm, node->window_list[index-1]) : NULL;
}

struct window *window_manager_find_largest_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    uint32_t best_id   = 0;
    uint32_t best_area = 0;

    for (struct window_node *node = window_node_find_first_leaf(view->root); node != NULL; node = window_node_find_next_leaf(node)) {
        uint32_t area = node->area.w * node->area.h;
        if (area > best_area) {
            best_id   = node->window_order[0];
            best_area = area;
        }
    }

    return best_id ? window_manager_find_window(wm, best_id) : NULL;
}

struct window *window_manager_find_smallest_managed_window(struct space_manager *sm, struct window_manager *wm)
{
    struct view *view = space_manager_find_view(sm, space_manager_active_space());
    if (!view) return NULL;

    uint32_t best_id   = 0;
    uint32_t best_area = UINT32_MAX;

    for (struct window_node *node = window_node_find_first_leaf(view->root); node != NULL; node = window_node_find_next_leaf(node)) {
        uint32_t area = node->area.w * node->area.h;
        if (area <= best_area) {
            best_id   = node->window_order[0];
            best_area = area;
        }
    }

    return best_id ? window_manager_find_window(wm, best_id) : NULL;
}

struct window *window_manager_find_sibling_for_managed_window(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return NULL;

    struct window_node *sibling_node = window_node_is_left_child(node) ? node->parent->right : node->parent->left;
    if (!window_node_is_leaf(sibling_node)) return NULL;

    return window_manager_find_window(wm, sibling_node->window_order[0]);
}

struct window *window_manager_find_first_nephew_for_managed_window(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return NULL;

    struct window_node *sibling_node = window_node_is_left_child(node) ? node->parent->right : node->parent->left;
    if (window_node_is_leaf(sibling_node) || !window_node_is_leaf(sibling_node->left)) return NULL;

    return window_manager_find_window(wm, sibling_node->left->window_order[0]);
}

struct window *window_manager_find_second_nephew_for_managed_window(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return NULL;

    struct window_node *sibling_node = window_node_is_left_child(node) ? node->parent->right : node->parent->left;
    if (window_node_is_leaf(sibling_node) || !window_node_is_leaf(sibling_node->right)) return NULL;

    return window_manager_find_window(wm, sibling_node->right->window_order[0]);
}

struct window *window_manager_find_uncle_for_managed_window(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return NULL;

    struct window_node *grandparent = node->parent->parent;
    if (!grandparent) return NULL;

    struct window_node *uncle_node = window_node_is_left_child(node->parent) ? grandparent->right : grandparent->left;
    if (!window_node_is_leaf(uncle_node)) return NULL;

    return window_manager_find_window(wm, uncle_node->window_order[0]);
}

struct window *window_manager_find_first_cousin_for_managed_window(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return NULL;

    struct window_node *grandparent = node->parent->parent;
    if (!grandparent) return NULL;

    struct window_node *uncle_node = window_node_is_left_child(node->parent) ? grandparent->right : grandparent->left;
    if (window_node_is_leaf(uncle_node) || !window_node_is_leaf(uncle_node->left)) return NULL;

    return window_manager_find_window(wm, uncle_node->left->window_order[0]);
}

struct window *window_manager_find_second_cousin_for_managed_window(struct window_manager *wm, struct window *window)
{
    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view) return NULL;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node || !node->parent) return NULL;

    struct window_node *uncle_node = window_node_is_left_child(node->parent) ? node->parent->parent->right : node->parent->parent->left;
    if (window_node_is_leaf(uncle_node) || !window_node_is_leaf(uncle_node->right)) return NULL;

    return window_manager_find_window(wm, uncle_node->right->window_order[0]);
}

static void window_manager_make_key_window(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    //
    // :SynthesizedEvent
    //
    // NOTE(koekeishiya): These events will be picked up by an event-tap
    // registered at the "Annotated Session" location; specifying that an
    // event-tap is placed at the point where session events have been
    // annotated to flow to an application.
    //

    memset(g_event_bytes, 0, 0xf8);
    g_event_bytes[0x04] = 0xf8;
    g_event_bytes[0x3a] = 0x10;
    memcpy(g_event_bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(g_event_bytes + 0x20, 0xff, 0x10);

    g_event_bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(window_psn, g_event_bytes);

    g_event_bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(window_psn, g_event_bytes);
}

void window_manager_focus_window_without_raise(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    TIME_FUNCTION;
        debug("%s: focused window without raise %d\n", __FUNCTION__, window_id);

    if (psn_equals(window_psn, &g_window_manager.focused_window_psn)) {
        memset(g_event_bytes, 0, 0xf8);
        g_event_bytes[0x04] = 0xf8;
        g_event_bytes[0x08] = 0x0d;

        g_event_bytes[0x8a] = 0x02;
        memcpy(g_event_bytes + 0x3c, &g_window_manager.focused_window_id, sizeof(uint32_t));
        SLPSPostEventRecordTo(&g_window_manager.focused_window_psn, g_event_bytes);

        //
        // @hack
        // Artificially delay the activation by 1ms. This is necessary
        // because some applications appear to be confused if both of
        // the events appear instantaneously.
        //

        usleep(10000);

        g_event_bytes[0x8a] = 0x01;
        memcpy(g_event_bytes + 0x3c, &window_id, sizeof(uint32_t));
        SLPSPostEventRecordTo(window_psn, g_event_bytes);
    }

    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
    ///* step 1: remember the previously-focused managed window */
    //struct window *prev =
    //    window_manager_find_window(&g_window_manager,
    //                            g_window_manager.focused_window_id);

    ///* step 2: raise the one we’re about to focus */
    //struct window *curr =
    //    window_manager_find_window(&g_window_manager, window_id);
    
    //if (prev && window_manager_should_manage_window(prev)) {
    //    /* demote the one that just lost focus */
    //    //window_manager_adjust_layer(prev, LAYER_BELOW);
    //    scripting_addition_set_layer(prev->id, -20);       // optional tidy-up
    //}

    //if (curr && window_manager_should_manage_window(curr)) {
    //    /* raise the newly-focused pane */
    //    //window_manager_adjust_layer(curr, LAYER_NORMAL);
    //    scripting_addition_set_layer(curr->id, 0);       // optional tidy-up
    //}
}

void window_manager_focus_window_with_raise(ProcessSerialNumber *window_psn, uint32_t window_id, AXUIElementRef window_ref)
{
    TIME_FUNCTION;

    #if 1
        _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
        window_manager_make_key_window(window_psn, window_id);
        AXUIElementPerformAction(window_ref, kAXRaiseAction);
    #else
        scripting_addition_focus_window(window_id);
    #endif
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
struct application *window_manager_focused_application(struct window_manager *wm)
{
    TIME_FUNCTION;

    ProcessSerialNumber psn = {0};
    _SLPSGetFrontProcess(&psn);

    pid_t pid;
    GetProcessPID(&psn, &pid);

    return window_manager_find_application(wm, pid);
}

struct window *window_manager_focused_window(struct window_manager *wm)
{
    TIME_FUNCTION;

    struct application *application = window_manager_focused_application(wm);
    if (!application) return NULL;

    uint32_t window_id = application_focused_window(application);
    return window_manager_find_window(wm, window_id);
}
#pragma clang diagnostic pop

bool window_manager_find_lost_front_switched_event(struct window_manager *wm, pid_t pid)
{
    return table_find(&wm->application_lost_front_switched_event, &pid) != NULL;
}

void window_manager_remove_lost_front_switched_event(struct window_manager *wm, pid_t pid)
{
    table_remove(&wm->application_lost_front_switched_event, &pid);
}

void window_manager_add_lost_front_switched_event(struct window_manager *wm, pid_t pid)
{
    table_add(&wm->application_lost_front_switched_event, &pid, (void *)(intptr_t) 1);
}

bool window_manager_find_lost_focused_event(struct window_manager *wm, uint32_t window_id)
{
    return table_find(&wm->window_lost_focused_event, &window_id) != NULL;
}

void window_manager_remove_lost_focused_event(struct window_manager *wm, uint32_t window_id)
{
    table_remove(&wm->window_lost_focused_event, &window_id);
}

void window_manager_add_lost_focused_event(struct window_manager *wm, uint32_t window_id)
{
    table_add(&wm->window_lost_focused_event, &window_id, (void *)(intptr_t) 1);
}

struct window *window_manager_find_window(struct window_manager *wm, uint32_t window_id)
{
    return table_find(&wm->window, &window_id);
}

void window_manager_remove_window(struct window_manager *wm, uint32_t window_id)
{
    table_remove(&wm->window, &window_id);
    table_remove(&g_window_manager.stack_state, &window_id);
}

void window_manager_add_window(struct window_manager *wm, struct window *window)
{
    table_add(&wm->window, &window->id, window);
    
}

struct application *window_manager_find_application(struct window_manager *wm, pid_t pid)
{
    return table_find(&wm->application, &pid);
}

void window_manager_remove_application(struct window_manager *wm, pid_t pid)
{
    table_remove(&wm->application, &pid);
}

void window_manager_add_application(struct window_manager *wm, struct application *application)
{
    table_add(&wm->application, &application->pid, application);
}

struct window **window_manager_find_application_windows(struct window_manager *wm, struct application *application, int *window_count)
{
    *window_count = 0;
    struct window **window_list = ts_alloc_list(struct window *, wm->window.count);

    table_for (struct window *window, wm->window, {
        if (window->application == application) {
            window_list[(*window_count)++] = window;
        }
    })

    return window_list;
}

struct window *window_manager_create_and_add_window(struct space_manager *sm, struct window_manager *wm, struct application *application, AXUIElementRef window_ref, uint32_t window_id, bool one_shot_rules)
{
    struct window *window = window_create(application, window_ref, window_id);

    char *window_title = window_title_ts(window);
    char *window_role = window_role_ts(window);
    char *window_subrole = window_subrole_ts(window);
    debug("%s:%d %s - %s (%s:%s:%d)\n", __FUNCTION__, window->id, window->application->name, window_title, window_role, window_subrole, window->is_root);

    if (window_is_unknown(window)) {
        debug("%s: ignoring AXUnknown window %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_manager_remove_lost_focused_event(wm, window->id);
        window_destroy(window);
        return NULL;
    }

    //
    // NOTE(koekeishiya): Attempt to track **all** windows.
    //

    if (!window_observe(window)) {
        debug("%s: could not observe %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_manager_remove_lost_focused_event(wm, window->id);
        window_unobserve(window);
        window_destroy(window);
        return NULL;
    }

    if (window_manager_find_lost_focused_event(wm, window->id)) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
        window_manager_remove_lost_focused_event(wm, window->id);
    }

    window_manager_add_window(wm, window);

    //
    // NOTE(koekeishiya): However, only **root windows** are eligible for management.
    //

    if (window->is_root) {

        //
        // NOTE(koekeishiya): A lot of windows misreport their accessibility role, so we allow the user
        // to specify rules to make sure that we do in fact manage these windows properly.
        //
        // This part of the rule must be applied at this stage (prior to other rule properties), and if
        // no such rule matches this window, it will be ignored if it does not have a role of kAXWindowRole.
        //

        window_manager_apply_manage_rules_to_window(sm, wm, window, window_title, window_role, window_subrole, one_shot_rules);

        if (window_manager_is_window_eligible(window)) {
            window->is_eligible = true;
            window_manager_apply_rules_to_window(sm, wm, window, window_title, window_role, window_subrole, one_shot_rules);
            window_manager_purify_window(wm, window);
            window_manager_set_window_opacity(wm, window, wm->normal_window_opacity);

            if (application->is_hidden)                              goto out;
            if (window_check_flag(window, WINDOW_MINIMIZE))          goto out;
            if (window_check_flag(window, WINDOW_FULLSCREEN))        goto out;
            if (window_check_rule_flag(window, WINDOW_RULE_MANAGED)) goto out;

            if (window_check_rule_flag(window, WINDOW_RULE_FULLSCREEN)) {
                window_clear_rule_flag(window, WINDOW_RULE_FULLSCREEN);
                goto out;
            }

            if (window_is_sticky(window->id) ||
                !window_can_move(window) ||
                !window_is_standard(window) ||
                !window_level_is_standard(window) ||
                (!window_can_resize(window) && window_is_undersized(window))) {
                window_set_flag(window, WINDOW_FLOAT);
            }
        } else {
            debug("%s ignoring incorrectly marked window %s %d\n", __FUNCTION__, window->application->name, window->id);
            window_set_flag(window, WINDOW_FLOAT);

            //
            // NOTE(koekeishiya): Print window information when debug_output is enabled.
            // Useful for identifying and creating rules if this window should in fact be managed.
            //

            if (g_verbose) {
                fprintf(stdout, "window info: \n");
                window_serialize(stdout, window, 0);
                fprintf(stdout, "\n");
            }
        }
    } else {
        debug("%s ignoring child window %s %d\n", __FUNCTION__, window->application->name, window->id);
        window_set_flag(window, WINDOW_FLOAT);

        //
        // NOTE(koekeishiya): Print window information when debug_output is enabled.
        //

        if (g_verbose) {
            fprintf(stdout, "window info: \n");
            window_serialize(stdout, window, 0);
            fprintf(stdout, "\n");
        }
    }

out:
    return window;
}

struct window **window_manager_add_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int *count)
{
    *count = 0;
    CFArrayRef window_list = application_window_list(application);
    if (!window_list) return NULL;

    int window_count = CFArrayGetCount(window_list);
    struct window **list = ts_alloc_list(struct window *, window_count);

    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list, i);

        uint32_t window_id = ax_window_id(window_ref);
        if (!window_id || window_manager_find_window(wm, window_id)) continue;

        struct window *window = window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), window_id, true);
        if (window) list[(*count)++] = window;
    }

    int rule_len = buf_len(wm->rules);
    for (int i = 0; i < rule_len; ++i) {
        if (rule_check_flag(&wm->rules[i], RULE_ONE_SHOT_REMOVE)) {
            rule_destroy(&wm->rules[i]);
            if (buf_del(wm->rules, i)) {
                --i;
                --rule_len;
            }
        }
    }

    CFRelease(window_list);
    return list;
}
static void dc(void)
{
    int window_count = 0;
    uint32_t window_list[1024] = {0};

    if (workspace_is_macos_sequoia()) {
        // NOTE(koekeishiya): Subscribe to all windows because of window_destroyed (and ordered) notifications
        table_for (struct window *window, g_window_manager.window, {
            window_list[window_count++] = window->id;
        })
    } else {
        // NOTE(koekeishiya): Subscribe to windows that have a feedback_border because of window_ordered notifications
        table_for (struct window_node *node, g_window_manager.insert_feedback, {
            window_list[window_count++] = node->window_order[0];
        })
    }

    SLSRequestNotificationsForWindows(g_connection, window_list, window_count);
}
static uint32_t *window_manager_existing_application_window_list(struct application *application, int *window_count)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return NULL;

    int space_count = 0;
    uint64_t *space_list = NULL;

    for (int i = 0; i < display_count; ++i) {
        int count;
        uint64_t *list = display_space_list(display_list[i], &count);
        if (!list) continue;

        //
        // NOTE(koekeishiya): display_space_list(..) uses a linear allocator,
        // and so we only need to track the beginning of the first list along
        // with the total number of windows that have been allocated.
        //

        if (!space_list) space_list = list;
        space_count += count;
    }

    return space_list ? space_window_list_for_connection(space_list, space_count, application ? application->connection : 0, window_count, true) : NULL;
}

bool window_manager_add_existing_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int refresh_index)
{
    bool result = false;

    int global_window_count;
    uint32_t *global_window_list = window_manager_existing_application_window_list(application, &global_window_count);
    if (!global_window_list) return result;

    CFArrayRef window_list_ref = application_window_list(application);
    int window_count = window_list_ref ? CFArrayGetCount(window_list_ref) : 0;

    int empty_count = 0;
    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list_ref, i);
        uint32_t window_id = ax_window_id(window_ref);

        //
        // @cleanup
        //
        // :Workaround
        //
        // NOTE(koekeishiya): The AX API appears to always include a single element for Finder that returns an empty window id.
        // This is likely the desktop window. Other similar cases should be handled the same way; simply ignore the window when
        // we attempt to do an equality check to see if we have correctly discovered the number of windows to track.
        //

        if (!window_id) {
            ++empty_count;
            continue;
        }

        if (!window_manager_find_window(wm, window_id)) {
            window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), window_id, false);
        }
    }

    if (global_window_count != window_count-empty_count) {
        if (refresh_index == -1) {
            bool missing_window = false;
            uint32_t *app_window_list = NULL;

            for (int i = 0; i < global_window_count; ++i) {
                struct window *window = window_manager_find_window(wm, global_window_list[i]);
                if (!window) {
                    missing_window = true;
                    ts_buf_push(app_window_list, global_window_list[i]);
                }
            }

            if (missing_window) {
                debug("%s: %s has %d windows that are not yet resolved, attempting workaround\n", __FUNCTION__, application->name, ts_buf_len(app_window_list));

                //
                // NOTE(koekeishiya): MacOS API does not return AXUIElementRef of windows on inactive spaces.
                // However, we can just brute-force the element_id and create the AXUIElementRef ourselves.
                //
                // :Attribution
                // https://github.com/decodism
                // https://github.com/lwouis/alt-tab-macos/issues/1324#issuecomment-2631035482
                //

                CFMutableDataRef data_ref = CFDataCreateMutable(NULL, 0x14);
                CFDataIncreaseLength(data_ref, 0x14);

                uint8_t *data = CFDataGetMutableBytePtr(data_ref);
                *(uint32_t *) (data + 0x0) = application->pid;
                *(uint32_t *) (data + 0x8) = 0x636f636f;

                for (uint64_t element_id = 0; element_id < 0x7fff; ++element_id) {
                    int app_window_list_len = ts_buf_len(app_window_list);
                    if (app_window_list_len == 0) break;

                    memcpy(data+0xc, &element_id, sizeof(uint64_t));
                    AXUIElementRef element_ref = _AXUIElementCreateWithRemoteToken(data_ref);

                    const void *role = NULL;
                    AXUIElementCopyAttributeValue(element_ref, kAXRoleAttribute, &role);

                    if (role) {
                        if (CFEqual(role, kAXWindowRole)) {
                            uint32_t element_wid = ax_window_id(element_ref);
                            bool matched = false;

                            if (element_wid != 0) {
                                for (int i = 0; i < app_window_list_len; ++i) {
                                    if (app_window_list[i] == element_wid) {
                                        matched = true;
                                        ts_buf_del(app_window_list, i);
                                        break;
                                    }
                                }
                            }

                            if (matched) {
                                window_manager_create_and_add_window(sm, wm, application, element_ref, element_wid, false);
                            } else {
                                CFRelease(element_ref);
                            }
                        }

                        CFRelease(role);
                    }
                }

                CFRelease(data_ref);
            }

            if (ts_buf_len(app_window_list) > 0) {
                debug("%s: workaround failed to resolve all windows for %s\n", __FUNCTION__, application->name);
                buf_push(wm->applications_to_refresh, application);
            } else {
                debug("%s: workaround resolved all windows for %s\n", __FUNCTION__, application->name);
            }
        } else {
            bool missing_window = false;

            for (int i = 0; i < global_window_count; ++i) {
                struct window *window = window_manager_find_window(wm, global_window_list[i]);
                if (!window) {
                    missing_window = true;
                    break;
                }
            }

            if (!missing_window) {
                debug("%s: all windows for %s are now resolved\n", __FUNCTION__, application->name);
                buf_del(wm->applications_to_refresh, refresh_index);
                result = true;
            }
        }
    } else if (refresh_index != -1) {
        debug("%s: all windows for %s are now resolved\n", __FUNCTION__, application->name);
        buf_del(wm->applications_to_refresh, refresh_index);
        result = true;
    }

    if (window_list_ref) CFRelease(window_list_ref);

    return result;
}

enum window_op_error window_manager_set_window_insertion(struct space_manager *sm, struct window *window, int direction)
{
    TIME_FUNCTION;

    uint64_t sid = window_space(window->id);
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout != VIEW_BSP) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    struct window_node *node = view_find_window_node(view, window->id);
    if (!node) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    if (view->insertion_point && view->insertion_point != window->id) {
        struct window_node *insert_node = view_find_window_node(view, view->insertion_point);
        if (insert_node) {
            insert_feedback_destroy(insert_node);
            insert_node->split = SPLIT_NONE;
            insert_node->child = CHILD_NONE;
            insert_node->insert_dir = 0;
        }
    }

    if (direction == node->insert_dir) {
        insert_feedback_destroy(node);
        node->split = SPLIT_NONE;
        node->child = CHILD_NONE;
        node->insert_dir = 0;
        view->insertion_point = 0;
        return WINDOW_OP_ERROR_SUCCESS;
    }

    if (direction == DIR_NORTH) {
        node->split = SPLIT_X;
        node->child = CHILD_FIRST;
    } else if (direction == DIR_EAST) {
        node->split = SPLIT_Y;
        node->child = CHILD_SECOND;
    } else if (direction == DIR_SOUTH) {
        node->split = SPLIT_X;
        node->child = CHILD_SECOND;
    } else if (direction == DIR_WEST) {
        node->split = SPLIT_Y;
        node->child = CHILD_FIRST;
    }

    node->insert_dir = direction;
    view->insertion_point = node->window_order[0];
    insert_feedback_show(node);

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_stack_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    struct view *a_view = window_manager_find_managed_window(wm, a);
    if (!a_view) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct view *b_view = window_manager_find_managed_window(wm, b);
    if (b_view) {
        space_manager_untile_window(b_view, b);
        window_manager_remove_managed_window(wm, b->id);
        window_manager_purify_window(wm, b);
    } else if (window_check_flag(b, WINDOW_FLOAT)) {
        if (!window_manager_is_window_eligible(b)) return WINDOW_OP_ERROR_INVALID_SRC_NODE;
        window_clear_flag(b, WINDOW_FLOAT);
        if (window_check_flag(b, WINDOW_STICKY)) window_manager_make_window_sticky(sm, wm, b, false);
    }

    struct window_node *a_node = view_find_window_node(a_view, a->id);
    if (a_node->window_count+1 >= NODE_MAX_WINDOW_COUNT) return WINDOW_OP_ERROR_MAX_STACK;

    view_stack_window_node(a_node, b);
    window_manager_add_managed_window(wm, b, a_view);
    window_manager_adjust_layer(b, LAYER_BELOW);
    scripting_addition_order_window(b->id, 1, a_node->window_order[1]);
    if(a_node-> window_count > 0){

    }
    struct area area = a_node->zoom ? a_node->zoom->area : a_node->area;
    window_manager_animate_window((struct window_capture) { b, area.x, area.y, area.w, area.h });
    debug("📚📚📚📚 window %d stacked above %d\n", b->id, a->id);
    debug("sweeping at window_manager_stack_window %d\n", a_view->sid);
    window_manager_sweep_stacks(a_view,  wm);
    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_warp_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    uint32_t a_sid = window_space(a->id);
    struct view *a_view = space_manager_find_view(sm, a_sid);
    if (a_view->layout != VIEW_BSP) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    uint32_t b_sid = window_space(b->id);
    struct view *b_view = space_manager_find_view(sm, b_sid);
    if (b_view->layout != VIEW_BSP) return WINDOW_OP_ERROR_INVALID_DST_VIEW;

    struct window_node *a_node = view_find_window_node(a_view, a->id);
    if (!a_node) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct window_node *b_node = view_find_window_node(b_view, b->id);
    if (!b_node) return WINDOW_OP_ERROR_INVALID_DST_NODE;

    if (a_node == b_node) return WINDOW_OP_ERROR_SAME_STACK;

    if (a_node->parent && b_node->parent &&
    a_node->parent == b_node->parent &&
        a_node->window_count == 1) {
        if (window_node_contains_window(b_node, b_view->insertion_point)) {
            b_node->parent->split = b_node->split;
            b_node->parent->child = b_node->child;

            view_remove_window_node(a_view, a);
            window_manager_remove_managed_window(wm, a_node->window_list[0]);
            window_manager_add_managed_window(wm, a, b_view);
            struct window_node *a_node_add = view_add_window_node_with_insertion_point(b_view, a, b->id);

            struct window_capture *window_list = NULL;
            window_node_capture_windows(a_node_add, &window_list);
            window_manager_animate_window_list(window_list, ts_buf_len(window_list));
        } else {
            if (window_node_contains_window(a_node, a_view->insertion_point)) {
                a_view->insertion_point = b->id;
            }

            window_node_swap_window_list(a_node, b_node);

            struct window_capture *window_list = NULL;
            window_node_capture_windows(a_node, &window_list);
            window_node_capture_windows(b_node, &window_list);
            window_manager_animate_window_list(window_list, ts_buf_len(window_list));
        }
    } else {
        if (a_view->sid == b_view->sid) {

            //
            // :NaturalWarp
            //
            // NOTE(koekeishiya): Precalculate both target areas and select the one that has the closest distance to the source area.
            // This allows the warp to feel more natural in terms of where the window is placed on screen, however, this is only utilized
            // for warp operations where both operands belong to the same space. There may be a better system to handle this if/when multiple
            // monitors should be supported.
            //

            struct area cf, cs;
            area_make_pair(window_node_get_split(b_view, b_node), window_node_get_gap(b_view), window_node_get_ratio(b_node), &b_node->area, &cf, &cs);

            CGPoint ca = { (int)(0.5f + a_node->area.x + a_node->area.w / 2.0f), (int)(0.5f + a_node->area.y + a_node->area.h / 2.0f) };
            float dcf = powf((ca.x - (int)(0.5f + cf.x + cf.w / 2.0f)), 2.0f) + powf((ca.y - (int)(0.5f + cf.y + cf.h / 2.0f)), 2.0f);
            float dcs = powf((ca.x - (int)(0.5f + cs.x + cs.w / 2.0f)), 2.0f) + powf((ca.y - (int)(0.5f + cs.y + cs.h / 2.0f)), 2.0f);

            if (dcf < dcs) {
                b_node->child = CHILD_FIRST;
            } else if (dcf > dcs) {
                b_node->child = CHILD_SECOND;
            } else {
                b_node->child = window_node_is_left_child(a_node) ? CHILD_FIRST : CHILD_SECOND;
            }

            struct window_node *a_node_rm = view_remove_window_node(a_view, a);
            struct window_node *a_node_add = view_add_window_node_with_insertion_point(b_view, a, b->id);

            struct window_capture *window_list = NULL;
            if (a_node_rm) {
                window_node_capture_windows(a_node_rm, &window_list);
            }

            if (a_node_rm != a_node_add && a_node_rm != a_node_add->parent) {
                window_node_capture_windows(a_node_add, &window_list);
            }

            window_manager_animate_window_list(window_list, ts_buf_len(window_list));
        } else {
            if (wm->focused_window_id == a->id) {
                struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(wm, a_view->sid, 1, a->id);
                if (next) {
                    window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
                } else {
                    _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
                }
            }

            //
            // :NaturalWarp
            //
            // TODO(koekeishiya): Warp operations with operands that belong to different monitors does not yet implement a heuristic to select
            // the target area that feels the most natural in terms of where the window is placed on screen. Is it possible to do better when
            // warping between spaces that belong to the same monitor as well??
            //

            space_manager_untile_window(a_view, a);
            window_manager_remove_managed_window(wm, a->id);
            window_manager_add_managed_window(wm, a, b_view);
            space_manager_move_window_to_space(b_view->sid, a);
            space_manager_tile_window_on_space_with_insertion_point(sm, a, b_view->sid, b->id);
        }
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_swap_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    uint64_t a_sid = window_space(a->id);
    struct view *a_view = space_manager_find_view(sm, a_sid);

    uint64_t b_sid = window_space(b->id);
    struct view *b_view = space_manager_find_view(sm, b_sid);

    struct window_node *a_node = view_find_window_node(a_view, a->id);
    if (!a_node) return WINDOW_OP_ERROR_INVALID_SRC_NODE;

    struct window_node *b_node = view_find_window_node(b_view, b->id);
    if (!b_node) return WINDOW_OP_ERROR_INVALID_DST_NODE;

    if (a_node == b_node) {
        int a_list_index = 0;
        int a_order_index = 0;

        int b_list_index = 0;
        int b_order_index = 0;

        for (int i = 0; i < a_node->window_count; ++i) {
            if (a_node->window_list[i] == a->id) {
                a_list_index = i;
            } else if (a_node->window_list[i] == b->id) {
                b_list_index = i;
            }

            if (a_node->window_order[i] == a->id) {
                a_order_index = i;
            } else if (a_node->window_order[i] == b->id) {
                b_order_index = i;
            }
        }

        a_node->window_list[a_list_index] = b->id;
        a_node->window_order[a_order_index] = b->id;

        a_node->window_list[b_list_index] = a->id;
        a_node->window_order[b_order_index] = a->id;

        if (a->id == wm->focused_window_id) {
            window_manager_focus_window_with_raise(&b->application->psn, b->id, b->ref);
        } else if (b->id == wm->focused_window_id) {
            window_manager_focus_window_with_raise(&a->application->psn, a->id, a->ref);
        }

        return WINDOW_OP_ERROR_SUCCESS;
    }

    if (a_view->layout != VIEW_BSP) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;
    if (b_view->layout != VIEW_BSP) return WINDOW_OP_ERROR_INVALID_DST_VIEW;

    if (window_node_contains_window(a_node, a_view->insertion_point)) {
        a_view->insertion_point = b->id;
    } else if (window_node_contains_window(b_node, b_view->insertion_point)) {
        b_view->insertion_point = a->id;
    }

    bool a_visible = space_is_visible(a_view->sid);
    bool b_visible = space_is_visible(b_view->sid);

    if (a_view->sid != b_view->sid) {
        for (int i = 0; i < a_node->window_count; ++i) {
            struct window *window = window_manager_find_window(wm, a_node->window_list[i]);
            window_manager_remove_managed_window(wm, a_node->window_list[i]);
            space_manager_move_window_to_space(b_view->sid, window);
            window_manager_add_managed_window(wm, window, b_view);
        }

        for (int i = 0; i < b_node->window_count; ++i) {
            struct window *window = window_manager_find_window(wm, b_node->window_list[i]);
            window_manager_remove_managed_window(wm, b_node->window_list[i]);
            space_manager_move_window_to_space(a_view->sid, window);
            window_manager_add_managed_window(wm, window, a_view);
        }

        if (a_visible && !b_visible && a->id == wm->focused_window_id) {
            window_manager_focus_window_with_raise(&b->application->psn, b->id, b->ref);
        } else if (b_visible && !a_visible && b->id == wm->focused_window_id) {
            window_manager_focus_window_with_raise(&a->application->psn, a->id, a->ref);
        }
    }

    window_node_swap_window_list(a_node, b_node);
    struct window_capture *window_list = NULL;

    if (a_visible) {
        window_node_capture_windows(a_node, &window_list);
    } else {
        view_set_flag(a_view, VIEW_IS_DIRTY);
    }

    if (b_visible) {
        window_node_capture_windows(b_node, &window_list);
    } else {
        view_set_flag(b_view, VIEW_IS_DIRTY);
    }

    window_manager_animate_window_list(window_list, ts_buf_len(window_list));
    
    // Get the main display bounds to calculate screen center
    CGRect screen_bounds = CGDisplayBounds(CGMainDisplayID());
    float center_x = screen_bounds.origin.x + (screen_bounds.size.width / 2.0f);
    float center_y = screen_bounds.origin.y + (screen_bounds.size.height / 2.0f);
    
    // Apply wobble effect to both windows with screen center as ripple point
    scripting_addition_warp_window(a->id, 1, 1.0, 1.0, center_x, center_y);
    scripting_addition_warp_window(b->id, 1, 1.0, 1.0, center_x, center_y);

    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_minimize_window(struct window *window)
{
    TIME_FUNCTION;

    if (!window_can_minimize(window)) return WINDOW_OP_ERROR_CANT_MINIMIZE;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return WINDOW_OP_ERROR_ALREADY_MINIMIZED;

    AXError result = AXUIElementSetAttributeValue(window->ref, kAXMinimizedAttribute, kCFBooleanTrue);
    return result == kAXErrorSuccess ? WINDOW_OP_ERROR_SUCCESS : WINDOW_OP_ERROR_MINIMIZE_FAILED;
}

enum window_op_error window_manager_deminimize_window(struct window *window)
{
    TIME_FUNCTION;

    if (!window_check_flag(window, WINDOW_MINIMIZE)) return WINDOW_OP_ERROR_NOT_MINIMIZED;

    AXError result = AXUIElementSetAttributeValue(window->ref, kAXMinimizedAttribute, kCFBooleanFalse);
    return result == kAXErrorSuccess ? WINDOW_OP_ERROR_SUCCESS : WINDOW_OP_ERROR_DEMINIMIZE_FAILED;
}

bool window_manager_close_window(struct window *window)
{
    TIME_FUNCTION;

    CFTypeRef button = NULL;
    AXUIElementCopyAttributeValue(window->ref, kAXCloseButtonAttribute, &button);
    if (!button) return false;

    AXUIElementPerformAction(button, kAXPressAction);
    CFRelease(button);

    return true;
}

void window_manager_send_window_to_space(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t dst_sid, bool moved_by_rule)
{
    TIME_FUNCTION;

    uint64_t src_sid = window_space(window->id);
    if (src_sid == dst_sid) return;

    if ((space_is_visible(src_sid) && (moved_by_rule || wm->focused_window_id == window->id))) {
        struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(wm, src_sid, 1, window->id);
        if (next) {
            window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
        } else {
            _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
        }
    }

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) {
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_purify_window(wm, window);
    }

    space_manager_move_window_to_space(dst_sid, window);

    if (window_manager_should_manage_window(window)) {
        struct view *view = space_manager_tile_window_on_space(sm, window, dst_sid);
        window_manager_add_managed_window(wm, window, view);
    }
}

enum window_op_error window_manager_apply_grid(struct space_manager *sm, struct window_manager *wm, struct window *window, unsigned r, unsigned c, unsigned x, unsigned y, unsigned w, unsigned h)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (view) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    uint32_t did = window_display_id(window->id);
    if (!did) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    if (x >=   c) x = c - 1;
    if (y >=   r) y = r - 1;
    if (w <=   0) w = 1;
    if (h <=   0) h = 1;
    if (w >  c-x) w = c - x;
    if (h >  r-y) h = r - y;

    CGRect bounds = display_bounds_constrained(did, false);
    struct view *dview = space_manager_find_view(sm, display_space_id(did));

    if (dview) {
        if (view_check_flag(dview, VIEW_ENABLE_PADDING)) {
            bounds.origin.x    += dview->left_padding;
            bounds.size.width  -= (dview->left_padding + dview->right_padding);
            bounds.origin.y    += dview->top_padding;
            bounds.size.height -= (dview->top_padding + dview->bottom_padding);
        }

        if (view_check_flag(dview, VIEW_ENABLE_GAP)) {
            int gap = window_node_get_gap(dview);

            if (x > 0) {
                bounds.origin.x   += gap;
                bounds.size.width -= gap;
            }

            if (y > 0) {
                bounds.origin.y    += gap;
                bounds.size.height -= gap;
            }

            if (c > x+w) bounds.size.width  -= gap;
            if (r > y+h) bounds.size.height -= gap;
        }
    }

    float cw = bounds.size.width / c;
    float ch = bounds.size.height / r;
    float fx = bounds.origin.x + bounds.size.width  - cw * (c - x);
    float fy = bounds.origin.y + bounds.size.height - ch * (r - y);
    float fw = cw * w;
    float fh = ch * h;

    window_manager_animate_window((struct window_capture) { .window = window, .x = fx, .y = fy, .w = fw, .h = fh });
    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_make_window_floating(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_float, bool force)
{
    TIME_FUNCTION;

    if (!window_manager_is_window_eligible(window)) return;

    if (!force) {
        if (!window_is_standard(window) || !window_level_is_standard(window) || !window_can_move(window)) {
            if (!window_check_rule_flag(window, WINDOW_RULE_MANAGED)) {
                return;
            }
        }
    }
    bool did_float;
    if (should_float) {
        struct view *view = window_manager_find_managed_window(wm, window);
        if (view) {
            space_manager_untile_window(view, window);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);
        }
        window_set_flag(window, WINDOW_FLOAT);
        did_float = true;
    } else {
        window_clear_flag(window, WINDOW_FLOAT);
        did_float = false;
        if (!window_check_flag(window, WINDOW_STICKY)) {
            if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                struct view *view = space_manager_tile_window_on_space(sm, window, space_manager_active_space());
                window_manager_add_managed_window(wm, window, view);
            }
        }
    }
    struct yb_prop_update msg = {
        .count = 1,
        .wid   = window->id,
        .value = did_float
    };

    push_janky_update(1227, &msg, sizeof(msg));

}

bool window_manager_hide_window(struct window *window)
{
    debug("Hiding window wm\n");
    if (!window){ debug("Invalid window, returning false\n"); return false;}
    if (window_check_flag(window, WINDOW_SCRATCHED) || window_check_flag(window, WINDOW_MINIMIZE) || window_check_flag(window, WINDOW_HIDDEN)) {debug("Window is already hidden, returning false\n"); return false;}
    
    // Check if window is currently managed (in BSP layout)
    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (view) {
        // Window is managed (tiled), remember this and remove from layout
        debug("Window %d was tiled, removing from layout\n", window->id);
        window->was_floating = false;
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(&g_window_manager, window->id);
    } else {
        // Window is floating, remember this
        debug("Window %d was floating\n", window->id);
        window->was_floating = true;
    }
    
    // Hide the window and mark as scratched and hidden
    //if (scripting_addition_order_window(window->id, 0, 0)) { // hide
        window_set_flag(window, WINDOW_SCRATCHED);           // mark as scratched
        window_set_flag(window, WINDOW_HIDDEN);             // mark as hidden
       
        extern struct space_widget g_space_widget;
        space_widget_refresh(&g_space_widget);
        
        // Update window notifications for Sequoia compatibility
        if (workspace_is_macos_sequoia()) {
            dc();
        }
        
        return true;
    //}
    
    //return false;
}

bool window_manager_unhide_window(struct window *window)
{
    if (!window) return false;
    
    // Show the window and clear scratched and hidden flags
    if (scripting_addition_order_window(window->id, 1, 0)) { // show
        window_clear_flag(window, WINDOW_SCRATCHED);         // clear scratched flag
        window_clear_flag(window, WINDOW_HIDDEN);           // clear hidden flag
        
        // Update window notifications for Sequoia compatibility
        if (workspace_is_macos_sequoia()) {
            dc();
        }
        
        // If window was previously tiled (not floating), add it back to the layout
        if (!window->was_floating && window_manager_is_window_eligible(window)) {
            debug("Restoring window %d to tiled layout\n", window->id);
            uint64_t sid = window_space(window->id);
            struct view *view = space_manager_find_view(&g_space_manager, sid);
            if (view && view->layout != VIEW_FLOAT) {
                if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(&g_window_manager, window))) {
                    struct view *view = space_manager_tile_window_on_space(&g_space_manager, window, space_manager_active_space());
                    window_manager_add_managed_window(&g_window_manager, window, view);
                }
            } else {
                debug("Cannot restore window %d to tiled layout - view is floating or not found\n", window->id);
            }
        } else {
            debug("Window %d remains floating (was_floating=%s)\n", window->id, window->was_floating ? "true" : "false");
        }
        
        // Update widget when floating window is shown (unscratched)
        extern struct space_widget g_space_widget;
        space_widget_refresh(&g_space_widget);
        
        return true;
    }
    
    return false;
}

bool window_manager_toggle_hidden(struct window *window)
{
    debug("Toggling visibility for window %d\n", window ? window->id : 0);
    if (!window) return false;
    

debug("Toggling visibility for window %d\n", window->id);
    if (window_check_flag(window, WINDOW_SCRATCHED)) {
        debug("-> Showing window %d\n", window->id);
        return window_manager_unhide_window(window);
    } else {
        debug("-> Hiding window %d\n", window->id);
        return window_manager_hide_window(window);
    }
}

bool window_manager_is_floating_window_hidden(struct window *window)
{
    if (!window) return false;
    if (!window_check_flag(window, WINDOW_FLOAT)) return false;
    
    return window_check_flag(window, WINDOW_SCRATCHED) || window_check_flag(window, WINDOW_HIDDEN);
}

bool window_manager_recover_floating_window(struct window *window)
{
    if (!window) return false;
    if (!window_check_flag(window, WINDOW_FLOAT)) return false;
    
    // Force show the window regardless of current state
    bool success = true;
    if (window_check_flag(window, WINDOW_SCRATCHED)) {
        success = scripting_addition_order_window(window->id, 1, 0); // show
        if (success) {
            window_clear_flag(window, WINDOW_SCRATCHED); // clear scratched flag
            window_clear_flag(window, WINDOW_HIDDEN);   // clear hidden flag
            
            // Update widget when floating window is recovered (unscratched)
            extern struct space_widget g_space_widget;
            space_widget_refresh(&g_space_widget);
        }
    }
    
    return success;
}

void window_manager_make_window_sticky(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_sticky)
{
    TIME_FUNCTION;

    if (!window_manager_is_window_eligible(window)) return;
    bool made_sticky;

    if (should_sticky) {
        if (scripting_addition_set_sticky(window->id, true)) {
            struct view *view = window_manager_find_managed_window(wm, window);
            if (view) {
                space_manager_untile_window(view, window);
                window_manager_remove_managed_window(wm, window->id);
                window_manager_purify_window(wm, window);
            }
            window_set_flag(window, WINDOW_STICKY);
        }
        made_sticky = true;
    } else {
        if (scripting_addition_set_sticky(window->id, false)) {
            window_clear_flag(window, WINDOW_STICKY);
            if (!window_check_flag(window, WINDOW_FLOAT)) {
                if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                    struct view *view = space_manager_tile_window_on_space(sm, window, space_manager_active_space());
                    window_manager_add_managed_window(wm, window, view);
                }
            }
        }
        made_sticky = false;
    }

    struct yb_prop_update msg = {
        .count = 1,
        .wid   = window->id,
        .value = made_sticky ? 1 : 0
    };
    push_janky_update(1008, &msg, sizeof(msg));
}

void window_manager_toggle_window_shadow(struct window *window)
{
    TIME_FUNCTION;

    bool shadow = !window_check_flag(window, WINDOW_SHADOW);
    if (scripting_addition_set_shadow(window->id, shadow)) {
        if (shadow) {
            window_set_flag(window, WINDOW_SHADOW);
        } else {
            window_clear_flag(window, WINDOW_SHADOW);
        }
    }
}

void window_manager_wait_for_native_fullscreen_transition(struct window *window)
{
    TIME_FUNCTION;

    if (workspace_is_macos_monterey() ||
        workspace_is_macos_ventura() ||
        workspace_is_macos_sonoma() ||
        workspace_is_macos_sequoia()) {
        while (!space_is_user(space_manager_active_space())) {

            //
            // NOTE(koekeishiya): Window has exited native-fullscreen mode.
            // We need to spin lock until the display is finished animating
            // because we are not actually able to interact with the window.
            //
            // The display_manager API does not work on macOS Monterey.
            //

            usleep(100000);
        }
    } else {
        uint32_t did = window_display_id(window->id);

        do {

            //
            // NOTE(koekeishiya): Window has exited native-fullscreen mode.
            // We need to spin lock until the display is finished animating
            // because we are not actually able to interact with the window.
            //

            usleep(100000);
        } while (display_manager_display_is_animating(did));
    }
}

void window_manager_toggle_window_native_fullscreen(struct window *window)
{
    TIME_FUNCTION;

    uint32_t sid = window_space(window->id);

    //
    // NOTE(koekeishiya): The window must become the focused window
    // before we can change its fullscreen attribute. We focus the
    // window and spin lock until a potential space animation has finished.
    //

    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    while (sid != space_manager_active_space()) { usleep(100000); }


    if (!window_is_fullscreen(window)) {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanTrue);
    } else {
        AXUIElementSetAttributeValue(window->ref, kAXFullscreenAttribute, kCFBooleanFalse);
    }

    //
    // NOTE(koekeishiya): We toggled the fullscreen attribute and must
    // now spin lock until the post-exit space animation has finished.
    //

    window_manager_wait_for_native_fullscreen_transition(window);
}

void window_manager_toggle_window_zoom_parent(struct window_manager *wm, struct window *window)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view || view->layout != VIEW_BSP) return;

    struct window_node *node = view_find_window_node(view, window->id);
    assert(node);

    if (!node->parent) return;

    if (node->zoom == node->parent) {
        node->zoom = NULL;
        if (space_is_visible(view->sid)) {
            window_node_flush(node);
        } else {
            view_set_flag(view, VIEW_IS_DIRTY);
        }
    } else {
        node->zoom = node->parent;
        if (space_is_visible(view->sid)) {
            window_node_flush(node);
        } else {
            view_set_flag(view, VIEW_IS_DIRTY);
        }
    }
}

void window_manager_toggle_window_zoom_fullscreen(struct window_manager *wm, struct window *window)
{
    TIME_FUNCTION;

    struct view *view = window_manager_find_managed_window(wm, window);
    if (!view || view->layout != VIEW_BSP) return;

    struct window_node *node = view_find_window_node(view, window->id);
    assert(node);

    if (node == view->root) return;

    if (node->zoom == view->root) {
        node->zoom = NULL;
        if (space_is_visible(view->sid)) {
            window_node_flush(node);
        } else {
            view_set_flag(view, VIEW_IS_DIRTY);
        }
    } else {
        node->zoom = view->root;
        if (space_is_visible(view->sid)) {
            window_node_flush(node);
        } else {
            view_set_flag(view, VIEW_IS_DIRTY);
        }
    }
}

void window_manager_toggle_window_windowed_fullscreen(struct window *window)
{
    TIME_FUNCTION;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    if (window_check_flag(window, WINDOW_WINDOWED)) {
        window_clear_flag(window, WINDOW_WINDOWED);
        window_manager_animate_window((struct window_capture) { .window = window, .x = window->windowed_frame.origin.x , .y = window->windowed_frame.origin.y, .w = window->windowed_frame.size.width, .h = window->windowed_frame.size.height });
    } else {
        window_set_flag(window, WINDOW_WINDOWED);
        window->windowed_frame = window->frame;
        CGRect bounds = display_bounds_constrained(did, true);
        window_manager_animate_window((struct window_capture) { .window = window, .x = bounds.origin.x, .y = bounds.origin.y, .w = bounds.size.width, .h = bounds.size.height });
    }
}

void window_manager_toggle_window_expose(struct window *window)
{
    TIME_FUNCTION;

    window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    CoreDockSendNotification(CFSTR("com.apple.expose.front.awake"), 0);
}

CGPoint window_manager_calculate_scaled_points(struct space_manager *sm, struct window *window)
{
    uint32_t did = window_display_id(window->id);
    if (!did) return CGPointZero;

    uint64_t sid = display_space_id(did);
    struct view *dview = space_manager_find_view(sm, sid);

    CGRect bounds = display_bounds_constrained(did, false);
    if (dview && view_check_flag(dview, VIEW_ENABLE_PADDING)) {
        bounds.origin.x    += dview->left_padding;
        bounds.size.width  -= (dview->left_padding + dview->right_padding);
        bounds.origin.y    += dview->top_padding;
        bounds.size.height -= (dview->top_padding + dview->bottom_padding);
    }

    // Store original frame
    window->pip_frame.origin = window->frame.origin;
    window->pip_frame.size = window->frame.size;
    
    // Calculate target dimensions (1/4 scale)
    float dw = bounds.size.width;
    int target_width = dw / 4;
    int target_height = target_width / (window->frame.size.width / window->frame.size.height);
    
    // Calculate scale factors
    window->pip_frame.scale_x = window->frame.size.width / target_width;
    window->pip_frame.scale_y = window->frame.size.height / target_height;
    
    // Store current dimensions for tracking
    window->pip_frame.current_size.width = target_width;
    window->pip_frame.current_size.height = target_height;
    
    // Calculate position (top-right corner)
    CGFloat transformed_x = (bounds.origin.x + dw) - target_width;
    CGFloat transformed_y = bounds.origin.y;
    window->pip_frame.origin.x = transformed_x;
    window->pip_frame.origin.y = transformed_y;
    // Store current position for tracking
    window->pip_frame.current.x = transformed_x;
    window->pip_frame.current.y = transformed_y;
    
    return CGPointMake(transformed_x, transformed_y);
}
void window_manager_toggle_window_pip(struct space_manager *sm, struct window *window)
{
    TIME_FUNCTION;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    uint64_t sid = display_space_id(did);
    struct view *dview = space_manager_find_view(sm, sid);

    CGRect bounds = display_bounds_constrained(did, false);
    if (dview && view_check_flag(dview, VIEW_ENABLE_PADDING)) {
        bounds.origin.x    += dview->left_padding;
        bounds.size.width  -= (dview->left_padding + dview->right_padding);
        bounds.origin.y    += dview->top_padding;
        bounds.size.height -= (dview->top_padding + dview->bottom_padding);
    }
    
    bool was_pip = window_check_flag(window, WINDOW_PIP);
    
    // Try to apply the scaling first
    bool scale_success = scripting_addition_scale_window(window->id, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
    //bool scale_success = scripting_addition_scale_window_custom(window->id, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);
    //bool scale_success = scripting_addition_scale_window_custom(window->id, 50, 50, 200, 200);

    if (scale_success) {
        // Only update the flag if scaling succeeded
        if (!was_pip) {
            // Entering PIP mode - use the calculate function to set everything up
            //CGPoint scaled_position = window_manager_calculate_scaled_points(sm, window);            
            window_set_flag(window, WINDOW_PIP);
        } else {
            // Exiting PIP mode - restore original coordinates

            window_clear_flag(window, WINDOW_PIP);
        }
        
        struct yb_prop_update msg = {
            .count = 1,
            .wid   = window->id,
            .value = !was_pip ? 1 : 0
        };
        push_janky_update(1117, &msg, sizeof(msg));
    }
}

void window_manager_set_window_pip_frame(struct space_manager *sm, struct window *window, float x, float y, float w, float h)
{
    TIME_FUNCTION;

    uint32_t did = window_display_id(window->id);
    if (!did) return;

    bool was_pip = window_check_flag(window, WINDOW_PIP);
    
    // Try to apply the scaling with custom coordinates using the new custom function
    bool scale_success = scripting_addition_scale_window_custom(window->id, x, y, w, h);


    if (scale_success) {
        // Only update the flag if scaling succeeded
        if (!was_pip) {
            // Entering PIP mode with custom frame
            window->pip_frame.current.x = x;
            window->pip_frame.current.y = y;
            window_set_flag(window, WINDOW_PIP);
        } else {
            // Already in PIP mode - just update position
            window->pip_frame.current.x = x;
            window->pip_frame.current.y = y;
        }
        
        struct yb_prop_update msg = {
            .count = 1,
            .wid   = window->id,
            .value = 1
        };
        push_janky_update(1117, &msg, sizeof(msg));
    }
}

static inline struct window *window_manager_find_scratchpad_window(struct window_manager *wm, char *label)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        if (string_equals(wm->scratchpad_window[i].label, label)) {
            return wm->scratchpad_window[i].window;
        }
    }

    return NULL;
}

bool window_manager_toggle_scratchpad_window_by_label(struct window_manager *wm, char *label)
{
    struct window *window = window_manager_find_scratchpad_window(wm, label);
    return window ? window_manager_toggle_scratchpad_window(wm, window, 0) : false;
}

bool window_manager_toggle_scratchpad_window(struct window_manager *wm, struct window *window, int forced_mode)
{
    TIME_FUNCTION;

    uint64_t sid = space_manager_active_space();
    if (!sid) return false;

    // TODO(koekeishiya): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
    bool visible_space = window_space(window->id) == sid || window_is_sticky(window->id);

    uint8_t ordered_in = 0;
    SLSWindowIsOrderedIn(g_connection, window->id, &ordered_in);

    switch (forced_mode) {
    case 0: goto mode_0;
    case 1: goto mode_1;
    case 2: goto mode_2;
    case 3: goto mode_3;
    }

mode_0:;
    if (visible_space && ordered_in) {
mode_1:;
        struct window *next = window_manager_find_window_on_space_by_rank_filtering_window(wm, sid, 1, window->id);
        if (next) {
            window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
        } else {
            _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
        }
        scripting_addition_order_window(window->id, 0, 0);
    } else if (visible_space && !ordered_in) {
mode_2:;
        scripting_addition_order_window(window->id, 1, 0);
        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    } else {
mode_3:;
        space_manager_move_window_to_space(sid, window);
        scripting_addition_order_window(window->id, 1, 0);
        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
    }

    return true;
}

bool window_manager_set_scratchpad_for_window(struct window_manager *wm, struct window *window, char *label)
{
    struct window *existing_window = window_manager_find_scratchpad_window(wm, label);
    if (existing_window) return false;

    window_manager_remove_scratchpad_for_window(wm, window, false);
    buf_push(wm->scratchpad_window, ((struct scratchpad) {
        .label = label,
        .window = window
    }));
    window->scratchpad = label;
    window_manager_make_window_floating(&g_space_manager, wm, window, true, false);

    return true;
}

bool window_manager_remove_scratchpad_for_window(struct window_manager *wm, struct window *window, bool unfloat)
{
    for (int i = 0; i < buf_len(wm->scratchpad_window); ++i) {
        if (wm->scratchpad_window[i].window == window) {
            window->scratchpad = NULL;

            free(wm->scratchpad_window[i].label);
            buf_del(wm->scratchpad_window, i);

            if (unfloat) {
                window_manager_toggle_scratchpad_window(wm, window, 3);
                window_manager_make_window_floating(&g_space_manager, wm, window, false, false);
            }

            return true;
        }
    }

    return false;
}

void window_manager_scratchpad_recover_windows(void)
{
    int window_count;
    uint32_t *window_list = window_manager_existing_application_window_list(NULL, &window_count);
    if (!window_list) return;

    if (scripting_addition_order_window_in(window_list, window_count)) {
        space_manager_refresh_application_windows(&g_space_manager);
    }
}

static void window_manager_validate_windows_on_space(struct window_manager *wm, struct view *view, uint32_t *window_list, int window_count)
{
    int view_window_count;
    uint32_t *view_window_list = view_find_window_list(view, &view_window_count);

    for (int i = 0; i < view_window_count; ++i) {
        bool found = false;

        for (int j = 0; j < window_count; ++j) {
            if (view_window_list[i] == window_list[j]) {
                found = true;
                break;
            }
        }

        if (!found) {
            struct window *window = window_manager_find_window(wm, view_window_list[i]);
            if (!window) continue;

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(koekeishiya): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_remove_window_node(view, window);
            window_manager_adjust_layer(window, LAYER_NORMAL);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);

            view_set_flag(view, VIEW_IS_DIRTY);
        }
    }
}

static void window_manager_check_for_windows_on_space(struct window_manager *wm, struct view *view, uint32_t *window_list, int window_count)
{
    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_manager_find_window(wm, window_list[i]);
        if (!window || !window_manager_should_manage_window(window)) continue;

        struct view *existing_view = window_manager_find_managed_window(wm, window);
        if (existing_view && existing_view->layout != VIEW_FLOAT && existing_view != view) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(koekeishiya): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_remove_window_node(existing_view, window);
            window_manager_adjust_layer(window, LAYER_NORMAL);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);
            view_set_flag(existing_view, VIEW_IS_DIRTY);
        }

        if (!existing_view || (existing_view->layout != VIEW_FLOAT && existing_view != view)) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(koekeishiya): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_add_window_node(view, window);
            window_manager_adjust_layer(window, LAYER_BELOW);
            window_manager_add_managed_window(wm, window, view);
            view_set_flag(view, VIEW_IS_DIRTY);
        }
    }
}

void window_manager_validate_and_check_for_windows_on_space(struct space_manager *sm, struct window_manager *wm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return;

    int window_count = 0;
    uint32_t *window_list = space_window_list(sid, &window_count, false);
    window_manager_validate_windows_on_space(wm, view, window_list, window_count);
    window_manager_check_for_windows_on_space(wm, view, window_list, window_count);

    //
    // @cleanup
    // 
    // :AXBatching
    //
    // NOTE(koekeishiya): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    if (space_is_visible(view->sid) && view_is_dirty(view)) {
        window_node_flush(view->root);
        view_clear_flag(view, VIEW_IS_DIRTY);
    }
}

void window_manager_correct_for_mission_control_changes(struct space_manager *sm, struct window_manager *wm)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    float animation_duration = wm->window_animation_duration;
    wm->window_animation_duration = 0.0f;

    for (int i = 0; i < display_count; ++i) {
        uint32_t did = display_list[i];

        int space_count;
        uint64_t *space_list = display_space_list(did, &space_count);
        if (!space_list) continue;

        uint64_t sid = display_space_id(did);
        for (int j = 0; j < space_count; ++j) {
            if (space_list[j] == sid) {
                window_manager_validate_and_check_for_windows_on_space(sm, wm, sid);
            } else {
                space_manager_mark_view_invalid(sm, space_list[j]);
            }
        }
    }

    wm->window_animation_duration = animation_duration;
}

void window_manager_handle_display_add_and_remove(struct space_manager *sm, struct window_manager *wm, uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return;

    for (int i = 0; i < space_count; ++i) {
        if (space_is_user(space_list[i])) {
            int window_count;
            uint32_t *window_list = space_window_list(space_list[i], &window_count, false);
            if (window_list) {
                struct view *view = space_manager_find_view(sm, space_list[i]);
                if (view->layout != VIEW_FLOAT && view->layout != VIEW_BSP) {
                    window_manager_check_for_windows_on_space(wm, view, window_list, window_count);
                }
            }
            break;
        }
    }

    uint64_t sid = display_space_id(did);
    for (int i = 0; i < space_count; ++i) {
        if (space_list[i] == sid) {
            space_manager_refresh_view(sm, sid);
        } else {
            space_manager_mark_view_invalid(sm, space_list[i]);
        }
    }
}

void window_manager_init(struct window_manager *wm)
{
    wm->system_element = AXUIElementCreateSystemWide();
    AXUIElementSetMessagingTimeout(wm->system_element, 1.0);

    wm->ffm_mode = FFM_DISABLED;
    wm->purify_mode = PURIFY_DISABLED;
    wm->window_origin_mode = WINDOW_ORIGIN_DEFAULT;
    wm->enable_mff = false;
    wm->enable_window_opacity = false;
    wm->menubar_opacity = 1.0f;
    wm->active_window_opacity = 1.0f;
    wm->normal_window_opacity = 1.0f;
    wm->window_opacity_duration = 0.0f;
    wm->window_animation_duration = 0.0f;
    wm->window_animation_easing = ease_out_cubic_type;
    wm->window_animation_fade_threshold = 0.1f;   // Apply fade when size difference > 30%
    wm->window_animation_fade_intensity = 0.1f;   // Fade to 60% opacity (1.0 - 0.4)
    wm->window_animation_fade_enabled = false;     // Enable fade effect by default
    wm->window_animation_two_phase_enabled = true; // Enable two-phase animation by default
    wm->window_animation_slide_ratio = 0.50f;      // 50% slide, 50% resize (was 0.90f)
    
    // Initialize edge override controls
    wm->window_animation_edge_threshold = 5.0f;                // 5 pixel threshold for edge detection
    wm->window_animation_force_top_anchor = false;             // Don't force top edge by default
    wm->window_animation_force_bottom_anchor = false;          // Don't force bottom edge by default
    wm->window_animation_force_left_anchor = false;            // Don't force left edge by default
    wm->window_animation_force_right_anchor = false;           // Don't force right edge by default
    wm->window_animation_override_stacked_top = false;         // Don't override stacked top by default
    wm->window_animation_override_stacked_bottom = false;      // Don't override stacked bottom by default
    wm->window_animation_stacked_top_anchor = 0;               // Default to top-left anchor for top windows
    wm->window_animation_stacked_bottom_anchor = 2;            // Default to bottom-left anchor for bottom windows
    wm->window_animation_blur_enabled = false;                 // Blur disabled by default
    wm->window_animation_blur_radius = 20.0f;                  // Default blur radius
    wm->window_animation_blur_style = 1;                       // Default to light blur style
    
    // Performance-focused animation toggles - optimize for snappy feel by default
    wm->window_animation_shadows_enabled = true;               // Shadows enabled by default (can disable for performance)
    wm->window_animation_opacity_enabled = true;               // Opacity animations enabled by default
    wm->window_animation_simplified_easing = false;            // Use complex easing by default
    wm->window_animation_reduced_resolution = false;           // Use full resolution by default
    wm->window_animation_fast_mode = false;                    // Fast mode disabled by default
    wm->window_animation_starting_size = 1.0f;                 // Start at target size by default (no scaling effect)
    
    wm->window_animation_pip_enabled = false;          // pip-based animation disabled by default (POC)
    wm->window_animation_frame_rate = 60.0f;                   // Default 60 fps for AX API calls
    wm->window_animation_pip_async_enabled = false;            // PiP async processing disabled by default

    wm->insert_feedback_color = rgba_color_from_hex(0xffd75f5f);

    table_init(&wm->application, 150, hash_wm, compare_wm);
    table_init(&wm->window, 150, hash_wm, compare_wm);
    table_init(&wm->managed_window, 150, hash_wm, compare_wm);
    table_init(&wm->window_lost_focused_event, 150, hash_wm, compare_wm);
    table_init(&wm->application_lost_front_switched_event, 150, hash_wm, compare_wm);
    table_init(&wm->window_animations_table, 150, hash_wm, compare_wm);
    table_init(&wm->insert_feedback, 150, hash_wm, compare_wm);
    table_init(&wm->stack_state, 256, hash_wm, compare_wm);
    wm->stack_gen = 0;
    pthread_mutex_init(&wm->window_animations_lock, NULL);
}

void window_manager_begin(struct space_manager *sm, struct window_manager *wm)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    table_for (struct process *process, g_process_manager.process, {
        if (workspace_application_is_observable(process)) {
            struct application *application = application_create(process);

            if (application_observe(application)) {
                window_manager_add_application(wm, application);
                window_manager_add_existing_application_windows(sm, wm, application, -1);
            } else {
                application_unobserve(application);
                application_destroy(application);
            }
        } else {
            debug("%s: %s (%d) is not observable, subscribing to activationPolicy changes\n", __FUNCTION__, process->name, process->pid);
            workspace_application_observe_activation_policy(g_workspace_context, process);
        }
    })
    [pool drain];

    struct window *window = window_manager_focused_window(wm);
    if (window) {
        wm->last_window_id = window->id;
        wm->focused_window_id = window->id;
        wm->focused_window_psn = window->application->psn;
        window_manager_set_window_opacity(wm, window, wm->active_window_opacity);
    }
}
