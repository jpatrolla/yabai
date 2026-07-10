#ifndef SA_COMMON_EXPERIMENTAL_H
#define SA_COMMON_EXPERIMENTAL_H

// SA opcodes for non-upstream features. Declared as #defines (not enum members)
// so common.h's `enum sa_opcode` stays byte-identical to upstream's — these
// values are still safely cast to `enum sa_opcode` by the dispatch switch.
//
// Naming/encoding rule: each opcode is one byte (wire format is `*message++`
// from a uint8 buffer), so the constant must fit in 0x14–0xFF.
//
// To upstream a feature: move its constant from this file into the enum body
// of common.h, move its case arm from dispatch_experimental.inc.m into
// payload.m's main switch, move the handler body inline.
//
// Gaps in the numbering are retired experiments; leave them unused so an old
// daemon/payload pair can never misread a recycled value.

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
// FR-21: cap on the xray overlap rects appended (variable-length) after the
// fixed SHOW struct — shared by the daemon packer and the payload parser.
// 16 rects = 256 bytes, well inside SA_SOCKET_BUFF_LEN.
#define SA_FOCUS_RING_XRAY_MAX_RECTS                16
#define SA_OPCODE_FOCUS_RING_HIDE                   0x34
#define SA_OPCODE_FOCUS_RING_SET_VISIBLE            0x35
// FR-19: animated twin of SET_VISIBLE for the desktop-ring toggle/Esc dismiss —
// fades the ACTIVE ring's alpha 1<->0 over a duration instead of snapping (and
// without tearing the ring down). Value 0x48 (the 0x33-0x35 block is full).
#define SA_OPCODE_FOCUS_RING_FADE_VISIBLE           0x48
#define SA_OPCODE_SPACE_ANIMATE                     0x41
// SPACE_ANIMATE `fade` byte — a per-side bitmask (enriched from the old 0/1 bool).
// A set bit ramps that side's window alpha over the slide; a clear bit rides the
// slide at full baseline opacity. 0 = no cross-fade (pure slide). The payload tick
// (space_animation.inc.m) gates win_ae (incoming) on ENTER and win_aeo (outgoing)
// on EXIT, so enter/exit fade independently — e.g. EXIT alone fades only the
// windows leaving. A stale payload reading the byte as a bool degrades to
// "any nonzero → fade both", never garbage.
#define SPACE_FADE_EXIT   (1u << 0)   // outgoing (exiting) space windows fade out
#define SPACE_FADE_ENTER  (1u << 1)   // incoming (entering) space windows fade in
#define SA_OPCODE_FOCUS_RING_SPACE_SWITCH           0x45
#define SA_OPCODE_ANIM_AX_BEGIN                     0x47   // hand a full LB+T3D(+AX) animation to the payload CA pump (Branch B)
#define SA_OPCODE_ANIM_SKIP_ALL                     0x49   // force every in-flight LB+T3D context to terminal NOW; replies uint32 forced-count (0x48 = FOCUS_RING_FADE_VISIBLE, defined above)
#define SA_OPCODE_PIN_WINDOWS                       0x53   // async identity-Transform3D pin on active-space windows (MC scale-nudge suppression). Wire: (uint32 dur_ms, uint32 count, uint32 wids[count]).
#define SA_OPCODE_WARP_SNAP                         0x55   // WM-9: 9-slice warp cover for duration==0 placements. Payload sets a chrome-pinned SLSSetWindowWarp mesh cur->dst (visual lands at dst immediately), arms the animating property, then clears on settle (SLSGetScreenRectForWindow within 1px of dst) or the cap. Wire: (uint32 wid, float dst_x, dst_y, dst_w, dst_h, uint32 cap_ms [0 => 400], uint32 flags). flags bit0 = WARP_SNAP_FLAG_LB: also pin LockedBounds at CUR for the cover (freezes the mesh's source space; mid-cover content commit ~cancels) with an atomic tx warp+LB clear at release. No reply.
#define WARP_SNAP_FLAG_LB                           0x1
#define SA_OPCODE_FOCUS_RING_MC_RIDE                0x56   // MC-exit ring ride: payload mirrors the target window's live CGSGetWindowTransform3D onto the ring band until the exit settles, fading the ring IN (0->1) in lockstep. Wire: (uint32 wid). No reply.
#define SA_OPCODE_FOCUS_RING_MC_ENTER_RIDE          0x57   // MC-enter ring ride: inverse of 0x56 — rides the band full->thumbnail as the window enters Mission Control while fading the ring OUT (1->0), then parks it hidden. Wire: (uint32 wid). No reply.
#define SA_OPCODE_SET_EXPOSE_ANIMATION_DURATION     0x58   // MC-5b: swizzle -[WVExpose animationDuration] (DockCore, injected payload). duration >= 0 overrides (0 = no MC enter/exit tween); < 0 = passthrough to native (~0.25). Zeroing it makes SLSGetScreenRectForWindow report MC's final layout in ~1 frame (layout oracle) and suppresses the native window animation for our own thumb->rect anim. Wire: (double duration). No reply.
#define SA_OPCODE_SPACES_RECONFIG                   0x59   // rebuild Dock's MC strip via the named @objc -[Spaces handleDisplayReconfig] (NON-Mission-Control path). No wire payload, no reply.

