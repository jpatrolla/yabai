// sa_inc/sa_experimental.inc.m
//
// Non-upstream `scripting_addition_*` client wrappers — the daemon-side
// counterpart of payload_inc/dispatch_experimental.inc.m. Grouped here so
// sa.m stays byte-identical (in spirit) to upstream's daemon client.
//
// One TU: this file is `#include`d at the bottom of sa.m. All static
// helpers (lockedbounds_lock_count, sa_lockedbounds_state, etc.) defined
// in sa.m above the include point are visible to these wrappers.
//
// Categories (in source order):
//   - Space animation: animate_space, animate_edge_nudge
//   - Focus ring: show / hide / set_visible / fade_visible / space_switch /
//     mc_ride / mc_enter_ride
//   - Transforms: scale_window_custom, batch_transform, batch_transform_3d
//   - LockedBounds: animate_window_lockedbounds, clear_lockedbounds,
//     set_border_lockedbounds, batch_animate_with_lockedbounds{,_t3d},
//     anim_ax_begin (the CA-pump batch), anim_skip_all_to_end
//   - Freeze: freeze_windows, thaw_windows
//   - Mission Control: pin_windows, spaces_reconfig,
//     set_expose_animation_duration

bool scripting_addition_animate_space(uint64_t out_sid, uint64_t in_sid, int32_t direction, float duration, double width, double gap, uint8_t wallpaper, uint8_t animate_menubar, uint32_t did, float refresh_hz, int32_t out_active_stage, int32_t in_active_stage, uint8_t easing, uint8_t fade, uint32_t ring_wid, float ring_x, float ring_y, float ring_w, float ring_h, float ring_radius, uint8_t fs_enabled, float fs_scale, uint8_t fs_easing, float fs_duration, float fs_delay, uint8_t fs_fade, float enter_delay, float exit_delay, float fade_enter_delay, float fade_exit_delay, float fade_enter_dur, float fade_exit_dur)
{
    // Native replica transforms whole spaces, not individual windows — no window
    // lists in the payload.
    sa_payload_init();
    pack(out_sid);
    pack(in_sid);
    pack(direction);
    pack(duration);
    pack(width);
    pack(gap);
    pack(wallpaper);
    pack(animate_menubar);   // SPA-11: slide menubar-band windows too (default off)
    pack(did);          // AC-7: per-display ca_clock cadence — unpack order in do_space_focus_animated MUST mirror this
    pack(refresh_hz);
    pack(out_active_stage);  // stage filter: active stage of each space (-1 = no
    pack(in_active_stage);   // filtering); collect drops off-stage thumbnails. Mirror in unpack.
    pack(easing);            // SPA: curve mode (enum focus_ring_easing). Mirror in unpack.
    pack(fade);              // SPA: cross-fade windows during slide. Mirror in unpack.
    pack(ring_wid);          // SPA-17: focus-ring geo-rider dest (0 = none). Mirror in unpack.
    pack(ring_x);
    pack(ring_y);
    pack(ring_w);
    pack(ring_h);
    pack(ring_radius);
    pack(fs_enabled);        // SPA-20 fullscreen-abyss levers (must match the payload unpack order; appended last).
    pack(fs_scale);
    pack(fs_easing);
    pack(fs_duration);
    pack(fs_delay);
    pack(fs_fade);
    pack(enter_delay);  // SPA slide stagger (s); unpack order in do_space_focus_animated MUST mirror this
    pack(exit_delay);
    pack(fade_enter_delay);  // SPA fade sub-timeline (s); unpack order MUST mirror this
    pack(fade_exit_delay);
    pack(fade_enter_dur);
    pack(fade_exit_dur);
    return sa_payload_send(SA_OPCODE_SPACE_ANIMATE);
}

bool scripting_addition_animate_edge_nudge(uint64_t sid, int32_t dx, int32_t dy, uint32_t duration_ms, uint32_t steps)
{
    sa_payload_init();
    pack(sid);
    pack(dx);
    pack(dy);
    pack(duration_ms);
    pack(steps);
    return sa_payload_send(SA_OPCODE_SPACE_NUDGE);
}

