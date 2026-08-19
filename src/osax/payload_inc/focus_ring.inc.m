// focus_ring.inc.m — payload-side focus-ring overlay: one display-sized,
// Dock-owned CA window per managed space, tracking the focused window.
// NOTE: forward decls for the entry points live in payload.m — their callers
// (opcode dispatch, t3d batch hook, deathwatch) appear earlier in the TU.

static void payload_focus_ring_follower(CFTypeRef tx, uint32_t wid, CGRect rect);

static float g_focus_ring_stroke_width = 7.0f;
static float g_focus_ring_stroke_alpha = 0.05f;
static float g_focus_ring_stroke_r     = 1.00f;
static float g_focus_ring_stroke_g     = 1.00f;
static float g_focus_ring_stroke_b     = 1.00f;

static int   g_focus_ring_blur_radius  = 0;

// NOTE: bleed pushes the band cutout inward past the window edge; the overlap
// strip only samples the window when the ring is ordered ABOVE the target.
static float g_focus_ring_blur_bleed   = 0.0f;

static float g_focus_ring_blur_saturation = 1.0f;
static float g_focus_ring_blur_brightness = 0.0f;
static float g_focus_ring_blur_contrast   = 1.0f;   // colorContrast inputAmount; 1.0 = identity
static float g_focus_ring_blur_hue        = 0.0f;   // colorHueRotate angle (degrees); 0.0 = identity
static int   g_focus_ring_blend_mode      = 0;   // enum focus_ring_blend_mode ordinal

static bool  g_focus_ring_blur_stroke          = false;
static int   g_focus_ring_blur_stroke_position = 0;     // 0 = above band, 1 = below band
static float g_focus_ring_blur_stroke_width    = 2.0f;

static float g_focus_ring_blur_tint_r = 1.00f, g_focus_ring_blur_tint_g = 1.00f,
             g_focus_ring_blur_tint_b = 1.00f, g_focus_ring_blur_tint_a = 0.05f;
static float g_focus_ring_blur_strokeclr_r = 1.00f, g_focus_ring_blur_strokeclr_g = 1.00f,
             g_focus_ring_blur_strokeclr_b = 1.00f, g_focus_ring_blur_strokeclr_a = 0.05f;
static float g_focus_ring_blur_feather = 0.0f;

// NOTE: per-kind style banks. The g_focus_ring_* globals hold whichever SHOW
// landed LAST, so a desktop SHOW would leak its style into any window-ring
// redraw that happens without a fresh SHOW (park, reveal, follower). Every
// SHOW stamps its kind's bank; payload_focus_surface_sync reads the bank.
struct fr_style_bank {
    float band_width;
    int   blur;
    float sat, bri, con, hue;
    float feather;
    int   blend;
    float tint_r, tint_g, tint_b, tint_a;
    float strokeclr_r, strokeclr_g, strokeclr_b, strokeclr_a;
};
#define FR_STYLE_BANK_DEFAULTS {                          \
    .band_width = 7.0f, .blur = 1,                        \
    .sat = 0.40f, .bri = 0.40f, .con = 2.0f, .hue = 5.0f, \
    .feather = 0.0f, .blend = 0,                          \
    .tint_r = 1.0f, .tint_g = 1.0f, .tint_b = 1.0f, .tint_a = 0.05f, \
    .strokeclr_r = 1.0f, .strokeclr_g = 1.0f, .strokeclr_b = 1.0f, .strokeclr_a = 0.05f, \
}
static struct fr_style_bank g_fr_style_main    = FR_STYLE_BANK_DEFAULTS;
static struct fr_style_bank g_fr_style_desktop = FR_STYLE_BANK_DEFAULTS;
static bool  g_focus_ring_animate          = false;
static float g_focus_ring_animate_duration = 0.25f;
static float g_focus_ring_fade_duration    = 0.15f;
static float g_focus_ring_window_alpha     = 1.0f;

// NOTE: rects are full screen frames stamped per SHOW — stale until the next
// SHOW when a foreign window moves. Outset so an edge-sharing window (zero-
// area overlap with the outside band) still reaches the seam.
static bool   g_focus_ring_xray       = false;
static float  g_focus_ring_xray_r     = 0.25f, g_focus_ring_xray_g = 0.78f,
              g_focus_ring_xray_b     = 1.00f, g_focus_ring_xray_a = 1.00f;
static int    g_focus_ring_xray_count = 0;
static CGRect g_focus_ring_xray_rects[SA_FOCUS_RING_XRAY_MAX_RECTS];

#define FOCUS_RING_XRAY_TOLERANCE 2.0f

// NOTE: index = wire ordinal (enum focus_ring_blend_mode) — append, never reorder.
static NSString * const g_focus_ring_blend_filter_types[] = {
    nil,                    //  0 NORMAL (no compositing filter)
    @"multiplyBlendMode",   //  1 MULTIPLY
    @"screenBlendMode",     //  2 SCREEN
    @"overlayBlendMode",    //  3 OVERLAY
    @"darkenBlendMode",     //  4 DARKEN
    @"lightenBlendMode",    //  5 LIGHTEN
    @"colorDodgeBlendMode", //  6 COLOR_DODGE
    @"colorBurnBlendMode",  //  7 COLOR_BURN
    @"softLightBlendMode",  //  8 SOFT_LIGHT
    @"hardLightBlendMode",  //  9 HARD_LIGHT
    @"differenceBlendMode", // 10 DIFFERENCE
    @"exclusionBlendMode",  // 11 EXCLUSION
    @"hueBlendMode",        // 12 HUE
    @"saturationBlendMode", // 13 SATURATION
    @"colorBlendMode",      // 14 COLOR
    @"luminosityBlendMode", // 15 LUMINOSITY
};
#define FOCUS_RING_BLEND_COUNT \
    ((int)(sizeof(g_focus_ring_blend_filter_types) / sizeof(g_focus_ring_blend_filter_types[0])))

#define FOCUS_RING_STROKE_WIDTH  (g_focus_ring_stroke_width)
#define FOCUS_RING_R             (g_focus_ring_stroke_r)
#define FOCUS_RING_G             (g_focus_ring_stroke_g)
#define FOCUS_RING_B             (g_focus_ring_stroke_b)
#define FOCUS_RING_A             (g_focus_ring_stroke_alpha)
#define FOCUS_RING_LEVEL         19
#define FOCUS_RING_DEFAULT_RGBA  0x00000000

// NOTE: show/hide + fades write the SYSTEM alpha slot; the normal slot carries
// the user's `alpha` knob and the compositor multiplies the two — never write
// the normal slot here. The slot is gated: writes need Dock's main (universal-
// owner) cid, via a transaction.
static void fr_stroke_note_alpha(uint32_t wid, float a);

static void payload_focus_set_system_alpha(CFTypeRef tx, uint32_t wid, float a)
{
    if (!wid) return;
    fr_stroke_note_alpha(wid, a);
    if (tx) { SLSTransactionSetWindowSystemAlpha(tx, wid, a); return; }
    CFTypeRef t = SLSTransactionCreate(SLSMainConnectionID());
    if (!t) return;
    SLSTransactionSetWindowSystemAlpha(t, wid, a);
    SLSTransactionCommit(t, 0);
    CFRelease(t);
}

static uint64_t g_payload_focus_ring_extra_tags    = 0;    // debug bookkeeping only, never applied at create
static int      g_payload_focus_ring_level          = 0;
static bool     g_payload_focus_ring_order_below    = true;
static bool     g_payload_focus_ring_color_override = false;// once set, rgba knob owns alpha (SHOW won't restamp from config)

static int g_payload_focus_ring_log_fd = -1;
static pthread_once_t g_payload_focus_ring_log_once = PTHREAD_ONCE_INIT;

#ifndef YB_LOG_TREE
#define YB_LOG_TREE "unknown"
#endif
#define PAYLOAD_FR_LOG_DIR  "/tmp/logs/yabai/" YB_LOG_TREE
#define PAYLOAD_FR_LOG_PATH PAYLOAD_FR_LOG_DIR "/focus_ring.log"

static void payload_focus_ring_log_open(void)
{
    mkdir("/tmp/logs", 0755);
    mkdir("/tmp/logs/yabai", 0755);
    mkdir(PAYLOAD_FR_LOG_DIR, 0755);
    g_payload_focus_ring_log_fd = open(PAYLOAD_FR_LOG_PATH,
                                        O_WRONLY | O_CREAT | O_APPEND,
                                        0644);
}

static void payload_focus_ring_log(const char *source, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));

static void payload_focus_ring_log(const char *source, const char *fmt, ...)
{
#if !YB_PAYLOAD_LOG
    (void)source; (void)fmt;
    return;
#endif
    pthread_once(&g_payload_focus_ring_log_once, payload_focus_ring_log_open);
    if (g_payload_focus_ring_log_fd < 0) return;

    char buf[512];
    int off = 0;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);

    int n = snprintf(buf + off, sizeof(buf) - off,
                     "[%ld.%09ld] [payload] [%s] ",
                     (long)ts.tv_sec, (long)ts.tv_nsec, source);
    if (n < 0 || (size_t)n >= sizeof(buf) - off) return;
    off += n;

    va_list ap;
    va_start(ap, fmt);
    n = vsnprintf(buf + off, sizeof(buf) - off, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n >= sizeof(buf) - off) n = (int)(sizeof(buf) - off - 1);
    off += n;

    if (off < (int)sizeof(buf) - 1) buf[off++] = '\n';
    (void)write(g_payload_focus_ring_log_fd, buf, (size_t)off);
}

// NOTE: g_payload_focus_ring (master flag + last focus) survives stroke
// destroy/create. FR-9 pool: one ring per managed space, parked on its last
// focus and attached as a real managed-space member so it rides the space
// slide; g_payload_focus_stroke aliases the active entry.

static struct {
    bool     visible;       // SET_VISIBLE: true => alpha 1, false => alpha 0
    uint32_t target_wid;    // last SHOW target — t3d hook's filter key
    float    target_radius;
} g_payload_focus_ring;

struct focus_stroke {
    bool            initialized;    // true once the SLS window is alive
    uint32_t        wid;            // our stroke window (Dock-cid owned)
    int             owner_cid;      // Dock cid that owns wid
    uint32_t        target_wid;     // target we're tracking
    float           target_radius;
    CGRect          target_rect;    // last target rect in screen coords
    CGPoint         surface_origin; // surface's screen origin (= display origin)
    CGSize          surface_size;   // surface dimensions (= display size)
    uint64_t        attached_sid;   // managed space the window is attached to
    uint64_t        last_used_mach; // LRU stamp (mach_absolute_time at last SHOW)
    float           last_alpha;     // last SYSTEM alpha written (advisory; reveal skip)
    id              ca_ctx;         // CAContext
    id              ca_backdrop;    // CABackdropLayer (behind-window blur; hidden at blur=0)
    id              ca_mask;        // CAShapeLayer (rounded band mask on the backdrop)
    id              ca_tint;        // CALayer color wash over the sampled band (band color/opacity + blend)
    id              ca_stroke;      // CAShapeLayer hard stroke overlay (focus_ring inner_stroke)
    id              ca_xray;        // CAShapeLayer xray recolor over ca_stroke, masked to overlap rects (FR-21)
    pthread_mutex_t ctx_lock;       // serializes sync/draw vs destroy across threads
};

#define FR_MAX_SPACES 16
static struct focus_stroke g_focus_stroke_pool[FR_MAX_SPACES] = {
    [0 ... FR_MAX_SPACES - 1] = { .ctx_lock = PTHREAD_MUTEX_INITIALIZER }
};
static struct focus_stroke *g_active_stroke = &g_focus_stroke_pool[0];

#define g_payload_focus_stroke (*g_active_stroke)

// NOTE: advisory — every ring alpha write funnels here EXCEPT the space
// slide's settle (pump tx); adopt_for_exit pre-stamps 0 for it. Races are
// benign: at worst a redundant or skipped fade, never a stuck ring.
static void fr_stroke_note_alpha(uint32_t wid, float a)
{
    if (!wid) return;
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (g_focus_stroke_pool[i].wid == wid) { g_focus_stroke_pool[i].last_alpha = a; return; }
    }
}

static void payload_focus_stroke_draw(float radius, bool animated);

static uint32_t payload_focus_display_id_for(CGRect r)
{
    extern CGError CGGetDisplaysWithPoint(CGPoint point, uint32_t max_displays,
                                          CGDirectDisplayID *displays, uint32_t *count);
    CGPoint c = { r.origin.x + r.size.width  / 2.0f,
                  r.origin.y + r.size.height / 2.0f };
    CGDirectDisplayID did = 0;
    uint32_t count = 0;
    if (CGGetDisplaysWithPoint(c, 1, &did, &count) != kCGErrorSuccess || count == 0) {
        did = CGMainDisplayID();
    }
    return did;
}

static CGRect payload_focus_display_rect_for(CGRect r)
{
    return CGDisplayBounds(payload_focus_display_id_for(r));
}

static int payload_focus_blur_effective(void)
{
    return g_focus_ring_blur_radius;
}

static float payload_focus_blur_band_width(void)
{
    return FOCUS_RING_STROKE_WIDTH;
}

// NOTE: every ring renders through this one CA tree; blur is a filter knob
// (radius 0 = unblurred band + tint), so any style change — including blur
// 0<->N — is a live layer update, never a window recreate. Behind-window
// sampling (CABackdropLayer) only composites on Dock's MAIN cid.

