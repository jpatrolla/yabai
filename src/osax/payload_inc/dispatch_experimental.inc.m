// dispatch_experimental.inc.m — case arms for the animation + focus-ring
// opcodes.
//
// #included INSIDE the big switch(opcode) at the bottom of payload.m. Each arm
// dispatches to a handler defined in one of the payload_inc/*.inc.m engine
// files (window_transform / anim / space_animation / focus_ring / edge_guard /
// warp_cover). Retired experiments have no opcodes in this tree — see the
// numbering-gaps note in common_experimental.h.

    // --- window_transform.inc.m: LockedBounds + Transform3D geometry ---
    case SA_OPCODE_WINDOW_SCALE_CUSTOM: {
        do_window_scale_custom(message);
    } break;
    case SA_OPCODE_WINDOW_TRANSFORM_BATCH: {
        do_window_transform_batch(message);
    } break;
    case SA_OPCODE_WINDOW_TRANSFORM_3D_BATCH: {
        do_window_transform_3d_batch(message);
    } break;
    case SA_OPCODE_WINDOW_LOCKEDBOUNDS_ANIMATE: {
        do_window_lockedbounds_animation(message);
    } break;
    case SA_OPCODE_WINDOW_LOCKEDBOUNDS_CLEAR: {
        do_window_lockedbounds_clear(message);
    } break;
    case SA_OPCODE_WINDOW_LOCKEDBOUNDS_BATCH: {
        do_window_lockedbounds_batch(message);
    } break;
    case SA_OPCODE_WINDOW_LOCKEDBOUNDS_TRANSLATE3D_BATCH: {
        do_window_lockedbounds_translate3d_batch(message);
    } break;
    case SA_OPCODE_WINDOW_FREEZE_BATCH: {
        do_window_freeze_batch(message);
    } break;
    case SA_OPCODE_WINDOW_THAW_BATCH: {
        do_window_thaw_batch(message);
    } break;
    case SA_OPCODE_BORDER_LOCKEDBOUNDS_SET: {
        do_border_lockedbounds_set(message);
    } break;

    // --- anim.inc.m: payload-CA LB+T3D+AX animator ---
    case SA_OPCODE_ANIM_AX_BEGIN: {
        do_anim_ax_begin(message);
    } break;
    case SA_OPCODE_ANIM_SKIP_ALL: {
        do_anim_skip_all(sockfd, message);
    } break;
    case SA_OPCODE_WARP_SNAP: {
        payload_warp_snap_begin(message);
    } break;

    // --- space_animation.inc.m: cross-fade / slide space focus ---
    case SA_OPCODE_SPACE_ANIMATE: {
        do_space_focus_animated(message);
    } break;

    // --- edge_guard.inc.m: multi_display_edge_guard nudge ---
    case SA_OPCODE_SPACE_NUDGE: {
        do_animate_edge_guard_nudge(message);
    } break;

    // --- focus_ring.inc.m: focus-ring overlay ---
    case SA_OPCODE_FOCUS_RING_SHOW: {
        do_focus_ring_show(message);
    } break;
    case SA_OPCODE_FOCUS_RING_HIDE: {
        do_focus_ring_hide(message);
    } break;
    case SA_OPCODE_FOCUS_RING_SET_VISIBLE: {
        do_focus_ring_set_visible(message);
    } break;
    case SA_OPCODE_FOCUS_RING_FADE_VISIBLE: {
        do_focus_ring_fade_visible(message);
    } break;
    case SA_OPCODE_FOCUS_RING_SPACE_SWITCH: {
        do_focus_ring_space_switch(message);
    } break;
    case SA_OPCODE_FOCUS_RING_MC_RIDE: {
        do_focus_ring_mc_ride(message);
    } break;
    case SA_OPCODE_FOCUS_RING_MC_ENTER_RIDE: {
        do_focus_ring_mc_enter_ride(message);
    } break;
    case SA_OPCODE_PIN_WINDOWS: {
        do_pin_windows(message);
    } break;
    case SA_OPCODE_SET_EXPOSE_ANIMATION_DURATION: {
        do_set_expose_animation_duration(message);
    } break;
    case SA_OPCODE_SPACES_RECONFIG: {
        do_spaces_reconfig(message);
    } break;
    case SA_OPCODE_WINDOW_SCALE_RECT: {
        do_window_scale_rect(message);
        break;
    }