bool scripting_addition_focus_ring_show(uint32_t wid, float x, float y, float w, float h, float radius, float stroke_width, float stroke_alpha, float stroke_r, float stroke_g, float stroke_b, bool force_style, int blur_radius, int style, float blur_saturation, float blur_brightness, int blend_mode, bool blur_stroke, int blur_stroke_position, float blur_stroke_width, float blur_bleed, float tint_r, float tint_g, float tint_b, float tint_a, float str_r, float str_g, float str_b, float str_a, float blur_contrast, float blur_feather, bool animate, float animate_duration, float fade_duration, float blur_hue, bool xray, float xray_r, float xray_g, float xray_b, float xray_a, int xray_count, CGRect *xray_rects, float window_alpha)
{
    sa_payload_init();
    pack(wid);
    pack(x);
    pack(y);
    pack(w);
    pack(h);
    pack(radius);
    pack(stroke_width);
    pack(stroke_alpha);
    pack(stroke_r);
    pack(stroke_g);
    pack(stroke_b);
    uint8_t fs = force_style ? 1 : 0;
    pack(fs);
    int32_t br = blur_radius;
    pack(br);
    int32_t st = style;
    pack(st);
    pack(blur_saturation);
    pack(blur_brightness);
    int32_t bm = blend_mode;
    pack(bm);
    uint8_t bs = blur_stroke ? 1 : 0;
    pack(bs);
    int32_t bsp = blur_stroke_position;
    pack(bsp);
    pack(blur_stroke_width);
    pack(blur_bleed);
    pack(tint_r);
    pack(tint_g);
    pack(tint_b);
    pack(tint_a);
    pack(str_r);
    pack(str_g);
    pack(str_b);
    pack(str_a);
    pack(blur_contrast);
    pack(blur_feather);   // appended (wire contract — never reorder)
    uint8_t an = animate ? 1 : 0;
    pack(an);
    pack(animate_duration);
    pack(fade_duration);   // appended (wire contract — never reorder)
    // Target's z-band, read daemon-side so the ring can share it (the payload
    // orders the ring relative to this wid; a BSP target sits at sublevel -20).
    // window_sub_level() is Tahoe-correct — the raw SLSGetWindowSubLevel SPI
    // returns 0 on Tahoe, so this read must NOT happen payload-side.
    int32_t target_level    = wid ? window_level(wid)     : 0;
    int32_t target_sublevel = wid ? window_sub_level(wid) : 0;
    pack(target_level);     // appended (wire contract — never reorder)
    pack(target_sublevel);  // appended (wire contract — never reorder)
    pack(blur_hue);         // appended (wire contract — never reorder)
    // FR-21 xray: flag + RGBA + rect count close the FIXED struct (the payload's
    // packed req mirrors through xray_count); the rects follow variable-length.
    uint8_t xr = xray ? 1 : 0;
    pack(xr);
    pack(xray_r);
    pack(xray_g);
    pack(xray_b);
    pack(xray_a);
    int32_t xn = (xray_rects && xray_count > 0) ? xray_count : 0;
    if (xn > SA_FOCUS_RING_XRAY_MAX_RECTS) xn = SA_FOCUS_RING_XRAY_MAX_RECTS;
    pack(xn);
    // appended (wire contract — never reorder): whole-window translucency, the
    // window's NORMAL alpha slot (visibility/fades ride the SYSTEM slot). Packs
    // inside the payload's fixed struct; the xray rects still follow it.
    pack(window_alpha);
    for (int i = 0; i < xn; ++i) {
        float rx = (float)xray_rects[i].origin.x;
        float ry = (float)xray_rects[i].origin.y;
        float rw = (float)xray_rects[i].size.width;
        float rh = (float)xray_rects[i].size.height;
        pack(rx);
        pack(ry);
        pack(rw);
        pack(rh);
    }
    return sa_payload_send(SA_OPCODE_FOCUS_RING_SHOW);
}

bool scripting_addition_focus_ring_hide(void)
{
    sa_payload_init();
    return sa_payload_send(SA_OPCODE_FOCUS_RING_HIDE);
}

bool scripting_addition_focus_ring_set_visible(bool visible)
{
    sa_payload_init();
    uint8_t v = visible ? 1 : 0;
    pack(v);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_SET_VISIBLE);
}

// FR-19: animated dismiss/reveal of the active ring (desktop toggle / Esc).
bool scripting_addition_focus_ring_fade_visible(bool visible, int fade_ms, int easing)
{
    sa_payload_init();
    uint8_t v = visible ? 1 : 0;
    pack(v);
    int32_t fm = fade_ms;
    pack(fm);
    int32_t ez = easing;
    pack(ez);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_FADE_VISIBLE);
}