static bool payload_focus_surface_create(int cid, CGRect surface_rect, uint32_t *out_wid)
{
    extern int     SLSNewWindow(int cid, int type, float x, float y, CFTypeRef region, uint32_t *wid);
    extern CGError SLSReleaseWindow(int cid, uint32_t wid);
    extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
    extern void    SLSSetWindowOpacity(int cid, uint32_t wid, bool isOpaque);
    extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
    extern CGError SLSSetWindowResolution(int cid, uint32_t wid, double res);
    extern void    SLSWindowSetShadowProperties(uint32_t wid, CFDictionaryRef properties);
    extern CGError SLSSetWindowLayerContext(int cid, uint32_t wid, CGContextRef context);
    extern CGError SLSSetWindowTitle(int cid, uint32_t wid, CFStringRef title);

    *out_wid = 0;

    // region = shape at (0,0); the screen position rides the x/y args.
    CGRect shape = CGRectMake(0.0, 0.0, surface_rect.size.width, surface_rect.size.height);
    CGSRegionRef region = NULL;
    if (CGSNewRegionWithRect(&shape, &region) != kCGErrorSuccess || !region) return false;
    uint32_t wid = 0;
    int rc = SLSNewWindow(cid, 5, surface_rect.origin.x, surface_rect.origin.y, region, &wid);
    CFRelease(region);
    if (rc != 0 || !wid) return false;

    uint64_t tags = (1ULL << 46 | 1ULL << 9);   // kCGSMergesWithMenuBar + kCGSIgnoreForEventsTagBit (click-through)
    SLSSetWindowTags(cid, wid, &tags, 64);
    extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
    uint64_t clear_menubar = (1ULL << 45);
    SLSClearWindowTags(cid, wid, &clear_menubar, 64);
    SLSSetWindowResolution(cid, wid, 2.0);
    SLSSetWindowOpacity(cid, wid, 0);
    SLSSetWindowLevel(cid, wid, g_payload_focus_ring_level);
    SLSSetWindowTitle(cid, wid, CFSTR("Focus Ring Quartz"));

    CFIndex shadow_density = 0;
    CFNumberRef dens = CFNumberCreate(NULL, kCFNumberCFIndexType, &shadow_density);
    CFDictionaryRef shadow_props = CFDictionaryCreate(NULL,
        (const void *[]){CFSTR("com.apple.WindowShadowDensity")},
        (const void *[]){dens}, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SLSWindowSetShadowProperties(wid, shadow_props);
    CFRelease(dens);
    CFRelease(shadow_props);

    // NOTE: the SA handler thread has no autorelease pool and no runloop — scope a
    // pool, retain what outlives it, and flush CATransaction explicitly.
    bool ok = false;
    uint32_t dbg_ctx_id  = 0;
    CGError  dbg_bind_rc = (CGError)-999;
    @autoreleasepool {
        Class CAContextCls  = NSClassFromString(@"CAContext");
        Class CALayerCls    = NSClassFromString(@"CALayer");
        Class CABackdropCls = NSClassFromString(@"CABackdropLayer");
        Class CAShapeCls    = NSClassFromString(@"CAShapeLayer");
        Class CATxCls       = NSClassFromString(@"CATransaction");
        if (CAContextCls && CALayerCls && CABackdropCls && CAShapeCls) {
            CGRect bounds = CGRectMake(0.0, 0.0, surface_rect.size.width, surface_rect.size.height);

            id ctx  = ((id (*)(id, SEL, id)) objc_msgSend)(CAContextCls, @selector(remoteContextWithOptions:), @{});
            id root = ((id (*)(id, SEL)) objc_msgSend)(CALayerCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(root, @selector(setFrame:), bounds);
            // y-down so the sampled backdrop renders right-side-up (matches the mask path).
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(root, @selector(setGeometryFlipped:), YES);

            id bd = ((id (*)(id, SEL)) objc_msgSend)(CABackdropCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(bd, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, id, id)) objc_msgSend)(bd, @selector(setValue:forKey:),
                @"NSCGSWindowBehindWindowCaptureBackdropGroup", @"groupName");
            ((void (*)(id, SEL, id, id)) objc_msgSend)(bd, @selector(setValue:forKey:), @(0.25), @"scale");
            ((void (*)(id, SEL, id, id)) objc_msgSend)(bd, @selector(setValue:forKey:), @YES, @"windowServerAware");

            id mask = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(mask, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, id)) objc_msgSend)(mask, @selector(setFillRule:), @"even-odd");
            CGColorRef blk = CGColorCreateGenericRGB(0, 0, 0, 1);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(mask, @selector(setFillColor:), blk);
            if (blk) CGColorRelease(blk);
            ((void (*)(id, SEL, id)) objc_msgSend)(bd, @selector(setMask:), mask);

            // sublayer of the backdrop so the band mask clips the wash too.
            id tint = ((id (*)(id, SEL)) objc_msgSend)(CALayerCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(tint, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, id)) objc_msgSend)(bd, @selector(addSublayer:), tint);

            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), bd);

            // NOTE: sibling of the backdrop — the band mask must not clip it. Created
            // unconditionally + hidden so the knob is a live toggle (no recreate).
            id stroke = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(stroke, @selector(setFrame:), bounds);
            CGColorRef clear = CGColorCreateGenericRGB(0, 0, 0, 0);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(stroke, @selector(setFillColor:), clear);
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(stroke, @selector(setHidden:), YES);
            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), stroke);

            id xray = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(xray, @selector(setFrame:), bounds);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(xray, @selector(setFillColor:), clear);
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(xray, @selector(setHidden:), YES);
            id xmask = ((id (*)(id, SEL)) objc_msgSend)(CAShapeCls, @selector(layer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(xmask, @selector(setFrame:), bounds);
            CGColorRef xopaque = CGColorCreateGenericRGB(0, 0, 0, 1);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(xmask, @selector(setFillColor:), xopaque);
            if (xopaque) CGColorRelease(xopaque);
            ((void (*)(id, SEL, id)) objc_msgSend)(xray, @selector(setMask:), xmask);
            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), xray);
            if (clear) CGColorRelease(clear);

            ((void (*)(id, SEL, id)) objc_msgSend)(ctx, @selector(setLayer:), root);

            g_payload_focus_stroke.ca_ctx      = ((id (*)(id, SEL)) objc_msgSend)(ctx,    @selector(retain));
            g_payload_focus_stroke.ca_backdrop = ((id (*)(id, SEL)) objc_msgSend)(bd,     @selector(retain));
            g_payload_focus_stroke.ca_mask     = ((id (*)(id, SEL)) objc_msgSend)(mask,   @selector(retain));
            g_payload_focus_stroke.ca_tint     = ((id (*)(id, SEL)) objc_msgSend)(tint,   @selector(retain));
            g_payload_focus_stroke.ca_stroke   = ((id (*)(id, SEL)) objc_msgSend)(stroke, @selector(retain));
            g_payload_focus_stroke.ca_xray     = ((id (*)(id, SEL)) objc_msgSend)(xray,   @selector(retain));

            dbg_bind_rc = SLSSetWindowLayerContext(cid, wid, (CGContextRef)ctx);
            dbg_ctx_id  = (uint32_t)((unsigned int (*)(id, SEL)) objc_msgSend)(ctx, sel_registerName("contextId"));
            if (CATxCls) ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(flush));
            ok = true;
        }
    }

    if (!ok) {
        SLSReleaseWindow(cid, wid);
        payload_focus_ring_log("blur_create_fail", "reason=ca_tree wid=%u", wid);
        return false;
    }

    SLSOrderWindow(cid, wid, 1, 0);
    payload_focus_ring_log("surface_bind", "wid=%u ctxId=%u bind_rc=%d", wid, dbg_ctx_id, (int)dbg_bind_rc);
    *out_wid = wid;
    return true;
}

static CGImageRef s_fm_img      = NULL;
static float      s_fm_w        = -1, s_fm_h = -1, s_fm_corner = -1,
                  s_fm_bw       = -1, s_fm_bleed = -1, s_fm_feather = -1;
static bool       s_fm_inset    = false;
static CGSize     s_fm_img_size = { 0, 0 };   // image extent in points

static void payload_focus_feather_mask_refresh(float w, float h, float corner,
                                               float bw, float bleed, float feather,
                                               bool inset)
{
    if (s_fm_img && s_fm_w == w && s_fm_h == h && s_fm_corner == corner &&
        s_fm_bw == bw && s_fm_bleed == bleed && s_fm_feather == feather &&
        s_fm_inset == inset) {
        return;
    }
    if (s_fm_img) { CGImageRelease(s_fm_img); s_fm_img = NULL; }

    float  pad   = feather + 2.0f;
    CGRect inner   = CGRectMake(pad + (inset ? 0.0f : bw), pad + (inset ? 0.0f : bw), w, h);
    CGRect outer   = inset ? inner : CGRectInset(inner, -bw, -bw);
    float  outer_r = inset ? 0.0f : corner + bw; if (outer_r < 0.0f) outer_r = 0.0f;
    float  hole_in = bleed + (inset ? bw : 0.0f);
    CGRect hole    = CGRectInset(inner, hole_in, hole_in);
    float  hole_r  = corner - bleed; if (hole_r < 0.0f) hole_r = 0.0f;
    float  img_w   = outer.size.width  + 2.0f * pad;
    float  img_h   = outer.size.height + 2.0f * pad;

    size_t pxw = (size_t)(img_w + 0.999f);
    size_t pxh = (size_t)(img_h + 0.999f);
    if (pxw == 0 || pxh == 0) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, pxw, pxh, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c) return;

    CGColorRef white = CGColorCreateGenericRGB(1, 1, 1, 1);
    float OFF = img_w + 1000.0f;

    if (inset) {
        CGContextSetFillColorWithColor(c, white);
        CGMutablePathRef op = CGPathCreateMutable();
        CGPathAddRoundedRect(op, NULL, outer, outer_r, outer_r);
        CGContextAddPath(c, op);
        CGContextFillPath(c);
        CGPathRelease(op);

        CGColorSpaceRef cs2 = CGColorSpaceCreateDeviceRGB();
        CGContextRef hctx = CGBitmapContextCreate(NULL, pxw, pxh, 8, 0, cs2, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(cs2);
        if (hctx) {
            CGContextSetShadowWithColor(hctx, CGSizeMake(OFF, 0), feather, white);
            CGContextSetFillColorWithColor(hctx, white);
            CGMutablePathRef hp = CGPathCreateMutable();
            CGPathAddRoundedRect(hp, NULL, CGRectOffset(hole, -OFF, 0), hole_r, hole_r);
            CGContextAddPath(hctx, hp);
            CGContextFillPath(hctx);
            CGPathRelease(hp);
            CGImageRef himg = CGBitmapContextCreateImage(hctx);
            CGContextRelease(hctx);
            if (himg) {
                CGContextSetBlendMode(c, kCGBlendModeDestinationOut);
                CGContextDrawImage(c, CGRectMake(0, 0, (CGFloat)pxw, (CGFloat)pxh), himg);
                CGImageRelease(himg);
            }
        }
    } else {
        // OUTSET (window ring): blur the filled OUTER shape via the shadow-offset
        // trick — draw it OFF px to the left (offscreen) so only its blurred
        // shadow lands at the real outer position — then cut the hole SHARP
        // (shadow off, clear blend). Clear center, crisp inner edge against the
        // window; the outer edge feathers out into the desktop.
        CGContextSetShadowWithColor(c, CGSizeMake(OFF, 0), feather, white);
        CGContextSetFillColorWithColor(c, white);
        CGMutablePathRef op = CGPathCreateMutable();
        CGPathAddRoundedRect(op, NULL, CGRectOffset(outer, -OFF, 0), outer_r, outer_r);
        CGContextAddPath(c, op);
        CGContextFillPath(c);
        CGPathRelease(op);

        CGContextSetShadowWithColor(c, CGSizeZero, 0, NULL);
        CGContextSetBlendMode(c, kCGBlendModeClear);
        CGMutablePathRef hp = CGPathCreateMutable();
        CGPathAddRoundedRect(hp, NULL, hole, hole_r, hole_r);
        CGContextAddPath(c, hp);
        CGContextFillPath(c);
        CGPathRelease(hp);
    }

    CGColorRelease(white);
    s_fm_img      = CGBitmapContextCreateImage(c);
    s_fm_img_size = CGSizeMake(img_w, img_h);
    CGContextRelease(c);

    s_fm_w = w; s_fm_h = h; s_fm_corner = corner;
    s_fm_bw = bw; s_fm_bleed = bleed; s_fm_feather = feather;
    s_fm_inset = inset;
}