// SPA-2 filmstrip: half-width of the centered space-id strip (origin at the
// center slot). A single burst can span this many hops in either direction.
#define SA_STRIP_HALF 16
#define SA_STRIP_LEN  (2 * SA_STRIP_HALF + 1)

// Flag bits for SA_OPCODE_WINDOW_LOCKEDBOUNDS_TRANSLATE3D_BATCH — bitwise OR
// into the wire-format `flags` field. Each bit gates the corresponding
// SA-side SLS call so the daemon can isolate which API does what.
#define SA_T3D_FLAG_LB      (1u << 0)  // apply SLSTransactionSetWindowLockedBounds
#define SA_T3D_FLAG_T3      (1u << 1)  // apply SLSTransactionSetWindowTransform3D
#define SA_T3D_FLAG_ALPHA   (1u << 2)  // apply opacity fade
// Mode bits — refine what LB / T3 do when enabled.
#define SA_T3D_FLAG_LB_FULL (1u << 3)  // LB lerps full XYWH (else size-only at anchor_xy)
#define SA_T3D_FLAG_T3_FULL (1u << 4)  // T3 full scale+translate matrix (else translate-only); the auto-policy stays translate-only
#define SA_T3D_FLAG_LOG     (1u << 5)  // payload emits per-row T3D_APPLY line to the unified log
#define SA_T3D_FLAG_AX      (1u << 6)  // payload fires real AX setFrame (Branch B in-payload AX)
#define SA_T3D_FLAG_ENDPIN             (1u << 7)  // payload pins AX origin at end_xy (origin-fixed resize, the validated default)
#define SA_T3D_FLAG_ENDPIN_RESIZE_ONLY (1u << 8)  // mid (Trigger 2) AX fires are resize-only (requires ENDPIN)
#define SA_T3D_FLAG_MOVE               (1u << 9)  // SLSTransactionMoveWindowWithGroup(wid, anchor_xy) in the SAME txn — the durable position commit for the no-LB SLSMove+T3D path (anchor = endpin origin). Composes with T3 (visual); never with LB (LB masks the move).
#define SA_T3D_FLAG_NOTIFY_DONE        (1u << 10) // payload sets/clears the daemon-observable "animating" property for THIS batch even when it's visual-only (no AX) — the completion signal the daemon's pending-finalize poll watches. Daemon sets it iff a finalize_callback is wired (SA_OPCODE_ANIM_AX_BEGIN only).
#define SA_T3D_FLAG_GEOM_LOG           (1u << 11) // payload-side geom probe: each frame sample every geometry getter (bounds/onscreen/screen-rect/frame-bounds/shape/constraints) and append a stacked block to /tmp/yabai_anim_probe.log, comparing the asked LB/AX rect against what the server/app report (detects constraint push-back). Diagnostic instrumentation in anim.inc.m; no daemon lever sets this bit in this tree.
#define SA_T3D_FLAG_GEOM_AX            (1u << 12) // geom probe: additionally issue a payload-side AX read (payload_ax_get_frame) per frame, logged alongside the SLS getters — disambiguates stale-AX from real clamp. Requires SA_T3D_FLAG_GEOM_LOG.
#define SA_T3D_FLAG_AX_WAKE            (1u << 14) // at begin, set AXManualAccessibility=true on each animated window's app so a Chromium/Electron app builds its lazy AX tree (else AXWindows is empty and the AX setFrame silently no-ops). Done via the Chromium-specific AXManualAccessibility, NOT AXEnhancedUserInterface, so AppKit doesn't animate the resize. Daemon sets it from `config window_animation_ax_wake` (default on); only acted on when SA_T3D_FLAG_AX is also set. Non-Chromium apps return kAXErrorAttributeUnsupported → harmless no-op.
#define SA_T3D_FLAG_PILE               (1u << 16) // stages-only (pile pose). INERT in this tree — the daemon never sets it, so the pile header block + per-row depth are never packed; the bit is retained for wire-compat. When clear the wire is byte-identical to the pre-pile format.
#define SA_T3D_FLAG_WARP               (1u << 18) // jello policy: rows whose SIZE animates carry the per-frame presentation as a chrome-pinned 9-slice SLSTransactionSetWindowWarp mesh (source = anchor dims, target = eased visual rect) INSTEAD of LB+T3D — LockedBounds does not play well with a live mesh (live-verified), so warp rows skip both; pure-move rows in the same batch keep the true_resize recipe (shadow follows T3D but NOT the warp). Terminal sites clear the warp unconditionally. Set by `config window_animation_policy jello`. NOTE: bits 13/15/17 are reserved (burned by an older payload lineage) — don't reuse them for new flags.
// (bits 19/20 free.)

