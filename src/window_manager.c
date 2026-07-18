#include <math.h>

extern mach_port_t g_bs_port;
extern uint8_t *g_event_bytes;
extern struct event_loop g_event_loop;
extern void *g_workspace_context;
extern struct process_manager g_process_manager;
extern struct mouse_state g_mouse_state;
extern double g_cv_host_clock_frequency;

static TABLE_HASH_FUNC(hash_wm)
{
    return *(uint32_t *) key;
}

static TABLE_COMPARE_FUNC(compare_wm)
{
    return *(uint32_t *) key_a == *(uint32_t *) key_b;
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
        // NOTE(asmvik): display_space_list(..) uses a linear allocator,
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

    if (effects->grid[0] != 0 && effects->grid[1] != 0) {
        window_manager_apply_grid(sm, wm, window, effects->grid[0], effects->grid[1], effects->grid[2], effects->grid[3], effects->grid[4], effects->grid[5]);
    }
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
    if (!window->is_root)                           return false;
    if (window_check_flag(window, WINDOW_FLOAT))    return false;
    if (window_is_sticky(window->id))               return false;
    if (window_check_flag(window, WINDOW_MINIMIZE)) return false;
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
}

void window_manager_add_managed_window(struct window_manager *wm, struct window *window, struct view *view)
{
    if (view->layout == VIEW_FLOAT) return;
    table_add(&wm->managed_window, &window->id, view);
    window_manager_purify_window(wm, window);
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
        AX_ENHANCED_UI_WORKAROUND_CACHED(window->application,{
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
                AX_ENHANCED_UI_WORKAROUND_CACHED(window->application,{ window_manager_resize_window(window, dx, dy); });
            }
        } else {
            window_manager_resize_window_relative_internal(window, window_ax_frame(window), direction, dx, dy, animate);
        }
    }

    return WINDOW_OP_ERROR_SUCCESS;
}

void window_manager_move_window(struct window *window, float x, float y)
{
    CGPoint position = CGPointMake(x, y);
    CFTypeRef position_ref = AXValueCreate(kAXValueTypeCGPoint, (void *) &position);
    if (!position_ref) return;

    AXUIElementSetAttributeValue(window->ref, kAXPositionAttribute, position_ref);
    CFRelease(position_ref);
}

void window_manager_resize_window(struct window *window, float width, float height)
{
    CGSize size = CGSizeMake(width, height);
    CFTypeRef size_ref = AXValueCreate(kAXValueTypeCGSize, (void *) &size);
    if (!size_ref) return;

    AXUIElementSetAttributeValue(window->ref, kAXSizeAttribute, size_ref);
    CFRelease(size_ref);
}

static void window_manager_cache_app_constraints(struct window_manager *wm,
                                                  pid_t pid,
                                                  CGSize min, CGSize max) {
  if (min.width  <= 0 && min.height <= 0 &&
      max.width  <= 0 && max.height <= 0) return;
  uint32_t key = (uint32_t)pid;
  struct app_size_constraints *existing = table_find(&wm->app_constraints, &key);
  if (existing) {
    existing->min = min;
    existing->max = max;
    return;
  }
  struct app_size_constraints *entry = malloc(sizeof(*entry));
  entry->min = min;
  entry->max = max;
  table_add(&wm->app_constraints, &key, entry);
}

static bool window_manager_get_cached_app_constraints(struct window_manager *wm,
                                                       pid_t pid,
                                                       CGSize *min, CGSize *max) {
  uint32_t key = (uint32_t)pid;
  struct app_size_constraints *entry = table_find(&wm->app_constraints, &key);
  if (!entry) return false;
  *min = entry->min;
  *max = entry->max;
  return true;
}

// NOTE: a settled frame must never read as different to the flush gate, or the tail re-animates.
_Static_assert(SA_ANIM_SETTLE_PX < AX_DIFF_THRESHOLD,
               "payload settle tolerance must stay strictly below the daemon AX_DIFF threshold");

// NOTE: shipped on the wire — the payload clamps every frame against these, so
// a wide-open value lets a constrained window transform past its min/max.
// T3D_ONLY rows stay wide-open by design; 0/empty axis = no-op (min 0 / max 1e9).
static void window_manager_resolve_anim_constraints(struct window_manager *wm,
                                                    struct window *window,
                                                    uint32_t row_mode,
                                                    float *min_w, float *min_h,
                                                    float *max_w, float *max_h,
                                                    bool *from_cache) {
  *min_w = 0.0f; *min_h = 0.0f; *max_w = 1.0e9f; *max_h = 1.0e9f;
  if (from_cache) *from_cache = false;
  if (row_mode == SA_T3D_ROW_MODE_T3D_ONLY || !window) return;

  extern bool window_iterator_get_constraints(int cid, uint32_t wid,
                                              CGSize *mn, CGSize *mx, CGSize *cur);
  CGSize cmn = {0}, cmx = {0}, cur = {0};
  bool ok = window_iterator_get_constraints(g_connection, window->id, &cmn, &cmx, &cur);
  bool have_real = ok && (cmn.width > 0 || cmn.height > 0 ||
                          cmx.width > 0 || cmx.height > 0);
  pid_t pid = window->application->pid;
  if (have_real) {
    window_manager_cache_app_constraints(wm, pid, cmn, cmx);
  } else {
    CFTypeRef val = NULL;
    if (SLSCopyWindowProperty(g_connection, window->id,
                              CFSTR("com.koekeishiya.yabai.constraint_class.v1"),
                              &val) == kCGErrorSuccess && val) {
      if (CFGetTypeID(val) == CFStringGetTypeID()) {
        char buf[96] = {0};
        if (CFStringGetCString((CFStringRef)val, buf, sizeof(buf), kCFStringEncodingUTF8)) {
          int type = 0, confirm = 0;
          float pmnw = 0, pmnh = 0, pmxw = 0, pmxh = 0, pasp = 0;
          if (sscanf(buf, "%d %f %f %f %f %f %d",
                     &type, &pmnw, &pmnh, &pmxw, &pmxh, &pasp, &confirm) >= 5 &&
              type == 1) {
            cmn.width = pmnw; cmn.height = pmnh;
            cmx.width = pmxw; cmx.height = pmxh;
            have_real = true;
            if (from_cache) *from_cache = true;
            LOGFT(__func__, "wid=%d learned single-axis min=(%.0f,%.0f) max=(%.0f,%.0f) [property]\n",
                  window->id, pmnw, pmnh, pmxw, pmxh);
          }
        }
      }
      CFRelease(val);
    }
  }
  (void)window_manager_get_cached_app_constraints;
  if (have_real) {
    *min_w = (cmn.width  > 0) ? (float)cmn.width  : 0.0f;
    *min_h = (cmn.height > 0) ? (float)cmn.height : 0.0f;
    *max_w = (cmx.width  > 0) ? (float)cmx.width  : 1.0e9f;
    *max_h = (cmx.height > 0) ? (float)cmx.height : 1.0e9f;

    // min==max axis: pin both ends on the wire so the clamp can never lerp past a fixed extent.
    struct axis_lock lock = window_classify_axis_lock(cmn, cmx);
    if (lock.width_fixed)  *min_w = *max_w = (float)cmn.width;
    if (lock.height_fixed) *min_h = *max_h = (float)cmn.height;
    if (lock.width_fixed || lock.height_fixed) {
      LOGFT(__func__, "wid=%d single-axis fixed (w=%d h=%d) -> pinned min=(%.0f,%.0f) max=(%.0f,%.0f)\n",
            window->id, lock.width_fixed, lock.height_fixed, *min_w, *min_h, *max_w, *max_h);
    }
  }
}

#define CA_ANIM_PROP CFSTR("com.koekeishiya.yabai.animating")
struct ca_anim_entry { uint32_t wid; uint64_t expire_mach; };
static struct ca_anim_entry g_ca_anim[256];
static pthread_mutex_t g_ca_anim_lock = PTHREAD_MUTEX_INITIALIZER;

static void window_manager_ca_anim_register(uint32_t wid, uint64_t expire_mach) {
    uint64_t now = mach_absolute_time();
    pthread_mutex_lock(&g_ca_anim_lock);
    int free_i = -1;
    for (int i = 0; i < 256; ++i) {
        if (g_ca_anim[i].wid == wid) { g_ca_anim[i].expire_mach = expire_mach; pthread_mutex_unlock(&g_ca_anim_lock); return; }
        if (free_i < 0 && (g_ca_anim[i].wid == 0 || now >= g_ca_anim[i].expire_mach)) free_i = i;
    }
    if (free_i >= 0) { g_ca_anim[free_i].wid = wid; g_ca_anim[free_i].expire_mach = expire_mach; }
    pthread_mutex_unlock(&g_ca_anim_lock);
}

// NOTE: expired entries are NOT reaped here — the watchdog sweep reads them to
// recover leaked LB pins; removal is the sweep's job.
static bool ca_anim_gate_active(uint32_t wid) {
    bool active = false;
    uint64_t now = mach_absolute_time();
    pthread_mutex_lock(&g_ca_anim_lock);
    for (int i = 0; i < 256; ++i) {
        if (g_ca_anim[i].wid != wid) continue;
        active = (now < g_ca_anim[i].expire_mach);
        break;
    }
    pthread_mutex_unlock(&g_ca_anim_lock);
    return active;
}

