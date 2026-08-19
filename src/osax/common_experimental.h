#ifndef SA_COMMON_EXPERIMENTAL_H
#define SA_COMMON_EXPERIMENTAL_H

// SA opcodes for non-upstream features — #defines, NOT enum members, so common.h's
// enum sa_opcode stays byte-identical to upstream. One byte on the wire: 0x14–0xFF.
// Gaps are retired experiments — never recycle a value (old daemon/payload pairs).

#define SA_OPCODE_WINDOW_SCALE_CUSTOM               0x14
#define SA_OPCODE_WINDOW_LOCKEDBOUNDS_ANIMATE       0x15
#define SA_OPCODE_WINDOW_LOCKEDBOUNDS_CLEAR         0x16
#define SA_OPCODE_WINDOW_LOCKEDBOUNDS_BATCH         0x17
#define SA_OPCODE_BORDER_LOCKEDBOUNDS_SET           0x1C
#define SA_OPCODE_WINDOW_FREEZE_BATCH               0x22
#define SA_OPCODE_WINDOW_THAW_BATCH                 0x23
#define SA_OPCODE_WINDOW_TRANSFORM_BATCH            0x2B
#define SA_OPCODE_WINDOW_TRANSFORM_3D_BATCH         0x30
#define SA_OPCODE_WINDOW_LOCKEDBOUNDS_TRANSLATE3D_BATCH 0x31
#define SA_OPCODE_SPACE_NUDGE                       0x32
#define SA_OPCODE_FOCUS_RING_SHOW                   0x33
// cap on the variable-length xray rect tail of SHOW (shared packer/parser)
#define SA_FOCUS_RING_XRAY_MAX_RECTS                16
#define SA_OPCODE_FOCUS_RING_HIDE                   0x34
#define SA_OPCODE_FOCUS_RING_SET_VISIBLE            0x35
// animated twin of SET_VISIBLE — fades the active ring's alpha, no teardown
#define SA_OPCODE_FOCUS_RING_FADE_VISIBLE           0x48
#define SA_OPCODE_SPACE_ANIMATE                     0x41
#define SA_OPCODE_FOCUS_RING_SPACE_SWITCH           0x45
#define SA_OPCODE_ANIM_AX_BEGIN                     0x47   // hand a full LB+T3D(+AX) animation to the payload CA pump (Branch B)
#define SA_OPCODE_ANIM_SKIP_ALL                     0x49   // force every in-flight LB+T3D context to terminal NOW; replies uint32 forced-count
#define SA_OPCODE_PIN_WINDOWS                       0x53   // async identity-Transform3D pin on active-space windows (MC scale-nudge suppression). Wire: (uint32 dur_ms, uint32 count, uint32 wids[count]).
#define SA_OPCODE_WARP_SNAP                         0x55   // RETIRED (9-slice warp cover); no handler. Reserved — never reuse.
#define SA_OPCODE_FOCUS_RING_MC_RIDE                0x56   // MC-exit ring ride: mirror the window's live T3D onto the ring band, fade ring IN. Wire: (uint32 wid). No reply.
#define SA_OPCODE_FOCUS_RING_MC_ENTER_RIDE          0x57   // MC-enter ring ride (inverse of 0x56): band full->thumbnail, fade ring OUT, park hidden. Wire: (uint32 wid). No reply.
#define SA_OPCODE_SET_EXPOSE_ANIMATION_DURATION     0x58   // MC-5b: swizzle -[WVExpose animationDuration] (DockCore). duration >= 0 overrides (0 = no MC tween); < 0 = native (~0.25). Wire: (double duration). No reply.
#define SA_OPCODE_SPACES_RECONFIG                   0x59   // rebuild Dock's MC strip via the named @objc -[Spaces handleDisplayReconfig] (NON-Mission-Control path). No wire payload, no reply.
#define SA_OPCODE_WINDOW_SCALE_RECT                 0x5A   // WM-12 pip drag-to-move: ABSOLUTE scale-to-rect. Wire: (uint32 wid, float tx, ty, tw, th). No reply.
#define SA_OPCODE_FOCUS_RING_RETARGET               0x5D   // fire-and-forget band retarget for agent-transport resizes (no per-frame follower): payload animates the band to the target on its ca_clock with apply_easing ordinals. Wire: (uint32 wid, float x, y, w, h, float duration_s, int32 easing). No reply. 0x5B/0x5C are main-tree pip opcodes.

