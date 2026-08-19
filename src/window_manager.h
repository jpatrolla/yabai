#ifndef WINDOW_MANAGER_H
#define WINDOW_MANAGER_H

#define kCPSAllWindows    0x100
#define kCPSUserGenerated 0x200
#define kCPSNoWindows     0x400

enum window_op_error
{
    WINDOW_OP_ERROR_SUCCESS,
    WINDOW_OP_ERROR_INVALID_SRC_VIEW,
    WINDOW_OP_ERROR_INVALID_SRC_NODE,
    WINDOW_OP_ERROR_INVALID_DST_VIEW,
    WINDOW_OP_ERROR_INVALID_DST_NODE,
    WINDOW_OP_ERROR_INVALID_OPERATION,
    WINDOW_OP_ERROR_SAME_WINDOW,
    WINDOW_OP_ERROR_CANT_MINIMIZE,
    WINDOW_OP_ERROR_ALREADY_MINIMIZED,
    WINDOW_OP_ERROR_MINIMIZE_FAILED,
    WINDOW_OP_ERROR_NOT_MINIMIZED,
    WINDOW_OP_ERROR_DEMINIMIZE_FAILED,
    WINDOW_OP_ERROR_MAX_STACK,
    WINDOW_OP_ERROR_SAME_STACK,
};

enum purify_mode
{
    PURIFY_DISABLED,
    PURIFY_MANAGED,
    PURIFY_ALWAYS
};

static const char *purify_mode_str[] =
{
    "on",
    "float",
    "off"
};

enum ffm_mode
{
    FFM_DISABLED,
    FFM_AUTOFOCUS,
    FFM_AUTORAISE
};

static const char *ffm_mode_str[] =
{
    "disabled",
    "autofocus",
    "autoraise"
};

enum window_origin_mode
{
    WINDOW_ORIGIN_DEFAULT,
    WINDOW_ORIGIN_FOCUSED,
    WINDOW_ORIGIN_CURSOR
};

static const char *window_origin_mode_str[] =
{
    "default",
    "focused",
    "cursor"
};

struct scratchpad
{
    char *label;
    struct window *window;
};

// Per-pid cache of (min, max) SLS size constraints: a freshly-created window's
// per-wid query can race AppKit's deferred publish and read empty.
struct app_size_constraints {
    CGSize min;
    CGSize max;
};

// NOTE: keyed by pid, never by wid -- WindowManager drops an app's connection at app
// exit, not at window close, so a closing window must not evict. conn is a hint the
// resident agent re-validates against the request's pid before it uses it.
struct wm_connection_hint {
    uint64_t conn;
    uint64_t stamp;
    uint32_t pid;
};

// NOTE: minted once by AppKit at window creation and never reissued, so this needs no
// expiry -- it is evicted when the window leaves yabai's table and at no other time.
// It also survives a WindowManager restart, because the string originates in the
// owning app, not in WM.
struct wm_window_ident {
    char uuid[64];
    uint32_t wid;
};

// TRUE_RESIZE = the LB+T3D composition; LB_ONLY = LockedBounds-only for real
// rows — riders keep T3D (the transform is stripped per-row, never globally).
#define WM_ANIM_POLICY_TRUE_RESIZE 0
#define WM_ANIM_POLICY_LB_ONLY     1
static char *anim_policy_str[] = {
    [WM_ANIM_POLICY_TRUE_RESIZE] = "true_resize",
    [WM_ANIM_POLICY_LB_ONLY]     = "lb_only",
};

enum space_focus_target_display_mode
{
    SPACE_FOCUS_TARGET_DISPLAY_DEFAULT,
    SPACE_FOCUS_TARGET_DISPLAY_MOUSE,
    SPACE_FOCUS_TARGET_DISPLAY_SMART,     // cursor display iff last focus was mouse-driven
};

static const char *space_focus_target_display_mode_str[] =
{
    "default",
    "mouse",
    "smart"
};

enum focus_method
{
    FOCUS_METHOD_KEYBOARD,
    FOCUS_METHOD_MOUSE,
};

enum window_state_class
{
    WINDOW_STATE_DEFAULT = 0,
    WINDOW_STATE_MANAGED,
    WINDOW_STATE_STACK,
    WINDOW_STATE_PARENT_ZOOM,
    WINDOW_STATE_FULLSCREEN_ZOOM,
    WINDOW_STATE_STICKY,
    WINDOW_STATE_PIP,
};