static bool ca_anim_prop_true(uint32_t wid) {
    CFTypeRef v = NULL;
    if (SLSCopyWindowProperty(g_connection, wid, CA_ANIM_PROP, &v) != kCGErrorSuccess || !v) return false;
    bool yes = (CFGetTypeID(v) == CFBooleanGetTypeID()) && CFBooleanGetValue((CFBooleanRef)v);
    CFRelease(v);
    return yes;
}

bool window_manager_is_animating(uint32_t wid) {
    if (!ca_anim_gate_active(wid)) return false;
    return ca_anim_prop_true(wid);
}

// NOTE: drag-follow T3D is outside the animating-property protocol, so
// is_animating can't see it. Drag matrices are pure 2D-affine — the exported
// 2D getter recovers them; a failed read reports false (flush proceeds).
bool window_manager_window_is_transformed(uint32_t wid) {
    CGAffineTransform t;
    if (SLSGetWindowTransform(g_connection, wid, &t) != kCGErrorSuccess) return false;
    return fabs(t.a - 1.0) > 1e-4 || fabs(t.d - 1.0) > 1e-4 ||
           fabs(t.b)       > 1e-4 || fabs(t.c)       > 1e-4 ||
           fabs(t.tx)      > 1e-4 || fabs(t.ty)      > 1e-4;
}

// NOTE: recovers LB pins left by a payload that died mid-animation (piggybacked
// on ca dispatch). Property still set past deadline -> clear via the now-live
// payload; keep the entry to retry while the payload is still down.
static void window_manager_ca_anim_sweep(void) {
    uint64_t now = mach_absolute_time();
    for (int i = 0; i < 256; ++i) {
        pthread_mutex_lock(&g_ca_anim_lock);
        uint32_t wid = g_ca_anim[i].wid;
        bool expired = wid && now >= g_ca_anim[i].expire_mach;
        pthread_mutex_unlock(&g_ca_anim_lock);
        if (!expired) continue;

        bool drop = true;
        if (ca_anim_prop_true(wid)) {
            drop = scripting_addition_clear_lockedbounds(wid);
        }
        if (drop) {
            pthread_mutex_lock(&g_ca_anim_lock);
            if (g_ca_anim[i].wid == wid) g_ca_anim[i].wid = 0; // recheck: slot not reused during unlock
            pthread_mutex_unlock(&g_ca_anim_lock);
        }
    }
}

// NOTE: the SA begin returns before the animation ends and cannot push
// completion — a poll thread fires the finalize when every wid's animating
// property clears or the expiry hits (NOTIFY_DONE keeps the property
// maintained even for visual-only batches).
#define CA_FINALIZE_MAX 16
struct ca_finalize_entry {
    uint32_t              wids[SA_ANIM_AX_MAX];
    int                   count;
    uint64_t              expire_mach;
    wm_finalize_callback  callback;
    void                 *user_data;
    bool                  active;
};
static struct ca_finalize_entry g_ca_finalize[CA_FINALIZE_MAX];
static pthread_mutex_t g_ca_finalize_lock = PTHREAD_MUTEX_INITIALIZER;
static bool g_ca_finalize_poll_active;

// callbacks run OUTSIDE the lock — a stages finalize re-enters the animation machinery.
static void *window_manager_ca_finalize_poll(void *unused) {
    (void)unused;
    for (;;) {
        usleep(16000);

        struct { wm_finalize_callback cb; void *ud; uint32_t wids[SA_ANIM_AX_MAX]; int count; } fired[CA_FINALIZE_MAX];
        int      nfired = 0;
        bool     any_active = false;
        uint64_t now = mach_absolute_time();

        pthread_mutex_lock(&g_ca_finalize_lock);
        for (int i = 0; i < CA_FINALIZE_MAX; ++i) {
            struct ca_finalize_entry *e = &g_ca_finalize[i];
            if (!e->active) continue;

            bool done = true;
            for (int j = 0; j < e->count; ++j) {
                if (ca_anim_prop_true(e->wids[j])) { done = false; break; }
            }
            bool expired = now >= e->expire_mach;
            if (done || expired) {
                fired[nfired].cb    = e->callback;
                fired[nfired].ud    = e->user_data;
                fired[nfired].count = e->count;
                memcpy(fired[nfired].wids, e->wids, e->count * sizeof(uint32_t));
                ++nfired;
                e->active = false;
            } else {
                any_active = true;
            }
        }
        bool keep_running = any_active;
        if (!keep_running) g_ca_finalize_poll_active = false;
        pthread_mutex_unlock(&g_ca_finalize_lock);

        for (int i = 0; i < nfired; ++i)
            if (fired[i].cb) fired[i].cb(fired[i].wids, fired[i].count, fired[i].ud);

        if (!keep_running) return NULL;
    }
}

// NOTE: on registry-full / spawn-failure the callback fires synchronously so the ud can't leak.
static void window_manager_ca_finalize_register(uint32_t *wids, int count, uint64_t expire_mach,
                                                wm_finalize_callback cb, void *ud) {
    if (count > SA_ANIM_AX_MAX) count = SA_ANIM_AX_MAX;

    pthread_mutex_lock(&g_ca_finalize_lock);
    int slot = -1;
    for (int i = 0; i < CA_FINALIZE_MAX; ++i) if (!g_ca_finalize[i].active) { slot = i; break; }
    bool start_thread = false;
    if (slot >= 0) {
        struct ca_finalize_entry *e = &g_ca_finalize[slot];
        memcpy(e->wids, wids, count * sizeof(uint32_t));
        e->count       = count;
        e->expire_mach = expire_mach;
        e->callback    = cb;
        e->user_data   = ud;
        e->active      = true;
        if (!g_ca_finalize_poll_active) { g_ca_finalize_poll_active = true; start_thread = true; }
    }
    pthread_mutex_unlock(&g_ca_finalize_lock);

    if (slot < 0) {
        if (cb) cb(NULL, 0, ud);
        return;
    }
    if (start_thread) {
        pthread_t t;
        if (pthread_create(&t, NULL, window_manager_ca_finalize_poll, NULL) == 0) {
            pthread_detach(t);
        } else {
            pthread_mutex_lock(&g_ca_finalize_lock);
            g_ca_finalize[slot].active = false;
            g_ca_finalize_poll_active  = false;
            pthread_mutex_unlock(&g_ca_finalize_lock);
            if (cb) cb(wids, count, ud);
        }
    }
}

