// window_transform.inc.m — per-frame LB/Transform3D geometry batches, driven by the daemon's animator.
// NOTE: include before focus_ring.inc.m — the debug LB+T3D batch forward-declares
// payload_focus_ring_follower (body there); production reaches the ring via the follower registry.

static void do_window_transform_batch(char *message)
{
    uint32_t count;
    unpack(count);
    if (count == 0 || count > 128) return;

    int cid = SLSMainConnectionID();
    CFTypeRef transaction = SLSTransactionCreate(cid);
    if (!transaction) return;

    for (uint32_t i = 0; i < count; ++i) {
#define X(t, n) t n;
        SA_XFORM_BATCH_ROW_FIELDS(X)
#undef X
#define X(t, n) unpack(n);
        SA_XFORM_BATCH_ROW_FIELDS(X)
#undef X
        if (!wid) continue;

        CGAffineTransform t = {
            .a = a, .b = b, .c = c, .d = d,
            .tx = tx, .ty = ty,
        };
        SLSTransactionSetWindowTransform(transaction, wid, 0, 0, t);
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

// NOTE: cap 24 — each row is wid + 16 doubles (132 B); keeps a full batch inside SA_SOCKET_BUFF_LEN.
extern CGError SLSTransactionSetWindowTransform3D(CFTypeRef transaction, uint32_t wid, double *t);

static void do_window_transform_3d_batch(char *message)
{
    uint32_t count;
    unpack(count);
    if (count == 0 || count > 24) return;

    int cid = SLSMainConnectionID();
    CFTypeRef transaction = SLSTransactionCreate(cid);
    if (!transaction) return;

    for (uint32_t i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        double m[16];
        for (int j = 0; j < 16; ++j) {
            unpack(m[j]);
        }
        if (!wid) continue;

        SLSTransactionSetWindowTransform3D(transaction, wid, m);
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_scale_custom(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    float tx, ty, tw, th;
    unpack(tx);
    unpack(ty);
    unpack(tw);
    unpack(th);
    if (tw <= 0 || th <= 0) return;

    CGRect frame = {};
    SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame);
    if (frame.size.width <= 0 || frame.size.height <= 0) return;

    CGAffineTransform original_transform = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);

    CGAffineTransform current_transform;
    SLSGetWindowTransform(SLSMainConnectionID(), wid, &current_transform);

    if (CGAffineTransformEqualToTransform(current_transform, original_transform)) {
        float x_scale = frame.size.width  / tw;
        float y_scale = frame.size.height / th;

        CGFloat transformed_x = -tx;
        CGFloat transformed_y = -ty;

        CGAffineTransform scale = CGAffineTransformMakeScale(x_scale, y_scale);
        CGAffineTransform transform = CGAffineTransformTranslate(scale, transformed_x, transformed_y);
        SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
    } else {
        SLSSetWindowTransform(SLSMainConnectionID(), wid, original_transform);
    }
}

// NOTE: stateless absolute map, streamed per-frame during drags — no toggle/restore
// branch (do_window_scale_custom owns the toggle idiom).
static void do_window_scale_rect(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    float tx, ty, tw, th;
    unpack(tx);
    unpack(ty);
    unpack(tw);
    unpack(th);
    if (tw <= 0 || th <= 0) return;

    int cid = SLSMainConnectionID();
    CGRect frame = {};
    SLSGetWindowBounds(cid, wid, &frame);
    if (frame.size.width <= 0 || frame.size.height <= 0) return;

    window_commit_scale_rect_transform(cid, wid, frame, CGRectMake(tx, ty, tw, th));
}

static void do_window_lockedbounds_animation(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) {
        return;
    }
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) {
        logpf("PAYLOAD", "lockedbounds_animation: SLSTransactionCreate FAIL wid=%u", wid);
        return;
    }

    float fade_duration;
    unpack(fade_duration);
   
    float cx, cy, cw, ch;
   
    unpack(cx);
    unpack(cy);
    unpack(cw);
    unpack(ch);
    
    float min_opacity;
    unpack(min_opacity);
    
    float progress;
    unpack(progress);
    
    CGRect current_frame = { .origin={cx, cy}, .size={cw, ch}};
    
    CGSRegionRef frame_region;
    CGSNewRegionWithRect(&current_frame, &frame_region);
    if (frame_region) {
        SLSSetWindowShape(SLSMainConnectionID(), wid, -9999, -9999, frame_region);
        CFRelease(frame_region);
    }
    
    CGPoint origin = current_frame.origin;
    SLSTransactionMoveWindowWithGroup(transaction, wid, origin);
    
    if (fade_duration > 0.0f) {
        float alpha = min_opacity + (1.0f - min_opacity) * progress;
        // NOTE: per-frame instant alpha only — SLSTransactionSetWindowAlphaAnimated SIGSEGVs
        // WindowServer (CGXWindow::fade_finish).
        SLSTransactionSetWindowAlpha(transaction, wid, alpha);
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}


extern CGError SLSWindowFreezeWithOptions(int cid, uint32_t wid, CFDictionaryRef options);
extern CGError SLSWindowThaw(int cid, uint32_t wid);

static void do_window_freeze_batch(char *message)
{
    uint32_t count;
    unpack(count);
    if (count == 0 || count > 128) {
        return;
    }

    int cid = SLSMainConnectionID();

    CFMutableDictionaryRef opts = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    for (uint32_t i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;
        SLSWindowFreezeWithOptions(cid, wid, opts);
    }

    CFRelease(opts);
}

static void do_window_thaw_batch(char *message)
{
    uint32_t count;
    unpack(count);
    if (count == 0 || count > 128) {
        return;
    }

    int cid = SLSMainConnectionID();

    for (uint32_t i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;
        SLSWindowThaw(cid, wid);
    }
}

static void do_window_lockedbounds_clear(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) {
        return;
    }

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) {
        logpf("PAYLOAD", "lockedbounds_clear: SLSTransactionCreate FAIL wid=%u", wid);
        return;
    }
    SLSTransactionClearWindowLockedBounds(transaction, wid);
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_lockedbounds_batch(char *message)
{
    uint32_t count;
    float fade_duration;
    
    unpack(count);
    unpack(fade_duration);
    
    if (count == 0 || count > 128) {
        return;
    }
    
    int cid = SLSMainConnectionID();
    
    char *message_start = message;
       
    
    CFTypeRef transaction = SLSTransactionCreate(cid);
    if (!transaction) {
        logpf("PAYLOAD", "lockedbounds_batch: SLSTransactionCreate FAIL count=%u", count);
        return;
    }

    for (uint32_t i = 0; i < count; ++i) {
#define X(t, n) t n;
        SA_LB_BATCH_ROW_FIELDS(X)
#undef X
#define X(t, n) unpack(n);
        SA_LB_BATCH_ROW_FIELDS(X)
#undef X
        if (!wid) continue;

        CGRect bounds = CGRectMake(x, y, w, h);
        SLSTransactionSetWindowLockedBounds(transaction, wid, bounds);

        float opacity = 1.0f - ((1.0f - min_opacity) * (1.0f - fabsf(progress - 0.5f) * 2.0f));
        SLSTransactionSetWindowAlpha(transaction, wid, opacity);
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);

}