// Finalize policy carried on SA_OPCODE_ANIM_AX_BEGIN — mirrors enum
// wm_finalize_mode (window_manager.h); values MUST stay in sync.
// CLEAR: at t=1 the payload drops LB and resets T3D to identity, so the
//   AX-committed end_rect becomes the steady visual. The only mode used here.
// LEAVE_TERMINAL: leaves the last-frame LB/T3D applied. Unused here
//   (stages-only); retained for wire-compat.
#define SA_FINALIZE_CLEAR          0u
#define SA_FINALIZE_LEAVE_TERMINAL 1u

// LB+T3D wire cap — single source for the daemon packer's window array
// (struct sa_anim_ax_begin, sa_inc/sa_experimental.h) and the payload
// animator's per-context array (payload_inc/anim.inc.m).
#define SA_ANIM_AX_MAX 64

// ── AC-9: single-source field lists for SA_OPCODE_ANIM_AX_BEGIN ────────────
// The daemon packer (scripting_addition_anim_ax_begin), the payload unpacker
// (do_anim_ax_begin — BOTH the main and the ctx-FULL degrade paths), the
// daemon-side struct sa_anim_ax_begin, and the wire-size assert below are ALL
// generated from these three X-macro lists. The pack order and the unpack order
// therefore cannot drift apart — the "pack MUST mirror unpack field-for-field"
// bug class is closed structurally.
//
// Each entry is  X(c_type, daemon_struct_member, payload_local_or_member).
// Two name columns bridge the daemon's struct naming (start_x, anchor_y, …) and
// the payload's (sx, ny, … for row struct members; bare locals for header/pile).
// Consumers pick the column they need; the ORDER — the only thing the wire cares
// about — is shared. Every field is 4 bytes (uint32_t/int32_t/float); the
// SA_ANIM_WIRE_SIZEOF assert below relies on that.
//
// Row semantics: anchor_* is the window's REAL surface rect (natural AX frame);
// start_*/end_* are the visual lerp endpoints (which differ from the surface for
// stages IN, thumb→natural — mirrors Branch A's natural-frame anchor). aspect is
// the w/h lock (0 = none); the payload trims the asked rect to it after min/max.
// The pile-only per-row `depth` cascade step is conditional, so it is handled by
// hand right after the row list (not part of any X list).
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

