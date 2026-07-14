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

enum window_focus_method
{
    WINDOW_FOCUS_METHOD_AX,
    WINDOW_FOCUS_METHOD_SLS
};

static const char *window_focus_method_str[] =
{
    "ax",
    "sls"
};

struct scratchpad
{
    char *label;
    struct window *window;
};

// Per-pid cache of (min, max) SLS size constraints, populated from
// window_iterator_get_constraints at animator setup. AppKit's setContentMin/
// MaxSize publish to SLS has a ~250ms timer, so a freshly-created window's
// per-wid query can race the publish and come back empty; caching by pid lets
// sibling windows reuse a previously-observed pair.
struct app_size_constraints {
    CGSize min;
    CGSize max;
};

// WM-9 instant-placement cover modes (window_animation_warp_cover).
#define WM_WARP_COVER_OFF     0
#define WM_WARP_COVER_PROXY   1
#define WM_WARP_COVER_LB_WARP 2
static char *warp_cover_mode_str[] = {
    [WM_WARP_COVER_OFF]     = "off",
    [WM_WARP_COVER_PROXY]   = "proxy",
    [WM_WARP_COVER_LB_WARP] = "lb_warp",
};

// WM-9 animated-path presentation policy (window_animation_policy).
// true_resize = the production LB+T3D composition (no warp).
// lb_only     = real rows animate via LockedBounds ONLY — no T3D transform.
//               Crisp bounds-driven move+resize; app content reflows on the
//               app's own re-render (no transform stretch). Visual-only riders
//               keep their T3D_ONLY presentation (they have no LB/AX path), so
//               the transform is stripped per-row, never globally.
#define WM_ANIM_POLICY_TRUE_RESIZE 0
#define WM_ANIM_POLICY_LB_ONLY     1
static char *anim_policy_str[] = {
    [WM_ANIM_POLICY_TRUE_RESIZE] = "true_resize",
    [WM_ANIM_POLICY_LB_ONLY]     = "lb_only",
};

// Which display's space a *defaulted* `space --focus` (prev/next) walks.
enum space_focus_target_display_mode
{
    SPACE_FOCUS_TARGET_DISPLAY_DEFAULT,   // active/menubar display (stock behavior)
    SPACE_FOCUS_TARGET_DISPLAY_MOUSE,     // display under the live cursor
    SPACE_FOCUS_TARGET_DISPLAY_SMART,     // cursor display iff last focus was mouse-driven
};

static const char *space_focus_target_display_mode_str[] =
{
    "default",
    "mouse",
    "smart"
};