static const char *window_state_class_str[] =
{
    "default",
    "managed",
    "stack",
    "parent_zoom",
    "fullscreen_zoom",
    "sticky",
    "pip"
};

// A native tab group (one real NSWindow per tab). Membership is learned from
// AXFocusedTabChanged pairs, never from geometry; macOS exposes no group object on the
// CGS/SLS or WindowManager side to read it from. Members may have no struct window — an
// unselected tab is AX-invisible and lives only in wm->tab_window.
struct tab_group
{
    uint32_t id;
    uint32_t *members;
};

struct window_manager
{
    AXUIElementRef system_element;
    struct table application;
    struct table window;
    struct table managed_window;
    struct table window_lost_focused_event;
    struct table application_lost_front_switched_event;
    struct table insert_feedback;
    struct table app_constraints;   // pid_t -> struct app_size_constraints*
    // Key: pid_t (as uint32_t). Value: struct wm_connection_hint*. Only ever a cache --
    // an empty table costs a connection walk per request, never a wrong answer.
    struct table wm_connection;
    // Key: wid (uint32_t). Value: struct wm_window_ident*.
    struct table wm_window_uuid;
    // untracked native-tab wids (wid -> wid)
    struct table tab_window;
    // native-tab group identity, learned from AXFocusedTabChanged pairs.
    struct table tab_group;         // group id -> struct tab_group*
    struct table tab_group_of_wid;  // wid -> group id
    uint32_t tab_group_last_id;
    uint32_t tab_focused_wid;       // last wid AppKit named via AXFocusedTabChanged
    struct rule *rules;
    struct application **applications_to_refresh;
    uint32_t focused_window_id;
    bool disable_fullscreen_animation;

    // NOTE: armed by the instant native-fullscreen enter and consumed by the first
    // space-membership add that lands the window in a fullscreen container. The deadline
    // bounds it because a transition that never lands would otherwise leave it armed for
    // an unrelated add much later.
    uint32_t instant_fullscreen_wid;
    uint64_t instant_fullscreen_deadline;
    ProcessSerialNumber focused_window_psn;
    // NOTE: focus-display anchor the SLS refocus arms resolve against — never the
    // event window's own space, so churn elsewhere can't steal the ring. 0 = unstamped.
    uint32_t focused_display_id;
    uint32_t last_window_id;
    // NOTE: mff dedupe — last wid the AX funnel warped the pointer to. NOT
    // focused_window_id: settle stamps move that ahead of the funnel and would
    // suppress mouse-follows-focus.
    uint32_t last_centered_wid;
    bool enable_mff;
    enum ffm_mode ffm_mode;
    enum purify_mode purify_mode;
    enum window_origin_mode window_origin_mode;
    bool enable_window_opacity;
    float menubar_opacity;
    float active_window_opacity;
    float normal_window_opacity;
    float window_opacity_duration;
    float window_animation_duration;
    // expose duration override pushed to the SA; < 0 = native passthrough. Daemon
    // copy is read-back only — the payload static is authoritative.
    float expose_animation_duration;
    int window_animation_easing;
    bool  window_animation_ax_wake;
    float window_animation_min_opacity;
    int   window_animation_policy;
    bool window_frame_verify_retry;     // re-fire a clamped terminal setFrame until it lands (default off)
    float space_animation_duration;  // payload space-slide duration (s); 0 = off (instant native switch)
    // Gap (in points) inserted between adjacent spaces during the animated
    // cross-space slide. 0 = flush (no gap). Widens the per-index stride to
    // width+gap so a strip of background shows between spaces mid-slide; at
    // rest the current space sits flush at the display origin. See the slide
    // animator in src/osax/payload_inc/space_animation.inc.m.
    float space_animation_gap;
    bool space_animation_animate_wallpaper;   // on = each space's picture rides its own space transform; off = pictures stay blanked and the wallpaper floor shows through. Default off.
    int space_animation_easing;   // slide curve (enum focus_ring_easing); shipped per switch to payload_ease. Default ease_out_expo
    // One parked space per display holding a captured desktop picture, sunk to
    // absolute level -1. Reconciled from space_animation_animate_wallpaper; the
    // config command remains as a manual override. Machine-global state that
    // outlives the daemon, so every path that clears it must tear it down.
    bool wallpaper_floor;
    // slide stagger (s): offsets the T3D motion, compressed into the slide; 0 = none.
    float space_animation_enter_delay;
    float space_animation_exit_delay;
    // Edge-of-display guard: nudge the active space back and stop (never cross
    // displays) when `space --focus next/prev` would leave this display. On/off.
    bool contain_space_focus_per_display;
    bool window_focus_for_floating_enabled;
    bool window_focus_inter_display;
    bool window_focus_wrap;
    enum space_focus_target_display_mode space_focus_target_display;
    enum focus_method last_focus_method;
    struct rgba_color insert_feedback_color;
    struct scratchpad *scratchpad_window;
};

