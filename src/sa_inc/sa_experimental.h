#ifndef SA_EXPERIMENTAL_H
#define SA_EXPERIMENTAL_H

// Non-upstream scripting_addition_* declarations + batch structs, tail-included
// from sa.h. NOTE: a new opcode touches four points — the define in osax/
// common_experimental.h, here, sa_experimental.inc.m, and payload_inc/dispatch_experimental.inc.m.

// NOTE: focus-ring wire is append-only — historical field names are kept for
// compat and no longer match daemon config keys; never reorder, only append.
// force_style=1 marks an explicit config change (clears the payload's
// color-override latch); `style` is a dead slot (payload ignores it).
// window_alpha rides the window's NORMAL alpha slot — visibility/fades own the
// SYSTEM slot. xray_rects append variable-length after the fixed struct.
bool scripting_addition_focus_ring_show(uint32_t wid, float x, float y, float w, float h, float radius, float stroke_width, float stroke_alpha, float stroke_r, float stroke_g, float stroke_b, bool force_style, int blur_radius, int style, float blur_saturation, float blur_brightness, int blend_mode, bool blur_stroke, int blur_stroke_position, float blur_stroke_width, float blur_bleed, float tint_r, float tint_g, float tint_b, float tint_a, float str_r, float str_g, float str_b, float str_a, float blur_contrast, float blur_feather, float fade_duration, float blur_hue, bool xray, float xray_r, float xray_g, float xray_b, float xray_a, int xray_count, CGRect *xray_rects, float window_alpha);
bool scripting_addition_focus_ring_hide(void);
// Animate the band to a target rect payload-side (agent-transport resizes have
// no per-frame follower). easing = enum animation_easing_type ordinal.
bool scripting_addition_focus_ring_retarget(uint32_t wid, float x, float y, float w, float h, float duration, int easing);
// Toggles overlay alpha 0/1 AND the payload-side cached `visible` flag in one
// opcode. Disabled => payload skips its own SLS-driven focus redraws.
bool scripting_addition_focus_ring_set_visible(bool visible);
// NOTE: fades alpha only — does not touch the master `visible` flag.
// fade_ms<=0 or no ring = instant.
bool scripting_addition_focus_ring_fade_visible(bool visible, int fade_ms, int easing);
// NOTE: dest_wid/rect/radius park a ring on the incoming focused window when no
// live pool entry exists to ride; dest_wid==0 = fall back to the existing entry.
bool scripting_addition_focus_ring_space_switch(uint64_t out_sid, uint64_t in_sid, int fade_ms, int easing,
                                                uint32_t dest_wid, CGRect dest_rect, float dest_radius);

// MC ring ride: arm the payload's MC-mode transform mirror on `wid` (payload resolves the
// base frame + reads the live CGSGetWindowTransform3D itself). _mc_ride = exit (fade in),
// _mc_enter_ride = enter (fade out then park hidden).
bool scripting_addition_focus_ring_mc_ride(uint32_t wid);
bool scripting_addition_focus_ring_mc_enter_ride(uint32_t wid);

bool scripting_addition_scale_window_custom(uint32_t wid, float tx, float ty, float tw, float th);
bool scripting_addition_animate_window_lockedbounds(uint32_t wid, float fade_duration, float cx, float cy, float cw, float ch, float min_opacity, float progress);
bool scripting_addition_clear_lockedbounds(uint32_t wid);
bool scripting_addition_set_border_lockedbounds(uint32_t border_wid, uint32_t clip_wid, float border_width, float x, float y, float w, float h);

#define SA_BATCH_LOCKEDBOUNDS_MAX 128
struct sa_lockedbounds_batch {
    uint32_t count;
    float fade_duration;
    struct {
        uint32_t wid;
        float x, y, w, h;
        float min_opacity;
        float progress;
    } windows[SA_BATCH_LOCKEDBOUNDS_MAX];
};

bool scripting_addition_batch_animate_with_lockedbounds(struct sa_lockedbounds_batch *batch);

// NOTE: applied from the Dock cid — the daemon's connection cannot transform
// cross-process wids.
#define SA_BATCH_TRANSFORM_MAX 128
struct sa_transform_batch {
    uint32_t count;
    struct {
        uint32_t wid;
        float a, b, c, d, tx, ty;
    } windows[SA_BATCH_TRANSFORM_MAX];
};
bool scripting_addition_batch_transform(struct sa_transform_batch *batch);

