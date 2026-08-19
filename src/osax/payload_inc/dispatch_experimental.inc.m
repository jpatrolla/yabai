// Experimental opcode case arms — #included inside handle_message's switch
// (payload.m); handlers live in the payload_inc/*.inc.m engine files.

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

    case SA_OPCODE_ANIM_AX_BEGIN: {
        do_anim_ax_begin(message);
    } break;
    case SA_OPCODE_ANIM_SKIP_ALL: {
        do_anim_skip_all(sockfd, message);
    } break;

    case SA_OPCODE_SPACE_ANIMATE: {
        do_space_focus_animated(message);
    } break;

    case SA_OPCODE_SPACE_NUDGE: {
        do_animate_edge_guard_nudge(message);
    } break;

    case SA_OPCODE_FOCUS_RING_SHOW: {
        do_focus_ring_show(message);
    } break;
    case SA_OPCODE_FOCUS_RING_HIDE: {
        do_focus_ring_hide(message);
    } break;
    case SA_OPCODE_FOCUS_RING_RETARGET: {
        do_focus_ring_retarget(message);
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
    case SA_OPCODE_DOCK_FS_CLAMP: {
        do_dock_fs_clamp(sockfd, message);
    } break;
    case SA_OPCODE_WALLPAPER_FLOOR: {
        do_wallpaper_floor(sockfd, message);
    } break;