static void payload_focus_surface_sync(float corner, bool animated)
{
    if (!g_payload_focus_stroke.ca_backdrop || !g_payload_focus_stroke.ca_mask) return;

    @autoreleasepool {
        Class CAFilterCls = NSClassFromString(@"CAFilter");
        Class CATxCls     = NSClassFromString(@"CATransaction");

        // NOTE: live tracking must run with implicit actions disabled or the band
        // trails the window; only discrete transitions (animated) ease.
        if (CATxCls) {
            ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(begin));
            ((void (*)(id, SEL, BOOL)) objc_msgSend)(CATxCls, @selector(setDisableActions:), animated ? NO : YES);
            if (animated) {
                ((void (*)(id, SEL, CFTimeInterval)) objc_msgSend)(CATxCls, @selector(setAnimationDuration:),
                                                                   (CFTimeInterval)g_focus_ring_animate_duration);
            }
        }

        const struct fr_style_bank *stb = (g_payload_focus_stroke.target_wid == 0)
                                        ? &g_fr_style_desktop : &g_fr_style_main;
        int  radius  = stb->blur;
        bool frosted = radius > 0;

        // quarter-res sampling pixelates visibly when unblurred — full res at radius 0.
        ((void (*)(id, SEL, id, id)) objc_msgSend)(g_payload_focus_stroke.ca_backdrop,
            @selector(setValue:forKey:), frosted ? @(0.25) : @(1.0), @"scale");

        if (CAFilterCls) {
            NSMutableArray *filters = [NSMutableArray array];
            if (frosted) {
                id blur = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"gaussianBlur");
                if (blur) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(blur, @selector(setValue:forKey:), @(radius), @"inputRadius");
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(blur, @selector(setValue:forKey:), @YES, @"inputNormalizeEdges");
                    [filters addObject:blur];
                }
            }
            if (stb->sat != 1.0f) {
                id sat = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorSaturate");
                if (sat) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(sat, @selector(setValue:forKey:), @(stb->sat), @"inputAmount");
                    [filters addObject:sat];
                }
            }
            if (stb->bri != 0.0f) {
                id bright = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorBrightness");
                if (bright) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(bright, @selector(setValue:forKey:), @(stb->bri), @"inputAmount");
                    [filters addObject:bright];
                }
            }
            if (stb->con != 1.0f) {
                id contrast = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorContrast");
                if (contrast) {
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(contrast, @selector(setValue:forKey:), @(stb->con), @"inputAmount");
                    [filters addObject:contrast];
                }
            }
            // inputAngle is RADIANS; the config knob is degrees.
            if (stb->hue != 0.0f) {
                id hue = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), @"colorHueRotate");
                if (hue) {
                    double angle = (double)stb->hue * (M_PI / 180.0);
                    ((void (*)(id, SEL, id, id)) objc_msgSend)(hue, @selector(setValue:forKey:), @(angle), @"inputAngle");
                    [filters addObject:hue];
                }
            }
            ((void (*)(id, SEL, id)) objc_msgSend)(g_payload_focus_stroke.ca_backdrop, @selector(setFilters:), filters);
        }

        if (g_payload_focus_stroke.ca_tint) {
            CGColorRef c = CGColorCreateGenericRGB(stb->tint_r, stb->tint_g,
                                                   stb->tint_b, stb->tint_a);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(g_payload_focus_stroke.ca_tint,
                                                           @selector(setBackgroundColor:), c);
            if (c) CGColorRelease(c);

            id comp = nil;
            int bm = stb->blend;
            if (CAFilterCls && bm > 0 && bm < FOCUS_RING_BLEND_COUNT) {
                NSString *type = g_focus_ring_blend_filter_types[bm];
                if (type) comp = ((id (*)(id, SEL, id)) objc_msgSend)(CAFilterCls, @selector(filterWithType:), type);
            }
            ((void (*)(id, SEL, id)) objc_msgSend)(g_payload_focus_stroke.ca_tint,
                                                   @selector(setCompositingFilter:), comp);
        }

        CGPoint o  = g_payload_focus_stroke.surface_origin;
        CGRect  t  = g_payload_focus_stroke.target_rect;
        float   bw = stb->band_width;
        // NOTE: desktop ring (target_wid == 0) renders INSET — outer = the rect
        // itself, hole = rect - band - bleed — so the band can't hang past the display
        // edge; every seam feature (bleed/stroke/feather/xray) composes off the
        // flipped hole. The configured radius always describes the SEAM (hole edge).
        bool   inset = (g_payload_focus_stroke.target_wid == 0);
        CGRect inner = CGRectMake(t.origin.x - o.x, t.origin.y - o.y, t.size.width, t.size.height);
        CGRect outer = inset ? inner : CGRectInset(inner, -bw, -bw);
        float  outer_r = inset ? 0.0f : corner + bw; if (outer_r < 0.0f) outer_r = 0.0f;

        float  bleed = g_focus_ring_blur_bleed;
        float  band_in = inset ? bw : 0.0f;
        float  bleed_cap = 0.5f * fminf(inner.size.width, inner.size.height) - 2.0f - band_in;
        if (bleed_cap < 0.0f) bleed_cap = 0.0f;
        if (bleed > bleed_cap) bleed = bleed_cap;
        if (bleed < 0.0f)      bleed = 0.0f;
        CGRect hole   = CGRectInset(inner, band_in + bleed, band_in + bleed);
        float  hole_r = corner - bleed; if (hole_r < 0.0f) hole_r = 0.0f;

        id maskl = g_payload_focus_stroke.ca_mask;
        if (stb->feather > 0.0f) {
            payload_focus_feather_mask_refresh(inner.size.width, inner.size.height,
                                               corner, bw, bleed, stb->feather,
                                               inset);
            if (s_fm_img) {
                float  pad   = stb->feather + 2.0f;
                CGRect frame = CGRectMake(inner.origin.x - pad - (inset ? 0.0f : bw),
                                          inner.origin.y - pad - (inset ? 0.0f : bw),
                                          s_fm_img_size.width, s_fm_img_size.height);
                ((void (*)(id, SEL, CGPathRef))  objc_msgSend)(maskl, @selector(setPath:), (CGPathRef)NULL);
                ((void (*)(id, SEL, CGRect))     objc_msgSend)(maskl, @selector(setFrame:), frame);
                ((void (*)(id, SEL, CGFloat))    objc_msgSend)(maskl, @selector(setContentsScale:), (CGFloat)1.0);
                ((void (*)(id, SEL, id))         objc_msgSend)(maskl, @selector(setContents:), (id)s_fm_img);
                ((void (*)(id, SEL, id))         objc_msgSend)(maskl, @selector(setFilters:), nil);
            }
        } else {
            CGRect bounds = CGRectMake(0, 0, g_payload_focus_stroke.surface_size.width,
                                             g_payload_focus_stroke.surface_size.height);
            ((void (*)(id, SEL, id))     objc_msgSend)(maskl, @selector(setContents:), (id)nil);
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(maskl, @selector(setFrame:), bounds);

            CGMutablePathRef path = CGPathCreateMutable();
            CGPathAddRoundedRect(path, NULL, outer, outer_r, outer_r);
            CGPathAddRoundedRect(path, NULL, hole, hole_r, hole_r);
            ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(maskl, @selector(setPath:), path);
            CGPathRelease(path);

            CGColorRef opaque = CGColorCreateGenericRGB(0, 0, 0, 1);
            ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(maskl, @selector(setFillColor:), opaque);
            if (opaque) CGColorRelease(opaque);
            ((void (*)(id, SEL, id)) objc_msgSend)(maskl, @selector(setFilters:), nil);
        }

        if (g_payload_focus_stroke.ca_stroke) {
            id st = g_payload_focus_stroke.ca_stroke;
            if (g_focus_ring_blur_stroke) {
                // NOTE: a CAShapeLayer stroke straddles its path — outset by half the width so
                // the inner edge sits on the seam and the stroke grows outward only.
                float  sw = g_focus_ring_blur_stroke_width;
                CGRect srect = CGRectInset(hole, -sw * 0.5f, -sw * 0.5f);
                float  sr    = hole_r + sw * 0.5f;
                CGMutablePathRef spath = CGPathCreateMutable();
                CGPathAddRoundedRect(spath, NULL, srect, sr, sr);
                ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(st, @selector(setPath:), spath);
                CGPathRelease(spath);

                CGColorRef sc = CGColorCreateGenericRGB(stb->strokeclr_r, stb->strokeclr_g,
                                                        stb->strokeclr_b, stb->strokeclr_a);
                ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(st, @selector(setStrokeColor:), sc);
                if (sc) CGColorRelease(sc);
                ((void (*)(id, SEL, CGFloat)) objc_msgSend)(st, @selector(setLineWidth:), (CGFloat)g_focus_ring_blur_stroke_width);
                CGFloat zp = (g_focus_ring_blur_stroke_position == 1) ? -1.0 : 1.0;
                ((void (*)(id, SEL, CGFloat)) objc_msgSend)(st, @selector(setZPosition:), zp);
                ((void (*)(id, SEL, BOOL)) objc_msgSend)(st, @selector(setHidden:), NO);
            } else {
                ((void (*)(id, SEL, BOOL)) objc_msgSend)(st, @selector(setHidden:), YES);
            }
        }

        if (g_payload_focus_stroke.ca_xray) {
            id xr = g_payload_focus_stroke.ca_xray;
            int xn = 0;
            if ((frosted ? g_focus_ring_blur_stroke : true)
                && g_focus_ring_xray && g_focus_ring_xray_count > 0) {
                CGMutablePathRef mpath = CGPathCreateMutable();
                for (int i = 0; i < g_focus_ring_xray_count; ++i) {
                    CGRect r = g_focus_ring_xray_rects[i];
                    CGRect lr = CGRectMake(r.origin.x - o.x, r.origin.y - o.y,
                                           r.size.width, r.size.height);
                    lr = CGRectInset(lr, -FOCUS_RING_XRAY_TOLERANCE, -FOCUS_RING_XRAY_TOLERANCE);
                    if (!CGRectIntersectsRect(lr, outer)) continue;
                    CGPathAddRect(mpath, NULL, lr);
                    ++xn;
                }
                if (xn > 0) {
                    float  seam_w = frosted ? g_focus_ring_blur_stroke_width : bw;
                    float  cl = inset ? bw * 0.5f : -bw * 0.5f;
                    CGRect seam   = frosted ? CGRectInset(hole, -seam_w * 0.5f, -seam_w * 0.5f)
                                            : CGRectInset(inner, cl, cl);
                    float  seam_r = frosted ? hole_r + seam_w * 0.5f : corner + bw * 0.5f;
                    if (seam_r < 0.0f) seam_r = 0.0f;
                    CGMutablePathRef xpath = CGPathCreateMutable();
                    CGPathAddRoundedRect(xpath, NULL, seam, seam_r, seam_r);
                    ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(xr, @selector(setPath:), xpath);
                    CGPathRelease(xpath);

                    CGColorRef xc = CGColorCreateGenericRGB(g_focus_ring_xray_r, g_focus_ring_xray_g,
                                                            g_focus_ring_xray_b, g_focus_ring_xray_a);
                    ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(xr, @selector(setStrokeColor:), xc);
                    if (xc) CGColorRelease(xc);
                    ((void (*)(id, SEL, CGFloat)) objc_msgSend)(xr, @selector(setLineWidth:), (CGFloat)seam_w);
                    CGFloat xzp = frosted
                                ? ((g_focus_ring_blur_stroke_position == 1) ? -1.0 : 1.0) + 0.5
                                : 1.5;
                    ((void (*)(id, SEL, CGFloat)) objc_msgSend)(xr, @selector(setZPosition:), xzp);

                    id xmask = ((id (*)(id, SEL)) objc_msgSend)(xr, @selector(mask));
                    if (xmask) ((void (*)(id, SEL, CGPathRef)) objc_msgSend)(xmask, @selector(setPath:), mpath);
                    ((void (*)(id, SEL, BOOL)) objc_msgSend)(xr, @selector(setHidden:), NO);
                }
                CGPathRelease(mpath);
            }
            if (xn == 0) ((void (*)(id, SEL, BOOL)) objc_msgSend)(xr, @selector(setHidden:), YES);
        }

        if (CATxCls) {
            ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(commit));
            ((void (*)(id, SEL)) objc_msgSend)(CATxCls, @selector(flush));
        }
    }
}

static bool payload_focus_stroke_ensure(int cid, CGRect target_rect, uint64_t sid)
{
    if (g_payload_focus_stroke.initialized) return true;

    // NOTE: one display-sized surface pinned at the display origin, never moved or
    // resized — target moves/resizes are per-frame band-path updates in the CA
    // tree. Rebuilt only on a cross-display/space/target focus change.
    CGRect surface_rect = payload_focus_display_rect_for(target_rect);
    CGSize stroke_size  = surface_rect.size;
    uint32_t wid = 0;

    if (!payload_focus_surface_create(cid, surface_rect, &wid)) {
        payload_focus_ring_log("stroke_create_fail", "reason=surface_create");
        return false;
    }

    if (sid != 0) {
        uint32_t wlist[1] = { wid };
        CFArrayRef arr = cfarray_of_cfnumbers(wlist, sizeof(uint32_t),
                                               1, kCFNumberSInt32Type);
        if (arr) {
            SLSMoveWindowsToManagedSpace(cid, arr, sid);
            CFRelease(arr);
        }
    }

    SLSSetWindowAlpha(cid, wid, g_focus_ring_window_alpha);
    payload_focus_set_system_alpha(NULL, wid, g_payload_focus_ring.visible ? 1.0f : 0.0f);

    g_payload_focus_stroke.initialized       = true;
    g_payload_focus_stroke.wid               = wid;
    g_payload_focus_stroke.owner_cid         = cid;
    g_payload_focus_stroke.target_rect       = target_rect;
    g_payload_focus_stroke.surface_origin    = surface_rect.origin;
    g_payload_focus_stroke.surface_size      = stroke_size;
    g_payload_focus_stroke.attached_sid      = sid;

    payload_focus_ring_log("stroke_create",
                           "wid=%u surface=(%.0f,%.0f %.0fx%.0f) blur=%d sid=%llu",
                           wid, surface_rect.origin.x, surface_rect.origin.y,
                           stroke_size.width, stroke_size.height,
                           payload_focus_blur_effective(),
                           (unsigned long long)sid);

    lb_follower_register(payload_focus_ring_follower);
    return true;
}