void window_manager_query_window_rules(FILE *rsp);
void window_manager_query_windows_for_spaces(FILE *rsp, uint64_t *space_list, int space_count, uint64_t flags);
void window_manager_query_windows_for_display(FILE *rsp, uint32_t did, uint64_t flags);
void window_manager_query_windows_for_displays(FILE *rsp, uint64_t flags);
bool window_manager_rule_matches_window(struct rule *rule, struct window *window, char *window_title, char *window_role, char *window_subrole);
void window_manager_apply_manage_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects);
void window_manager_apply_rule_effects_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, struct rule_effects *effects);
void window_manager_apply_manage_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules);
void window_manager_apply_rules_to_window(struct space_manager *sm, struct window_manager *wm, struct window *window, char *window_title, char *window_role, char *window_subrole, bool one_shot_rules);
void window_manager_center_mouse(struct window_manager *wm, struct window *window);
bool window_manager_is_window_eligible(struct window *window);
bool window_manager_should_manage_window(struct window *window);
uint8_t window_state_class(struct window_manager *wm, struct window *window);
bool window_flags_changed(struct window_manager *wm, struct window *window);
void window_manager_tile_window(struct window_manager *wm, struct window *window);
void window_manager_move_window(struct window *window, float x, float y);
void window_manager_resize_window(struct window *window, float width, float height);
enum window_op_error window_manager_adjust_window_ratio(struct window_manager *wm, struct window *window, int action, float ratio);
void window_manager_animate_window(struct window_capture capture);
void window_manager_animate_window_list(struct window_capture *window_list, int window_count);

// true while a LB+T3D animation is in flight for wid; gates the BSP feedback flush.
bool window_manager_is_animating(uint32_t wid);
bool window_manager_stepped_active(uint32_t wid);
// true while a non-CA transform writer (drag-follow) holds wid — invisible to is_animating.
bool window_manager_window_is_transformed(uint32_t wid);

#define WM_T3D_USE_AX     (1u << 0)
#define WM_T3D_USE_LB     (1u << 1)
#define WM_T3D_USE_T3     (1u << 2)
#define WM_T3D_USE_ALPHA  (1u << 3)
#define WM_T3D_LB_FULL    (1u << 5)   // LB lerps full XYWH (else size-only at anchor_xy)
#define WM_T3D_T3_FULL    (1u << 6)   // T3 stage matrix scale+translate (else translate-only)
#define WM_T3D_ENDPIN     (1u << 7)   // origin-fixed resize; T3D carries the positional delta
#define WM_T3D_ENDPIN_RESIZE_ONLY (1u << 8) // with endpin, per-tick AX fire is resize-only
// (bits 4 and 9-13 retired)
#define WM_AX_TH_NONE 0
#define WM_AX_TH_PX   1
#define WM_AX_TH_PCT  2
static char *ax_threshold_mode_str[] = {
    [WM_AX_TH_NONE] = "none",
    [WM_AX_TH_PX]   = "px",
    [WM_AX_TH_PCT]  = "pct",
};
#define WM_AX_TH_MODE_COUNT 3

enum wm_finalize_mode {
    WM_FINALIZE_CLEAR = 0,
    WM_FINALIZE_LEAVE_TERMINAL,
};
// NOTE: fires once per batch when every wid's animating property clears or the
// expiry elapses. Background poll thread (synchronous on failure paths) —
// dispatch_async non-trivial work. `wids` dies after return; may be NULL,0.
typedef void (*wm_finalize_callback)(uint32_t *wids, int count, void *user_data);