// FR-9: ride a space switch — vanish the outgoing space's parked ring, reveal
// the incoming space's (which rides in with the slide as a space member).
bool scripting_addition_focus_ring_space_switch(uint64_t out_sid, uint64_t in_sid, int fade_ms, int easing,
                                                uint32_t dest_wid, CGRect dest_rect, float dest_radius)
{
    sa_payload_init();
    pack(out_sid);
    pack(in_sid);
    int32_t fm = fade_ms;
    pack(fm);
    int32_t ez = easing;
    pack(ez);
    // Destination focused window (for the park-on-miss path). Order/width must
    // match the packed req struct in do_focus_ring_space_switch.
    pack(dest_wid);
    float dx = dest_rect.origin.x,    dy = dest_rect.origin.y;
    float dw = dest_rect.size.width,  dh = dest_rect.size.height;
    pack(dx); pack(dy); pack(dw); pack(dh);
    pack(dest_radius);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_SPACE_SWITCH);
}

// MC-exit ring ride: arm the payload's MC-mode transform mirror on `wid`. The
// payload resolves the base frame (SLSGetScreenRectForWindow — final throughout
// the exit) and reads the live CGSGetWindowTransform3D each VBL.
bool scripting_addition_focus_ring_mc_ride(uint32_t wid)
{
    sa_payload_init();
    pack(wid);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_MC_RIDE);
}

bool scripting_addition_focus_ring_mc_enter_ride(uint32_t wid)
{
    sa_payload_init();
    pack(wid);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_MC_ENTER_RIDE);
}

bool scripting_addition_scale_window_custom(uint32_t wid, float tx, float ty, float tw, float th)
{
    sa_payload_init();
    pack(wid);
    pack(tx);
    pack(ty);
    pack(tw);
    pack(th);
    return sa_payload_send(SA_OPCODE_WINDOW_SCALE_CUSTOM);
}

bool scripting_addition_batch_transform(struct sa_transform_batch *batch)
{
    if (!batch || batch->count == 0) return true;
    sa_payload_init();
    pack(batch->count);
    for (uint32_t i = 0; i < batch->count; ++i) {
#define X(t, n) pack(batch->windows[i].n);
        SA_XFORM_BATCH_ROW_FIELDS(X)   // AC-23: order single-sourced with do_window_transform_batch
#undef X
    }
    return sa_payload_send(SA_OPCODE_WINDOW_TRANSFORM_BATCH);
}

bool scripting_addition_batch_transform_3d(struct sa_transform_3d_batch *batch)
{
    if (!batch || batch->count == 0) return true;
    if (batch->count > SA_BATCH_TRANSFORM_3D_MAX) return false;
    sa_payload_init();
    pack(batch->count);
    for (uint32_t i = 0; i < batch->count; ++i) {
        pack(batch->windows[i].wid);
        for (int j = 0; j < 16; ++j) {
            pack(batch->windows[i].m[j]);
        }
    }
    return sa_payload_send(SA_OPCODE_WINDOW_TRANSFORM_3D_BATCH);
}

bool scripting_addition_animate_window_lockedbounds(uint32_t wid, float fade_duration, float cx, float cy, float cw, float ch, float min_opacity, float progress)
{
    sa_payload_init();
    pack(wid);
    pack(fade_duration);
    pack(cx);
    pack(cy);
    pack(cw);
    pack(ch);
    pack(min_opacity);
    pack(progress);
    return sa_payload_send(SA_OPCODE_WINDOW_LOCKEDBOUNDS_ANIMATE);
}
bool scripting_addition_clear_lockedbounds(uint32_t wid)
{
    sa_payload_init();
    pack(wid);
    return sa_payload_send(SA_OPCODE_WINDOW_LOCKEDBOUNDS_CLEAR);
}

bool scripting_addition_set_border_lockedbounds(uint32_t border_wid, uint32_t clip_wid, float border_width, float x, float y, float w, float h)
{
    sa_payload_init();
    pack(border_wid);
    pack(clip_wid);
    pack(border_width);
    pack(x);
    pack(y);
    pack(w);
    pack(h);
    return sa_payload_send(SA_OPCODE_BORDER_LOCKEDBOUNDS_SET);
}


bool scripting_addition_batch_animate_with_lockedbounds(struct sa_lockedbounds_batch *batch)
{
    sa_payload_init();
    pack(batch->count);
    pack(batch->fade_duration);

    for (uint32_t i = 0; i < batch->count; ++i) {
#define X(t, n) pack(batch->windows[i].n);
        SA_LB_BATCH_ROW_FIELDS(X)   // AC-23: same list as the animate_window_list packer + the payload unpacker
#undef X
    }

    return sa_payload_send(SA_OPCODE_WINDOW_LOCKEDBOUNDS_BATCH);
}

