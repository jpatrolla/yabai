#ifndef SA_EXPERIMENTAL_H
#define SA_EXPERIMENTAL_H

// Non-upstream `scripting_addition_*` declarations and the batch struct
// types they take. Tail-included from sa.h so upstream's sa.h diff stays
// minimal. Adding an opcode touches four points: the define in
// osax/common_experimental.h, the declaration here, the sender in
// sa_experimental.inc.m, and the payload arm in
// payload_inc/dispatch_experimental.inc.m.

// focus_ring: stream draw commands to the Dock-side overlay. Show updates
// the target wid + rect + radius and triggers a stroke redraw; hide clears
// all overlays. The Dock-side handler also auto-redraws the stroke from
// inside do_window_lockedbounds_translate3d_batch when the animating wid
// matches the last-set target, so animations get lockstep tracking
// without further SA round-trips per frame.
// Payload re-resolves the target's sid via SLSCopySpacesForWindows inside
// the SHOW handler, so the daemon passes no display/space identifiers.
// The wire keeps its historical field names (append-only contract) — daemon-side
// they now map: stroke_width = focus_ring_width (band thickness), stroke_alpha /
// stroke_{r,g,b} = focus_ring_color_opacity / focus_ring_color (the band's color
// wash — the payload renders the wash from the resolved tint_* below; these slots
// are stamped for wire compat + the payload's show_recv log). Daemon stamps them
// on every SHOW; payload updates its render globals from these before computing
// surface size (a width change forces a reshape via the size_changed branch in
// do_focus_ring_show). force_style=1 marks an explicit config change: it clears
// the payload-side color_override latch so config values reassert authority;
// passive focus events pass 0 and leave the latch untouched.
// blur_radius is the background-blur (vibrancy) radius in px (0 = unblurred
// sample); the payload masks it to the band via the window shape. style is the
// legacy enum focus_ring_style wire slot — derived daemon-side from blur_radius,
// ignored by the payload since FR-24.
// blur_saturation / blur_brightness adjust the sampled frosted content (CAFilter
// colorSaturate/colorBrightness; identity 1.0/0.0) — daemon keys focus_ring_
// saturation/brightness — and blend_mode (enum focus_ring_blend_mode) is the
// color-wash sublayer's compositingFilter. blur_stroke... wire fields carry the
// INNER STROKE (daemon keys focus_ring_inner_stroke*): blur_stroke enables the
// hard CAShapeLayer stroke hugging the band's inner edge; blur_stroke_position
// is its zPosition vs the band (above/below) and blur_stroke_width its thickness
// in px. blur_bleed is the inner-bleed px (band overlaps + frosts the window's
// own edge; key focus_ring_bleed). tint_{r,g,b,a} is the band color wash's final
// RGBA and str_{r,g,b,a} the inner stroke's — resolved daemon-side (the stroke
// inherits the band's color/color_opacity unless overridden).
// FR-21 xray: xray flag + RGBA + up to SA_FOCUS_RING_XRAY_MAX_RECTS screen-space
// frames of overlapping windows, appended (variable-length) after the fixed
// struct; the payload recolors the band segments clipped to those frames
// (renders on the sharp blur-0 band or the inner stroke). xray_rects may be
// NULL when xray_count is 0.
// window_alpha: whole-window translucency (`alpha` knob) — the window's NORMAL
// alpha slot; visibility/fades ride the SYSTEM slot so the two never collide.
bool scripting_addition_focus_ring_show(uint32_t wid, float x, float y, float w, float h, float radius, float stroke_width, float stroke_alpha, float stroke_r, float stroke_g, float stroke_b, bool force_style, int blur_radius, int style, float blur_saturation, float blur_brightness, int blend_mode, bool blur_stroke, int blur_stroke_position, float blur_stroke_width, float blur_bleed, float tint_r, float tint_g, float tint_b, float tint_a, float str_r, float str_g, float str_b, float str_a, float blur_contrast, float blur_feather, float fade_duration, float blur_hue, bool xray, float xray_r, float xray_g, float xray_b, float xray_a, int xray_count, CGRect *xray_rects, float window_alpha);
bool scripting_addition_focus_ring_hide(void);
// Toggles overlay alpha 0/1 AND the payload-side cached `visible` flag in one
// opcode. Disabled => payload skips its own SLS-driven focus redraws.
bool scripting_addition_focus_ring_set_visible(bool visible);
// FR-19: animated dismiss/reveal of the ACTIVE ring for the desktop toggle and
// Esc. Fades alpha 1<->0 over fade_ms on the payload ca_clock pump (the ring
// persists parked at 0, so the reverse toggle just fades it back). fade_ms<=0 or
// no ring => instant. Does NOT touch the master `visible` flag.
bool scripting_addition_focus_ring_fade_visible(bool visible, int fade_ms, int easing);
// FR-9: vanish the outgoing space's parked ring and reveal the incoming space's
// (rides in with the slide as a managed-space member). Either may be absent.
// fade_ms > 0 fades the incoming ring in (ease_out_expo over fade_ms, matching
// the slide) instead of revealing it instantly; 0 = instant (native/snap).
//
// dest_wid/dest_rect/dest_radius describe the incoming space's focused window so
// the payload can PARK a ring on it when the destination has no live pool entry
// to ride (never-visited / focus-unchanged / evicted). dest_wid==0 = nothing to
// park (the toggle-only path); the payload falls back to whatever entry exists.
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

