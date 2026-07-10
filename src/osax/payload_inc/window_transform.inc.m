// window_transform.inc.m — LockedBounds + Transform3D geometry primitives.
//
// The per-frame geometry write path behind yabai's smooth window move/resize
// feature: 2D/3D transform batches, the SetWindowLockedBounds variants,
// WindowServer freeze/thaw, and the composed LB+T3D translate batch (the
// LB+T3D recipe — AX commits rasterization, LB smooths size, T3D smooths
// position). Border LockedBounds lives here too. These are driven per-frame
// from the daemon's animator; they do not own a render loop themselves.
//
// Include-order constraint (single TU): before focus_ring.inc.m —
// do_window_lockedbounds_translate3d_batch (a debug-only path) forward-declares
// the focus-ring follower payload_focus_ring_follower and calls it directly
// (body there). The production engine reaches the ring via the AC-6 follower
// registry instead. Case arms live in payload_inc/dispatch_experimental.inc.m.

// Apply a batch of CGAffineTransforms to wids in a single SLSTransaction
// on Dock's cid. Per-frame transform animation entry point — mirrors the
// lockedbounds_batch pattern (single round-trip per frame, multiple wids
// per call). Wire format per window: wid + 6 floats (a,b,c,d,tx,ty)
// representing the affine matrix.
static void do_window_transform_batch(char *message)
{
    uint32_t count;
    unpack(count);
    if (count == 0 || count > 128) return;

    int cid = SLSMainConnectionID();
    CFTypeRef transaction = SLSTransactionCreate(cid);
    if (!transaction) return;

    for (uint32_t i = 0; i < count; ++i) {
        // AC-23: row declared + unpacked from SA_XFORM_BATCH_ROW_FIELDS — the same
        // list the daemon packer expands, so the two orders can't drift.
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

// 3D batch — CATransform3D per wid via SLSTransactionSetWindowTransform3D.
// Each entry is wid (4 bytes) + 16 doubles (128 bytes) = 132 bytes; the
// conservative cap of 24 sits well inside the SA_SOCKET_BUFF_LEN budget.
// Caller chunks larger batches client-side.
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

// Toggle-scale a window to land inside an arbitrary target rect (tx, ty, tw, th).
// Mirrors do_window_scale's math but uses the explicit target rect directly
// instead of computing PiP from a display rect. First call: scale into rect.
// Second call (transform already matches scaled state): restore to natural.
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
    
    // SLSSetWindowShape rather than LockedBounds — matches the border update
    // pattern and avoids rendering artifacts.
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
        // Instant per-frame alpha only — the value is already lerped by
        // `progress`, so the fade is driven frame-by-frame. The animated-alpha
        // SPI (SLSTransactionSetWindowAlphaAnimated) SIGSEGVs WindowServer in
        // CGXWindow::fade_finish, so it must never be reached.
        SLSTransactionSetWindowAlpha(transaction, wid, alpha);
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}


// WindowServer freeze/thaw SPIs — freeze locks a window's current backing
// texture as the compositor's displayed content; thaw releases it (with an
// optional deletion delay, default 1.0s). Used here to mask the AX-driven
// resize race at the start of a LockedBounds animation.
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

    // Empty options dict → WindowServer defaults (whole-window freeze, no
    // size minimum, deletion delay 1.0s). A shorter deletion delay could be
    // set here if crossfade-on-thaw is desired.
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
        // AC-23: row declared + unpacked from SA_LB_BATCH_ROW_FIELDS (shared with
        // both daemon packers for this struct).
#define X(t, n) t n;
        SA_LB_BATCH_ROW_FIELDS(X)
#undef X
#define X(t, n) unpack(n);
        SA_LB_BATCH_ROW_FIELDS(X)
#undef X
        if (!wid) continue;

        CGRect bounds = CGRectMake(x, y, w, h);
        SLSTransactionSetWindowLockedBounds(transaction, wid, bounds);

        // Opacity: min_opacity at the ends, 1.0 at the progress midpoint.
        float opacity = 1.0f - ((1.0f - min_opacity) * (1.0f - fabsf(progress - 0.5f) * 2.0f));
        SLSTransactionSetWindowAlpha(transaction, wid, opacity);
    }

    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);

}