bool scripting_addition_batch_animate_with_lockedbounds_t3d(struct sa_lockedbounds_t3d_batch *batch)
{
    sa_payload_init();
    pack(batch->count);
    pack(batch->flags);
    pack(batch->fade_duration);

    for (uint32_t i = 0; i < batch->count; ++i) {
#define X(t, n) pack(batch->windows[i].n);
        SA_ANIM_BATCH_ROW_FIELDS(X)   // AC-23: order single-sourced with do_window_lockedbounds_translate3d_batch
#undef X
    }

    return sa_payload_send(SA_OPCODE_WINDOW_LOCKEDBOUNDS_TRANSLATE3D_BATCH);
}

// AC-9: pack order is generated from the SA_ANIM_*_FIELDS X-macro lists in
// common_experimental.h — the SAME lists do_anim_ax_begin expands to unpack, so
// the two sides cannot drift field-for-field. To add a wire field, edit the list.
bool scripting_addition_anim_ax_begin(struct sa_anim_ax_begin *b)
{
    sa_payload_init();
#define X(t, dn, pn) pack(b->dn);
    SA_ANIM_HDR_FIELDS(X)
#undef X
    // Pile pose block — only when SA_T3D_FLAG_PILE, so the wire stays
    // byte-identical to the pre-pile format for every non-pile animation.
    bool pile = (b->flags & SA_T3D_FLAG_PILE) != 0;
    if (pile) {
#define X(t, dn, pn) pack(b->dn);
        SA_ANIM_PILE_FIELDS(X)
#undef X
    }
    for (uint32_t i = 0; i < b->count; ++i) {
#define X(t, dn, pn) pack(b->windows[i].dn);
        SA_ANIM_ROW_FIELDS(X)
#undef X
        if (pile) pack(b->windows[i].depth);
    }
    return sa_payload_send(SA_OPCODE_ANIM_AX_BEGIN);
}

uint32_t scripting_addition_anim_skip_all_to_end(void)
{
    sa_payload_init();
    *(int16_t *)bytes = length - sizeof(length);
    bytes[sizeof(length)] = SA_OPCODE_ANIM_SKIP_ALL;

    int sockfd;
    uint32_t result = 0;

    if (!socket_open(&sockfd)) return 0;
    if (socket_connect(sockfd, g_sa_socket_file)) {
        if (send(sockfd, bytes, length, 0) != -1) {
            uint32_t reply = 0;
            if (recv(sockfd, &reply, sizeof(reply), 0) == (ssize_t)sizeof(reply)) result = reply;
        }
    }
    socket_close(sockfd);
    return result;
}

bool scripting_addition_freeze_windows(uint32_t *wids, int count)
{
    if (count <= 0) return true;
    sa_payload_init();
    uint32_t n = (uint32_t)count;
    pack(n);
    for (int i = 0; i < count; ++i) {
        pack(wids[i]);
    }
    return sa_payload_send(SA_OPCODE_WINDOW_FREEZE_BATCH);
}

bool scripting_addition_thaw_windows(uint32_t *wids, int count)
{
    if (count <= 0) return true;
    sa_payload_init();
    uint32_t n = (uint32_t)count;
    pack(n);
    for (int i = 0; i < count; ++i) {
        pack(wids[i]);
    }
    return sa_payload_send(SA_OPCODE_WINDOW_THAW_BATCH);
}

// Pin a window list to identity Transform3D for dur_ms (async, payload-side) — suppresses
// the MC scale nudge after a server-side space op. Wire: (dur_ms, count, wids...).
bool scripting_addition_pin_windows(uint32_t *window_list, int window_count, uint32_t dur_ms)
{
    if (window_count <= 0) return true;   // nothing to pin
    uint32_t count = (uint32_t)window_count;
    sa_payload_init();
    pack(dur_ms);
    pack(count);
    for (int i = 0; i < window_count; ++i) pack(window_list[i]);
    return sa_payload_send(SA_OPCODE_PIN_WINDOWS);
}

// Rebuild Dock's MC strip via -[Spaces handleDisplayReconfig] (no wire payload).
bool scripting_addition_spaces_reconfig(void)
{
    sa_payload_init();
    return sa_payload_send(SA_OPCODE_SPACES_RECONFIG);
}

bool scripting_addition_set_expose_animation_duration(double duration)
{
    sa_payload_init();
    pack(duration);
    return sa_payload_send(SA_OPCODE_SET_EXPOSE_ANIMATION_DURATION);
}

#undef sa_payload_init
#undef pack
#undef sa_payload_send