// Batch animation structure
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

// Per-frame transform batch — single round-trip Dock-cid SLSTransaction
// applies CGAffineTransform per wid. Used by stage transition transform
// animation (cross-process wids, so daemon's g_connection can't reach).
#define SA_BATCH_TRANSFORM_MAX 128
struct sa_transform_batch {
    uint32_t count;
    struct {
        uint32_t wid;
        float a, b, c, d, tx, ty;  // CGAffineTransform components
    } windows[SA_BATCH_TRANSFORM_MAX];
};
bool scripting_addition_batch_transform(struct sa_transform_batch *batch);

// 3D variant of the per-frame batch — applies CATransform3D per wid via
// SLSTransactionSetWindowTransform3D. Used by the Phase H real-window
// stage transition path (transform applied to the actual app wid; logical
// bounds preserved, only screen_rect changes — the Stage Manager pattern).
//
// Cap is smaller than the 2D batch because each entry is 132 bytes
// (4 + 16 doubles) vs 28 bytes for 2D; it stays well inside SA_SOCKET_BUFF_LEN.
// The client wrapper chunks larger batches automatically.
#define SA_BATCH_TRANSFORM_3D_MAX 24
struct sa_transform_3d_batch {
    uint32_t count;
    struct {
        uint32_t wid;
        double   m[16];   // CATransform3D layout (row-major struct order)
    } windows[SA_BATCH_TRANSFORM_3D_MAX];
};
bool scripting_addition_batch_transform_3d(struct sa_transform_3d_batch *batch);

// Per-frame ax_lb_t3 batch — lever-driven combination of LockedBounds + Transform3D
// (AX setFrame is fired daemon-side independently). `flags` bits toggle each SA-side
// API so the caller can isolate which primitive does what visually.
//
// Budget: 56 bytes/window (per-row `mode` packed as uint32_t for alignment)
//         → 4081 bytes / 56 ≈ 72; cap at 64 (headroom).
// Flag bits SA_T3D_FLAG_* and per-row SA_T3D_ROW_MODE_* live in
// osax/common_experimental.h so both daemon and SA see them.
#define SA_BATCH_LOCKEDBOUNDS_T3D_MAX 64