// One fcsel per direction: enter and exit. Shared so the daemon can tell a full clamp from a
// partial one by the site count the payload replies with.
#define DOCK_FS_SITE_COUNT 2

// The two-up picker's duration lives in a separate set of sites: three handlers share the d8 idiom
// (cancel/ESC, commit, hover-preview) and the ATU driver uses a d0 variant.
#define DOCK_FS_ATU_D8_SITE_COUNT 3
#define DOCK_FS_ATU_D0_SITE_COUNT 1
#define DOCK_FS_TOTAL_SITE_COUNT (DOCK_FS_SITE_COUNT + DOCK_FS_ATU_D8_SITE_COUNT + \
                                  DOCK_FS_ATU_D0_SITE_COUNT)

// NOTE: outside OSAX_ATTRIB_ALL on purpose -- the stock handshake check is an equality test
// against that mask, so a bit inside it would make every payload look like it failed validation.
#define OSAX_ATTRIB_FS_CLAMP                        0x80   // all of Dock's native-fullscreen duration sites were located, one-up and two-up

/* 0x60 retired — was an OLDER SA_OPCODE_WALLPAPER_FLOOR lineage (persistent floor v1, then the per-slide lease); not reused. The floor returns as 0x65 below. */
#define SA_OPCODE_DOCK_FS_CLAMP                     0x5E   // zero Dock's native-fullscreen durations at their source, both one-up and two-up. One-up: patch the `fcsel d8, d1, d0, ne` computing `slow ? 2.5 : 0.5` to `movi d8, #0` -- d8 feeds both Dock's space-slide timer and the XPC reply AppKit crossfades on. Two-up: the picker's own `Shift ? 5.0 : 0.25` fcsels, whose value drives the WATransaction space-transform lerp. Global while on, process-local, dies with Dock. Wire: (int32 enable). Replies uint32 = sites now in the requested state (DOCK_FS_TOTAL_SITE_COUNT on success).
#define SA_OPCODE_WALLPAPER_FLOOR                   0x65   // persistent captured-wallpaper floor: one parked space per display at absolute level -1. Wire: (u8 clear, u8 hide, u8 show, u8 keep_dock, u8 refresh); replies diagnostic text on the socket. 0x5F-0x64 are main-tree opcodes (TILE_EXIT, DOCK_BAND_QUERY, CLIPBOARD_*). First slot free in BOTH trees after this is 0x66.

// half-width of the centered space-id strip a single burst can span
#define SA_STRIP_HALF 16
#define SA_STRIP_LEN  (2 * SA_STRIP_HALF + 1)