// Debug-only LB+T3D batch (production animator: anim.inc.m). T3D translate is
// screen-relative: tx = -xs * (lerp - anchor).
static void payload_focus_ring_follower(CFTypeRef tx, uint32_t wid, CGRect rect);

static void t3dlog_rect(char *b, size_t n, bool on,
                        double x, double y, double w, double h) {
    if (on) snprintf(b, n, "%6.0f,%6.0f %6.0fx%6.0f", x, y, w, h);
    else    snprintf(b, n, "%6s%21s", "--", "");
}
static void t3dlog_size(char *b, size_t n, double w, double h) {
    snprintf(b, n, "%14s%6.0fx%6.0f", "", w, h);
}

static void do_window_lockedbounds_translate3d_batch(char *message)
{
    uint32_t count;
    uint32_t flags;
    float fade_duration;
    unpack(count);
    unpack(flags);
    unpack(fade_duration);
    if (count == 0 || count > 64) return;

    int cid = SLSMainConnectionID();
    CFTypeRef transaction = SLSTransactionCreate(cid);
    if (!transaction) return;

    bool do_lb      = (flags & SA_T3D_FLAG_LB)      != 0;
    bool do_t3      = (flags & SA_T3D_FLAG_T3)      != 0;
    bool do_alpha   = (flags & SA_T3D_FLAG_ALPHA)   != 0;
    bool lb_full    = (flags & SA_T3D_FLAG_LB_FULL) != 0;
    bool t3_full    = (flags & SA_T3D_FLAG_T3_FULL) != 0;
    bool do_log     = (flags & SA_T3D_FLAG_LOG)     != 0;
    bool do_move    = (flags & SA_T3D_FLAG_MOVE)    != 0;

    for (uint32_t i = 0; i < count; ++i) {
#define X(t, n) t n;
        SA_ANIM_BATCH_ROW_FIELDS(X)
#undef X
#define X(t, n) unpack(n);
        SA_ANIM_BATCH_ROW_FIELDS(X)
#undef X
        if (!wid) continue;

        bool row_do_lb = do_lb;
        bool row_do_t3 = do_t3;
        switch (mode) {
            case SA_T3D_ROW_MODE_T3D_ONLY: row_do_lb = false; break;
            case SA_T3D_ROW_MODE_LB_ONLY:  row_do_t3 = false; break;
            case SA_T3D_ROW_MODE_LB_T3D:
            default:                       break;
        }

        if (do_move) {
            SLSTransactionMoveWindowWithGroup(transaction, wid, CGPointMake(anchor_x, anchor_y));
        }

        // NOTE: clamp the lerp to the wire min/max — hard-constraint apps (VLC, Terminal) reject
        // out-of-range bounds after commit and snap back (visible jitter). Both the T3D scale and
        // the LB rect must use clamped_* or the backing renders one size while LB displays another.
        float clamped_w = fmaxf(min_w, fminf(max_w, lerp_w));
        float clamped_h = fmaxf(min_h, fminf(max_h, lerp_h));

        if (row_do_t3) {
            double xs = 1.0, ys = 1.0;
            if (t3_full && clamped_w > 0.0f && clamped_h > 0.0f) {
                xs = (double)anchor_w / (double)clamped_w;
                ys = (double)anchor_h / (double)clamped_h;
            }
            double dx = (double)lerp_x - (double)anchor_x;
            double dy = (double)lerp_y - (double)anchor_y;
            double tx = -xs * dx;
            double ty = -ys * dy;
            double m[16] = {
                xs,  0.0, 0.0, 0.0,
                0.0, ys,  0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                tx,  ty,  0.0, 1.0,
            };
            SLSTransactionSetWindowTransform3D(transaction, wid, m);
        }

        if (row_do_lb) {
            float lb_x = lb_full ? lerp_x : anchor_x;
            float lb_y = lb_full ? lerp_y : anchor_y;
            CGRect bounds = CGRectMake(lb_x, lb_y, clamped_w, clamped_h);
            // NOTE: a real place drops LockedBounds visibility — keep the
            // 0x7ffffeff sentinel (non-AtPlace wrapper).
            SLSTransactionSetWindowLockedBounds(transaction, wid, bounds);
        }

        if (do_alpha) {
            float opacity = 1.0f - ((1.0f - min_opacity) * (1.0f - fabsf(progress - 0.5f) * 2.0f));
            SLSTransactionSetWindowAlpha(transaction, wid, opacity);
        }

        payload_focus_ring_follower(transaction, wid, CGRectMake(lerp_x, lerp_y, clamped_w, clamped_h));

        if (do_log) {
            float  llb_x = lb_full ? lerp_x : anchor_x;
            float  llb_y = lb_full ? lerp_y : anchor_y;
            double lxs = 1.0, lys = 1.0;
            if (row_do_t3 && t3_full && clamped_w > 0.0f && clamped_h > 0.0f) {
                lxs = (double)anchor_w / (double)clamped_w;
                lys = (double)anchor_h / (double)clamped_h;
            }
            double ltx = row_do_t3 ? -lxs * ((double)lerp_x - (double)anchor_x) : 0.0;
            double lty = row_do_t3 ? -lys * ((double)lerp_y - (double)anchor_y) : 0.0;
            char lerp_b[32], clamp_b[32], lb_b[32], t3_b[36];
            t3dlog_rect(lerp_b, sizeof lerp_b, true, lerp_x, lerp_y, lerp_w, lerp_h);
            t3dlog_size(clamp_b, sizeof clamp_b, clamped_w, clamped_h);
            t3dlog_rect(lb_b, sizeof lb_b, row_do_lb, llb_x, llb_y, clamped_w, clamped_h);
            if (row_do_t3)
                snprintf(t3_b, sizeof t3_b, "s%.2f,%.2f t%.0f,%.0f", lxs, lys, ltx, lty);
            else
                snprintf(t3_b, sizeof t3_b, "--");
            logpf("T3D_APPLY",
                "w%-3u mt%.3f       lerp %s clamp %s lb %s t3 %s",
                wid, progress, lerp_b, clamp_b, lb_b, t3_b);
        }
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_border_lockedbounds_set(char *message)
{
    uint32_t border_wid, clip_wid;
    float border_width;
    unpack(border_wid);
    unpack(clip_wid);
    unpack(border_width);
    
    logpf("PAYLOAD", "Border animation called: border_wid=%u, clip_wid=%u, width=%f", border_wid, clip_wid, border_width);
    
    if (!border_wid || !clip_wid) {
        logpf("PAYLOAD", "Border animation skipped - missing WIDs");
        return;
    }
    
    float x, y, w, h;
    unpack(x);
    unpack(y);
    unpack(w);
    unpack(h);
    
    logpf("PAYLOAD", "Border frame data: x=%.1f, y=%.1f, w=%.1f, h=%.1f, width=%.1f", x, y, w, h, border_width);
    
    CGRect window_frame = CGRectMake(x, y, w, h);
    
    float half_border = (border_width / 2.0f);
    
    CGRect border_frame = CGRectMake(
        x - border_width - half_border - 2.0f,
        y - border_width - half_border - 2.0f,
        w + (border_width * 2) + border_width + 4.0f,
        h + (border_width * 2) + border_width + 4.0f
    );
    
    float clip_inset = -50.0f;
    CGRect clip_bounds = CGRectMake(border_width + half_border + (clip_inset / 2.0f), border_width + half_border + (clip_inset / 2.0f), w - clip_inset, h - clip_inset);
    
    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) {
        logpf("PAYLOAD", "border_lockedbounds_set: SLSTransactionCreate FAIL border_wid=%u", border_wid);
        return;
    }

    SLSTransactionSetWindowLockedBounds(transaction, border_wid, border_frame);
    
    SLSTransactionSetWindowLockedBounds(transaction, clip_wid, clip_bounds);
    
    SLSTransactionCommit(transaction, 1);
    CFRelease(transaction);
    
    CGContextRef border_context = SLSGetWindowLayerContext(SLSMainConnectionID(), border_wid);
    
    if (border_context) {
        logpf("PAYLOAD", "Got border window layer context: %p", border_context);
        
        CGMutablePathRef clip_path = CGPathCreateMutable();
        
        CGRect outer_rect = CGRectMake(0, 0, border_frame.size.width, border_frame.size.height);
        CGPathAddRect(clip_path, NULL, outer_rect);
        
        CGRect inner_rect = CGRectMake(
            border_width + half_border + 20.0f,
            border_width + half_border + 2.0f,
            w,
            h
        );
        CGPathAddRect(clip_path, NULL, inner_rect);
        
        logpf("PAYLOAD", "Setting clip path - outer: (%.1f,%.1f,%.1fx%.1f), inner: (%.1f,%.1f,%.1fx%.1f)", 
              outer_rect.origin.x, outer_rect.origin.y, outer_rect.size.width, outer_rect.size.height,
              inner_rect.origin.x, inner_rect.origin.y, inner_rect.size.width, inner_rect.size.height);
        
        CGContextAddPath(border_context, clip_path);
        CGContextClip(border_context);
        
        CGContextSetRGBFillColor(border_context, 1.0, 0.0, 0.0, 0.8);
        CGContextFillRect(border_context, outer_rect);
        
        CGPathRelease(clip_path);
        logpf("PAYLOAD", "Applied clipping path and fill to border context");
    } else {
        logpf("PAYLOAD", "Failed to get border window layer context");
    }
}