bool window_manager_animate_windows_lockedbounds_t3d_async(
    struct window_capture *window_list, int window_count,
    uint32_t api_flags, float duration_override,
    int ax_th_mode, float ax_th_val,
    CGRect *start_override, uint32_t row_mode,
    enum wm_finalize_mode finalize_mode,
    wm_finalize_callback finalize_callback,
    void *finalize_user_data)
{
    if (ax_th_mode != WM_AX_TH_PX && ax_th_mode != WM_AX_TH_PCT) {
        ax_th_mode = WM_AX_TH_NONE;
    }
    if (ax_th_val <= 0.0f) ax_th_mode = WM_AX_TH_NONE;

    struct sa_anim_ax_begin b = {0};
    // NOTE: riders (window == NULL, wid != 0) must ride a separate visual-only
    // context: the AX context's settle probe walks EVERY row and a T3D-only
    // surface never lands, so one rider would stall the whole batch. Ship the
    // rider context BEFORE the batch it shadows (same pump keeps ticks in phase);
    // LEAVE_TERMINAL so the transform holds until the caller disposes the surface.
    struct sa_anim_ax_begin v = {0};
    int vpacked = 0;
    int n = window_count > SA_ANIM_AX_MAX ? SA_ANIM_AX_MAX : window_count;
    b.flags = 0;
    if (api_flags & WM_T3D_USE_LB)  b.flags |= SA_T3D_FLAG_LB;
    if (api_flags & WM_T3D_USE_T3)  b.flags |= SA_T3D_FLAG_T3;
    if (api_flags & WM_T3D_LB_FULL) b.flags |= SA_T3D_FLAG_LB_FULL;
    if (api_flags & WM_T3D_T3_FULL) b.flags |= SA_T3D_FLAG_T3_FULL;
    if (api_flags & WM_T3D_USE_AX)    b.flags |= SA_T3D_FLAG_AX;
    if (api_flags & WM_T3D_USE_ALPHA) b.flags |= SA_T3D_FLAG_ALPHA;
    if (api_flags & WM_T3D_ENDPIN)             b.flags |= SA_T3D_FLAG_ENDPIN;
    if (api_flags & WM_T3D_ENDPIN_RESIZE_ONLY) b.flags |= SA_T3D_FLAG_ENDPIN_RESIZE_ONLY;
    if (g_window_manager.window_animation_ax_wake)      b.flags |= SA_T3D_FLAG_AX_WAKE;
    if (g_window_manager.window_animation_policy == WM_ANIM_POLICY_LB_ONLY)
        b.flags |= SA_T3D_FLAG_LB | SA_T3D_FLAG_LB_FULL;
    uint32_t eff_row_mode = row_mode;
    if (g_window_manager.window_animation_policy == WM_ANIM_POLICY_LB_ONLY &&
        row_mode == SA_T3D_ROW_MODE_LB_T3D)
        eff_row_mode = SA_T3D_ROW_MODE_LB_ONLY;
    if (finalize_callback) b.flags |= SA_T3D_FLAG_NOTIFY_DONE;
    b.easing        = (uint32_t)g_window_manager.window_animation_easing;
    b.duration      = duration_override > 0.0f ? duration_override
                                               : (float)g_window_manager.window_animation_duration;
    b.fade_duration = g_window_manager.window_opacity_duration;
    b.ax_th_mode    = (uint32_t)ax_th_mode;
    b.ax_th_val     = ax_th_val;
    b.finalize_mode = (uint32_t)finalize_mode;
    int packed = 0;
    for (int i = 0; i < n; ++i) {
        struct window *win = window_list[i].window;
        if (!win) {
            uint32_t rwid = window_list[i].wid;
            if (!rwid || vpacked >= SA_ANIM_AX_MAX) continue;
            CGRect rf;
            if (SLSGetWindowBounds(g_connection, rwid, &rf) != kCGErrorSuccess ||
                rf.size.width <= 0.0f || rf.size.height <= 0.0f) continue;
            CGRect rs = (start_override != NULL) ? start_override[i] : rf;
            v.windows[vpacked].wid  = rwid;
            v.windows[vpacked].mode = SA_T3D_ROW_MODE_T3D_ONLY;
            v.windows[vpacked].pid  = 0;
            v.windows[vpacked].start_x = rs.origin.x;   v.windows[vpacked].start_y = rs.origin.y;
            v.windows[vpacked].start_w = rs.size.width; v.windows[vpacked].start_h = rs.size.height;
            v.windows[vpacked].anchor_x = rf.origin.x;   v.windows[vpacked].anchor_y = rf.origin.y;
            v.windows[vpacked].anchor_w = rf.size.width; v.windows[vpacked].anchor_h = rf.size.height;
            v.windows[vpacked].end_x = window_list[i].x; v.windows[vpacked].end_y = window_list[i].y;
            v.windows[vpacked].end_w = window_list[i].w; v.windows[vpacked].end_h = window_list[i].h;
            v.windows[vpacked].min_opacity = g_window_manager.window_animation_min_opacity;
            v.windows[vpacked].min_w = 0.0f;   v.windows[vpacked].min_h = 0.0f;
            v.windows[vpacked].max_w = 1.0e9f; v.windows[vpacked].max_h = 1.0e9f;
            vpacked++;
            continue;
        }
        CGRect f = window_ax_frame(win);
        CGRect s = (start_override != NULL) ? start_override[i] : f;
        b.windows[packed].wid  = win->id;
        b.windows[packed].mode = eff_row_mode;
        b.windows[packed].pid  = win->application->pid;
        b.windows[packed].start_x = s.origin.x;   b.windows[packed].start_y = s.origin.y;
        b.windows[packed].start_w = s.size.width; b.windows[packed].start_h = s.size.height;
        // anchor = the REAL surface rect; start/end are only the visual lerp endpoints —
        // anchoring at start collapses a stages grow to identity at t=0.
        b.windows[packed].anchor_x = f.origin.x;   b.windows[packed].anchor_y = f.origin.y;
        b.windows[packed].anchor_w = f.size.width; b.windows[packed].anchor_h = f.size.height;
        b.windows[packed].end_x = window_list[i].x; b.windows[packed].end_y = window_list[i].y;
        b.windows[packed].end_w = window_list[i].w; b.windows[packed].end_h = window_list[i].h;
        b.windows[packed].min_opacity = g_window_manager.window_animation_min_opacity;
        bool cm_cache = false;
        window_manager_resolve_anim_constraints(&g_window_manager, win, eff_row_mode,
            &b.windows[packed].min_w, &b.windows[packed].min_h,
            &b.windows[packed].max_w, &b.windows[packed].max_h, &cm_cache);
        if (b.windows[packed].min_w > 0.0f || b.windows[packed].min_h > 0.0f ||
            b.windows[packed].max_w < 1.0e9f || b.windows[packed].max_h < 1.0e9f) {
            char *cm_title = window_title_ts(win);
            LOGFT("T3D_CONSTRAIN",
                "wid%-3u [%s] \"%s\" min=(%.0fx%.0f) max=(%.0fx%.0f) src=%s "
                "end=(%.0fx%.0f) [branchB]",
                win->id, win->application->name, cm_title ? cm_title : "",
                b.windows[packed].min_w, b.windows[packed].min_h,
                (b.windows[packed].max_w >= 1.0e9f) ? 0.0 : (double)b.windows[packed].max_w,
                (b.windows[packed].max_h >= 1.0e9f) ? 0.0 : (double)b.windows[packed].max_h,
                cm_cache ? "cache" : "query",
                b.windows[packed].end_w, b.windows[packed].end_h);
        }
        packed++;
    }
    b.count = (uint32_t)packed;
    v.count = (uint32_t)vpacked;
    // no real rows -> no completion signal; fire the finalize now (NULL/0) so the
    // caller's user_data frees. Riders (if any) still ship visually.
    if (b.count == 0 && finalize_callback) {
        finalize_callback(NULL, 0, finalize_user_data);
    }
    if (b.count == 0 && v.count == 0) return true;
    // pace on the batch's own display vblank; did=0 would leave the payload link inert.
    b.did = window_display_id(b.count ? b.windows[0].wid : v.windows[0].wid);
    if (!b.did) b.did = CGMainDisplayID();
    struct display_timing *dt = display_timing_get(b.did);
    b.refresh_hz = (dt && dt->refresh_rate_hz > 1.0) ? (float)dt->refresh_rate_hz : 60.0f;

    if (v.count) {
        if (api_flags & WM_T3D_USE_T3)  v.flags |= SA_T3D_FLAG_T3;
        if (api_flags & WM_T3D_T3_FULL) v.flags |= SA_T3D_FLAG_T3_FULL;
        if (!(v.flags & SA_T3D_FLAG_T3)) v.flags = SA_T3D_FLAG_T3;
        v.easing        = b.easing;
        v.duration      = b.duration;
        v.fade_duration = b.fade_duration;
        v.ax_th_mode    = (uint32_t)WM_AX_TH_NONE;
        v.ax_th_val     = 0.0f;
        v.finalize_mode = SA_FINALIZE_LEAVE_TERMINAL;
        v.did           = b.did;
        v.refresh_hz    = b.refresh_hz;
        scripting_addition_anim_ax_begin(&v);
    }
    if (b.count == 0) return true;

    if (!scripting_addition_anim_ax_begin(&b)) {
        return false;
    }
    if (b.flags & SA_T3D_FLAG_AX) {
        window_manager_ca_anim_sweep();
        uint64_t expire = mach_absolute_time() +
            (uint64_t)((b.duration + 1.0f) * g_cv_host_clock_frequency);
        for (int i = 0; i < packed; ++i)
            window_manager_ca_anim_register(b.windows[i].wid, expire);
    }
    if (finalize_callback) {
        uint32_t fwids[SA_ANIM_AX_MAX];
        for (int i = 0; i < packed; ++i) fwids[i] = b.windows[i].wid;
        uint64_t fexpire = mach_absolute_time() +
            (uint64_t)((b.duration + 1.0f) * g_cv_host_clock_frequency);
        window_manager_ca_finalize_register(fwids, packed, fexpire,
                                            finalize_callback, finalize_user_data);
    }

    return true;
}

struct window_ax_only_ctx {
    struct window *window;
    CGRect start;
    CGRect end;
    double duration;
    int easing;
    uint64_t start_time;
    int64_t interval_ns;
};

static void window_manager_animate_ax_only_tick(struct window_ax_only_ctx *ctx);

static void window_manager_animate_ax_only_tick(struct window_ax_only_ctx *ctx)
{
    uint64_t now = mach_absolute_time();
    double t = (double)(now - ctx->start_time) /
               (double)(ctx->duration * g_cv_host_clock_frequency);
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;

    float mt = (float)t;
    switch (ctx->easing) {
#define ANIMATION_EASING_TYPE_ENTRY(value) \
  case value##_type:                       \
    mt = value(t);                         \
    break;
        ANIMATION_EASING_TYPE_LIST
#undef ANIMATION_EASING_TYPE_ENTRY
    }

    float lerp_x = lerp(ctx->start.origin.x,    mt, ctx->end.origin.x);
    float lerp_y = lerp(ctx->start.origin.y,    mt, ctx->end.origin.y);
    float lerp_w = lerp(ctx->start.size.width,  mt, ctx->end.size.width);
    float lerp_h = lerp(ctx->start.size.height, mt, ctx->end.size.height);

    window_manager_set_window_frame(ctx->window, lerp_x, lerp_y, lerp_w, lerp_h);

    if (t >= 1.0) {
        free(ctx);
        return;
    }

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, ctx->interval_ns),
        dispatch_get_main_queue(),
        ^{ window_manager_animate_ax_only_tick(ctx); });
}

void window_manager_animate_window_ax_only_async(
    struct window *window, CGRect target, float ax_hz)
{
    if (!window) return;
    if (ax_hz <= 0.0f) ax_hz = 60.0f;