// Flag bits for the T3D batch wire `flags` field — each bit gates one SA-side call.
#define SA_T3D_FLAG_LB      (1u << 0)  // apply SLSTransactionSetWindowLockedBounds
#define SA_T3D_FLAG_T3      (1u << 1)  // apply SLSTransactionSetWindowTransform3D
#define SA_T3D_FLAG_ALPHA   (1u << 2)  // apply opacity fade
#define SA_T3D_FLAG_LB_FULL (1u << 3)  // LB lerps full XYWH (else size-only at anchor_xy)
#define SA_T3D_FLAG_T3_FULL (1u << 4)  // T3 full scale+translate matrix (else translate-only)
#define SA_T3D_FLAG_LOG     (1u << 5)  // payload emits per-row T3D_APPLY line to the unified log
#define SA_T3D_FLAG_AX      (1u << 6)  // payload fires real AX setFrame (Branch B in-payload AX)
#define SA_T3D_FLAG_ENDPIN             (1u << 7)  // payload pins AX origin at end_xy (origin-fixed resize, the validated default)
#define SA_T3D_FLAG_ENDPIN_RESIZE_ONLY (1u << 8)  // mid (Trigger 2) AX fires are resize-only (requires ENDPIN)
#define SA_T3D_FLAG_MOVE               (1u << 9)  // durable position commit for the no-LB path; composes with T3, never with LB (LB masks the move)
#define SA_T3D_FLAG_NOTIFY_DONE        (1u << 10) // payload toggles the daemon-observable "animating" property for visual-only batches
#define SA_T3D_FLAG_GEOM_LOG           (1u << 11) // payload-side geometry probe -> /tmp/yabai_anim_probe.log (diagnostic; no lever in this tree)
#define SA_T3D_FLAG_GEOM_AX            (1u << 12) // geom probe adds a per-frame payload AX read; requires GEOM_LOG
#define SA_T3D_FLAG_AX_WAKE            (1u << 14) // AXManualAccessibility (NOT AXEnhancedUserInterface — AppKit would animate the resize) so Chromium builds its lazy AX tree
#define SA_T3D_FLAG_PILE               (1u << 16) // stages-only; INERT here — retained for wire-compat
#define SA_T3D_FLAG_WARP               (1u << 18) // RETIRED (jello 9-slice rows); INERT. NOTE: bits 13/15/17 burned by an older payload lineage — never reuse.

// Finalize policy on ANIM_AX_BEGIN — values MUST mirror enum wm_finalize_mode
// (window_manager.h). LEAVE_TERMINAL unused here; retained for wire-compat.
#define SA_FINALIZE_CLEAR          0u
#define SA_FINALIZE_LEAVE_TERMINAL 1u

// single source for the daemon packer's array and the payload's per-context array
#define SA_ANIM_AX_MAX 64

// Single-source X-macro lists for ANIM_AX_BEGIN: packer, unpacker (both paths), daemon
// struct, and the wire-size assert all expand from these — ORDER is the wire contract.
// Columns: X(c_type, daemon_struct_member, payload_local). anchor_* = the window's REAL
// surface rect; start_*/end_* = visual lerp endpoints; aspect = w/h lock (0 = none).
// The pile-only per-row depth is conditional and handled by hand after the row list.
#define SA_ANIM_HDR_FIELDS(X) \
    X(uint32_t, count,         count) \
    X(uint32_t, flags,         flags) \
    X(uint32_t, easing,        easing) \
    X(float,    duration,      duration) \
    X(float,    fade_duration, fade_duration) \
    X(uint32_t, ax_th_mode,    ax_th_mode) \
    X(float,    ax_th_val,     ax_th_val) \
    X(uint32_t, did,           did) \
    X(float,    refresh_hz,    refresh_hz) \
    X(uint32_t, finalize_mode, finalize_mode)

// packed/unpacked ONLY when flags & SA_T3D_FLAG_PILE — non-pile wire stays byte-identical
#define SA_ANIM_PILE_FIELDS(X) \
    X(float,    pile_perspective, persp) \
    X(float,    pile_tx,          ptx) \
    X(float,    pile_ty,          pty) \
    X(float,    pile_tz,          ptz) \
    X(float,    pile_ry,          pry) \
    X(float,    pile_rx,          prx) \
    X(float,    pile_rz,          prz) \
    X(float,    pile_sc,          psc) \
    X(float,    pile_skx,         pskx) \
    X(float,    pile_sky,         psky) \
    X(float,    pile_origin_x,    pox) \
    X(float,    pile_origin_y,    poy) \
    X(float,    pile_overflow_z,  povz) \
    X(float,    pile_cx,          pcx) \
    X(float,    pile_cy,          pcy) \
    X(uint32_t, pile_max_step,    pmstep) \
    X(uint32_t, pile_pose_easing, peasing)