struct sa_lockedbounds_t3d_batch {
    uint32_t count;
    uint32_t flags;          // SA_T3D_FLAG_* bits
    float    fade_duration;
    struct {
        uint32_t wid;
        // Per-row mode (SA_T3D_ROW_MODE_*) — per-row mask on the global
        // `flags`. All current callers pass LB_T3D (no-op intersection).
        uint32_t mode;
        // Running anchor — where AX currently sits. Initially = start_*.
        // Advances toward end_* each periodic AX-setFrame tick. Used as
        // (a) LockedBounds origin (mode 1) and (b) Transform3D natural rect.
        float anchor_x, anchor_y;
        float anchor_w, anchor_h;  // needed for T3_FULL scale: xs = anchor_w/lerp_w
        float lerp_x, lerp_y;   // Current interpolated position (target this frame)
        float lerp_w, lerp_h;   // Current interpolated size
        float min_opacity;
        float progress;
        // SLS size constraints, snapshotted by daemon at animation-start.
        // Payload clamps lerp_w/lerp_h to [min_w, max_w]/[min_h, max_h]
        // before SLSTransactionSetWindowLockedBounds so hard-constraint apps
        // (VLC, Terminal, AppKit windows with explicit min/max) don't visibly
        // overshoot during the per-frame lerp. Unconstrained windows pass
        // min=0, max=FLT_MAX so the clamp is a no-op. One SLS query per
        // animation, daemon-side — payload never queries.
        float min_w, min_h;
        float max_w, max_h;
    } windows[SA_BATCH_LOCKEDBOUNDS_T3D_MAX];
};
bool scripting_addition_batch_animate_with_lockedbounds_t3d(struct sa_lockedbounds_t3d_batch *batch);

// SA_OPCODE_ANIM_AX_BEGIN (0x47) — hand a full LB+T3D(+AX) animation to the
// payload CA pump (Branch B). The payload owns the per-VBL clock, lerp, easing,
// and in-process LB+T3D commit; ax_th_* + pid parameterize the in-payload AX
// path (SA_T3D_FLAG_AX). SA_ANIM_AX_MAX lives in osax/common_experimental.h —
// the single source shared with the payload cap.

// AC-9: body generated from the SA_ANIM_*_FIELDS X-macro lists in
// common_experimental.h — the SAME lists the daemon packer and payload unpacker
// expand, so the struct, the wire, and the decode cannot fall out of sync. Field
// semantics (anchor vs start/end, aspect, pile pose knobs, depth) are documented
// at those lists. `depth` is in the struct unconditionally but only packed when
// flags & SA_T3D_FLAG_PILE, so it is hand-declared below the row list.
struct sa_anim_ax_begin {
#define X(t, dn, pn) t dn;
    SA_ANIM_HDR_FIELDS(X)
    SA_ANIM_PILE_FIELDS(X)
    struct {
        SA_ANIM_ROW_FIELDS(X)
        uint32_t depth;      // pile cascade step (0 = front anchor); only packed when flags & SA_T3D_FLAG_PILE
    } windows[SA_ANIM_AX_MAX];
#undef X
};
bool scripting_addition_anim_ax_begin(struct sa_anim_ax_begin *b);

// SA_OPCODE_ANIM_SKIP_ALL (0x49) — force every in-flight LB+T3D context to
// its terminal state NOW (end AX frame committed, identity T3D, LB cleared).
// Synchronous: returns after the payload handler has fully run. Returns the
// number of windows forced (0 = nothing in flight, or IPC failure). A live
// cross-fade slide is not touched — it self-settles at t>=1.
uint32_t scripting_addition_anim_skip_all_to_end(void);

bool scripting_addition_freeze_windows(uint32_t *wids, int count);
bool scripting_addition_thaw_windows(uint32_t *wids, int count);

// Animated space switch: show both spaces, slide their windows past each
// other at the VBL rate (per-window Transform3D + cross-fade), then commit
// (HideSpace + SetManagedDisplayCurrentSpace + Dock _currentSpace poke).
// `wallpaper` makes each space's wallpaper ride the slide with its windows,
// native-style (off = both hold as a static backdrop). This is the
// production space_animation path.
bool scripting_addition_animate_space(uint64_t out_sid, uint64_t in_sid, int32_t direction, float duration, double width, double gap, uint8_t wallpaper, uint8_t animate_menubar, uint32_t did, float refresh_hz, int32_t out_active_stage, int32_t in_active_stage, uint8_t easing, uint8_t fade, uint32_t ring_wid, float ring_x, float ring_y, float ring_w, float ring_h, float ring_radius, uint8_t fs_enabled, float fs_scale, uint8_t fs_easing, float fs_duration, float fs_delay, uint8_t fs_fade, float enter_delay, float exit_delay, float fade_enter_delay, float fade_exit_delay, float fade_enter_dur, float fade_exit_dur);