    struct window_ax_only_ctx *ctx = malloc(sizeof(struct window_ax_only_ctx));
    ctx->window      = window;
    ctx->start       = window_ax_frame(window);
    ctx->end         = target;
    ctx->duration    = g_window_manager.window_animation_duration;
    ctx->easing      = g_window_manager.window_animation_easing;
    ctx->start_time  = mach_absolute_time();
    ctx->interval_ns = (int64_t)(NSEC_PER_SEC / ax_hz);

    dispatch_async(dispatch_get_main_queue(),
                   ^{ window_manager_animate_ax_only_tick(ctx); });
}

// production recipe: origin pinned at end so the app never reflows on an internal move.
#define WM_T3D_AUTO_POLICY                                          \
    (WM_T3D_ENDPIN | WM_T3D_ENDPIN_RESIZE_ONLY |                    \
     WM_T3D_USE_AX | WM_T3D_USE_LB | WM_T3D_LB_FULL | WM_T3D_USE_T3)

static inline uint32_t window_manager_auto_policy_flags(struct window_manager *wm) {
  (void)wm;
  return WM_T3D_AUTO_POLICY;
}

void window_manager_animate_window_list(struct window_capture *window_list,
                                        int window_count) {
  TIME_FUNCTION;

  if (g_window_manager.window_animation_duration &&
      window_manager_animate_windows_lockedbounds_t3d_async(
          window_list, window_count,
          window_manager_auto_policy_flags(&g_window_manager), 0.0f,
          WM_AX_TH_PX,
          1.0f,
          NULL, SA_T3D_ROW_MODE_LB_T3D,
          WM_FINALIZE_CLEAR, NULL, NULL)) {
    return;
  }

  for (int i = 0; i < window_count; ++i) {
    window_manager_set_window_frame(window_list[i].window, window_list[i].x,
                                    window_list[i].y, window_list[i].w,
                                    window_list[i].h);
  }
}

void window_manager_animate_window(struct window_capture capture) {
  TIME_FUNCTION;

  if (g_window_manager.window_animation_duration &&
      window_manager_animate_windows_lockedbounds_t3d_async(
          &capture, 1, window_manager_auto_policy_flags(&g_window_manager), 0.0f,
          WM_AX_TH_PX,
          1.0f,
          NULL, SA_T3D_ROW_MODE_LB_T3D,
          WM_FINALIZE_CLEAR, NULL, NULL)) {
    return;
  }

  window_manager_set_window_frame(capture.window, capture.x, capture.y,
                                  capture.w, capture.h);
}

void window_manager_animate_set_window_frame(struct window *window, float x, float y,
                                             float width, float height) {
  // no EUI bracket per tick — the payload holds EUI false for the whole animation.
  window_manager_resize_window(window, width, height);
  window_manager_move_window(window, x, y);
}

void window_manager_animate_window_resize(struct window *window,
                                          CGRect start_frame, CGRect end_frame,
                                          float duration) {
  if (!window)
    return;

  int total_frames = (int)(duration * 60.0f);
  if (total_frames < 2)
    total_frames = 2;

  for (int frame = 0; frame <= total_frames; frame++) {
    float t = (float)frame / (float)total_frames;

    float cx =
        start_frame.origin.x + t * (end_frame.origin.x - start_frame.origin.x);
    float cy =
        start_frame.origin.y + t * (end_frame.origin.y - start_frame.origin.y);
    float cw = start_frame.size.width +
               t * (end_frame.size.width - start_frame.size.width);
    float ch = start_frame.size.height +
               t * (end_frame.size.height - start_frame.size.height);

    scripting_addition_animate_window_lockedbounds(
        window->id,
        g_window_manager.window_opacity_duration,
        cx, cy, cw, ch, g_window_manager.window_animation_min_opacity,
        t
    );

    if (frame < total_frames) {
      usleep((int)(duration * 1000000.0f / total_frames));
    }
  }
}


#pragma mark - WM-9: proxy warp cover

// NOTE: proxy shows a frozen snapshot 9-slice-warped to dst while the real
// window hides at alpha 0; reveal restores the original alpha (carried on the
// proxy for translucent windows). No supersede: cover-in-flight -> bare AX.
extern CGError SLSSetWindowWarp(int cid, uint32_t wid, int w, int h, float *mesh);
extern void SLSSetWindowBackgroundBlurRadius(int cid, uint32_t wid, int radius);

#define WM_PROXY_COVER_SETTLE_CAP_S 0.400f  // reveal no later than this
#define WM_PROXY_COVER_SETTLE_PX    1.0     // real frame within this of dst = landed
#define WM_PROXY_COVER_TICK_US      8000    // settle poll cadence
#define WM_PROXY_COVER_BLUR_R   30      // invisible on opaque snapshots (no SLS getter for the real radius)

// NOTE: duplicated from payload_inc/warp_cover.inc.m — keep the two in sync.
// out = 4*4*4 floats {srcX,srcY,dstX,dstY}; src window-local, dst global.
static void wm_warp_mesh_9slice(double w0, double h0, CGRect dst,
                                double bl, double br, double bt, double bb,
                                float *out)
{
    double lim_w = fmin(w0, dst.size.width)  - 2.0;
    double lim_h = fmin(h0, dst.size.height) - 2.0;
    if (lim_w < 0.0) lim_w = 0.0;
    if (lim_h < 0.0) lim_h = 0.0;
    if (bl + br > lim_w && bl + br > 0.0) {
        double s = lim_w / (bl + br); bl *= s; br *= s;
    }
    if (bt + bb > lim_h && bt + bb > 0.0) {
        double s = lim_h / (bt + bb); bt *= s; bb *= s;
    }

    double sxs[4] = { 0.0, bl, w0 - br, w0 };
    double sys[4] = { 0.0, bt, h0 - bb, h0 };
    double dxs[4] = { dst.origin.x, dst.origin.x + bl,
                      dst.origin.x + dst.size.width - br,
                      dst.origin.x + dst.size.width };
    double dys[4] = { dst.origin.y, dst.origin.y + bt,
                      dst.origin.y + dst.size.height - bb,
                      dst.origin.y + dst.size.height };
    int idx = 0;
    for (int gy = 0; gy < 4; gy++) {
        for (int gx = 0; gx < 4; gx++) {
            out[idx++] = (float)sxs[gx];
            out[idx++] = (float)sys[gy];
            out[idx++] = (float)dxs[gx];
            out[idx++] = (float)dys[gy];
        }
    }
}

struct wm_proxy_cover_ctx {
    uint32_t wid, pwid;
    float alpha;
    float fade_s;
    CGRect dst;
    CGImageRef image;
    CGContextRef context;
};

static void *wm_proxy_cover_thread(void *data)
{
    struct wm_proxy_cover_ctx *ctx = data;

    // reveal order: restore the real window first (invisible — still under the proxy), then fade the proxy.
    uint64_t deadline = mach_absolute_time()
                      + (uint64_t)(WM_PROXY_COVER_SETTLE_CAP_S * g_cv_host_clock_frequency);
    for (;;) {
        CGRect real = {0};
        if (SLSGetWindowBounds(g_connection, ctx->wid, &real) == kCGErrorSuccess &&
            fabs(real.origin.x - ctx->dst.origin.x) <= WM_PROXY_COVER_SETTLE_PX &&
            fabs(real.origin.y - ctx->dst.origin.y) <= WM_PROXY_COVER_SETTLE_PX &&
            fabs(real.size.width  - ctx->dst.size.width)  <= WM_PROXY_COVER_SETTLE_PX &&
            fabs(real.size.height - ctx->dst.size.height) <= WM_PROXY_COVER_SETTLE_PX) break;
        if (mach_absolute_time() >= deadline) break;
        usleep(WM_PROXY_COVER_TICK_US);
    }
    scripting_addition_set_opacity(ctx->wid, ctx->alpha, 0.0f);
    scripting_addition_set_opacity(ctx->pwid, 0.0f, ctx->fade_s);

    usleep((useconds_t)((ctx->fade_s + 0.05f) * 1000000.0f));
    SLSReleaseWindow(g_connection, ctx->pwid);
    CGContextRelease(ctx->context);
    CFRelease(ctx->image);
    free(ctx);
    return NULL;
}