#define SA_ANIM_ROW_FIELDS(X) \
    X(uint32_t, wid,         wid) \
    X(uint32_t, mode,        mode) \
    X(int32_t,  pid,         pid) \
    X(float,    start_x,     sx) \
    X(float,    start_y,     sy) \
    X(float,    start_w,     sw) \
    X(float,    start_h,     sh) \
    X(float,    end_x,       ex) \
    X(float,    end_y,       ey) \
    X(float,    end_w,       ew) \
    X(float,    end_h,       eh) \
    X(float,    anchor_x,    nx) \
    X(float,    anchor_y,    ny) \
    X(float,    anchor_w,    nw) \
    X(float,    anchor_h,    nh) \
    X(float,    min_opacity, min_opacity) \
    X(float,    min_w,       min_w) \
    X(float,    min_h,       min_h) \
    X(float,    max_w,       max_w) \
    X(float,    max_h,       max_h) \
    X(float,    aspect,      aspect)

// worst-case (PILE) wire footprint, derived from the lists — keeps cap/field growth
// inside one SA socket message at compile time
#define SA_ANIM_WIRE_SIZEOF(t, dn, pn) + (int)sizeof(t)
#define SA_ANIM_BEGIN_HEADER_WIRE_BYTES \
    (2 + 1 + (0 SA_ANIM_HDR_FIELDS(SA_ANIM_WIRE_SIZEOF)) \
           + (0 SA_ANIM_PILE_FIELDS(SA_ANIM_WIRE_SIZEOF)))
#define SA_ANIM_ROW_WIRE_BYTES \
    ((0 SA_ANIM_ROW_FIELDS(SA_ANIM_WIRE_SIZEOF)) + (int)sizeof(uint32_t) /*pile-only depth*/)
_Static_assert(SA_ANIM_BEGIN_HEADER_WIRE_BYTES + SA_ANIM_AX_MAX * SA_ANIM_ROW_WIRE_BYTES <= SA_SOCKET_BUFF_LEN,
               "anim_ax_begin at SA_ANIM_AX_MAX rows must fit one SA socket message");

// AC-23: same single-source discipline for the remaining per-row batch wires — ONE name
// column shared by daemon struct member and payload unpack local; order is the wire
// contract. transform_3d_batch is absent by design (wid + double m[16], nothing to desync).
#define SA_XFORM_BATCH_ROW_FIELDS(X) \
    X(uint32_t, wid) \
    X(float,    a) X(float, b) X(float, c) X(float, d) \
    X(float,    tx) X(float, ty)

#define SA_LB_BATCH_ROW_FIELDS(X) \
    X(uint32_t, wid) \
    X(float,    x) X(float, y) X(float, w) X(float, h) \
    X(float,    min_opacity) \
    X(float,    progress)

#define SA_ANIM_BATCH_ROW_FIELDS(X) \
    X(uint32_t, wid) \
    X(uint32_t, mode) \
    X(float,    anchor_x) X(float, anchor_y) X(float, anchor_w) X(float, anchor_h) \
    X(float,    lerp_x)   X(float, lerp_y)   X(float, lerp_w)   X(float, lerp_h) \
    X(float,    min_opacity) \
    X(float,    progress) \
    X(float,    min_w) X(float, min_h) X(float, max_w) X(float, max_h)

// NOTE: MUST stay strictly below the daemon's AX_DIFF threshold (view.h) or a settled
// frame re-animates the tail; coupling _Static_assert'ed in window_manager.c.
#define SA_ANIM_SETTLE_PX 1.0f

// per-row mask on the global SA_T3D_FLAG_LB/_T3 bits (T3D_ONLY/LB_ONLY drop one side);
// every current caller passes LB_T3D
#define SA_T3D_ROW_MODE_LB_T3D    0u
#define SA_T3D_ROW_MODE_T3D_ONLY  1u
#define SA_T3D_ROW_MODE_LB_ONLY   2u

#endif
