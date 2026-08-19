// sa_inc/sa_experimental.inc.m — non-upstream scripting_addition_* wrappers,
// #include'd at the bottom of sa.m (single TU: sa.m's static helpers and the
// pack macros are in scope). Payload counterpart: payload_inc/dispatch_experimental.inc.m.
// NOTE: pack order in every wrapper is the wire — it must mirror the payload
// unpacker field-for-field; new fields append at the end only.

// NOTE: the pack order IS the wire contract — do_space_focus_animated unpacks in
// exactly this order, and any change to it needs an OSAX_VERSION bump.
bool scripting_addition_animate_space(uint64_t out_sid, uint64_t in_sid, int32_t direction, float duration, double width, double gap, uint32_t did, float refresh_hz, uint8_t easing, uint32_t ring_wid, float ring_x, float ring_y, float ring_w, float ring_h, float ring_radius, float enter_delay, float exit_delay)
{
    sa_payload_init();
    pack(out_sid);
    pack(in_sid);
    pack(direction);
    pack(duration);
    pack(width);
    pack(gap);
    pack(did);
    pack(refresh_hz);
    pack(easing);
    pack(ring_wid);
    pack(ring_x);
    pack(ring_y);
    pack(ring_w);
    pack(ring_h);
    pack(ring_radius);
    pack(enter_delay);
    pack(exit_delay);
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

bool scripting_addition_focus_ring_show(uint32_t wid, float x, float y, float w, float h, float radius, float stroke_width, float stroke_alpha, float stroke_r, float stroke_g, float stroke_b, bool force_style, int blur_radius, int style, float blur_saturation, float blur_brightness, int blend_mode, bool blur_stroke, int blur_stroke_position, float blur_stroke_width, float blur_bleed, float tint_r, float tint_g, float tint_b, float tint_a, float str_r, float str_g, float str_b, float str_a, float blur_contrast, float blur_feather, float fade_duration, float blur_hue, bool xray, float xray_r, float xray_g, float xray_b, float xray_a, int xray_count, CGRect *xray_rects, float window_alpha)
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
    pack(blur_feather);
    pack(fade_duration);
    // NOTE: level/sublevel read daemon-side — window_sub_level() papers over
    // SLSGetWindowSubLevel returning 0 on Tahoe; this read must not move payload-side.
    int32_t target_level    = wid ? window_level(wid)     : 0;
    int32_t target_sublevel = wid ? window_sub_level(wid) : 0;
    pack(target_level);
    pack(target_sublevel);
    pack(blur_hue);
    uint8_t xr = xray ? 1 : 0;
    pack(xr);
    pack(xray_r);
    pack(xray_g);
    pack(xray_b);
    pack(xray_a);
    int32_t xn = (xray_rects && xray_count > 0) ? xray_count : 0;
    if (xn > SA_FOCUS_RING_XRAY_MAX_RECTS) xn = SA_FOCUS_RING_XRAY_MAX_RECTS;
    pack(xn);
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

bool scripting_addition_focus_ring_retarget(uint32_t wid, float x, float y, float w, float h, float duration, int easing)
{
    sa_payload_init();
    pack(wid);
    pack(x);
    pack(y);
    pack(w);
    pack(h);
    pack(duration);
    int32_t ez = easing;
    pack(ez);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_RETARGET);
}

bool scripting_addition_focus_ring_set_visible(bool visible)
{
    sa_payload_init();
    uint8_t v = visible ? 1 : 0;
    pack(v);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_SET_VISIBLE);
}

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
    pack(dest_wid);
    float dx = dest_rect.origin.x,    dy = dest_rect.origin.y;
    float dw = dest_rect.size.width,  dh = dest_rect.size.height;
    pack(dx); pack(dy); pack(dw); pack(dh);
    pack(dest_radius);
    return sa_payload_send(SA_OPCODE_FOCUS_RING_SPACE_SWITCH);
}

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
        SA_XFORM_BATCH_ROW_FIELDS(X)
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
        SA_LB_BATCH_ROW_FIELDS(X)
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
        SA_ANIM_BATCH_ROW_FIELDS(X)
#undef X
    }

    return sa_payload_send(SA_OPCODE_WINDOW_LOCKEDBOUNDS_TRANSLATE3D_BATCH);
}

bool scripting_addition_anim_ax_begin(struct sa_anim_ax_begin *b)
{
    sa_payload_init();
#define X(t, dn, pn) pack(b->dn);
    SA_ANIM_HDR_FIELDS(X)
#undef X
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

bool scripting_addition_pin_windows(uint32_t *window_list, int window_count, uint32_t dur_ms)
{
    if (window_count <= 0) return true;
    uint32_t count = (uint32_t)window_count;
    sa_payload_init();
    pack(dur_ms);
    pack(count);
    for (int i = 0; i < window_count; ++i) pack(window_list[i]);
    return sa_payload_send(SA_OPCODE_PIN_WINDOWS);
}

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

// Persistent wallpaper floor. All the state lives payload-side (the spaces and
// windows are Dock-owned); the daemon half is four thin verbs over one wire
// struct: [u8 clear][u8 hide][u8 show][u8 keep_dock][u8 refresh].
struct __attribute__((packed)) wallpaper_floor_req {
    uint8_t clear, hide, show, keep_dock, refresh;
};

// NOTE: the payload reports the outcome only in this response, and a build that
// never reached the SA is indistinguishable from one that worked unless it is
// logged — the slide behaves completely differently with no floor under it.
static void wallpaper_floor_call(struct wallpaper_floor_req req)
{
    sa_payload_init();
    pack(req.clear);
    pack(req.hide);
    pack(req.show);
    pack(req.keep_dock);
    pack(req.refresh);
    if (pack_overflow) return;

    *(int16_t *)bytes = length - sizeof(length);
    bytes[sizeof(length)] = SA_OPCODE_WALLPAPER_FLOOR;

    int sockfd;
    char response[2048] = {0};

    if (!socket_open(&sockfd)) return;
    if (socket_connect(sockfd, g_sa_socket_file)) {
        if (send(sockfd, bytes, length, 0) != -1) {
            ssize_t n = recv(sockfd, response, sizeof(response) - 1, 0);
            if (n > 0) response[n] = '\0';
        }
    }
    socket_close(sockfd);

    LOGFT("WP_FLOOR", "clear=%u hide=%u show=%u refresh=%u -> %s",
          req.clear, req.hide, req.show, req.refresh,
          response[0] ? response : "NO RESPONSE (payload unreachable)");
}

void wallpaper_floor_build(void)   { wallpaper_floor_call((struct wallpaper_floor_req){0}); }
void wallpaper_floor_clear(void)   { wallpaper_floor_call((struct wallpaper_floor_req){.clear = 1}); }
void wallpaper_floor_refresh(void) { wallpaper_floor_call((struct wallpaper_floor_req){.refresh = 1}); }

void wallpaper_floor_set_hidden(bool hide)
{
    struct wallpaper_floor_req req = {0};
    req.hide = hide ? 1 : 0;
    req.show = hide ? 0 : 1;
    wallpaper_floor_call(req);
}

uint32_t scripting_addition_dock_fs_clamp(bool enable)
{
    sa_payload_init();
    int32_t on = enable;
    pack(on);
    if (pack_overflow) return 0;

    *(int16_t *)bytes = length - sizeof(length);
    bytes[sizeof(length)] = SA_OPCODE_DOCK_FS_CLAMP;

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

#undef sa_payload_init
#undef pack
#undef sa_payload_send