// NOTE: 132-byte rows — the cap keeps a full batch inside SA_SOCKET_BUFF_LEN;
// the client wrapper chunks larger batches.
#define SA_BATCH_TRANSFORM_3D_MAX 24
struct sa_transform_3d_batch {
    uint32_t count;
    struct {
        uint32_t wid;
        double   m[16];   // CATransform3D layout (row-major struct order)
    } windows[SA_BATCH_TRANSFORM_3D_MAX];
};
bool scripting_addition_batch_transform_3d(struct sa_transform_3d_batch *batch);

// NOTE: flag bits + per-row modes live in osax/common_experimental.h (shared
// with the payload); 56-byte rows — cap 64 stays inside SA_SOCKET_BUFF_LEN.
#define SA_BATCH_LOCKEDBOUNDS_T3D_MAX 64

struct sa_lockedbounds_t3d_batch {
    uint32_t count;
    uint32_t flags;
    float    fade_duration;
    struct {
        uint32_t wid;
        // per-row mask on the global flags (SA_T3D_ROW_MODE_*)
        uint32_t mode;
        // running anchor — where AX currently sits (advances per AX tick): LockedBounds
        // origin and the Transform3D natural rect
        float anchor_x, anchor_y;
        float anchor_w, anchor_h;  // needed for T3_FULL scale: xs = anchor_w/lerp_w
        float lerp_x, lerp_y;   // Current interpolated position (target this frame)
        float lerp_w, lerp_h;   // Current interpolated size
        float min_opacity;
        float progress;
        // SLS size constraints snapshotted daemon-side at animation start — the payload
        // clamps lerp_w/h to them and never queries; unconstrained = 0 / FLT_MAX.
        float min_w, min_h;
        float max_w, max_h;
    } windows[SA_BATCH_LOCKEDBOUNDS_T3D_MAX];
};
bool scripting_addition_batch_animate_with_lockedbounds_t3d(struct sa_lockedbounds_t3d_batch *batch);

// NOTE: hands the whole LB+T3D(+AX) animation to the payload CA pump (clock,
// lerp, easing, commit). SA_ANIM_AX_MAX is shared with the payload cap.

// NOTE: generated from the SA_ANIM_*_FIELDS X-macros in common_experimental.h —
// the same lists the packer and payload unpacker expand; add wire fields by
// editing the lists. Pile fields (and per-row depth) pack only under SA_T3D_FLAG_PILE.
struct sa_anim_ax_begin {
#define X(t, dn, pn) t dn;
    SA_ANIM_HDR_FIELDS(X)
    SA_ANIM_PILE_FIELDS(X)
    struct {
        SA_ANIM_ROW_FIELDS(X)
        uint32_t depth;
    } windows[SA_ANIM_AX_MAX];
#undef X
};
bool scripting_addition_anim_ax_begin(struct sa_anim_ax_begin *b);

// NOTE: synchronous — forces every in-flight LB+T3D context to its end state and
// returns the count forced (0 = none or IPC failure). A live space slide
// self-settles and is untouched.
uint32_t scripting_addition_anim_skip_all_to_end(void);

bool scripting_addition_freeze_windows(uint32_t *wids, int count);
bool scripting_addition_thaw_windows(uint32_t *wids, int count);

bool scripting_addition_animate_space(uint64_t out_sid, uint64_t in_sid, int32_t direction, float duration, double width, double gap, uint32_t did, float refresh_hz, uint8_t easing, uint32_t ring_wid, float ring_x, float ring_y, float ring_w, float ring_h, float ring_radius, float enter_delay, float exit_delay);

// steps = per-VBL keyframe count for the destination display.
bool scripting_addition_animate_edge_nudge(uint64_t sid, int32_t dx, int32_t dy, uint32_t duration_ms, uint32_t steps);

// NOTE: identity-T3D pin (suppresses the MC scale nudge); currently unreferenced.
bool scripting_addition_pin_windows(uint32_t *window_list, int window_count, uint32_t dur_ms);

bool scripting_addition_spaces_reconfig(void);
bool scripting_addition_set_expose_animation_duration(double duration);

// NOTE: global while it is on -- this rewrites Dock's own transition timing, so EVERY native
// fullscreen transition is instant, not only the ones yabai drives. The patch lives in Dock's
// text and dies with Dock, so it has to be re-asserted after a Dock relaunch.
//
// Returns the number of sites now holding the requested word; 0 means it did nothing. This has
// to come back over the wire rather than from OSAX_ATTRIB_FS_CLAMP -- the handshake that carries
// the attributes runs in the transient `yabai --load-sa` process, never in the daemon.
uint32_t scripting_addition_dock_fs_clamp(bool enable);

void wallpaper_floor_build(void);
void wallpaper_floor_clear(void);
void wallpaper_floor_refresh(void);
void wallpaper_floor_set_hidden(bool hide);

#endif