// NOTE: false = SA unreachable and NO animation is running — the caller must
// land the frames itself or the layout silently stalls.
bool window_manager_animate_windows_lockedbounds_t3d_async(struct window_capture *window_list, int window_count, uint32_t api_flags, float duration_override, int ax_th_mode, float ax_th_val, CGRect *start_override, uint32_t row_mode, enum wm_finalize_mode finalize_mode, wm_finalize_callback finalize_callback, void *finalize_user_data);
void window_manager_animate_window_ax_only_async(struct window *window, CGRect target, float ax_hz);
void window_manager_animate_window_stepped_async(struct window *window, CGRect target, float ax_hz);
void window_manager_animate_set_window_frame(struct window *window, float x, float y, float width, float height);
void window_manager_animate_window_resize(struct window *window, CGRect start_frame, CGRect end_frame, float duration);
void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height);
void window_manager_cache_wm_connection(struct window_manager *wm, pid_t pid, uint64_t conn);
bool window_manager_get_cached_wm_connection(struct window_manager *wm, pid_t pid, uint64_t *conn);
void window_manager_evict_wm_connection(struct window_manager *wm, pid_t pid);
void window_manager_flush_wm_connections(struct window_manager *wm);
void window_manager_cache_window_uuid(struct window_manager *wm, uint32_t wid, const char *uuid);
const char *window_manager_get_cached_window_uuid(struct window_manager *wm, uint32_t wid);
void window_manager_evict_window_uuid(struct window_manager *wm, uint32_t wid);
int window_manager_find_rank_of_window_in_list(uint32_t wid, uint32_t *window_list, int window_count);
struct window *window_manager_find_window_on_space_by_rank_filtering_window(struct window_manager *wm, uint64_t sid, int rank, uint32_t filter_wid);
struct window *window_manager_find_window_at_point_filtering_window(struct window_manager *wm, CGPoint point, uint32_t filter_wid);
struct window *window_manager_find_window_at_point(struct window_manager *wm, CGPoint point);
struct window *window_manager_find_window_below_cursor(struct window_manager *wm);
struct window *window_manager_find_closest_managed_window_in_direction(struct window_manager *wm, struct window *window, int direction);
struct window *window_manager_find_closest_window_in_direction(struct window_manager *wm, struct window *window, int direction);
struct window *window_manager_find_prev_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_next_managed_window(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_first_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_last_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_recent_managed_window(struct window_manager *wm);
struct window *window_manager_find_prev_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_next_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_first_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_last_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_recent_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window);
struct window *window_manager_find_window_in_stack(struct space_manager *sm, struct window_manager *wm, struct window *window, int index);
struct window *window_manager_find_largest_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_smallest_managed_window(struct space_manager *sm, struct window_manager *wm);
struct window *window_manager_find_sibling_for_managed_window(struct window_manager *wm, struct window *window);
struct window *window_manager_find_first_nephew_for_managed_window(struct window_manager *wm, struct window *window);
struct window *window_manager_find_second_nephew_for_managed_window(struct window_manager *wm, struct window *window);
struct window *window_manager_find_uncle_for_managed_window(struct window_manager *wm, struct window *window);
struct window *window_manager_find_first_cousin_for_managed_window(struct window_manager *wm, struct window *window);
struct window *window_manager_find_second_cousin_for_managed_window(struct window_manager *wm, struct window *window);
void window_manager_focus_window_without_raise(ProcessSerialNumber *window_psn, uint32_t window_id);
void window_manager_focus_window_with_raise(ProcessSerialNumber *window_psn, uint32_t window_id, AXUIElementRef window_ref);
struct window *window_manager_focused_window(struct window_manager *wm);
struct application *window_manager_focused_application(struct window_manager *wm);
uint32_t window_manager_space_front_window(struct window_manager *wm, uint64_t sid);
uint32_t window_manager_space_key_focus_window(struct window_manager *wm, uint64_t sid);
uint32_t window_manager_update_focused_window(struct window_manager *wm, uint64_t sid);
void window_manager_stamp_focused_window(struct window_manager *wm, uint32_t wid);
bool window_manager_is_tab_window(struct window_manager *wm, uint32_t wid);
bool window_manager_add_tab_window(struct window_manager *wm, uint32_t wid);
bool window_manager_remove_tab_window(struct window_manager *wm, uint32_t wid);
bool window_manager_adopt_tab_window(struct space_manager *sm, struct window_manager *wm, uint32_t wid);
void window_manager_seed_tab_windows(struct window_manager *wm, struct application *application);
uint32_t window_manager_space_topmost_window(struct window_manager *wm, uint64_t sid);
uint32_t window_manager_space_next_to_front_window(struct window_manager *wm, uint64_t sid);
uint32_t window_manager_space_application_window(struct window_manager *wm, struct application *application, uint64_t sid);
struct window *window_manager_space_topmost_tracked_window(struct window_manager *wm, uint64_t sid, uint32_t filter_wid);
struct view *window_manager_find_managed_window(struct window_manager *wm, struct window *window);
void window_manager_remove_managed_window(struct window_manager *wm, uint32_t wid);
void window_manager_add_managed_window(struct window_manager *wm, struct window *window, struct view *view);
bool window_manager_find_lost_front_switched_event(struct window_manager *wm, pid_t pid);
void window_manager_remove_lost_front_switched_event(struct window_manager *wm, pid_t pid);
void window_manager_add_lost_front_switched_event(struct window_manager *wm, pid_t pid);
bool window_manager_find_lost_focused_event(struct window_manager *wm, uint32_t window_id);
void window_manager_remove_lost_focused_event(struct window_manager *wm, uint32_t window_id);
void window_manager_add_lost_focused_event(struct window_manager *wm, uint32_t window_id);
struct window *window_manager_find_window(struct window_manager *wm, uint32_t window_id);
void window_manager_remove_window(struct window_manager *wm, uint32_t window_id);
void window_manager_add_window(struct window_manager *wm, struct window *window);
struct application *window_manager_find_application(struct window_manager *wm, pid_t pid);
void window_manager_remove_application(struct window_manager *wm, pid_t pid);
void window_manager_add_application(struct window_manager *wm, struct application *application);
struct window **window_manager_find_application_windows(struct window_manager *wm, struct application *application, int *window_count);
enum window_op_error window_manager_move_window_relative(struct window_manager *wm, struct window *window, int type, float dx, float dy);
void window_manager_resize_window_relative_internal(struct window *window, CGRect frame, int direction, float dx, float dy, bool animate);
enum window_op_error window_manager_resize_window_relative(struct window_manager *wm, struct window *window, int direction, float dx, float dy, bool animate);
void window_manager_set_purify_mode(struct window_manager *wm, enum purify_mode mode);
void window_manager_set_menubar_opacity(struct window_manager *wm, float opacity);
void window_manager_set_active_window_opacity(struct window_manager *wm, float opacity);
void window_manager_set_normal_window_opacity(struct window_manager *wm, float opacity);
void window_manager_set_window_opacity_enabled(struct window_manager *wm, bool enabled);
bool window_manager_set_opacity(struct window_manager *wm, struct window *window, float opacity);
void window_manager_set_window_opacity(struct window_manager *wm, struct window *window, float opacity);
void window_manager_set_focus_follows_mouse(struct window_manager *wm, enum ffm_mode mode);
enum window_op_error window_manager_set_window_insertion(struct space_manager *sm, struct window *window, int direction);
enum window_op_error window_manager_stack_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_warp_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_swap_window(struct space_manager *sm, struct window_manager *wm, struct window *a, struct window *b);
enum window_op_error window_manager_minimize_window(struct window *window);
enum window_op_error window_manager_deminimize_window(struct window *window);
bool window_manager_close_window(struct window *window);
void window_manager_send_window_to_space(struct space_manager *sm, struct window_manager *wm, struct window *window, uint64_t sid, bool moved_by_rule);
void window_manager_send_window_to_display(struct space_manager *sm, struct window_manager *wm, struct window *window, uint32_t dst_did, uint64_t dst_sid);
struct window *window_manager_create_and_add_window(struct space_manager *sm, struct window_manager *wm, struct application *application, AXUIElementRef window_ref, uint32_t window_id, bool one_shot_rules);
struct window **window_manager_add_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int *count);
bool window_manager_add_existing_application_windows(struct space_manager *sm, struct window_manager *wm, struct application *application, int refresh_index);
enum window_op_error window_manager_apply_grid(struct space_manager *sm, struct window_manager *wm, struct window *window, unsigned r, unsigned c, unsigned x, unsigned y, unsigned w, unsigned h);
void window_manager_purify_window(struct window_manager *wm, struct window *window);
void window_manager_make_window_floating(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_float, bool force);
void window_manager_make_window_sticky(struct space_manager *sm, struct window_manager *wm, struct window *window, bool should_sticky);
void window_manager_adjust_layer(struct window *window, int layer);
bool window_manager_set_window_layer(struct window *window, int layer);
void window_manager_toggle_window_shadow(struct window *window);
void window_manager_toggle_window_zoom_parent(struct window_manager *wm, struct window *window);
void window_manager_toggle_window_zoom_fullscreen(struct window_manager *wm, struct window *window);
void window_manager_toggle_window_windowed_fullscreen(struct window *window);
void window_manager_toggle_window_native_fullscreen(struct window *window);
bool window_manager_set_disable_fullscreen_animation(struct window_manager *wm, bool enabled);
void window_manager_instant_fullscreen_follow(uint32_t wid);
void window_manager_toggle_window_expose(struct window *window);
void window_manager_toggle_window_pip(struct space_manager *sm, struct window *window);
bool window_manager_toggle_scratchpad_window_by_label(struct window_manager *wm, char *label);
bool window_manager_toggle_scratchpad_window(struct window_manager *wm, struct window *window, int forced_mode);
bool window_manager_set_scratchpad_for_window(struct window_manager *wm, struct window *window, char *label);
bool window_manager_remove_scratchpad_for_window(struct window_manager *wm, struct window *window, bool unfloat);
void window_manager_scratchpad_recover_windows(void);
void window_manager_wait_for_native_fullscreen_transition(struct window *window);
void window_manager_validate_and_check_for_windows_on_space(struct space_manager *sm, struct window_manager *wm, uint64_t sid);
void window_manager_correct_for_mission_control_changes(struct space_manager *sm, struct window_manager *wm);
void window_manager_handle_display_add_and_remove(struct space_manager *sm, struct window_manager *wm, uint32_t did);
void window_manager_track_role_windows(struct window_manager *wm);
void window_manager_stamp_focused_window(struct window_manager *wm, uint32_t wid);
bool window_manager_is_tab_window(struct window_manager *wm, uint32_t wid);
bool window_manager_add_tab_window(struct window_manager *wm, uint32_t wid);
bool window_manager_remove_tab_window(struct window_manager *wm, uint32_t wid);
bool window_manager_adopt_tab_window(struct space_manager *sm, struct window_manager *wm, uint32_t wid);
void window_manager_demote_tab_window(struct window_manager *wm, struct window *window);
struct tab_group *window_manager_find_tab_group(struct window_manager *wm, uint32_t wid);
bool window_manager_tab_group_link(struct window_manager *wm, uint32_t a_wid, uint32_t b_wid);
int window_manager_tab_group_member_count(struct window_manager *wm, uint32_t wid);
bool window_manager_tab_group_prune(struct window_manager *wm, uint32_t wid);
bool window_manager_tab_group_unlink(struct window_manager *wm, uint32_t wid);
struct window *window_manager_tab_group_displaced_window(struct window_manager *wm, struct window *b);
struct window *window_manager_tab_group_torn_off(struct window_manager *wm, struct window *b);
bool window_manager_adopt_tab_group_members(struct space_manager *sm, struct window_manager *wm, struct window *dying);
struct window *window_manager_tab_group_heir(struct window_manager *wm, struct window *dying);
bool window_manager_tab_inherit_node(struct window_manager *wm, struct window *a, struct window *b);
bool window_manager_tab_take_over_node(struct window_manager *wm, struct window *a, struct window *b);
struct tab_hypothesis { uint32_t a_wid; uint32_t b_wid; };
void window_manager_tab_reconcile(struct window_manager *wm, struct tab_hypothesis *hints, int hint_count, uint32_t torn_wid, uint32_t reserved_wid);
void window_manager_seed_tab_windows(struct window_manager *wm, struct application *application);

void window_manager_begin(struct space_manager *sm, struct window_manager *wm);
void window_manager_init(struct window_manager *wm);
void window_manager_wallpaper_floor_sync(struct window_manager *wm);

#endif