static void payload_focus_stroke_draw(float radius, bool animated)
{
    if (!g_payload_focus_stroke.initialized) return;

    pthread_mutex_lock(&g_payload_focus_stroke.ctx_lock);
    payload_focus_surface_sync(radius, animated && g_focus_ring_animate);
    pthread_mutex_unlock(&g_payload_focus_stroke.ctx_lock);

    payload_focus_ring_log("stroke_draw",
                           "wid=%u blur=%d radius=%.1f band_w=%.1f surface=%.0fx%.0f",
                           g_payload_focus_stroke.wid,
                           payload_focus_blur_effective(), radius,
                           payload_focus_blur_effective() > 0
                               ? payload_focus_blur_band_width()
                               : FOCUS_RING_STROKE_WIDTH,
                           g_payload_focus_stroke.surface_size.width,
                           g_payload_focus_stroke.surface_size.height);
}

static void payload_focus_stroke_destroy(int cid)
{
    if (!g_payload_focus_stroke.initialized) return;

    pthread_mutex_lock(&g_payload_focus_stroke.ctx_lock);
    if (g_payload_focus_stroke.ca_ctx) {
        ((void (*)(id, SEL, id)) objc_msgSend)(g_payload_focus_stroke.ca_ctx, @selector(setLayer:), (id)nil);
    }
    if (g_payload_focus_stroke.ca_xray) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_xray, @selector(release));
        g_payload_focus_stroke.ca_xray = nil;
    }
    if (g_payload_focus_stroke.ca_stroke) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_stroke, @selector(release));
        g_payload_focus_stroke.ca_stroke = nil;
    }
    if (g_payload_focus_stroke.ca_tint) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_tint, @selector(release));
        g_payload_focus_stroke.ca_tint = nil;
    }
    if (g_payload_focus_stroke.ca_mask) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_mask, @selector(release));
        g_payload_focus_stroke.ca_mask = nil;
    }
    if (g_payload_focus_stroke.ca_backdrop) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_backdrop, @selector(release));
        g_payload_focus_stroke.ca_backdrop = nil;
    }
    if (g_payload_focus_stroke.ca_ctx) {
        ((void (*)(id, SEL)) objc_msgSend)(g_payload_focus_stroke.ca_ctx, @selector(release));
        g_payload_focus_stroke.ca_ctx = nil;
    }
    pthread_mutex_unlock(&g_payload_focus_stroke.ctx_lock);

    if (g_payload_focus_stroke.wid) {
        extern CGError SLSReleaseWindow(int cid, uint32_t wid);
        // NOTE: release with the owning cid — a non-owning, non-universal cid leaks it.
        int owner = g_payload_focus_stroke.owner_cid ? g_payload_focus_stroke.owner_cid : cid;
        SLSReleaseWindow(owner, g_payload_focus_stroke.wid);
        g_payload_focus_stroke.wid = 0;
    }

    g_payload_focus_stroke.initialized       = false;
    g_payload_focus_stroke.target_wid        = 0;
    g_payload_focus_stroke.target_radius     = 0.0f;
    g_payload_focus_stroke.target_rect       = CGRectZero;
    g_payload_focus_stroke.surface_origin    = CGPointZero;
    g_payload_focus_stroke.surface_size      = CGSizeZero;
    g_payload_focus_stroke.attached_sid      = 0;

    payload_focus_ring_log("stroke_destroy", "ok");
}

static struct focus_stroke *fr_pool_find(uint64_t sid)
{
    if (sid == 0) return NULL;
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (g_focus_stroke_pool[i].initialized &&
            g_focus_stroke_pool[i].attached_sid == sid)
            return &g_focus_stroke_pool[i];
    }
    return NULL;
}

static struct focus_stroke *fr_pool_acquire(int cid, uint64_t sid)
{
    if (sid == 0) return g_active_stroke;

    struct focus_stroke *e = fr_pool_find(sid);
    if (e) return e;

    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (!g_focus_stroke_pool[i].initialized) return &g_focus_stroke_pool[i];
    }

    // NOTE: destroy operates on the active-entry alias — point it at the victim
    // first; the caller immediately re-points it at the freed slot.
    struct focus_stroke *lru = &g_focus_stroke_pool[0];
    for (int i = 1; i < FR_MAX_SPACES; i++) {
        if (g_focus_stroke_pool[i].last_used_mach < lru->last_used_mach)
            lru = &g_focus_stroke_pool[i];
    }
    g_active_stroke = lru;
    payload_focus_stroke_destroy(cid);
    payload_focus_ring_log("pool_evict", "sid=%llu slot=%ld",
                           (unsigned long long)sid, (long)(lru - g_focus_stroke_pool));
    return lru;
}

// NOTE: exactly one ring on screen — park every other entry at alpha 0 (a
// ring parked on another display's current space stays visible otherwise).
static void fr_pool_hide_others(int cid, struct focus_stroke *keep)
{
    int hidden = 0;
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        struct focus_stroke *fs = &g_focus_stroke_pool[i];
        if (fs == keep || !fs->initialized || !fs->wid) continue;
        payload_focus_set_system_alpha(NULL, fs->wid, 0.0f);
        // zero target_wid so a later re-entry rebuild-snaps instead of crossfading
        // from a stale target (see the want_xfade gate).
        if (fs->target_wid != 0) {
            payload_focus_ring_log("park_invalidate", "slot=%d wid=%u",
                                   i, fs->target_wid);
            fs->target_wid = 0;
        }
        hidden++;
    }
    if (hidden) payload_focus_ring_log("hide_others", "n=%d", hidden);
}

// NOTE: single global fade animator — a new fade retargets it. A ca_clock step
// client (no own CVDisplayLink); alpha rides the pump's shared per-VBL
// transaction so it commits in the same frame as the slide.
static struct {
    pthread_mutex_t  lock;
    uint32_t         wid;          // incoming ring — fades 0->1 (the only one used by FR-9)
    int              cid;
    uint32_t         out_wid;      // outgoing ring — fades 1->0 (focus-change crossfade; 0 = none)
    int              out_cid;
    uint64_t         start_mach;
    double           duration_s;
    double           mach_to_s;
    int              easing;        // enum focus_ring_easing (kept in sync with focus_ring.h)
    uint32_t         did;           // ca_clock display this fade registered on (stale-clock guard)
    _Atomic bool     active;
} g_focus_fade = { .lock = PTHREAD_MUTEX_INITIALIZER };

// NOTE: one stash slot — a focus change mid-crossfade snap-finishes the prior
// outgoing first, so at most two ring windows ever coexist.
static struct focus_stroke g_focus_xfade_out = { .ctx_lock = PTHREAD_MUTEX_INITIALIZER };

// caller holds g_focus_fade.lock; zeroes out_wid so the tick stops touching it.
static void payload_focus_xfade_drop_locked(void)
{
    struct focus_stroke *e = &g_focus_xfade_out;
    g_focus_fade.out_wid = 0;
    g_focus_fade.out_cid = 0;
    if (!e->initialized && !e->wid && !e->ca_ctx) return;

    @autoreleasepool {
        if (e->ca_ctx) ((void (*)(id, SEL, id)) objc_msgSend)(e->ca_ctx, @selector(setLayer:), (id)nil);
        if (e->ca_xray)     { ((void (*)(id, SEL)) objc_msgSend)(e->ca_xray,     @selector(release)); e->ca_xray = nil; }
        if (e->ca_stroke)   { ((void (*)(id, SEL)) objc_msgSend)(e->ca_stroke,   @selector(release)); e->ca_stroke = nil; }
        if (e->ca_tint)     { ((void (*)(id, SEL)) objc_msgSend)(e->ca_tint,     @selector(release)); e->ca_tint = nil; }
        if (e->ca_mask)     { ((void (*)(id, SEL)) objc_msgSend)(e->ca_mask,     @selector(release)); e->ca_mask = nil; }
        if (e->ca_backdrop) { ((void (*)(id, SEL)) objc_msgSend)(e->ca_backdrop, @selector(release)); e->ca_backdrop = nil; }
        if (e->ca_ctx)      { ((void (*)(id, SEL)) objc_msgSend)(e->ca_ctx,      @selector(release)); e->ca_ctx = nil; }
    }
    if (e->wid) {
        extern CGError SLSReleaseWindow(int cid, uint32_t wid);
        int owner = e->owner_cid ? e->owner_cid : SLSMainConnectionID();
        SLSReleaseWindow(owner, e->wid);
        e->wid = 0;
    }
    e->initialized = false;
    e->owner_cid   = 0;
}

static void payload_focus_xfade_drop(void)
{
    pthread_mutex_lock(&g_focus_fade.lock);
    payload_focus_xfade_drop_locked();
    pthread_mutex_unlock(&g_focus_fade.lock);
}

static void payload_focus_xfade_stash_entry(struct focus_stroke *a)
{
    pthread_mutex_lock(&g_focus_fade.lock);
    payload_focus_xfade_drop_locked();

    struct focus_stroke *e = &g_focus_xfade_out;
    e->wid         = a->wid;
    e->owner_cid   = a->owner_cid;
    e->ca_ctx      = a->ca_ctx;
    e->ca_backdrop = a->ca_backdrop;
    e->ca_mask     = a->ca_mask;
    e->ca_tint     = a->ca_tint;
    e->ca_stroke   = a->ca_stroke;
    e->ca_xray     = a->ca_xray;
    e->initialized = true;

    // detach without releasing — the stash owns the refs now.
    a->wid = 0;
    a->ca_ctx = a->ca_backdrop = a->ca_mask = a->ca_tint = a->ca_stroke = a->ca_xray = nil;
    a->initialized       = false;
    a->target_wid        = 0;
    a->target_rect       = CGRectZero;
    a->surface_origin    = CGPointZero;
    a->surface_size      = CGSizeZero;
    a->attached_sid      = 0;
    pthread_mutex_unlock(&g_focus_fade.lock);
}

static void payload_focus_xfade_stash(void)
{
    payload_focus_xfade_stash_entry(g_active_stroke);
}

static double focus_ease(int mode, double t)
{
    return payload_ease(mode, t);   // shared curve table — see payload_inc/easing.inc.m
}

static void payload_focus_fade_stop(void)
{
    if (!atomic_load(&g_focus_fade.active)) return;
    atomic_store(&g_focus_fade.active, false);
    // NOTE: flag-only stop — the step self-settles next tick; never block. Also
    // finish a mid-flight outgoing ring: the tick zeroes out_wid on clean
    // completion, so this never touches a window it already released.
    if (g_focus_fade.out_wid) {
        payload_focus_set_system_alpha(NULL, g_focus_fade.out_wid, 0.0f);
        g_focus_fade.out_wid = 0;
    }
    payload_focus_xfade_drop();
}

static inline void payload_focus_fade_set_alpha(CFTypeRef tx, int cid, uint32_t wid, float a)
{
    (void)cid;
    payload_focus_set_system_alpha(tx, wid, a);
}

static bool payload_focus_fade_ca_step(void *ctx, CFTypeRef tx, uint32_t did)
{
    (void)ctx;
    if (!atomic_load(&g_focus_fade.active)) return true;

    pthread_mutex_lock(&g_focus_fade.lock);
    uint32_t wid  = g_focus_fade.wid;
    int      cid  = g_focus_fade.cid;
    uint32_t owid = g_focus_fade.out_wid;
    int      ocid = g_focus_fade.out_cid;
    double   dur  = g_focus_fade.duration_s;
    uint64_t st   = g_focus_fade.start_mach;
    double   m2s  = g_focus_fade.mach_to_s;
    int      ez   = g_focus_fade.easing;
    uint32_t fdid = g_focus_fade.did;
    pthread_mutex_unlock(&g_focus_fade.lock);

    // stale-clock guard: re-registered on another display — release this slot.
    if (did != fdid) return true;

    if (!wid && !owid) { payload_focus_fade_stop(); return true; }

    double t = dur > 0.0 ? (double)(mach_absolute_time() - st) * m2s / dur : 1.0;
    if (t > 1.0) t = 1.0;
    double e = focus_ease(ez, t);
    if (wid)  payload_focus_fade_set_alpha(tx, cid,  wid,  (float)e);
    if (owid) payload_focus_fade_set_alpha(tx, ocid, owid, (float)(1.0 - e));

    if (t >= 1.0) {
        if (wid)  payload_focus_fade_set_alpha(tx, cid, wid, 1.0f);
        if (owid) {
            payload_focus_fade_set_alpha(tx, ocid, owid, 0.0f);
            payload_focus_xfade_drop();
        }
        // clear wids first so fade_stop can't touch the window just released.
        pthread_mutex_lock(&g_focus_fade.lock);
        g_focus_fade.wid     = 0;
        g_focus_fade.out_wid = 0;
        pthread_mutex_unlock(&g_focus_fade.lock);
        payload_focus_fade_stop();
        return true;
    }
    return false;
}