static void wm_proxy_cover_run(struct window *window, CGRect dst)
{
    uint32_t wid = window->id;

    float alpha = 1.0f;
    SLSGetWindowAlpha(g_connection, wid, &alpha);
    if (alpha < 0.01f) return;

    CGRect cur = {0};
    if (SLSGetWindowBounds(g_connection, wid, &cur) != kCGErrorSuccess ||
        cur.size.width <= 1.0 || cur.size.height <= 1.0) return;

    CFArrayRef image_array = SLSHWCaptureWindowList(g_connection, &wid, 1, (1 << 11) | (1 << 8));
    if (!image_array) return;                   // no TCC / no backing -> bare AX
    if (!CFArrayGetCount(image_array)) { CFRelease(image_array); return; }
    CGImageRef image = alpha == 1.0f
        ? (CGImageRef) CFRetain(CFArrayGetValueAtIndex(image_array, 0))
        : cgimage_restore_alpha((CGImageRef) CFArrayGetValueAtIndex(image_array, 0));
    CFRelease(image_array);
    if (!image) return;

    CFTypeRef frame_region;
    CGSNewRegionWithRect(&cur, &frame_region);
    CFTypeRef empty_region = CGRegionCreateEmptyRegion();
    uint64_t tags = 1ULL << 46;
    uint32_t pwid = 0;
    SLSNewWindowWithOpaqueShapeAndContext(g_connection, 2, frame_region, empty_region,
                                          13 | (1 << 18), &tags, 0, 0, 64, &pwid, NULL);
    CFRelease(frame_region);
    CFRelease(empty_region);
    if (!pwid) { CFRelease(image); return; }

    sls_window_disable_shadow(pwid);
    SLSSetWindowOpacity(g_connection, pwid, 0);
    SLSSetWindowBackgroundBlurRadius(g_connection, pwid, WM_PROXY_COVER_BLUR_R);
    SLSSetWindowResolution(g_connection, pwid, 2.0f);
    SLSSetWindowAlpha(g_connection, pwid, alpha);
    SLSSetWindowLevel(g_connection, pwid, window_level(wid));
    SLSSetWindowSubLevel(g_connection, pwid, window_sub_level(wid));
    CGContextRef context = SLWindowContextCreate(g_connection, pwid, 0);
    CGRect local = {{0, 0}, cur.size};
    CGContextClearRect(context, local);
    CGContextDrawImage(context, local, image);
    CGContextFlush(context);
    SLSOrderWindow(g_connection, pwid, 1, wid);

    scripting_addition_set_opacity(wid, 0.0f, 0.0f);
    float mesh[4 * 4 * 4];
    wm_warp_mesh_9slice(cur.size.width, cur.size.height, dst,
                        120.0, 24.0, 52.0, 24.0, mesh);
    SLSSetWindowWarp(g_connection, pwid, 4, 4, mesh);

    float fade_s = g_window_manager.window_animation_cover_fade;
    if (fade_s < 0.0f) fade_s = 0.0f;

    struct wm_proxy_cover_ctx *ctx = malloc(sizeof(struct wm_proxy_cover_ctx));
    ctx->wid = wid;
    ctx->pwid = pwid;
    ctx->alpha = alpha;
    ctx->fade_s = fade_s;
    ctx->dst = dst;
    ctx->image = image;
    ctx->context = context;
    pthread_t thread;
    pthread_create(&thread, NULL, wm_proxy_cover_thread, ctx);
    pthread_detach(thread);
}

// NOTE: the one AX commit path — apply and verify-retry must never drift in ordering.
static void wm_commit_frame_ax(struct window *window, CGRect frame)
{
    AX_ENHANCED_UI_WORKAROUND_CACHED(window->application,{
        CGPoint position = frame.origin;
        CFTypeRef position_ref = AXValueCreate(kAXValueTypeCGPoint, (void *) &position);

        CGSize size = frame.size;
        CFTypeRef size_ref = AXValueCreate(kAXValueTypeCGSize, (void *) &size);

        // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *before* moving it.
        if (size_ref) AXUIElementSetAttributeValue(window->ref, kAXSizeAttribute, size_ref);

        if (position_ref) {
            AXUIElementSetAttributeValue(window->ref, kAXPositionAttribute, position_ref);
            CFRelease(position_ref);
        }

        // NOTE(asmvik): Due to macOS constraints (visible screen-area), we might need to resize the window *after* moving it.
        if (size_ref) {
            AXUIElementSetAttributeValue(window->ref, kAXSizeAttribute, size_ref);
            CFRelease(size_ref);
        }
    });
}

static inline bool wm_rect_close(CGRect a, CGRect b, float eps)
{
    return fabsf((float)a.origin.x    - (float)b.origin.x)    <= eps &&
           fabsf((float)a.origin.y    - (float)b.origin.y)    <= eps &&
           fabsf((float)a.size.width  - (float)b.size.width)  <= eps &&
           fabsf((float)a.size.height - (float)b.size.height) <= eps;
}

// NOTE: macOS can clamp a single-shot resize->move (min-size, on-screen,
// display-seam refusal) with no second chance — re-fire the SAME commit until
// landed/plateau/cap. Main queue only; re-resolve the window by wid each tick.
#define WM_VERIFY_TICK_MS   16
#define WM_VERIFY_MAX_RETRY 3
#define WM_VERIFY_TOL       2.0f

struct wm_verify_ctx {
    uint32_t wid;
    CGRect   want;
    CGRect   prev;
    int      attempt;
    bool     have_prev;
};

static void wm_verify_tick(struct wm_verify_ctx *c)
{
    CGRect after = {0};
    if (SLSGetWindowBounds(g_connection, c->wid, &after) != kCGErrorSuccess) {
        free(c); return;
    }
    if (wm_rect_close(after, c->want, WM_VERIFY_TOL)) {
        free(c); return;
    }
    if (c->have_prev && wm_rect_close(after, c->prev, WM_VERIFY_TOL)) {
        free(c); return;
    }
    if (c->attempt >= WM_VERIFY_MAX_RETRY) {
        free(c); return;
    }

    struct window *w = window_manager_find_window(&g_window_manager, c->wid);
    if (!w) { free(c); return; }

    wm_commit_frame_ax(w, c->want);
    c->prev = after;
    c->have_prev = true;
    c->attempt++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WM_VERIFY_TICK_MS * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ wm_verify_tick(c); });
}

static void window_manager_arm_frame_verify(uint32_t wid, CGRect before, CGRect want)
{
    if (wm_rect_close(before, want, WM_VERIFY_TOL)) return;
    struct wm_verify_ctx *c = malloc(sizeof(*c));
    if (!c) return;
    c->wid = wid; c->want = want; c->prev = (CGRect){0};
    c->attempt = 0; c->have_prev = false;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(WM_VERIFY_TICK_MS * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ wm_verify_tick(c); });
}

void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height)
{
    //
    // NOTE(asmvik): Attempting to check the window frame cache to prevent unnecessary movement and resize calls to the AX API
    // is not reliable because it is possible to perform operations that should be applied, at a higher rate than the AX API events
    // are received, causing our cache to become out of date and incorrectly guard against some changes that **should** be applied.
    // This causes the window layout to **not** be modified the way we expect.
    //
    // A possible solution is to use the faster CG window notifications, as they are **a lot** more responsive, and can be used to
    // track changes to the window frame in real-time without delay.
    //

    if (g_window_manager.window_animation_warp_cover != WM_WARP_COVER_OFF &&
        g_window_manager.window_animation_duration == 0.0f) {
        CGRect dst = CGRectMake(x, y, width, height);
        CGRect cur = {0};
        if (SLSGetWindowBounds(g_connection, window->id, &cur) == kCGErrorSuccess &&
            (fabs(cur.origin.x - x) > 2.0f || fabs(cur.origin.y - y) > 2.0f ||
             fabs(cur.size.width - width) > 2.0f || fabs(cur.size.height - height) > 2.0f)) {
            // arm is_animating BEFORE the cover so the first MOVED/RESIZED can't re-flush BSP mid-cover.
            window_manager_ca_anim_register(window->id,
                mach_absolute_time() + (uint64_t)(0.600f * g_cv_host_clock_frequency));
            if (g_window_manager.window_animation_warp_cover == WM_WARP_COVER_LB_WARP) {
                // blocking send — the cover is applied before the AX fire can race it; an
                // armless SA silently no-ops to bare AX.
                scripting_addition_warp_snap(window->id, dst, 0, false,
                    (uint32_t)fmaxf(0.0f, g_window_manager.window_animation_warp_min_ms));
            } else {
                wm_proxy_cover_run(window, dst);
            }

            // a retile fires no WINDOW_FOCUSED — snap the ring to dst with the cover
            // (focused window only; painted pre-commit to match the proxy).
            if (window->id == g_window_manager.focused_window_id) {
                focus_ring_show_for_wid_rect(window->id, dst);
            }
        }
    }

    CGRect want = CGRectMake(x, y, width, height);
    CGRect ax_before = {0};
    bool have_before = g_window_manager.window_frame_verify_retry &&
                       SLSGetWindowBounds(g_connection, window->id, &ax_before) == kCGErrorSuccess;

    wm_commit_frame_ax(window, want);

    if (have_before) window_manager_arm_frame_verify(window->id, ax_before, want);
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
    if (window->layer != LAYER_AUTO) return;

    scripting_addition_set_layer(window->id, layer);
}