// Elastic edge-nudge: translate a space's content by (dx, dy) then snap back
// via a damped harmonic oscillator. Physics constants live SA-side. `steps`
// is the per-VBL keyframe count (compute from display_timing_get for the
// destination display).
bool scripting_addition_animate_edge_nudge(uint64_t sid, int32_t dx, int32_t dy, uint32_t duration_ms, uint32_t steps);

// Async identity-Transform3D pin on a window list (dur_ms) — suppresses an animated MC
// scale nudge. No current callers (the space-op path rebuilds via handleDisplayReconfig,
// which triggers no nudge); retained as a wired, working primitive.
bool scripting_addition_pin_windows(uint32_t *window_list, int window_count, uint32_t dur_ms);

// Rebuild Dock's MC strip after a server-side space op, via the named @objc
// -[Spaces handleDisplayReconfig] — a NON-Mission-Control rebuild path (no MC cycle,
// no scale nudge). No wire payload. Called by space_manager_dock_rebuild_strip.
bool scripting_addition_spaces_reconfig(void);
bool scripting_addition_set_expose_animation_duration(double duration);

// WM-9: 9-slice warp snap cover for duration==0 placements.
// Sends SA_OPCODE_WARP_SNAP (0x55) to the payload before the daemon's AX
// commit: the payload maps the current backing onto dst via SLSSetWindowWarp,
// arms the is_animating property (BSP re-flush gate), then clears on settle
// or the hard cap (cap_ms; 0 → payload default 400ms). lb_pin additionally
// pins LockedBounds at the current rect for the cover (lb_warp: freezes the
// mesh's source space; atomic tx warp+LB clear at release).
// Returns false only on IPC failure; a warp rc!=0 in the payload degrades
// to bare-AX silently.
//
// Transport: no per-case ack byte (same arm shape as SA_OPCODE_ANIM_AX_BEGIN);
// the daemon's recv unblocks on connection-close after the handler returns.
// warp_ms > 0 tweens the mesh cur->dst over that long (ease-out expo)
// instead of snapping; 0 = instant. Lever: window_animation_warp_min_ms.
// Wire: [int16_t body_len][uint8_t 0x55][uint32 wid][float dst_x,dst_y,dst_w,dst_h][uint32 cap_ms][uint32 flags][uint32 warp_ms]
// — byte-identical to struct sa_warp_snap in warp_cover.inc.m.
static inline bool scripting_addition_warp_snap(uint32_t wid, CGRect dst, uint32_t cap_ms, bool lb_pin, uint32_t warp_ms)
{
    extern char g_sa_socket_file[];
    struct __attribute__((packed)) {
        uint32_t wid;
        float    dst_x, dst_y, dst_w, dst_h;
        uint32_t cap_ms;
        uint32_t flags;
        uint32_t warp_ms;
    } payload = { wid,
                  (float)dst.origin.x, (float)dst.origin.y,
                  (float)dst.size.width, (float)dst.size.height,
                  cap_ms,
                  lb_pin ? WARP_SNAP_FLAG_LB : 0u,
                  warp_ms };
    // Build the wire message: 2-byte length prefix + 1-byte opcode + payload.
    // Matches what sa_payload_send(SA_OPCODE_WARP_SNAP) expands to in sa.m.
    char    buf[sizeof(int16_t) + 1 + sizeof(payload)];
    int16_t wire_len = (int16_t)(1 + (int16_t)sizeof(payload));
    memcpy(buf, &wire_len, sizeof(wire_len));
    buf[sizeof(int16_t)] = SA_OPCODE_WARP_SNAP;
    memcpy(buf + sizeof(int16_t) + 1, &payload, sizeof(payload));
    int  sockfd;
    char dummy;
    bool ok = false;
    if (socket_open(&sockfd)) {
        if (socket_connect(sockfd, g_sa_socket_file)) {
            if (send(sockfd, buf, sizeof(buf), 0) != -1) {
                recv(sockfd, &dummy, 1, 0); // unblocks on connection-close (no reply byte)
                ok = true;
            }
        }
        socket_close(sockfd);
    }
    return ok;
}

#endif