static void payload_focus_fade_start_xfade(int in_cid, uint32_t in_wid,
                                           int out_cid, uint32_t out_wid,
                                           double duration_s, int easing)
{
    if ((!in_wid && !out_wid) || duration_s <= 0.0) return;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);

    uint32_t did = payload_focus_display_id_for(g_payload_focus_stroke.target_rect);

    pthread_mutex_lock(&g_focus_fade.lock);
    g_focus_fade.wid        = in_wid;
    g_focus_fade.cid        = in_cid;
    g_focus_fade.out_wid    = out_wid;
    g_focus_fade.out_cid    = out_cid;
    g_focus_fade.easing     = easing;
    g_focus_fade.mach_to_s  = (double)tb.numer / ((double)tb.denom * 1e9);
    g_focus_fade.start_mach = mach_absolute_time();
    g_focus_fade.duration_s = duration_s;
    g_focus_fade.did        = did;
    atomic_store(&g_focus_fade.active, true);
    pthread_mutex_unlock(&g_focus_fade.lock);

    if (in_wid)  payload_focus_set_system_alpha(NULL, in_wid,  0.0f);
    if (out_wid) payload_focus_set_system_alpha(NULL, out_wid, 1.0f);

    // NOTE: register only after dropping the animator lock — ca_clock_register
    // takes clients_lock (lock order). Idempotent by ctx; a retarget re-activates.
    ca_clock_register(did, 0.0f, payload_focus_fade_ca_step, &g_focus_fade);
    ca_clock_resume(did);
    payload_focus_ring_log("fade_ca", "via ca_clock did=0x%x dur=%.3f in=%u out=%u",
                           did, duration_s, in_wid, out_wid);
}

static void payload_focus_fade_start(int cid, uint32_t wid, double duration_s, int easing)
{
    payload_focus_xfade_drop();
    payload_focus_fade_start_xfade(cid, wid, 0, 0, duration_s, easing);
}

static void payload_focus_stroke_track(CFTypeRef transaction, uint32_t wid,
                                       float x, float y, float w, float h)
{
    if (!g_payload_focus_stroke.initialized) return;
    if (!g_payload_focus_ring.visible) return;
    if (wid == 0 || wid != g_payload_focus_stroke.target_wid) return;

    // NOTE: re-pin by moving the SAME window (SLSSetWindowShape) — a recreate
    // would lose the target's sublevel, which cannot be read back on Tahoe. The
    // daemon gates ring shows while a display animates, so the follower is the
    // sole writer here. Surface keeps its size; a larger destination can clip
    // until settle.
    CGPoint tc = { x + w * 0.5f, y + h * 0.5f };
    CGRect surf = { g_payload_focus_stroke.surface_origin, g_payload_focus_stroke.surface_size };
    if (!CGRectContainsPoint(surf, tc)) {
        CGRect dr = payload_focus_display_rect_for(CGRectMake(x, y, w, h));
        if (dr.origin.x != g_payload_focus_stroke.surface_origin.x ||
            dr.origin.y != g_payload_focus_stroke.surface_origin.y) {
            extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x, float y, CGSRegionRef shape);
            CGRect shape = CGRectMake(0.0, 0.0, g_payload_focus_stroke.surface_size.width,
                                                g_payload_focus_stroke.surface_size.height);
            CGSRegionRef region = NULL;
            if (CGSNewRegionWithRect(&shape, &region) == kCGErrorSuccess && region) {
                SLSSetWindowShape(g_payload_focus_stroke.owner_cid, g_payload_focus_stroke.wid,
                                  dr.origin.x, dr.origin.y, region);
                CFRelease(region);
                g_payload_focus_stroke.surface_origin = dr.origin;
                payload_focus_ring_log("stroke_repin",
                                       "wid=%u -> display_origin=(%.0f,%.0f)",
                                       wid, dr.origin.x, dr.origin.y);
            }
        }
    }

    g_payload_focus_stroke.target_rect = CGRectMake(x, y, w, h);
    payload_focus_stroke_draw(g_payload_focus_stroke.target_radius, false);
    (void)transaction;   // the CA flush self-syncs; no SLS txn ride needed.

    payload_focus_ring_log("stroke_track",
                           "wid=%u target_wid=%u rect=(%.0f,%.0f %.0fx%.0f)",
                           g_payload_focus_stroke.wid, wid, x, y, w, h);
}

// NOTE: single retarget animator — agent-transport resizes have no per-frame
// follower, so the daemon fires the target once and the band animates here on
// the ca_clock. easing is the daemon's apply_easing ordinal, matching the
// stepped resize curve; a SHOW/HIDE/MC-ride supersedes it (ownership transfer).
static struct {
    pthread_mutex_t lock;
    uint32_t        target_wid;
    CGRect          from, to;
    uint64_t        start_mach;
    double          duration_s;
    double          mach_to_s;
    int             easing;
    uint32_t        did;
    _Atomic bool    active;
} g_focus_retarget = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void payload_focus_retarget_stop(void)
{
    atomic_store(&g_focus_retarget.active, false);
}

static bool payload_focus_retarget_ca_step(void *ctx, CFTypeRef tx, uint32_t did)
{
    (void)ctx;
    if (!atomic_load(&g_focus_retarget.active)) return true;

    pthread_mutex_lock(&g_focus_retarget.lock);
    uint32_t wid  = g_focus_retarget.target_wid;
    CGRect   from = g_focus_retarget.from;
    CGRect   to   = g_focus_retarget.to;
    double   dur  = g_focus_retarget.duration_s;
    uint64_t st   = g_focus_retarget.start_mach;
    double   m2s  = g_focus_retarget.mach_to_s;
    int      ez   = g_focus_retarget.easing;
    uint32_t rdid = g_focus_retarget.did;
    pthread_mutex_unlock(&g_focus_retarget.lock);

    if (did != rdid) return true;
    if (wid == 0 || wid != g_payload_focus_stroke.target_wid) {
        payload_focus_retarget_stop();
        return true;
    }

    double t = dur > 0.0 ? (double)(mach_absolute_time() - st) * m2s / dur : 1.0;
    if (t > 1.0) t = 1.0;
    float e = apply_easing((float)t, ez);

    payload_focus_stroke_track(tx, wid,
                               from.origin.x    + (to.origin.x    - from.origin.x)    * e,
                               from.origin.y    + (to.origin.y    - from.origin.y)    * e,
                               from.size.width  + (to.size.width  - from.size.width)  * e,
                               from.size.height + (to.size.height - from.size.height) * e);

    if (t >= 1.0) { payload_focus_retarget_stop(); return true; }
    return false;
}

static void do_focus_ring_retarget(char *message)
{
    struct __attribute__((packed)) {
        uint32_t wid;
        float    x, y, w, h;
        float    duration;
        int32_t  easing;
    } req;
    memcpy(&req, message, sizeof(req));

    if (!g_payload_focus_stroke.initialized) return;
    if (req.wid == 0 || req.wid != g_payload_focus_stroke.target_wid) {
        payload_focus_ring_log("retarget_skip", "wid=%u target_wid=%u",
                               req.wid, g_payload_focus_stroke.target_wid);
        return;
    }

    CGRect to = CGRectMake(req.x, req.y, req.w, req.h);
    if (req.duration <= 0.0f) {
        payload_focus_retarget_stop();
        payload_focus_stroke_track(NULL, req.wid, to.origin.x, to.origin.y,
                                   to.size.width, to.size.height);
        return;
    }

    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    uint32_t did = payload_focus_display_id_for(to);

    pthread_mutex_lock(&g_focus_retarget.lock);
    g_focus_retarget.target_wid = req.wid;
    g_focus_retarget.from       = g_payload_focus_stroke.target_rect;
    g_focus_retarget.to         = to;
    g_focus_retarget.easing     = req.easing;
    g_focus_retarget.mach_to_s  = (double)tb.numer / ((double)tb.denom * 1e9);
    g_focus_retarget.start_mach = mach_absolute_time();
    g_focus_retarget.duration_s = req.duration;
    g_focus_retarget.did        = did;
    atomic_store(&g_focus_retarget.active, true);
    pthread_mutex_unlock(&g_focus_retarget.lock);

    ca_clock_register(did, 0.0f, payload_focus_retarget_ca_step, &g_focus_retarget);
    ca_clock_resume(did);
    payload_focus_ring_log("retarget", "wid=%u to=(%.0f,%.0f %.0fx%.0f) dur=%.3f ez=%d",
                           req.wid, req.x, req.y, req.w, req.h, req.duration, req.easing);
}

// deathwatch teardown — frees every ring so no alpha-0 overlay outlives yabai.
static void payload_focus_ring_destroy_all(void)
{
    payload_focus_retarget_stop();
    payload_focus_fade_stop();
    int cid = SLSMainConnectionID();
    for (int i = 0; i < FR_MAX_SPACES; i++) {
        if (!g_focus_stroke_pool[i].initialized) continue;
        g_active_stroke = &g_focus_stroke_pool[i];
        payload_focus_stroke_destroy(cid);
    }
    g_active_stroke = &g_focus_stroke_pool[0];
    g_payload_focus_ring.visible       = false;
    g_payload_focus_ring.target_wid    = 0;
    g_payload_focus_ring.target_radius = 0.0f;
    payload_focus_ring_log("destroy_all", "ok");
}

// ===========================================================================
// Transform mirror — ride a sheet's slide-in/out animation
// ===========================================================================
typedef CGError (*fr_get_at_placement_fn)(int cid, uint32_t wid, int placement, int arg3, CGAffineTransform *out);
typedef CGError (*fr_set_at_placement_fn)(int cid, uint32_t wid, int placement, int arg3, CGAffineTransform *t);

#define FR_MIRROR_PLACEMENT 0x8000001

// SHEET mirrors the sheet's placement slot; MC / MC_ENTER project the focused
// window's live transform3d and couple a fade (in on exit, out on enter).
#define FR_MIRROR_MODE_SHEET    0
#define FR_MIRROR_MODE_MC       1
#define FR_MIRROR_MODE_MC_ENTER 2

// NOTE: the enter grace must outlast the signal->motion gap (the enter signal
// fires ~280ms before app-Expose moves anything); enter fades on time from
// FIRST MOTION, not from arm. Exit is already displaced at arm — brief grace.
#define FR_MC_ENTER_FADE_S         0.20
#define FR_MC_ENTER_MOTION_GRACE_S 0.50
#define FR_MC_EXIT_MOTION_GRACE_S  0.08

static struct {
    pthread_mutex_t  mutex;
    volatile uint32_t src_wid;       // window whose live transform we mirror (0 = idle)
    volatile uint32_t overlay_wid;   // our overlay receiving the translate (sheet mode)
    volatile bool     active;        // ca_clock step client active
    int      cid;
    bool     saw_motion;             // don't settle-stop before the slide actually begins
    int      mode;                   // FR_MIRROR_MODE_SHEET | FR_MIRROR_MODE_MC | FR_MIRROR_MODE_MC_ENTER
    CGRect   base_frame;             // MC modes: window's NATURAL frame (SLSGetWindowBounds) — size source + settle target
    double   base_dist;              // MC exit: arm-time |Δrect| from the settled frame — the fade's 100%-remaining anchor
    double   base_tx, base_ty;       // sheet transform at arm time — captured rect bakes it in; mirror (current - base)
    uint64_t start_mach;             // safety timeout reference
    double   mach_to_s;
    uint32_t did;                    // ca_clock display this mirror registered on (stale-clock guard)
    bool     initialized;
    fr_get_at_placement_fn get_at;
    fr_set_at_placement_fn set_xf;
} g_focus_mirror;

static float fr_mc_exit_alpha(double base_dist, double cur_dist)
{
    if (base_dist < 4.0) return 1.0f;
    double p = 1.0 - cur_dist / base_dist;
    if (p < 0.0) p = 0.0;
    if (p > 1.0) p = 1.0;
    return (float)p;
}

static CGRect fr_project_frame_t3d(CGRect natural, const float m[16])
{
    double sx = m[0], sy = m[5], tx = m[12], ty = m[13];
    CGRect r = natural;
    if (sx != 0.0) { r.origin.x = -tx / sx; r.size.width  = natural.size.width  / sx; }
    if (sy != 0.0) { r.origin.y = -ty / sy; r.size.height = natural.size.height / sy; }
    return r;
}