// Translate3D + LockedBounds per-frame — deferred/periodic-AX animation.
// XY via Transform3D translate; WH via SetWindowLockedBounds anchored at the
// caller-supplied "anchor" (= current AX position, which may be advancing if
// the daemon-side driver is firing periodic AX setFrame ticks).
//
// Matrix convention:
//   dx = rendered.x - natural.x       → (lerp_x - anchor_x) in our case
//   tx = -xs * dx                     → with xs=1: tx = -(lerp_x - anchor_x)
//   resulting screen_origin = natural_origin + (-tx, -ty) = rendered_origin ✓
// NB: the sign is the empirically-correct sign (live-verified).
//
// Wire format: count (4) + flags (4) + fade_duration (4) + per-window rows
// (SA_ANIM_BATCH_ROW_FIELDS — shared with the daemon packer). `flags` bits
// gate each SA-side API so callers can isolate which primitive does what
// (the daemon side independently controls AX setFrame via window_manager).
// Forward decl — the focus-ring follower (AC-6), body in focus_ring.inc.m. This
// debug-only batch path calls it directly (it's included before the LB+T3D engine,
// so it can't reach the follower registry the production pump iterates).
static void payload_focus_ring_follower(CFTypeRef tx, uint32_t wid, CGRect rect);

// Fixed-width rect / size formatters for the T3D_APPLY unified-log table.
// Right-align x,y,w,h into a 27-col slot (size pads the x,y cols so its w,h
// stack under a rect's w,h); idle channels render a padded "--".
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
        // AC-23: row declared + unpacked from SA_ANIM_BATCH_ROW_FIELDS — the same
        // list the daemon packer expands, so the orders can't drift.
#define X(t, n) t n;
        SA_ANIM_BATCH_ROW_FIELDS(X)
#undef X
#define X(t, n) unpack(n);
        SA_ANIM_BATCH_ROW_FIELDS(X)