bool window_manager_set_window_layer(struct window *window, int layer)
{
    int parent_layer = layer;
    int child_layer = layer;

    if (layer == LAYER_AUTO) {
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

    return window_manager_find_window(wm, closest->window_order[0]);
}

static inline int direction_opposite(int direction)
{
    switch (direction) {
    case DIR_NORTH: return DIR_SOUTH;
    case DIR_EAST:  return DIR_WEST;
    case DIR_SOUTH: return DIR_NORTH;
    case DIR_WEST:  return DIR_EAST;
    }

    return direction;
}

static struct window *window_manager_find_window_in_direction_on_space(struct window_manager *wm, struct window *window, uint64_t sid, int direction, bool farthest, int *best_distance_out)
{
    int window_count;
    uint32_t *window_list = space_window_list(sid, &window_count, false);
    if (!window_list) return NULL;

    struct area source_area = area_from_cgrect(window->frame);
    CGPoint source_area_max = area_max_point(source_area);

    int best_distance = farthest ? INT_MIN : INT_MAX;
    int best_rank = INT_MAX;
    struct window *best_window = NULL;

    for (int i = 0; i < window_count; ++i) {
        if (window_list[i] == window->id) continue;

        struct window *target = window_manager_find_window(wm, window_list[i]);
        if (!target || !target->is_eligible) continue;

        struct area target_area = area_from_cgrect(target->frame);
        CGPoint target_area_max = area_max_point(target_area);
        if (area_is_in_direction(&source_area, source_area_max, &target_area, target_area_max, direction)) {
            int distance = area_distance_in_direction(&source_area, source_area_max, &target_area, target_area_max, direction);
            bool better = farthest ? distance > best_distance : distance < best_distance;
            if (better || (distance == best_distance && i < best_rank)) {
                best_window = target;
                best_distance = distance;
                best_rank = i;
            }
        }
    }

    if (best_window && best_distance_out) *best_distance_out = best_distance;

    return best_window;
}

struct window *window_manager_find_closest_window_in_direction(struct window_manager *wm, struct window *window, int direction)
{
    struct window *closest = window_manager_find_closest_managed_window_in_direction(wm, window, direction);
    if (closest) return closest;

    if (wm->window_focus_for_floating_enabled) {
        closest = window_manager_find_window_in_direction_on_space(wm, window, window_space(window->id), direction, false, NULL);
        if (closest) return closest;
    }

    if (wm->window_focus_inter_display) {
        uint32_t source_did = window_display_id(window->id);
        uint32_t target_did = source_did ? display_manager_find_closest_display_in_direction(source_did, direction) : 0;
        if (target_did) {
            closest = window_manager_find_window_in_direction_on_space(wm, window, display_space_id(target_did), direction, false, NULL);
            if (closest) return closest;
        }
    }

    if (wm->window_focus_wrap) {
        int opposite = direction_opposite(direction);

        if (!wm->window_focus_inter_display) {
            return window_manager_find_window_in_direction_on_space(wm, window, window_space(window->id), opposite, true, NULL);
        }

        int display_count;
        uint32_t *display_list = display_manager_active_display_list(&display_count);
        if (!display_list) return NULL;

        int best_distance = INT_MIN;
        struct window *best_window = NULL;

        for (int i = 0; i < display_count; ++i) {
            int distance;
            struct window *candidate = window_manager_find_window_in_direction_on_space(wm, window, display_space_id(display_list[i]), opposite, true, &distance);
            if (candidate && distance > best_distance) {
                best_window = candidate;
                best_distance = distance;
            }
        }

        return best_window;
    }

    return NULL;
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

    struct window_node *grandparent = node->parent->parent;
    if (!grandparent) return NULL;

    struct window_node *uncle_node = window_node_is_left_child(node->parent) ? grandparent->right : grandparent->left;
    if (window_node_is_leaf(uncle_node) || !window_node_is_leaf(uncle_node->right)) return NULL;

    return window_manager_find_window(wm, uncle_node->right->window_order[0]);
}

static void window_manager_make_key_window(ProcessSerialNumber *window_psn, uint32_t window_id)
{
    //
    // :SynthesizedEvent
    //
    // NOTE(asmvik): These events will be picked up by an event-tap
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

    if (psn_equals(window_psn, &g_window_manager.focused_window_psn)) {
        memset(g_event_bytes, 0, 0xf8);
        g_event_bytes[0x04] = 0xf8;
        g_event_bytes[0x08] = 0x0d;

        g_event_bytes[0x8a] = 0x02;
        memcpy(g_event_bytes + 0x3c, &g_window_manager.focused_window_id, sizeof(uint32_t));
        SLPSPostEventRecordTo(&g_window_manager.focused_window_psn, g_event_bytes);

        //
        // @hack
        // Artificially delay the activation by 40ms. This is necessary
        // because some applications appear to be confused if both of
        // the events appear instantaneously.
        //

        usleep(40000);

        g_event_bytes[0x8a] = 0x01;
        memcpy(g_event_bytes + 0x3c, &window_id, sizeof(uint32_t));
        SLPSPostEventRecordTo(window_psn, g_event_bytes);
    }

    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
}

void window_manager_focus_window_with_raise(ProcessSerialNumber *window_psn, uint32_t window_id, AXUIElementRef window_ref)
{
    TIME_FUNCTION;

    _SLPSSetFrontProcessWithOptions(window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(window_psn, window_id);
    AXUIElementPerformAction(window_ref, kAXRaiseAction);
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

    // NOTE: sid must come straight from SLS — space_manager_active_space()
    // resolves through this very function (unbounded recursion). The AX read lags
    // focus churn and can answer cross-space; it stays fallback-only.
    uint32_t window_id = 0;
    if (application->connection) {
        window_id = space_query_focused_wid(SLSGetActiveSpace(g_connection), application->connection,
                                            WQ_TAG_NORMAL,
                                            WQ_TAG_STICKY | WQ_TAG_HIDDEN | WQ_TAG_MINIMIZED);
    }
    if (!window_id) window_id = application_focused_window(application);
    return window_manager_find_window(wm, window_id);
}

// Topmost focus-candidate on `sid` for connection `owner` (0 = any process).
// NOTE: minimized windows still enumerate on their origin space — hence the
// server-side sticky/hidden/minimized exclusion.
static uint32_t space_window_for_owner(uint64_t sid, int owner)
{
    if (!sid) return 0;
    return space_query_focused_wid(sid, owner, WQ_TAG_NORMAL,
                                   WQ_TAG_STICKY | WQ_TAG_HIDDEN | WQ_TAG_MINIMIZED);
}

static int window_manager_connection_for_psn(struct window_manager *wm, ProcessSerialNumber *psn)
{
    pid_t pid = 0;
    GetProcessPID(psn, &pid);
    struct application *application = window_manager_find_application(wm, pid);
    return (application && application->connection) ? application->connection : 0;
}

uint32_t window_manager_space_front_window(struct window_manager *wm, uint64_t sid)
{
    ProcessSerialNumber psn = {0};
    _SLPSGetFrontProcess(&psn);
    int cid = window_manager_connection_for_psn(wm, &psn);
    return cid ? space_window_for_owner(sid, cid) : 0;
}

uint32_t window_manager_space_key_focus_window(struct window_manager *wm, uint64_t sid)
{
    ProcessSerialNumber psn = {0};
    uint8_t fallback = 0;
    SLPSGetKeyFocusProcess(&psn, &fallback);
    // fallback==1 = no real key holder (degrades to the front answer); not branched on yet.
    (void) fallback;
    int cid = window_manager_connection_for_psn(wm, &psn);
    return cid ? space_window_for_owner(sid, cid) : 0;
}

// Pure state stamp of a GIVEN wid into the tracked focus state:
// no side effects — no center-mouse, no opacity swap, no per-space recall write, no
// signal push, no ring call. Factored out of the resolver below so the native-tab
// follow (SLS_WINDOW_CREATED, event_loop.c) can stamp the re-materialized tab wid
// DIRECTLY — key focus can't be re-resolved for an AX-silent tab switch (it fires
// no 815), so the 1325 wid is the only truth.
//
// 0 IS the defocus signal (desktop / no key holder) — stamped, not skipped. Key
// focus can express "nothing focused"; topmost-z never could.
//
// Why 808 must NOT reach here (load-bearing): 808 precedes the AX WINDOW_FOCUSED on
// every daemon-directed raise (`window --focus east`). Pre-stamping focused_window_id
// there makes window_did_receive_focus's change gate (event_loop.c) see "no change"
// and skip window_manager_center_mouse — a deterministic mff regression. Only the
// 815/816 visibility-TRANSITION settle sites (and SPACE_CHANGED commit / front-switch
// defocus) call this; plain raises of already-visible windows emit no 815, so the AX
// edge stays intact. The residual race is covered by last_centered_wid in the funnel.
//
// Thread contract: event-loop thread ONLY — same thread as every other
// focused_window_id write (window_did_receive_focus, SPACE_CHANGED, front-switch).
//
// PSN stamped only for tracked wids (raw SLS tab wids carry none; keeping the
// old PSN beats inventing one — the consumer compares PSNs, never dereferences).
void window_manager_stamp_focused_window(struct window_manager *wm, uint32_t wid)
{
    if (wid != wm->focused_window_id) {
        wm->last_window_id = wm->focused_window_id;
        wm->focused_window_id = wid;
    }

    if (wid) {
        // Never zero the display anchor on a 0 resolve — DISPLAY_CHANGED and the
        // MOUSE_DOWN geometry pre-stamp own the no-window case.
        wm->focused_display_id = window_display_id(wid);
        struct window *window = window_manager_find_window(wm, wid);
        if (window) wm->focused_window_psn = window->application->psn;
    }
}

uint32_t window_manager_update_focused_window(struct window_manager *wm, uint64_t sid)
{
    uint32_t wid = window_manager_space_key_focus_window(wm, sid);
    if (wid != wm->focused_window_id)
        debug("%s: sid=%lld wid=%d (was %d)\n", __FUNCTION__, (long long) sid, wid, wm->focused_window_id);
    window_manager_stamp_focused_window(wm, wid);
    return wid;
}

bool window_manager_is_tab_window(struct window_manager *wm, uint32_t wid)
{
    return wid && table_find(&wm->tab_window, &wid) != NULL;
}

// true only if NEWLY added (false = re-materialize/switch or invalid).
bool window_manager_add_tab_window(struct window_manager *wm, uint32_t wid)
{
    if (!wid || table_find(&wm->tab_window, &wid)) return false;
    table_add(&wm->tab_window, &wid, (void *)(uintptr_t) wid);
    return true;
}

bool window_manager_remove_tab_window(struct window_manager *wm, uint32_t wid)
{
    if (!wid || !table_find(&wm->tab_window, &wid)) return false;
    table_remove(&wm->tab_window, &wid);
    return true;
}

// A tab hidden at daemon start is AX-invisible (absent from kAXWindowsAttribute)
// and seed-subscribed only, so it emits no AX move/resize; on selection it
// re-enters the window list and window_observe can attach (which may lag a cold
// switch, so the caller retries). Returns true on adopt so the caller can rebuild
// notifications — update_window_notifications is static in its TU, unreachable here.
bool window_manager_adopt_tab_window(struct space_manager *sm, struct window_manager *wm, uint32_t wid)
{
    if (!wid) return false;
    if (window_manager_find_window(wm, wid)) return false;
    if (!window_manager_is_tab_window(wm, wid)) return false;

    int owner = 0; SLSGetWindowOwner(g_connection, wid, &owner);
    if (!owner) return false;
    pid_t pid = 0; SLSConnectionGetPID(owner, &pid);
    if (!pid) return false;

    struct application *application = window_manager_find_application(wm, pid);
    if (!application) return false;

    CFArrayRef window_list = application_window_list(application);
    if (!window_list) return false;

    bool adopted = false;
    int window_count = CFArrayGetCount(window_list);
    for (int i = 0; i < window_count; ++i) {
        AXUIElementRef window_ref = CFArrayGetValueAtIndex(window_list, i);
        if (ax_window_id(window_ref) != wid) continue;
        if (window_manager_create_and_add_window(sm, wm, application, CFRetain(window_ref), wid, false)) {
            window_manager_remove_tab_window(wm, wid);
            adopted = true;
        }
        break;
    }

    CFRelease(window_list);
    return adopted;
}

// NOTE: space_list_options=0x0 reaches ordered-out, no-space tabs that AX and
// the space-scoped list can't see; owner-scoped. The next
// update_window_notifications() subscribes what we add.
void window_manager_seed_tab_windows(struct window_manager *wm, struct application *application)
{
    if (!application || !application->connection) return;

    struct window_query_filter filter = {
        .owner = application->connection,
        .spaces = NULL,
        .space_count = 0,
        .space_list_options = 0x0,
        .window_list_options = 0x7,
        .query_flags = 0x5,
        .include_tags = 0,
        .exclude_tags = 0,
    };

    CFTypeRef iterator = window_query_run(g_connection, &filter);
    if (!iterator) return;

    int added = 0;
    while (SLSWindowIteratorAdvance(iterator)) {
        uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
        if (!wid) continue;
        if (window_manager_find_window(wm, wid)) continue;
        if (SLSWindowIteratorGetLevel(iterator) != 0) continue;

        // content windows carry tag bits 56+57; menubar strips / aux windows never do.
        // Bit semantics unverified — the clean separation is the load-bearing fact.
        uint64_t tags = SLSWindowIteratorGetTags(iterator);
        if ((tags & 0x0300000000000000ULL) != 0x0300000000000000ULL) continue;

        if (window_manager_add_tab_window(wm, wid)) {
            ++added;
            CFStringRef t = SLSWindowIteratorCopyTitle(iterator);
            char title[128] = {0};
            if (t) { CFStringGetCString(t, title, sizeof(title), kCFStringEncodingUTF8); CFRelease(t); }
            debug("%s: %s +tab wid=%d title=\"%s\"\n", __FUNCTION__, application->name, wid, title);
        }
    }
    CFRelease(iterator);

    if (added) debug("%s: %s seeded %d tab window(s)\n", __FUNCTION__, application->name, added);
}

// z-topmost normal window, any owner — the 808 reconcile re-resolves with this
// instead of trusting the 808 payload wid (usually a demoted sibling).
uint32_t window_manager_space_topmost_window(struct window_manager *wm, uint64_t sid)
{
    (void) wm;
    return space_window_for_owner(sid, 0);
}

uint32_t window_manager_space_next_to_front_window(struct window_manager *wm, uint64_t sid)
{
    ProcessSerialNumber psn = {0};
    SLPSGetNextToFrontProcess(&psn);
    int cid = window_manager_connection_for_psn(wm, &psn);
    return cid ? space_window_for_owner(sid, cid) : 0;
}

// "does the app still hold a window on sid" — the destroy-time focus-advance gate.
uint32_t window_manager_space_application_window(struct window_manager *wm, struct application *application, uint64_t sid)
{
    (void) wm;
    if (!application || !application->connection) return 0;
    return space_window_for_owner(sid, application->connection);
}

// NOTE: iterates rather than taking row[0] so an untracked topmost window
// can't shadow a tracked one beneath it. Mask matches space_window_for_owner.
struct window *window_manager_space_topmost_tracked_window(struct window_manager *wm, uint64_t sid, uint32_t filter_wid)
{
    if (!sid) return NULL;

    struct window_query_filter filter = {
        .owner = 0,
        .spaces = &sid,
        .space_count = 1,
        .window_list_options = 0x2,
        .query_flags = 0x2,
        .include_tags = WQ_TAG_NORMAL,
        .exclude_tags = WQ_TAG_STICKY | WQ_TAG_HIDDEN | WQ_TAG_MINIMIZED,
    };

    CFTypeRef iterator = window_query_run(g_connection, &filter);
    if (!iterator) return NULL;

    struct window *result = NULL;
    while (SLSWindowIteratorAdvance(iterator)) {
        uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
        if (wid == filter_wid) continue;
        struct window *window = window_manager_find_window(wm, wid);
        if (window) { result = window; break; }
    }
    CFRelease(iterator);
    return result;
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
    // NOTE(asmvik): Attempt to track **all** windows.
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
    // NOTE(asmvik): However, only **root windows** are eligible for management.
    //

    if (window->is_root) {

        //
        // NOTE(asmvik): A lot of windows misreport their accessibility role, so we allow the user
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
            // NOTE(asmvik): Print window information when debug_output is enabled.
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
        // NOTE(asmvik): Print window information when debug_output is enabled.
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
        // NOTE(asmvik): display_space_list(..) uses a linear allocator,
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
        // NOTE(asmvik): The AX API appears to always include a single element for Finder that returns an empty window id.
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
                // NOTE(asmvik): MacOS API does not return AXUIElementRef of windows on inactive spaces.
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

    struct area area = a_node->zoom ? a_node->zoom->area : a_node->area;
    window_manager_animate_window((struct window_capture) { .window = b, .x = area.x, .y = area.y, .w = area.w, .h = area.h });
    return WINDOW_OP_ERROR_SUCCESS;
}

enum window_op_error window_manager_warp_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b)
{
    TIME_FUNCTION;

    if (a->id == b->id) return WINDOW_OP_ERROR_SAME_WINDOW;

    uint64_t a_sid = window_space(a->id);
    struct view *a_view = space_manager_find_view(sm, a_sid);
    if (a_view->layout != VIEW_BSP) return WINDOW_OP_ERROR_INVALID_SRC_VIEW;

    uint64_t b_sid = window_space(b->id);
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
            window_manager_remove_managed_window(wm, a->id);
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
            // NOTE(asmvik): Precalculate both target areas and select the one that has the closest distance to the source area.
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
            // TODO(asmvik): Warp operations with operands that belong to different monitors does not yet implement a heuristic to select
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

#define WM_DISPLAY_LANDING_MARGIN 20

enum wm_entry_edge { WM_EDGE_LEFT, WM_EDGE_RIGHT, WM_EDGE_TOP, WM_EDGE_BOTTOM };

// derived from display geometry (not the parsed keyword); macOS +y is down.
static enum wm_entry_edge window_manager_entry_edge(uint32_t src_did, uint32_t dst_did)
{
    CGRect s = CGDisplayBounds(src_did);
    CGRect d = CGDisplayBounds(dst_did);
    float dx = (d.origin.x + d.size.width  * 0.5f) - (s.origin.x + s.size.width  * 0.5f);
    float dy = (d.origin.y + d.size.height * 0.5f) - (s.origin.y + s.size.height * 0.5f);
    if (fabsf(dx) >= fabsf(dy)) {
        return (dx >= 0.0f) ? WM_EDGE_LEFT
                            : WM_EDGE_RIGHT;
    }
    return (dy >= 0.0f) ? WM_EDGE_TOP
                        : WM_EDGE_BOTTOM;
}

static CGRect window_manager_edge_landing_frame(uint32_t dst_did, enum wm_entry_edge edge, CGRect cur)
{
    CGRect u = display_bounds_constrained(dst_did, false);
    float m = (float)WM_DISPLAY_LANDING_MARGIN;
    float w = cur.size.width, h = cur.size.height;
    if (w > u.size.width  - 2.0f * m) w = u.size.width  - 2.0f * m;
    if (h > u.size.height - 2.0f * m) h = u.size.height - 2.0f * m;

    float x = cur.origin.x;
    float y = cur.origin.y;
    switch (edge) {
    case WM_EDGE_LEFT:   x = u.origin.x + m;                       break;
    case WM_EDGE_RIGHT:  x = u.origin.x + u.size.width  - w - m;   break;
    case WM_EDGE_TOP:    y = u.origin.y + m;                       break;
    case WM_EDGE_BOTTOM: y = u.origin.y + u.size.height - h - m;   break;
    }

    float xmin = u.origin.x + m, xmax = u.origin.x + u.size.width  - w - m;
    float ymin = u.origin.y + m, ymax = u.origin.y + u.size.height - h - m;
    if (x < xmin) x = xmin;
    if (x > xmax) x = xmax;
    if (y < ymin) y = ymin;
    if (y > ymax) y = ymax;
    return (CGRect){ { x, y }, { w, h } };
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
    SLSSpaceSetFrontPSN(g_connection, dst_sid, window->application->psn);

    if (window_manager_should_manage_window(window)) {
        struct view *view = space_manager_tile_window_on_space(sm, window, dst_sid);
        window_manager_add_managed_window(wm, window, view);
    }
}

void window_manager_send_window_to_display(struct space_manager *sm, struct window_manager *wm, struct window *window, uint32_t dst_did, uint64_t dst_sid)
{
    TIME_FUNCTION;

    uint64_t src_sid = window_space(window->id);
    if (src_sid == dst_sid) return;

    uint32_t src_did = window_display_id(window->id);
    enum wm_entry_edge edge = window_manager_entry_edge(src_did, dst_did);

    // NOTE: no focus handoff to a source sibling (unlike send_window_to_space) —
    // the window stays visible + focused; the ring rides its glide.

    struct view *sview = window_manager_find_managed_window(wm, window);
    if (sview) {
        space_manager_untile_window(sview, window);
        window_manager_remove_managed_window(wm, window->id);
        window_manager_purify_window(wm, window);
    }

    struct view *dview = space_manager_find_view(sm, dst_sid);
    bool dst_tiles = window_manager_should_manage_window(window) && dview && dview->layout != VIEW_FLOAT;

    if (dst_tiles) {
        space_manager_move_window_to_space(dst_sid, window);
        SLSSpaceSetFrontPSN(g_connection, dst_sid, window->application->psn);
        struct view *v = space_manager_tile_window_on_space(sm, window, dst_sid);
        window_manager_add_managed_window(wm, window, v);
    } else {
        // float dst: animate straight from the current frame — no seed, no
        // pre-reassociation (macOS reassociates by geometry as it crosses).
        CGRect land = window_manager_edge_landing_frame(dst_did, edge, window->frame);
        window_manager_animate_window((struct window_capture){ .window = window,
            .x = land.origin.x, .y = land.origin.y, .w = land.size.width, .h = land.size.height });
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

    if (should_float) {
        struct view *view = window_manager_find_managed_window(wm, window);
        if (view) {
            space_manager_untile_window(view, window);
            window_manager_remove_managed_window(wm, window->id);
            window_manager_purify_window(wm, window);
        }
        window_set_flag(window, WINDOW_FLOAT);
    } else {
        window_clear_flag(window, WINDOW_FLOAT);

        if (!window_check_flag(window, WINDOW_STICKY)) {
            if ((window_manager_should_manage_window(window)) && (!window_manager_find_managed_window(wm, window))) {
                struct view *view = space_manager_tile_window_on_space(sm, window, space_manager_active_space());
                window_manager_add_managed_window(wm, window, view);
            }
        }
    }
}

void window_manager_make_window_sticky(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_sticky)
{
    TIME_FUNCTION;

    if (!window_manager_is_window_eligible(window)) return;

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
    }
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
        workspace_is_macos_sequoia() ||
        workspace_is_macos_tahoe()) {
        while (!space_is_user(space_manager_active_space())) {

            //
            // NOTE(asmvik): Window has exited native-fullscreen mode.
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
            // NOTE(asmvik): Window has exited native-fullscreen mode.
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
    // NOTE(asmvik): The window must become the focused window
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
    // NOTE(asmvik): We toggled the fullscreen attribute and must
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

    bool entering = !window_is_pip(window->id);

    scripting_addition_scale_window(window->id, bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height);

    // Pip is transform-only: the window's real frame never changes, so no 806/807
    // geometry event fires and the ring won't re-sync on its own.
    if (focus_ring_get_enabled() && focus_ring_get_target_wid() == window->id) {
        CGRect frame = {};
        SLSGetWindowBounds(g_connection, window->id, &frame);
        if (frame.size.width <= 0 || frame.size.height <= 0) return;

        CGRect ring_rect = frame;
        if (entering) {
            // keep in sync with do_window_scale's pip rect (payload side).
            int target_width  = bounds.size.width / 4;
            int target_height = target_width / (frame.size.width / frame.size.height);
            ring_rect = CGRectMake(bounds.origin.x + bounds.size.width - target_width,
                                   bounds.origin.y, target_width, target_height);
        }
        focus_ring_show_for_wid_rect(window->id, ring_rect);
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

    // TODO(asmvik): Both functions use the same underlying API and could be combined in a single function to reduce redundant work.
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
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
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
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
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
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
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
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
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
                if (view->layout != VIEW_FLOAT) {
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
    wm->focused_display_id = 0;
    wm->last_centered_wid = 0;
    wm->enable_mff = false;
    wm->enable_window_opacity = false;
    wm->menubar_opacity = 1.0f;
    wm->active_window_opacity = 1.0f;
    wm->normal_window_opacity = 1.0f;
    wm->window_opacity_duration = 0.0f;
    wm->window_frame_verify_retry = false;
    wm->window_animation_duration = 0.0f;
    wm->expose_animation_duration = -1.0f;
    wm->window_animation_easing = ease_out_circ_type;
    wm->window_animation_ax_wake = true;
    wm->window_animation_min_opacity = 1.0f;
    wm->window_animation_warp_cover = WM_WARP_COVER_OFF;
    wm->window_animation_cover_fade = 0.25f;
    wm->window_animation_warp_min_ms = 100.0f;
    wm->window_animation_policy = WM_ANIM_POLICY_TRUE_RESIZE;
    wm->space_animation_duration = 0.0f;
    wm->space_animation_background = true;
    wm->space_animation_fade       = false;
    wm->space_animation_fade_enter = true;
    wm->space_animation_fade_exit  = true;
    wm->space_animation_enter_delay = 0.0f;
    wm->space_animation_exit_delay  = 0.0f;
    wm->space_animation_fade_enter_delay = -1.0f;
    wm->space_animation_fade_exit_delay  = -1.0f;
    wm->space_animation_fade_enter_dur   = -1.0f;
    wm->space_animation_fade_exit_dur    = -1.0f;
    wm->contain_space_focus_per_display = true;
    wm->window_focus_for_floating_enabled = true;
    wm->window_focus_inter_display = false;
    wm->window_focus_wrap          = false;
    wm->space_focus_target_display = SPACE_FOCUS_TARGET_DISPLAY_DEFAULT;
    wm->last_focus_method = FOCUS_METHOD_KEYBOARD;
    wm->insert_feedback_color = rgba_color_from_hex(0xffd75f5f);

    table_init(&wm->application, 150, hash_wm, compare_wm);
    table_init(&wm->window, 150, hash_wm, compare_wm);
    table_init(&wm->managed_window, 150, hash_wm, compare_wm);
    table_init(&wm->window_lost_focused_event, 150, hash_wm, compare_wm);
    table_init(&wm->application_lost_front_switched_event, 150, hash_wm, compare_wm);
    table_init(&wm->insert_feedback, 150, hash_wm, compare_wm);
    table_init(&wm->app_constraints, 150, hash_wm, compare_wm);
    table_init(&wm->tab_window, 150, hash_wm, compare_wm);
}

// NOTE: role-1 desktop windows are WindowServer chrome — no AX presence.
// Track lightweight entries (NULL ref, is_eligible=false) so focus can target
// them. Idempotent; re-run on topology changes — a reconnect mints a NEW wid.
void window_manager_track_role_windows(struct window_manager *wm)
{
    pid_t finder_pid = 0;
    GetProcessPID(&g_process_manager.finder_psn, &finder_pid);
    if (!finder_pid) return;

    struct application *finder = window_manager_find_application(wm, finder_pid);
    if (!finder) return;

    int display_count = 0;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    for (int i = 0; i < display_count; ++i) {
        uint32_t role_wid = display_manager_resident_desktop_window(display_list[i], display_space_id(display_list[i]));
        if (!role_wid) continue;

        // evict from the tab set first: dual membership makes SLS_WINDOW_DESTROYED
        // early-return on the tab hit and leak the window-table entry.
        if (window_manager_remove_tab_window(wm, role_wid)) {
            debug("%s: evicted role-1 wid %u from the tab set\n", __FUNCTION__, role_wid);
        }

        if (window_manager_find_window(wm, role_wid)) continue;

        struct window *window = window_create(finder, NULL, role_wid);
        window->is_eligible = false;
        window_manager_add_window(wm, window);
        debug("%s: tracked role-1 desktop window %u (did=%u)\n",
              __FUNCTION__, role_wid, display_list[i]);
    }
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
                window_manager_seed_tab_windows(wm, application);
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

    window_manager_track_role_windows(wm);
}