// NOTE: the per-tick placement read is the one accepted blocking SLS round-
// trip in a step — it mirrors a live server value, bounded by the 0.6s safety.
static bool payload_focus_mirror_ca_step(void *ctx, CFTypeRef tx, uint32_t did)
{
    (void)ctx;
    pthread_mutex_lock(&g_focus_mirror.mutex);
    uint32_t src     = g_focus_mirror.src_wid;
    uint32_t overlay = g_focus_mirror.overlay_wid;
    if (!g_focus_mirror.active || !src) {
        if (g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER)
            logpf("FR_ENTER_STEP", "CA-BAIL active=%d src=%u mode=%d (mirror cleared externally)",
                  g_focus_mirror.active, src, g_focus_mirror.mode);
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return true;
    }
    // stale-clock guard: re-registered on another display — release this slot.
    if (did != g_focus_mirror.did) {
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return true;
    }
    int cid = g_focus_mirror.cid;

    if (g_focus_mirror.mode == FR_MIRROR_MODE_MC ||
        g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER) {
        bool   is_enter = (g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER);
        uint32_t sw     = g_payload_focus_stroke.wid;
        float  m[16];
        CGRect base = g_focus_mirror.base_frame;

        // terminal state: exit lands full-alpha on the final frame; enter parks hidden.
        #define FR_MC_FINALIZE() do {                                                   \
            if (is_enter) {                                                             \
                g_payload_focus_ring.visible = false;                                   \
                payload_focus_set_system_alpha(tx, sw, 0.0f);                           \
            } else {                                                                    \
                payload_focus_ring_follower(tx, src, base);                             \
                payload_focus_set_system_alpha(tx, sw,                                  \
                                               g_payload_focus_ring.visible ? 1.0f : 0.0f); \
            }                                                                           \
            g_focus_mirror.src_wid = 0;                                                 \
            g_focus_mirror.active  = false;                                             \
        } while (0)

        int rc_read = fr_cgs_read_window_t3d(cid, src, m);
        if (is_enter && rc_read != 0)
            logpf("FR_ENTER_STEP", "GETTER-FAIL rc=%d → finalize (park)", rc_read);
        if (rc_read != 0) {
            FR_MC_FINALIZE();
            pthread_mutex_unlock(&g_focus_mirror.mutex);
            return true;
        }
        CGRect cur     = fr_project_frame_t3d(base, m);
        double dscale  = fabs((double)m[0] - 1.0) + fabs((double)m[5] - 1.0);
        double dpos    = fabs(cur.origin.x - base.origin.x) + fabs(cur.origin.y - base.origin.y);
        bool   moving  = (dscale > 0.01 || dpos > 0.5);
        uint64_t now   = mach_absolute_time();
        if (moving && !g_focus_mirror.saw_motion) {
            g_focus_mirror.saw_motion = true;
            g_focus_mirror.start_mach = now;
        }
        double elapsed = (double)(now - g_focus_mirror.start_mach) * g_focus_mirror.mach_to_s;

        if (!moving && !g_focus_mirror.saw_motion) {
            double grace = is_enter ? FR_MC_ENTER_MOTION_GRACE_S : FR_MC_EXIT_MOTION_GRACE_S;
            if (elapsed < grace) {
                pthread_mutex_unlock(&g_focus_mirror.mutex);
                return false;
            }
            if (is_enter) {
                logpf("FOCUS_RING_MC_ENTER", "no motion within %.2fs → snap hide", grace);
            }
            FR_MC_FINALIZE();
            pthread_mutex_unlock(&g_focus_mirror.mutex);
            return true;
        }

        payload_focus_ring_follower(tx, src, cur);

        // gate on target match — a still-retargeting stroke must not fade the wrong wid.
        if (g_payload_focus_stroke.target_wid == src) {
            double dsize    = fabs(cur.size.width - base.size.width) + fabs(cur.size.height - base.size.height);
            double cur_dist = dpos + dsize;
            float a = is_enter
                    ? (float)(1.0 - (elapsed / FR_MC_ENTER_FADE_S > 1.0 ? 1.0 : elapsed / FR_MC_ENTER_FADE_S))
                    : fr_mc_exit_alpha(g_focus_mirror.base_dist, cur_dist);
            payload_focus_set_system_alpha(tx, sw, a);
        }

        bool settled = ((!moving && g_focus_mirror.saw_motion) || elapsed > 0.6);
        if (settled) FR_MC_FINALIZE();
        #undef FR_MC_FINALIZE
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return settled;
    }

    if (!overlay || !g_focus_mirror.get_at || !g_focus_mirror.set_xf) {
        pthread_mutex_unlock(&g_focus_mirror.mutex);
        return true;
    }
    CGAffineTransform t = CGAffineTransformIdentity;
    g_focus_mirror.get_at(cid, src, 0x8000001, 0, &t);
    bool moving = (fabs(t.tx) > 0.5 || fabs(t.ty) > 0.5);
    if (moving) g_focus_mirror.saw_motion = true;

    // offset by (current - base): the captured band rect already bakes in the
    // sheet's arm-time transform; at rest this lands on -base = the final frame.
    double ax = t.tx - g_focus_mirror.base_tx;
    double ay = t.ty - g_focus_mirror.base_ty;
    // 1px lead-edge buffer per animated axis — the ring otherwise lands 1px shy.
    if (g_focus_mirror.base_tx != 0.0) ax -= (g_focus_mirror.base_tx > 0.0) ? 1.0 : -1.0;
    if (g_focus_mirror.base_ty != 0.0) ay -= (g_focus_mirror.base_ty > 0.0) ? 1.0 : -1.0;
    CGAffineTransform xf = CGAffineTransformMake(1, 0, 0, 1, ax, ay);
    g_focus_mirror.set_xf(cid, overlay, FR_MIRROR_PLACEMENT, 0, &xf);

    // the settled value stays on the overlay; the next show's mirror_stop resets it.
    double elapsed = (double)(mach_absolute_time() - g_focus_mirror.start_mach) * g_focus_mirror.mach_to_s;
    bool settled = ((!moving && g_focus_mirror.saw_motion) || elapsed > 0.6);
    if (settled) {
        g_focus_mirror.src_wid = 0;
        g_focus_mirror.active = false;
    }
    pthread_mutex_unlock(&g_focus_mirror.mutex);
    return settled;
}

static void payload_focus_mirror_init(void)
{
    if (g_focus_mirror.initialized) return;
    struct mach_timebase_info tb; mach_timebase_info(&tb);
    g_focus_mirror.mach_to_s = (double)tb.numer / ((double)tb.denom * 1e9);
    pthread_mutex_init(&g_focus_mirror.mutex, NULL);
    g_focus_mirror.get_at = (fr_get_at_placement_fn)dlsym(RTLD_DEFAULT, "SLSGetWindowTransformAtPlacement");
    if (!g_focus_mirror.get_at)
        g_focus_mirror.get_at = (fr_get_at_placement_fn)dlsym(RTLD_DEFAULT, "_SLSGetWindowTransformAtPlacement");
    g_focus_mirror.set_xf = (fr_set_at_placement_fn)dlsym(RTLD_DEFAULT, "SLSSetWindowTransformAtPlacement");
    if (!g_focus_mirror.set_xf)
        g_focus_mirror.set_xf = (fr_set_at_placement_fn)dlsym(RTLD_DEFAULT, "_SLSSetWindowTransformAtPlacement");
    int t3d_ok = fr_cgs_t3d_resolve();   // string-xref resolve of _CGSGetWindowTransform3D (dlsym-null)
    logpf("FOCUS_RING_MC_RIDE", "init tf3d resolver=%s", t3d_ok ? "OK (string-xref)" : "FAILED");
    g_focus_mirror.initialized = true;
}

static void payload_focus_mirror_start(int cid, uint32_t sheet_wid, uint32_t overlay_wid,
                                       double base_tx, double base_ty)
{
    if (!sheet_wid || !overlay_wid) return;
    payload_focus_mirror_init();
    if (!g_focus_mirror.get_at || !g_focus_mirror.set_xf) return;

    uint32_t did = payload_focus_display_id_for(g_payload_focus_stroke.target_rect);

    pthread_mutex_lock(&g_focus_mirror.mutex);
    g_focus_mirror.cid         = cid;
    g_focus_mirror.src_wid     = sheet_wid;
    g_focus_mirror.mode        = FR_MIRROR_MODE_SHEET;
    g_focus_mirror.overlay_wid = overlay_wid;
    g_focus_mirror.saw_motion  = false;
    g_focus_mirror.base_tx     = base_tx;
    g_focus_mirror.base_ty     = base_ty;
    g_focus_mirror.start_mach  = mach_absolute_time();
    g_focus_mirror.did         = did;
    g_focus_mirror.active      = true;
    pthread_mutex_unlock(&g_focus_mirror.mutex);

    ca_clock_register(did, 0.0f, payload_focus_mirror_ca_step, &g_focus_mirror);
    ca_clock_resume(did);
}

static void payload_focus_mirror_start_mc(int cid, uint32_t target_wid,
                                          uint32_t overlay_wid, CGRect base_frame,
                                          int mode, double base_dist)
{
    if (!target_wid) return;
    payload_focus_mirror_init();
    if (!fr_cgs_t3d_resolve()) return;

    uint32_t did = payload_focus_display_id_for(base_frame);
    pthread_mutex_lock(&g_focus_mirror.mutex);
    g_focus_mirror.cid         = cid;
    g_focus_mirror.src_wid     = target_wid;
    g_focus_mirror.overlay_wid = overlay_wid;
    g_focus_mirror.saw_motion  = false;
    g_focus_mirror.mode        = mode;
    g_focus_mirror.base_frame  = base_frame;
    g_focus_mirror.base_dist   = base_dist;
    g_focus_mirror.start_mach  = mach_absolute_time();
    g_focus_mirror.did         = did;
    g_focus_mirror.active      = true;
    pthread_mutex_unlock(&g_focus_mirror.mutex);

    ca_clock_register(did, 0.0f, payload_focus_mirror_ca_step, &g_focus_mirror);
    ca_clock_resume(did);
}

static void payload_focus_mirror_stop(void)
{
    if (g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER || g_focus_mirror.mode == FR_MIRROR_MODE_MC)
        logpf("FR_ENTER_STEP", "MIRROR_STOP called while mode=%d src=%u active=%d (SHOW stomped the ride?)",
              g_focus_mirror.mode, g_focus_mirror.src_wid, g_focus_mirror.active);
    if (!g_focus_mirror.initialized || !g_focus_mirror.active) return;
    pthread_mutex_lock(&g_focus_mirror.mutex);
    if (g_focus_mirror.set_xf && g_focus_mirror.overlay_wid) {
        CGAffineTransform id = CGAffineTransformIdentity;
        g_focus_mirror.set_xf(g_focus_mirror.cid, g_focus_mirror.overlay_wid, FR_MIRROR_PLACEMENT, 0, &id);
    }
    g_focus_mirror.src_wid = 0;
    g_focus_mirror.active = false;
    // NOTE: flag-only — the tick takes this same mutex; a blocking stop deadlocks.
    pthread_mutex_unlock(&g_focus_mirror.mutex);
}