#undef X
        if (!wid) continue;

        // Per-row mode dispatch: intersect the global flag bits with the
        // per-row mode for this row's effective LB/T3 application (LB_T3D
        // rows keep the global flags; T3D_ONLY/LB_ONLY drop one side).
        bool row_do_lb = do_lb;
        bool row_do_t3 = do_t3;
        switch (mode) {
            case SA_T3D_ROW_MODE_T3D_ONLY: row_do_lb = false; break;
            case SA_T3D_ROW_MODE_LB_ONLY:  row_do_t3 = false; break;
            case SA_T3D_ROW_MODE_LB_T3D:
            default:                       break;
        }

        // No-LB SLSMove+T3D path: commit the durable real position to the
        // endpin anchor (= end_xy) in the SAME transaction as the T3D below.
        // anchor is the pinned end origin, so this is idempotent frame-to-frame
        // (the app adopts it once via kCGSWindowDidMove); T3D then carries the
        // visual back to the lerp position. Must NOT be paired with LB — LB
        // masks the move and the position snaps back (live-verified).
        if (do_move) {
            SLSTransactionMoveWindowWithGroup(transaction, wid, CGPointMake(anchor_x, anchor_y));
        }

        // Per-frame SLS-constraint clamp. Daemon snapshotted the target app's
        // SLS min/max at animation-start (with per-pid cache fallback for
        // freshly-spawned windows whose AppKit publish is still in flight)
        // and pushed those values on the wire as min_*/max_*. We clamp the
        // lerp here to keep the per-frame LB+T3D writes inside the app's
        // valid range — without this, hard-constraint apps (VLC, Terminal,
        // AppKit min/max) reject out-of-range bounds and snap back after
        // commit, producing visible jitter. Unconstrained windows get
        // min=0, max=1e9 from the daemon so the clamp is a no-op.
        float clamped_w = fmaxf(min_w, fminf(max_w, lerp_w));
        float clamped_h = fmaxf(min_h, fminf(max_h, lerp_h));

        if (row_do_t3) {
            // Stage-convention matrix (see header).
            // Mode 1 (translate-only): xs=ys=1, translate from anchor to lerp.
            // Mode 2 (full, T3_FULL bit): xs = anchor_w/clamped_w, ys = anchor_h/clamped_h
            //                             (Stage Manager scale convention — >1 to shrink).
            //
            // IMPORTANT: scale uses clamped_w/clamped_h (not raw lerp_w/lerp_h).
            // The LB write below pins the displayed rect to clamped_*. If the
            // matrix scaled to raw lerp_* instead, the backing would render at
            // one size while LB displayed another → compositor stretch when the
            // animation starts from a constraint-violating start_* (window below
            // min or above max). For unconstrained windows clamped_* == lerp_*
            // so this is a no-op.
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
            // Mode 1 (size-only at anchor): pin origin to anchor_xy, lerp WH only.
            // Mode 2 (full XYWH, LB_FULL bit): LB origin lerps too (LB alone
            //                                  carries both axes).
            float lb_x = lb_full ? lerp_x : anchor_x;
            float lb_y = lb_full ? lerp_y : anchor_y;
            CGRect bounds = CGRectMake(lb_x, lb_y, clamped_w, clamped_h);
            // Not the AtPlace variant — it silently drops LB visibility
            // regardless of place value.
            SLSTransactionSetWindowLockedBounds(transaction, wid, bounds);
        }

        if (do_alpha) {
            float opacity = 1.0f - ((1.0f - min_opacity) * (1.0f - fabsf(progress - 0.5f) * 2.0f));
            SLSTransactionSetWindowAlpha(transaction, wid, opacity);
        }

        // focus_ring lockstep — if this batch entry is the currently-
        // tracked focus target, stroke the ring at its per-frame rect.
        // Use clamped_w/clamped_h (not raw lerp_w/lerp_h) so the ring
        // tracks the actually-rendered window size when constraints kick
        // in. Without this the ring sizes to the BSP node rect (e.g.
        // 250x150) while the window itself sits at min (e.g. 500x375),
        // leaving a visible gap. The IOSurface backing update lands
        // microseconds before the SLSTransactionCommit below (same thread,
        // same code path), so the compositor picks up the new backing
        // alongside this tick's transforms on the same refresh.
        payload_focus_ring_follower(transaction, wid, CGRectMake(lerp_x, lerp_y, clamped_w, clamped_h));

        if (do_log) {
            // What the payload actually fed to SLS this frame. Recompute the
            // applied LB rect + T3D matrix from the same inputs the row_do_lb /
            // row_do_t3 blocks used (scale off clamped_*, not raw lerp_*), so a
            // T3D_APPLY line can be diffed against the daemon's T3D_FRAME line
            // for the same wid/progress to spot intent-vs-applied drift.
            float  llb_x = lb_full ? lerp_x : anchor_x;
            float  llb_y = lb_full ? lerp_y : anchor_y;
            double lxs = 1.0, lys = 1.0;
            if (row_do_t3 && t3_full && clamped_w > 0.0f && clamped_h > 0.0f) {
                lxs = (double)anchor_w / (double)clamped_w;
                lys = (double)anchor_h / (double)clamped_h;
            }
            double ltx = row_do_t3 ? -lxs * ((double)lerp_x - (double)anchor_x) : 0.0;
            double lty = row_do_t3 ? -lys * ((double)lerp_y - (double)anchor_y) : 0.0;
            // Fixed-width columns so APPLY lines stack frame-to-frame. Idle
            // channels show a padded `--` to keep later columns aligned. lb/t3
            // are the last fields, so even an over-wide t3 can't shift others.
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
    
    // Border window: positioned and sized to surround the target area  
    CGRect border_frame = CGRectMake(
        x - border_width - half_border - 2.0f,
        y - border_width - half_border - 2.0f,
        w + (border_width * 2) + border_width + 4.0f,
        h + (border_width * 2) + border_width + 4.0f
    );
    
    float clip_inset = -50.0f;  // debug tuning: negative inset oversizes the clip
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
        
        // Clip path: outer border rect + inner hole over the window content.
        CGMutablePathRef clip_path = CGPathCreateMutable();
        
        CGRect outer_rect = CGRectMake(0, 0, border_frame.size.width, border_frame.size.height);
        CGPathAddRect(clip_path, NULL, outer_rect);
        
        // Inner hole, positioned relative to the border window's origin.
        CGRect inner_rect = CGRectMake(
            border_width + half_border + 20.0f,  // x offset from border edge
            border_width + half_border + 2.0f,  // y offset from border edge  
            w,                                   // original window width
            h                                    // original window height
        );
        CGPathAddRect(clip_path, NULL, inner_rect);
        
        logpf("PAYLOAD", "Setting clip path - outer: (%.1f,%.1f,%.1fx%.1f), inner: (%.1f,%.1f,%.1fx%.1f)", 
              outer_rect.origin.x, outer_rect.origin.y, outer_rect.size.width, outer_rect.size.height,
              inner_rect.origin.x, inner_rect.origin.y, inner_rect.size.width, inner_rect.size.height);
        
        CGContextAddPath(border_context, clip_path);
        CGContextClip(border_context);
        
        // Debug fill: visible red so the ring shape can be checked.
        CGContextSetRGBFillColor(border_context, 1.0, 0.0, 0.0, 0.8);
        CGContextFillRect(border_context, outer_rect);
        
        CGPathRelease(clip_path);
        logpf("PAYLOAD", "Applied clipping path and fill to border context");
    } else {
        logpf("PAYLOAD", "Failed to get border window layer context");
    }
}