// Most recent input modality that drove a focus change. Used by the `smart`
// space_focus_target_display mode to arbitrate between the active display
// (keyboard) and the cursor's display (mouse). Defaults to keyboard.
enum focus_method
{
    FOCUS_METHOD_KEYBOARD,
    FOCUS_METHOD_MOUSE,
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
    // Per-pid SLS size-constraint cache. Key: pid_t (as uint32_t).
    // Value: struct app_size_constraints*.
    struct table app_constraints;
    // Untracked native-tab wids (AX-hidden, SLS-only). Held so their per-window
    // notification subscription survives update_window_notifications()'s full-list
    // rebuild; seed of the tab-group table. Key: wid. Value: (void*)(uintptr_t)wid.
    struct table tab_window;
    struct rule *rules;
    struct application **applications_to_refresh;
    uint32_t focused_window_id;
    ProcessSerialNumber focused_window_psn;
    // Authoritative focus-display anchor. The weak SLS arms
    // (refocus_ring) resolve the ring against THIS display's current space —
    // never the event window's own space — so z-order/visibility churn on
    // another display's visible space can't steal the ring. Stamped at every
    // real focus landing (window_did_receive_focus), click-synchronously from
    // MOUSE_DOWN geometry, on DISPLAY_CHANGED, and re-anchored by the 805
    // crossing arm when the focused window changes displays. 0 = unstamped.
    uint32_t focused_display_id;
    uint32_t last_window_id;
    // mff dedupe anchor: the last window window_did_receive_focus actually warped
    // the pointer to. Distinct from focused_window_id so a settle stamp
    // (window_manager_update_focused_window) that moves
    // focused_window_id ahead of the AX funnel can't suppress mouse-follows-focus.
    // Written only by the funnel.
    uint32_t last_centered_wid;
    bool enable_mff;
    enum ffm_mode ffm_mode;
    enum purify_mode purify_mode;
    enum window_origin_mode window_origin_mode;
    enum window_focus_method focus_method;
    bool enable_window_opacity;
    float menubar_opacity;
    float active_window_opacity;
    float normal_window_opacity;
    float window_opacity_duration;
    float window_animation_duration;
    // MC-5b: -[WVExpose animationDuration] override pushed to the Dock-side SA
    // (config expose_animation_duration). < 0 = native passthrough. Daemon holds
    // it only for read-back; the payload static is authoritative.
    float expose_animation_duration;
    int window_animation_easing;
    bool  window_animation_ax_wake;
    float window_animation_min_opacity;
    int   window_animation_warp_cover;  // WM_WARP_COVER_OFF | _PROXY | _LB_WARP
    float window_animation_cover_fade;  // proxy cover fade-out (s); 0 = hard reveal
    float window_animation_warp_min_ms; // lb_warp: mesh tween length (ms, ease-out expo); 0 = instant snap
    int   window_animation_policy;      // WM_ANIM_POLICY_TRUE_RESIZE | _LB_ONLY (duration>0 presentation recipe)
    bool window_frame_verify_retry;     // config window_frame_verify_retry (default OFF): after a terminal AX setFrame, poll SLS bounds and re-fire resize->move (bounded, tolerance-gated) until the window lands on target or plateaus — fixes single-shot (duration 0.0) grid moves that land "half way" when macOS clamps the move/resize.
    // Duration (s) of the payload space cross-fade/slide animator; 0 = off
    // (instant native switch). Drives `space --focus` for adjacent same-display
    // switches; the focus ring reads it to auto-time its fade against the slide.
    float space_animation_duration;
    // Wallpaper participation in the animated switch: on = each space's
    // wallpaper rides the slide with its windows, native-style (falls back to
    // a static backdrop when the two spaces share one picture window); off =
    // both wallpapers hold as a static, opaque backdrop behind the sliding
    // windows.
    bool space_animation_background;
    // Space-slide cross-fade levers (space_manager_focus_space_animated packs
    // these into the SPACE_FADE_* mask). Master gate + independent per-side
    // control: with the master on, fade the incoming and/or outgoing windows
    // over the slide; turn one side off for a one-sided fade (e.g. exit-only).
    // Master default off = pure slide.
    bool space_animation_fade;         // master: cross-fade windows during the slide (default off)
    bool space_animation_fade_enter;   // when fade on: fade the INCOMING space's windows in (default on)
    bool space_animation_fade_exit;    // when fade on: fade the OUTGOING space's windows out (default on)
    // Slide stagger (seconds): delay each space's window SLIDE start within the
    // switch, so the exit can lead and the enter trail (a geometric hand-off).
    // Offsets the Transform3D motion, NOT the fade. Bounded by the slide — the
    // motion is compressed into the time left after the delay; raise
    // space_animation_duration to give a big stagger room. 0 = slide with no delay.
    float space_animation_enter_delay;   // seconds before the incoming windows start sliding in
    float space_animation_exit_delay;    // seconds before the outgoing windows start sliding out
    // Fade sub-timeline (seconds): the cross-fade's OWN delay + duration per side,
    // decoupled from the slide. <0 delay / <=0 dur = auto (track the slide: delay =
    // the side's slide delay, duration = ramp to the slide end). Dial to time the
    // fade independently of the Transform3D motion.
    float space_animation_fade_enter_delay;   // incoming fade delay; <0 = auto
    float space_animation_fade_exit_delay;    // outgoing fade delay; <0 = auto
    float space_animation_fade_enter_dur;     // incoming fade duration; <=0 = auto
    float space_animation_fade_exit_dur;      // outgoing fade duration; <=0 = auto
    // Edge-of-display guard: nudge the active space back and stop (never cross
    // displays) when `space --focus next/prev` would leave this display. On/off.
    bool contain_space_focus_per_display;
    // Directional `window --focus DIR` fallbacks past the current space. Tier 2
    // (floating windows on the current space) is always on; these gate the rest.
    bool window_focus_inter_display;   // hop to a window on the display in that direction
    bool window_focus_wrap;            // no target in direction: wrap to the farthest opposite
    // Which display's space stack a *defaulted* `space --focus` prev/next walks.
    enum space_focus_target_display_mode space_focus_target_display;
    // Last focus modality (keyboard/mouse); feeds the `smart` gate above.
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
void window_manager_tile_window(struct window_manager *wm, struct window *window);
void window_manager_move_window(struct window *window, float x, float y);
void window_manager_resize_window(struct window *window, float width, float height);
enum window_op_error window_manager_adjust_window_ratio(struct window_manager *wm, struct window *window, int action, float ratio);
void window_manager_animate_window(struct window_capture capture);
void window_manager_animate_window_list(struct window_capture *window_list, int window_count);

// True while a LB+T3D animation is in flight for `wid` (CA animating-property
// protocol). Gates the BSP feedback flush so a flush can't start an animation
// that races a live one on the same wid.
bool window_manager_is_animating(uint32_t wid);
// True while a non-CA Transform3D writer (e.g. drag-follow) holds `wid`. Read
// via the exported 2D affine getter. Gates the flush alongside is_animating.
bool window_manager_window_is_transformed(uint32_t wid);

// Lever bits for window_manager_animate_windows_lockedbounds_t3d_async.
#define WM_T3D_USE_AX     (1u << 0)
#define WM_T3D_USE_LB     (1u << 1)
#define WM_T3D_USE_T3     (1u << 2)
#define WM_T3D_USE_ALPHA  (1u << 3)
#define WM_T3D_LB_FULL    (1u << 5)   // LB lerps full XYWH (else size-only at anchor_xy)
#define WM_T3D_T3_FULL    (1u << 6)   // T3 stage matrix scale+translate (else translate-only)
#define WM_T3D_ENDPIN     (1u << 7)   // origin-fixed resize; T3D carries the positional delta
#define WM_T3D_ENDPIN_RESIZE_ONLY (1u << 8) // with endpin, per-tick AX fire is resize-only
// (bits 4 and 9-13 retired)
// AX setFrame fire-decision modes (per-window, evaluated each callback).
#define WM_AX_TH_NONE 0
#define WM_AX_TH_PX   1
#define WM_AX_TH_PCT  2
static char *ax_threshold_mode_str[] = {
    [WM_AX_TH_NONE] = "none",
    [WM_AX_TH_PX]   = "px",
    [WM_AX_TH_PCT]  = "pct",
};
#define WM_AX_TH_MODE_COUNT 3

// Finalize mode for window_manager_animate_windows_lockedbounds_t3d_async.
// CLEAR (default — production resize): at t=1, clear LB and reset T3 to identity.
// LEAVE_TERMINAL: at t=1, leave LB + T3 at their last per-frame values.
enum wm_finalize_mode {
    WM_FINALIZE_CLEAR = 0,
    WM_FINALIZE_LEAVE_TERMINAL,
};
// Optional finalize callback: fired once per batch when every wid's animating
// property has cleared, or the death-safety expiry elapses. Runs on a background
// poll thread (synchronously on registration-failure paths) — dispatch_async
// non-trivial work. `wids` is dead after the callback returns — do not retain it;
// failure paths may pass wids=NULL, count=0.
typedef void (*wm_finalize_callback)(uint32_t *wids, int count, void *user_data);

// Returns true when the batch was handed to the SA (or there was nothing to
// do); false when the SA was unreachable — the caller must land the frames
// itself (instant set_window_frame), or the layout silently stalls.
bool window_manager_animate_windows_lockedbounds_t3d_async(struct window_capture *window_list, int window_count, uint32_t api_flags, float duration_override, int ax_th_mode, float ax_th_val, CGRect *start_override, uint32_t row_mode, enum wm_finalize_mode finalize_mode, wm_finalize_callback finalize_callback, void *finalize_user_data);
void window_manager_animate_window_ax_only_async(struct window *window, CGRect target, float ax_hz);
void window_manager_animate_set_window_frame(struct window *window, float x, float y, float width, float height);
void window_manager_animate_window_resize(struct window *window, CGRect start_frame, CGRect end_frame, float duration);
void window_manager_set_window_frame(struct window *window, float x, float y, float width, float height);
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
void window_manager_begin(struct space_manager *sm, struct window_manager *wm);
void window_manager_init(struct window_manager *wm);

#endif