// NOTE: SHOW wire struct is append-only (packed, little-endian) — never
// reorder. force_style=1 (explicit config change) clears the color_override
// latch; passive focus events pass 0. sid is re-resolved payload-side.
static void do_focus_ring_show(char *message)
{
    struct __attribute__((packed)) {
        uint32_t wid;
        float    x, y, w, h;
        float    radius;
        float    stroke_width;
        float    stroke_alpha;
        float    stroke_r, stroke_g, stroke_b;
        uint8_t  force_style;
        int32_t  blur_radius;
        int32_t  style;
        float    blur_saturation;
        float    blur_brightness;
        int32_t  blend_mode;
        uint8_t  blur_stroke;
        int32_t  blur_stroke_position;
        float    blur_stroke_width;
        float    blur_bleed;
        float    tint_r, tint_g, tint_b, tint_a;
        float    str_r, str_g, str_b, str_a;
        float    blur_contrast;
        float    blur_feather;   // appended (wire contract)
        float    fade_duration;  // appended (wire contract — never reorder)
        int32_t  target_level;     // appended (wire contract — never reorder)
        int32_t  target_sublevel;  // appended (wire contract — never reorder)
        float    blur_hue;         // appended (wire contract — never reorder)
        // appended (wire contract): xray_count closes the fixed struct; that many
        // 4-float rects follow it. window_alpha appended after (rects still by sizeof).
        uint8_t  xray;
        float    xray_r, xray_g, xray_b, xray_a;
        int32_t  xray_count;
        float    window_alpha;
    } req;
    memcpy(&req, message, sizeof(req));

    payload_focus_retarget_stop();

    g_focus_ring_xray   = req.xray != 0;
    g_focus_ring_xray_r = req.xray_r;
    g_focus_ring_xray_g = req.xray_g;
    g_focus_ring_xray_b = req.xray_b;
    g_focus_ring_xray_a = req.xray_a < 0.0f ? 0.0f : (req.xray_a > 1.0f ? 1.0f : req.xray_a);
    {
        int n = req.xray_count;
        if (n < 0) n = 0;
        if (n > SA_FOCUS_RING_XRAY_MAX_RECTS) n = SA_FOCUS_RING_XRAY_MAX_RECTS;
        const char *cursor = message + sizeof(req);
        for (int i = 0; i < n; ++i) {
            float v[4];
            memcpy(v, cursor + i * 4 * sizeof(float), sizeof(v));
            g_focus_ring_xray_rects[i] = CGRectMake(v[0], v[1], v[2], v[3]);
        }
        g_focus_ring_xray_count = n;
    }

    if (req.force_style) g_payload_focus_ring_color_override = false;

    if (req.stroke_width  >= 0.0f && req.stroke_width  <= 32.0f) g_focus_ring_stroke_width = req.stroke_width;
    g_focus_ring_window_alpha = req.window_alpha < 0.0f ? 0.0f
                              : (req.window_alpha > 1.0f ? 1.0f : req.window_alpha);
    if (!g_payload_focus_ring_color_override) {
        if (req.stroke_alpha >= 0.0f && req.stroke_alpha <= 1.0f) g_focus_ring_stroke_alpha = req.stroke_alpha;
        g_focus_ring_stroke_r = req.stroke_r;
        g_focus_ring_stroke_g = req.stroke_g;
        g_focus_ring_stroke_b = req.stroke_b;
    }

    g_focus_ring_blur_radius = req.blur_radius < 0 ? 0
                             : (req.blur_radius > 64 ? 64 : req.blur_radius);

    // req.style stays on the wire (contract) but is ignored — blur radius decides.

    g_focus_ring_blur_saturation = req.blur_saturation < 0.0f ? 0.0f
                                 : (req.blur_saturation > 4.0f ? 4.0f : req.blur_saturation);
    g_focus_ring_blur_brightness = req.blur_brightness < -1.0f ? -1.0f
                                 : (req.blur_brightness > 1.0f ? 1.0f : req.blur_brightness);
    g_focus_ring_blur_contrast = req.blur_contrast < 0.0f ? 0.0f
                               : (req.blur_contrast > 4.0f ? 4.0f : req.blur_contrast);
    g_focus_ring_blur_hue = req.blur_hue < 0.0f ? 0.0f
                          : (req.blur_hue > 360.0f ? 360.0f : req.blur_hue);
    g_focus_ring_blend_mode = (req.blend_mode < 0 || req.blend_mode >= FOCUS_RING_BLEND_COUNT)
                            ? 0 : req.blend_mode;

    g_focus_ring_blur_stroke          = req.blur_stroke != 0;
    g_focus_ring_blur_stroke_position = (req.blur_stroke_position == 1) ? 1 : 0;
    g_focus_ring_blur_stroke_width    = req.blur_stroke_width < 0.5f ? 0.5f
                                      : (req.blur_stroke_width > 32.0f ? 32.0f : req.blur_stroke_width);

    g_focus_ring_blur_bleed = req.blur_bleed < 0.0f ? 0.0f
                            : (req.blur_bleed > 64.0f ? 64.0f : req.blur_bleed);

    g_focus_ring_blur_tint_r = req.tint_r; g_focus_ring_blur_tint_g = req.tint_g;
    g_focus_ring_blur_tint_b = req.tint_b; g_focus_ring_blur_tint_a = req.tint_a;
    g_focus_ring_blur_strokeclr_r = req.str_r; g_focus_ring_blur_strokeclr_g = req.str_g;
    g_focus_ring_blur_strokeclr_b = req.str_b; g_focus_ring_blur_strokeclr_a = req.str_a;

    g_focus_ring_blur_feather = req.blur_feather < 0.0f ? 0.0f
                              : (req.blur_feather > 64.0f ? 64.0f : req.blur_feather);

    g_focus_ring_fade_duration = req.fade_duration < 0.0f ? 0.0f
                               : (req.fade_duration > 5.0f ? 5.0f : req.fade_duration);

    {
        struct fr_style_bank *bank = (req.wid == 0) ? &g_fr_style_desktop : &g_fr_style_main;
        bank->band_width  = g_focus_ring_stroke_width;
        bank->blur        = g_focus_ring_blur_radius;
        bank->sat         = g_focus_ring_blur_saturation;
        bank->bri         = g_focus_ring_blur_brightness;
        bank->con         = g_focus_ring_blur_contrast;
        bank->hue         = g_focus_ring_blur_hue;
        bank->feather     = g_focus_ring_blur_feather;
        bank->blend       = g_focus_ring_blend_mode;
        bank->tint_r      = g_focus_ring_blur_tint_r;
        bank->tint_g      = g_focus_ring_blur_tint_g;
        bank->tint_b      = g_focus_ring_blur_tint_b;
        bank->tint_a      = g_focus_ring_blur_tint_a;
        bank->strokeclr_r = g_focus_ring_blur_strokeclr_r;
        bank->strokeclr_g = g_focus_ring_blur_strokeclr_g;
        bank->strokeclr_b = g_focus_ring_blur_strokeclr_b;
        bank->strokeclr_a = g_focus_ring_blur_strokeclr_a;
    }

    payload_focus_ring_log("show_recv",
                           "wid=%u rect=(%.0f,%.0f %.0fx%.0f) radius=%.1f width=%.2f alpha=%.2f rgb=(%.2f,%.2f,%.2f) force=%d",
                           req.wid,
                           req.x, req.y, req.w, req.h, req.radius,
                           g_focus_ring_stroke_width, g_focus_ring_stroke_alpha,
                           g_focus_ring_stroke_r, g_focus_ring_stroke_g, g_focus_ring_stroke_b,
                           req.force_style);

    int cid = SLSMainConnectionID();
    CGRect target_rect = CGRectMake(req.x, req.y, req.w, req.h);

    // read the sheet slot early — the baseline must match the offset baked into
    // the daemon-captured rect (minimizes the settle shift).
    payload_focus_mirror_init();
    CGAffineTransform mirror_base = CGAffineTransformIdentity;
    if (g_focus_mirror.get_at) g_focus_mirror.get_at(cid, req.wid, 0x8000001, 0, &mirror_base);

    extern CFArrayRef SLSCopySpacesForWindows(int cid, int selector, CFArrayRef window_list);
    uint64_t sid = 0;
    if (req.wid != 0) {
        uint32_t wlist[1] = { req.wid };
        CFArrayRef warr = cfarray_of_cfnumbers(wlist, sizeof(uint32_t),
                                                1, kCFNumberSInt32Type);
        if (warr) {
            CFArrayRef sids = SLSCopySpacesForWindows(cid, 0x7, warr);
            if (sids && CFArrayGetCount(sids) > 0) {
                CFNumberRef n = CFArrayGetValueAtIndex(sids, 0);
                CFNumberGetValue(n, kCFNumberSInt64Type, &sid);
            }
            if (sids) CFRelease(sids);
            CFRelease(warr);
        }
    }

    // key the desktop ring (wid==0) to the covered display's CURRENT space — a
    // sid==0 scratch entry can never be found by space-keyed lookups again.
    if (sid == 0) {
        extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
        CGPoint c = CGPointMake(req.x + req.w / 2.0f, req.y + req.h / 2.0f);
        CGDirectDisplayID ddid = 0;
        uint32_t dcnt = 0;
        if (CGGetDisplaysWithPoint(c, 1, &ddid, &dcnt) == kCGErrorSuccess && dcnt > 0) {
            CFUUIDRef u = CGDisplayCreateUUIDFromDisplayID(ddid);
            if (u) {
                CFStringRef uuid = CFUUIDCreateString(NULL, u);
                if (uuid) {
                    sid = SLSManagedDisplayGetCurrentSpace(cid, uuid);
                    CFRelease(uuid);
                }
                CFRelease(u);
            }
        }
    }

    // capture the on-screen entry BEFORE fr_pool_acquire repoints g_active_stroke.
    struct focus_stroke *prev_active = g_active_stroke;

    g_active_stroke = fr_pool_acquire(cid, sid);
    g_active_stroke->last_used_mach = mach_absolute_time();

    bool needs_new_surface = false;
    if (g_payload_focus_stroke.initialized) {
        CGRect  surf = { g_payload_focus_stroke.surface_origin,
                         g_payload_focus_stroke.surface_size };
        CGPoint tc   = { target_rect.origin.x + target_rect.size.width  / 2.0f,
                         target_rect.origin.y + target_rect.size.height / 2.0f };
        needs_new_surface = (g_payload_focus_stroke.target_wid  != req.wid) ||
                            (g_payload_focus_stroke.attached_sid != sid)     ||
                            !CGRectContainsPoint(surf, tc);
    }

    // NOTE: crossfade gate. Outgoing target_wid==0 is BOTH the desktop ring AND
    // the sentinel fr_pool_hide_others stamps to force a rebuild-snap. The desktop
    // ring is the ACTIVE slot rebuilt in place; an invalidated park is always a
    // different slot — so wid==0 may crossfade only when prev_active == active.
    bool want_xfade = g_payload_focus_stroke.initialized
                   && needs_new_surface
                   && g_payload_focus_ring.visible
                   && g_focus_ring_animate
                   && g_focus_ring_fade_duration > 0.0f
                   && (g_payload_focus_stroke.target_wid != 0 || prev_active == g_active_stroke)
                   && g_payload_focus_stroke.target_wid != req.wid
                   && g_payload_focus_stroke.attached_sid == sid;

    // NOTE: cross-pool fade — focus landing on a DIFFERENT slot means the old ring
    // is the departed display's; fade it 1->0 instead of the hide_others snap. Two
    // desktop rings share wid 0, so the distinct slot IS the change test.
    bool want_xdisplay_fade = (prev_active != g_active_stroke)
                           && prev_active->initialized
                           && prev_active->wid != 0
                           && (prev_active->target_wid != req.wid ||
                               (prev_active->target_wid == 0 && req.wid == 0))
                           && g_payload_focus_ring.visible
                           && g_focus_ring_animate
                           && g_focus_ring_fade_duration > 0.0f;

    if (!g_payload_focus_stroke.initialized || needs_new_surface) {
        if (g_payload_focus_stroke.initialized) {
            if (want_xfade) payload_focus_xfade_stash();
            else            payload_focus_stroke_destroy(cid);
        }
        if (!payload_focus_stroke_ensure(cid, target_rect, sid)) {
            if (want_xfade) payload_focus_xfade_drop();  // ensure failed — don't orphan the stash
            payload_focus_ring_log("show_skip",
                                   "wid=%u reason=ensure_failed",
                                   req.wid);
            return;
        }
        // born transparent when dissolving — no full-alpha flash before the fade-in.
        if (want_xfade || want_xdisplay_fade) {
            payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid, 0.0f);
        }
    }

    g_payload_focus_stroke.target_wid    = req.wid;
    g_payload_focus_stroke.target_radius = req.radius;
    g_payload_focus_stroke.target_rect   = target_rect;

    g_payload_focus_ring.target_wid    = req.wid;
    g_payload_focus_ring.target_radius = req.radius;

    payload_focus_stroke_draw(req.radius, false);

    // NOTE: SLSOrderWindow only resolves against the target when both share level
    // AND sublevel (a BSP target sits at the -20 sublevel) — stamp the daemon-
    // supplied pair first; the payload can't read sublevel back on Tahoe. Bleed's
    // edge-sampling needs the ring ABOVE the target; the order_below knob wins.
    extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
    SLSSetWindowLevel(cid, g_payload_focus_stroke.wid, req.target_level);
    SLSSetWindowSubLevel(cid, g_payload_focus_stroke.wid, req.target_sublevel);

    extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
    bool bleed_active = g_focus_ring_blur_bleed > 0.0f;
    bool order_below = g_payload_focus_ring_order_below;
    int order = order_below ? -1 : 1;
    CGError order_rc = SLSOrderWindow(cid, g_payload_focus_stroke.wid, order, req.wid);
    payload_focus_ring_log("show_done",
                           "target=%u overlay=%u cid=%d %s%s level=%d sublevel=%d order_rc=%d",
                           req.wid, g_payload_focus_stroke.wid, cid,
                           order_below ? "below" : "above",
                           bleed_active ? " (bleed-on)" : "",
                           req.target_level, req.target_sublevel, (int)order_rc);

    // restamp visibility every SHOW — the reuse path skips ensure()'s alpha.
    {
        int alpha_owner = g_payload_focus_stroke.owner_cid
                        ? g_payload_focus_stroke.owner_cid : cid;
        SLSSetWindowAlpha(alpha_owner, g_payload_focus_stroke.wid, g_focus_ring_window_alpha);
        if (want_xfade && g_focus_xfade_out.initialized) {
            int out_owner = g_focus_xfade_out.owner_cid ? g_focus_xfade_out.owner_cid : cid;
            payload_focus_fade_start_xfade(alpha_owner, g_payload_focus_stroke.wid,
                                           out_owner,   g_focus_xfade_out.wid,
                                           (double)g_focus_ring_fade_duration, 1);
        } else if (want_xdisplay_fade) {
            payload_focus_xfade_stash_entry(prev_active);
            if (g_focus_xfade_out.initialized) {
                int out_owner = g_focus_xfade_out.owner_cid ? g_focus_xfade_out.owner_cid : cid;
                payload_focus_fade_start_xfade(alpha_owner, g_payload_focus_stroke.wid,
                                               out_owner,   g_focus_xfade_out.wid,
                                               (double)g_focus_ring_fade_duration, 1);
                payload_focus_ring_log("xdisplay_fade",
                                       "in_wid=%u out_wid=%u dur=%.3f",
                                       g_payload_focus_stroke.wid, g_focus_xfade_out.wid,
                                       g_focus_ring_fade_duration);
            } else {
                payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid,
                                               g_payload_focus_ring.visible ? 1.0f : 0.0f);
            }
        } else if (atomic_load(&g_focus_fade.active) &&
                   g_focus_fade.wid == g_payload_focus_stroke.wid) {
            // NOTE: a desktop click fans out to duplicate wid==0 shows tens of ms apart;
            // one landing mid-crossfade on the SAME overlay must not snap — that strands
            // the stashed outgoing ring visible. Let the fade ride.
            payload_focus_ring_log("xfade_keep",
                                   "wid=%u (duplicate re-show during fade)",
                                   g_payload_focus_stroke.wid);
        } else {
            payload_focus_fade_stop();
            payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid,
                                           g_payload_focus_ring.visible ? 1.0f : 0.0f);
        }
        fr_pool_hide_others(cid, g_active_stroke);
    }

    // NOTE: the mirror is ONE shared engine — an MC ride also lives in
    // g_focus_mirror; a SHOW landing mid-ride must not mirror_stop() it.
    bool mc_ride_active = g_focus_mirror.active &&
                          (g_focus_mirror.mode == FR_MIRROR_MODE_MC ||
                           g_focus_mirror.mode == FR_MIRROR_MODE_MC_ENTER);
    if (!mc_ride_active && g_focus_mirror.get_at && g_focus_mirror.set_xf) {
        bool moving = (fabs(mirror_base.tx) > 0.5 || fabs(mirror_base.ty) > 0.5);
        payload_focus_ring_log("mirror", "target=%u overlay=%u moving=%d base=(%.1f,%.1f)",
                               req.wid, g_payload_focus_stroke.wid, moving ? 1 : 0,
                               mirror_base.tx, mirror_base.ty);
        if (moving) payload_focus_mirror_start(cid, req.wid, g_payload_focus_stroke.wid,
                                               mirror_base.tx, mirror_base.ty);
        else        payload_focus_mirror_stop();
    }
}