// Pile pose block — packed/unpacked ONLY when flags & SA_T3D_FLAG_PILE, so the
// non-pile wire stays byte-identical to the pre-pile format. The payload column
// names are the temp floats it later widens into a `struct pile_xform` of doubles.
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

// Wire footprint of SA_OPCODE_ANIM_AX_BEGIN, derived from the lists above so a
// field addition updates the assert for free. Sized for the WORST case (PILE on:
// the pile header block + per-row depth are packed). int16 length + opcode byte +
// header + pile; row = the row list + the pile-only depth uint32. When PILE is
// clear the message is smaller and still fits. sa.m's pack() overflow guard is the
// runtime backstop; this assert keeps a cap/field growth from outgrowing one SA
// message at compile time.
#define SA_ANIM_WIRE_SIZEOF(t, dn, pn) + (int)sizeof(t)
#define SA_ANIM_BEGIN_HEADER_WIRE_BYTES \
    (2 + 1 + (0 SA_ANIM_HDR_FIELDS(SA_ANIM_WIRE_SIZEOF)) \
           + (0 SA_ANIM_PILE_FIELDS(SA_ANIM_WIRE_SIZEOF)))
#define SA_ANIM_ROW_WIRE_BYTES \
    ((0 SA_ANIM_ROW_FIELDS(SA_ANIM_WIRE_SIZEOF)) + (int)sizeof(uint32_t) /*pile-only depth*/)
_Static_assert(SA_ANIM_BEGIN_HEADER_WIRE_BYTES + SA_ANIM_AX_MAX * SA_ANIM_ROW_WIRE_BYTES <= SA_SOCKET_BUFF_LEN,
               "anim_ax_begin at SA_ANIM_AX_MAX rows must fit one SA socket message");

// ── AC-23: single-source per-row field lists for the other batch opcodes ──────
// Same X-macro discipline as SA_ANIM_*_FIELDS, applied to the remaining
// hand-mirrored per-row batch wires so pack and unpack cannot drift. These take a
// SINGLE name column — the daemon struct member and the payload unpack local share
// the name (verified in window_transform.inc.m). The daemon packer expands
// `pack(batch->windows[i].n)`; the payload unpacker declares `t n;` then
// `unpack(n)` into that local. Order is the wire contract. Structs stay
// hand-written (they carry rich per-field docs); a list field missing from a
// struct is a compile error in the packer, so they can't silently diverge.
// (transform_3d_batch is intentionally absent: its row is wid + double m[16], an
// array with no field-name list to desync.)
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

// Payload settle tolerance: per-edge px for "real frame landed at end"
// (anim.inc.m settle probe). MUST stay strictly below
// the daemon's AX_DIFF threshold (view.h) — a settled frame must never read
// as "different" to the BSP flush gate or window_node_flush re-animates the
// tail. Coupling is _Static_assert'ed in window_manager.c.
#define SA_ANIM_SETTLE_PX 1.0f

// Per-row mode for SA_OPCODE_WINDOW_LOCKEDBOUNDS_TRANSLATE3D_BATCH. The mode
// acts as a per-row mask on the global SA_T3D_FLAG_LB / _T3 bits, for batches
// whose rows need different primitive subsets. Every current caller passes
// LB_T3D.
//
// LB_T3D (= 0): both LB and T3 apply (intersect with global flags) — the only
//               mode in use.
// T3D_ONLY     : LB suppressed for this row; T3D + alpha follow global flags.
// LB_ONLY      : T3D suppressed for this row; LB + alpha follow global flags.
#define SA_T3D_ROW_MODE_LB_T3D    0u
#define SA_T3D_ROW_MODE_T3D_ONLY  1u
#define SA_T3D_ROW_MODE_LB_ONLY   2u

#endif