static void do_focus_ring_hide(char *message)
{
    (void)message;
    payload_focus_ring_log("hide_recv", "prev_wid=%u", g_payload_focus_ring.target_wid);

    payload_focus_retarget_stop();
    payload_focus_fade_stop();
    payload_focus_stroke_destroy(SLSMainConnectionID());
    g_payload_focus_ring.target_wid    = 0;
    g_payload_focus_ring.target_radius = 0.0f;
}

// NOTE: fades the ACTIVE ring 1<->0 and leaves it PARKED (surface kept) so the
// reverse toggle fades back in; deliberately never touches the master flag.
static void do_focus_ring_fade_visible(char *message)
{
    uint8_t v;
    memcpy(&v, message, sizeof(v)); message += sizeof(v);
    int32_t fade_ms;
    memcpy(&fade_ms, message, sizeof(fade_ms)); message += sizeof(fade_ms);
    int32_t easing;
    memcpy(&easing, message, sizeof(easing));
    bool visible = v != 0;

    uint32_t wid   = g_payload_focus_stroke.wid;
    int      owner = g_payload_focus_stroke.owner_cid
                   ? g_payload_focus_stroke.owner_cid : SLSMainConnectionID();

    payload_focus_ring_log("fade_visible_recv", "wid=%u visible=%d fade_ms=%d",
                           wid, visible ? 1 : 0, fade_ms);

    if (!wid || !g_payload_focus_stroke.initialized) return;

    if (fade_ms <= 0) {
        payload_focus_fade_stop();
        payload_focus_set_system_alpha(NULL, wid, visible ? 1.0f : 0.0f);
        return;
    }

    double dur = (double)fade_ms / 1000.0;
    if (visible) payload_focus_fade_start_xfade(owner, wid, 0, 0, dur, easing);
    else         payload_focus_fade_start_xfade(0, 0, owner, wid, dur, easing);
}

static void do_focus_ring_set_visible(char *message)
{
    uint8_t v;
    memcpy(&v, message, sizeof(v));
    bool visible = v != 0;

    payload_focus_ring_log("set_visible_recv", "visible=%d", visible ? 1 : 0);

    g_payload_focus_ring.visible = visible;

    if (!visible) {
        // DISABLE parks every per-space ring — a parked one would flash in on switch.
        for (int i = 0; i < FR_MAX_SPACES; i++) {
            struct focus_stroke *fs = &g_focus_stroke_pool[i];
            if (!fs->initialized || !fs->wid) continue;
            payload_focus_set_system_alpha(NULL, fs->wid, 0.0f);
            payload_focus_ring_log("set_visible", "wid=%u visible=0", fs->wid);
        }
        return;
    }

    // ENABLE re-lights only the ACTIVE ring — the daemon re-asserts per focus
    // (self-heal), and re-lighting parked rings blinks the land-time reveal.
    if (g_payload_focus_stroke.initialized && g_payload_focus_stroke.wid) {
        payload_focus_set_system_alpha(NULL, g_payload_focus_stroke.wid, 1.0f);
        payload_focus_ring_log("set_visible", "wid=%u visible=1 (active only)", g_payload_focus_stroke.wid);
    }
}

// NOTE: park = create for the destination from geometry only (style from the
// banks; this opcode carries no style), born parked on its focused window.
static struct focus_stroke *payload_focus_ring_park(int cid, uint32_t wid,
                                                    CGRect target_rect,
                                                    float radius, uint64_t sid)
{
    if (sid == 0 || wid == 0) return NULL;

    g_active_stroke = fr_pool_acquire(cid, sid);
    g_active_stroke->last_used_mach = mach_absolute_time();

    bool needs_new_surface = false;
    if (g_payload_focus_stroke.initialized) {
        CGRect  surf = { g_payload_focus_stroke.surface_origin,
                         g_payload_focus_stroke.surface_size };
        CGPoint tc   = { target_rect.origin.x + target_rect.size.width  / 2.0f,
                         target_rect.origin.y + target_rect.size.height / 2.0f };
        needs_new_surface = (g_payload_focus_stroke.target_wid  != wid) ||
                            (g_payload_focus_stroke.attached_sid != sid)  ||
                            !CGRectContainsPoint(surf, tc);
    }

    if (!g_payload_focus_stroke.initialized || needs_new_surface) {
        if (g_payload_focus_stroke.initialized) payload_focus_stroke_destroy(cid);
        if (!payload_focus_stroke_ensure(cid, target_rect, sid)) {
            payload_focus_ring_log("park_skip", "wid=%u sid=%llu reason=ensure_failed",
                                   wid, (unsigned long long)sid);
            return NULL;
        }
    }

    g_payload_focus_stroke.target_wid    = wid;
    g_payload_focus_stroke.target_radius = radius;
    g_payload_focus_stroke.target_rect   = target_rect;
    g_payload_focus_ring.target_wid      = wid;
    g_payload_focus_ring.target_radius   = radius;

    payload_focus_stroke_draw(radius, false);

    extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
    bool order_below = g_payload_focus_ring_order_below;
    SLSOrderWindow(cid, g_payload_focus_stroke.wid, order_below ? -1 : 1, wid);

    return g_active_stroke;
}

// NOTE: idempotent with the space-switch park (needs_new_surface reuses); the
// slide drives GEO only — the alpha reveal stays with the focus_ring fade.
uint32_t payload_focus_ring_park_for_slide(int cid, uint32_t target_wid,
                                           CGRect rect, float radius, uint64_t sid)
{
    if (target_wid == 0 || sid == 0) return 0;
    struct focus_stroke *s = payload_focus_ring_park(cid, target_wid, rect, radius, sid);
    return s ? g_payload_focus_stroke.wid : 0;
}

// NOTE: call AFTER the in-side park — a full pool's LRU acquire can evict this
// entry. The slide parks it dark via its own pump tx; pre-stamp the advisory
// alpha (that path bypasses fr_stroke_note_alpha).
uint32_t payload_focus_ring_adopt_for_exit(uint64_t out_sid)
{
    if (!g_payload_focus_ring.visible) return 0;
    struct focus_stroke *out = fr_pool_find(out_sid);
    if (!out || !out->initialized || !out->wid) return 0;
    out->last_alpha = 0.0f;
    return out->wid;
}

static void do_focus_ring_space_switch(char *message)
{
    struct __attribute__((packed)) {
        uint64_t out_sid;
        uint64_t in_sid;
        int32_t  fade_ms;     // >0: fade incoming 0->1 over this (animated path); 0: instant
        int32_t  easing;      // alpha curve (enum focus_ring_easing)
        uint32_t dest_wid;    // incoming space's focused window (0 = toggle-only)
        float    dest_x, dest_y, dest_w, dest_h;   // its screen rect
        float    dest_radius; // its corner radius
    } req;
    memcpy(&req, message, sizeof(req));

    int cid = SLSMainConnectionID();

    struct focus_stroke *out = fr_pool_find(req.out_sid);
    if (out && out->wid) {
        payload_focus_set_system_alpha(NULL, out->wid, 0.0f);
    }

    struct focus_stroke *in = fr_pool_find(req.in_sid);
    // re-park when the parked entry's target or rect went stale while the space
    // was inactive — a stale entry rides in at its old rect, then visibly snaps.
    if (req.dest_wid != 0) {
        CGRect dest_rect = CGRectMake(req.dest_x, req.dest_y, req.dest_w, req.dest_h);
        bool stale = (!in || !in->wid) ||
                     (in->target_wid != req.dest_wid) ||
                     !CGRectEqualToRect(in->target_rect, dest_rect);
        if (stale) {
            in = payload_focus_ring_park(cid, req.dest_wid, dest_rect, req.dest_radius, req.in_sid);
        }
    }
    if (in && in->wid) {
        int owner = in->owner_cid ? in->owner_cid : cid;
        bool do_fade = (req.fade_ms > 0 && g_payload_focus_ring.visible);
        if (g_payload_focus_ring.visible && in->last_alpha >= 0.99f) {
            // already lit at the destination — re-running the reveal seeds alpha 0 first
            // (the land blink). Just cancel any stale fade.
            payload_focus_fade_stop();
            payload_focus_ring_log("space_switch", "reveal_skip in=%u reason=already_lit", in->wid);
        } else if (do_fade) {
            payload_focus_fade_start(owner, in->wid, (double)req.fade_ms / 1000.0, req.easing);
        } else {
            payload_focus_fade_stop();
            payload_focus_set_system_alpha(NULL, in->wid, g_payload_focus_ring.visible ? 1.0f : 0.0f);
        }
        g_active_stroke = in;   // t3d/track now target the destination's ring
    }

    fr_pool_hide_others(cid, in);

    payload_focus_ring_log("space_switch",
                           "out_sid=%llu in_sid=%llu out=%u in=%u fade_ms=%d",
                           (unsigned long long)req.out_sid,
                           (unsigned long long)req.in_sid,
                           out ? out->wid : 0, in ? in->wid : 0, req.fade_ms);
}

// NOTE: follower runs on the pump thread under the engine lock — touch only
// the passed tx, no blocking SLS calls. Called for every animated wid;
// stroke_track self-filters on the target.
// MC exit: armed at alpha 0, band pre-placed on the thumbnail, then ridden
// thumbnail->full while fading 0->1 — so the full-size frame never flashes.
static void do_focus_ring_mc_ride(char *message)
{
    struct __attribute__((packed)) { uint32_t wid; } req;
    memcpy(&req, message, sizeof req);
    if (!req.wid) return;

    payload_focus_retarget_stop();
    uint32_t sw = g_payload_focus_stroke.wid;
    g_payload_focus_ring.visible = true;
    payload_focus_set_system_alpha(NULL, sw, 0.0f);

    payload_focus_mirror_init();
    if (!fr_cgs_t3d_resolve()) {
        payload_focus_set_system_alpha(NULL, sw, 1.0f);
        logpf("FOCUS_RING_MC_RIDE", "arm wid=%u resolver=FAILED (reveal, no ride)", req.wid);
        return;
    }

    int    cid  = SLSMainConnectionID();
    CGRect base = {0};
    if (SLSGetWindowBounds(cid, req.wid, &base) != kCGErrorSuccess ||
        base.size.width <= 0 || base.size.height <= 0) {
        payload_focus_set_system_alpha(NULL, sw, 1.0f);
        logpf("FOCUS_RING_MC_RIDE", "arm wid=%u no bounds (reveal, no ride)", req.wid);
        return;
    }

    float  m[16] = {0};
    int    rc    = fr_cgs_read_window_t3d(cid, req.wid, m);
    double base_dist = 0.0;
    if (rc == 0 && g_payload_focus_stroke.target_wid == req.wid) {
        CGRect arm = fr_project_frame_t3d(base, m);
        payload_focus_ring_follower(NULL, req.wid, arm);
        base_dist = fabs(arm.origin.x - base.origin.x) + fabs(arm.origin.y - base.origin.y)
                  + fabs(arm.size.width - base.size.width) + fabs(arm.size.height - base.size.height);
    }

    payload_focus_mirror_start_mc(cid, req.wid, sw, base, FR_MIRROR_MODE_MC, base_dist);
    logpf("FOCUS_RING_MC_RIDE", "armed wid=%u rc=%d natural=(%.0f,%.0f %.0fx%.0f) sx=%.3f dist=%.0f",
          req.wid, rc, base.origin.x, base.origin.y, base.size.width, base.size.height, m[0], base_dist);
}

// MC enter: inverse ride full->thumbnail fading 1->0, parks hidden; no getter/
// bounds -> snap hide.
static void do_focus_ring_mc_enter_ride(char *message)
{
    struct __attribute__((packed)) { uint32_t wid; } req;
    memcpy(&req, message, sizeof req);
    if (!req.wid) return;

    payload_focus_retarget_stop();
    uint32_t sw = g_payload_focus_stroke.wid;

    payload_focus_mirror_init();
    if (!fr_cgs_t3d_resolve()) {
        g_payload_focus_ring.visible = false;
        payload_focus_set_system_alpha(NULL, sw, 0.0f);
        logpf("FOCUS_RING_MC_ENTER", "arm wid=%u resolver=FAILED (snap hide)", req.wid);
        return;
    }

    int    cid  = SLSMainConnectionID();
    CGRect base = {0};
    if (SLSGetWindowBounds(cid, req.wid, &base) != kCGErrorSuccess ||
        base.size.width <= 0 || base.size.height <= 0) {
        g_payload_focus_ring.visible = false;
        payload_focus_set_system_alpha(NULL, sw, 0.0f);
        logpf("FOCUS_RING_MC_ENTER", "arm wid=%u no bounds (snap hide)", req.wid);
        return;
    }

    g_payload_focus_ring.visible = true;
    payload_focus_mirror_start_mc(cid, req.wid, sw, base, FR_MIRROR_MODE_MC_ENTER, 0.0);
    logpf("FOCUS_RING_MC_ENTER", "armed wid=%u natural=(%.0f,%.0f %.0fx%.0f)",
          req.wid, base.origin.x, base.origin.y, base.size.width, base.size.height);
}

static void payload_focus_ring_follower(CFTypeRef tx, uint32_t wid, CGRect rect)
{
    payload_focus_stroke_track(tx, wid, rect.origin.x, rect.origin.y,
                               rect.size.width, rect.size.height);
}
