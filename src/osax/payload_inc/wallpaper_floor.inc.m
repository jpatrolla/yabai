// Persistent per-display wallpaper floor.
//
// One parked space per display holds a captured copy of that display's desktop
// picture, sunk to absolute level -1 so it composites beneath every ordinary
// (level-0) space. There is no per-frame work and no per-switch work: a space
// slide moves the spaces above the floor, and the floor is simply what shows
// through the gap. It rides native space switches for the same reason.
//
// NOTE: the floor outlives a space switch because it is a space member, so the
// only thing that must move it is Mission Control / exposé — which composites
// every space at once and would otherwise reveal it. The hide on entry and the
// show on exit arrive from the daemon over this file's verb, driven by
// mission_control_osl_observe; there is no in-payload log hook.
//
// NOTE: spaces are created with options=1 (no auto-reap), so a floor that is not
// torn down outlives the payload. wp_floor_teardown runs from the verb; the
// daemon's startup clear is what reaps a floor stranded by a daemon restart.

extern CGError  SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
extern CGError  SLSSetWindowTitle(int cid, uint32_t wid, CFStringRef title);
extern void     SLSShowSpaces(int cid, CFArrayRef spaces);
extern void     SLSHideSpaces(int cid, CFArrayRef spaces);
extern CGError  SLSTransactionAddWindowToSpaceAndRemoveFromSpaces(CFTypeRef tx, uint32_t wid,
                                                                  uint64_t sid, uint64_t scope);
extern CGError  SLSTransactionSetSpaceAbsoluteLevel(CFTypeRef tx, uint64_t sid, int level);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
extern int      SLSSpaceGetAbsoluteLevel(int cid, uint64_t sid);
extern CGError  SLSReleaseWindow(int cid, uint32_t wid);

static bool wallpaper_title_matches(int cid, uint32_t wid, CFStringRef want, bool prefix)
{
    extern CGError SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef key, CFTypeRef *out);

    CFTypeRef title = NULL;
    if (SLSCopyWindowProperty(cid, wid, CFSTR("kCGSWindowTitle"), &title) != kCGErrorSuccess) return false;
    if (!title) return false;

    bool match = false;
    if (CFGetTypeID(title) == CFStringGetTypeID()) {
        match = prefix ? CFStringHasPrefix((CFStringRef)title, want)
                       : CFStringCompare((CFStringRef)title, want, 0) == kCFCompareEqualTo;
    }
    CFRelease(title);
    return match;
}

// Resolve a space's desktop-background windows: Dock's per-space picture and any
// WallpaperAgent transition buffers sitting on that space.
//
// NOTE: identity is TITLE + exact level, never lowest-level — the "Offscreen
// Wallpaper Window" buffer sits one level BELOW the picture, so a lowest-level pick
// resolves it and blacks the slide. Its lifetime belongs to WallpaperAgent: absent,
// re-minted, and pinned to no particular space.
//
// SA_WP_OFF_MAX and struct wallpaper_space_set are declared in
// space_animation.inc.m — do NOT redeclare them here.
static void wallpaper_resolve_space(uint64_t sid, struct wallpaper_space_set *out)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner,
                                                       CFArrayRef spaces, uint32_t options,
                                                       uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);

    memset(out, 0, sizeof(*out));

    int cid = SLSMainConnectionID();
    CFNumberRef sid_num = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    if (!sid_num) return;
    CFArrayRef space_list = CFArrayCreate(NULL, (const void **)&sid_num, 1,
                                          &kCFTypeArrayCallBacks);
    CFRelease(sid_num);
    if (!space_list) return;

    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef wids = SLSCopyWindowsWithOptionsAndTags(
        cid, 0, space_list, 0x7, &set_tags, &clear_tags);
    CFRelease(space_list);
    if (!wids) return;

    int picture_level = CGWindowLevelForKey(2) - 1;

    CFIndex count = CFArrayGetCount(wids);
    for (CFIndex i = 0; i < count; ++i) {
        uint32_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(wids, i), kCFNumberSInt32Type, &wid);
        if (!wid) continue;

        int level = 0;
        if (SLSGetWindowLevel(cid, wid, &level) != kCGErrorSuccess) continue;
        if (level > picture_level) continue;

        if (!out->picture && level == picture_level &&
            wallpaper_title_matches(cid, wid, CFSTR("Wallpaper-"), true)) {
            out->picture = wid;
            continue;
        }
        if (out->off_n < SA_WP_OFF_MAX &&
            wallpaper_title_matches(cid, wid, CFSTR("Offscreen Wallpaper Window"), false)) {
            out->offscreen[out->off_n++] = wid;
        }
    }
    CFRelease(wids);

    logpf("SPACE_ANIM", "wallpaper resolve sid=%llu → picture=%u buffers=%d (scanned=%ld)",
          (unsigned long long)sid, out->picture, out->off_n, (long)count);
}

// Stage thumbnails anchor into the picture's ordering group, which enrolls them in
// WindowServer's space-transition manifest; the daemon caches this on
// view->wallpaper_wid.
static uint32_t find_wallpaper_wid_for_space(uint64_t sid)
{
    struct wallpaper_space_set set;
    wallpaper_resolve_space(sid, &set);
    return set.picture;
}

#define WP_PROBE_MAX  16
#define WP_HIDDEN_MAX 64

#define WP_HIDE_DOCK 0x1   // Dock's per-space "Wallpaper-<uuid>" pictures
#define WP_HIDE_WP   0x2   // WallpaperAgent's "Offscreen Wallpaper Window" buffers

// NOTE: minted on Dock's cid, so anything wp_floor_teardown does not release
// outlives yabai and clears only on a Dock restart.
// NOTE: `stolen` is DOCK's own layer, on loan — it must go back to `stolen_super` or
// the user has no wallpaper until Dock restarts. Unreachable as ported: wp_floor_build
// always passes adopt_host = nil, and nothing here restores.
struct wp_host_bind {
    id  ctx;            // retained CAContext bound to the probe window
    id  root;           // retained root layer handed to that context
    id  stolen;         // retained CALayerHost adopted from Dock, or nil
    id  stolen_super;   // retained superlayer to give `stolen` back to
    int bind;
    int bound_back;     // SLSGetWindowLayerContext saw the bind land
};

static uint32_t g_wp_probe_wids[WP_PROBE_MAX];
static int      g_wp_probe_n;

// NOTE: same Dock-lifetime problem, worse symptom — a hidden real wallpaper stays
// hidden with nothing on screen to show for it. Every mint/clear unhides first.
static uint32_t g_wp_hidden_wids[WP_HIDDEN_MAX];
static int      g_wp_hidden_n;

// NOTE: commits synchronously (method 1) because a floor rebuild unblanks here and
// captures the same pictures immediately after — an async commit lets
// SLSHWCaptureWindowList read them at alpha 0 and the floor comes up black.
static int wp_probe_unhide_all(int cid)
{
    int n = g_wp_hidden_n;
    if (!n) return 0;

    CFTypeRef tx = SLSTransactionCreate(cid);
    if (tx) {
        for (int i = 0; i < n; i++) SLSTransactionSetWindowSystemAlpha(tx, g_wp_hidden_wids[i], 1.0f);
        SLSTransactionCommit(tx, 1);
        CFRelease(tx);
    }
    g_wp_hidden_n = 0;
    return n;
}

// NOTE: defined further down in this file. The floor's windows share this sweep's
// level and sit one CFStringHasPrefix casing away from its title test — blanking
// them would black the desktop out.
static bool wp_floor_owns_wid(uint32_t wid);

// Blank every real desktop-background window in the requested families. Identity is
// title + level (the same rule as wallpaper_resolve_space), queried across ALL spaces
// because the offscreen buffers are pinned to none.
static void wp_probe_hide_families(int cid, uint8_t mask, int *out_dock, int *out_wp)
{
    extern CFArrayRef SLSCopyWindowsWithOptionsAndTagsAndSpaceOptions(
        int cid, uint32_t owner, uint32_t space_options, uint32_t options,
        uint64_t *set_tags, uint64_t *clear_tags);
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);

    *out_dock = 0;
    *out_wp   = 0;
    if (!mask) return;

    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef all = SLSCopyWindowsWithOptionsAndTagsAndSpaceOptions(cid, 0, 0x7, 0x7,
                                                                     &set_tags, &clear_tags);
    if (!all) return;

    CFTypeRef tx = SLSTransactionCreate(cid);
    int picture_level = CGWindowLevelForKey(2) - 1;

    CFIndex count = CFArrayGetCount(all);
    for (CFIndex i = 0; i < count && g_wp_hidden_n < WP_HIDDEN_MAX; ++i) {
        uint32_t wid = 0;
        CFNumberGetValue(CFArrayGetValueAtIndex(all, i), kCFNumberSInt32Type, &wid);
        if (!wid) continue;

        // NOTE: the floor re-sweeps on every space creation, so already-blanked wids
        // must be skipped — re-recording them fills g_wp_hidden_wids with duplicates
        // until the cap silently drops the new pictures the sweep exists to catch.
        bool mine = wp_floor_owns_wid(wid);
        for (int p = 0; p < g_wp_probe_n && !mine; p++) {
            if (g_wp_probe_wids[p] == wid) mine = true;
        }
        for (int p = 0; p < g_wp_hidden_n && !mine; p++) {
            if (g_wp_hidden_wids[p] == wid) mine = true;
        }
        if (mine) continue;

        bool is_dock = false, is_off = false;
        int  level   = 0;
        if ((mask & WP_HIDE_DOCK) &&
            SLSGetWindowLevel(cid, wid, &level) == kCGErrorSuccess && level == picture_level) {
            is_dock = wallpaper_title_matches(cid, wid, CFSTR("Wallpaper-"), true);
        }
        if (!is_dock && (mask & WP_HIDE_WP)) {
            is_off = wallpaper_title_matches(cid, wid, CFSTR("Offscreen Wallpaper Window"), false);
        }
        if (!is_dock && !is_off) continue;

        if (tx) SLSTransactionSetWindowSystemAlpha(tx, wid, 0.0f);
        g_wp_hidden_wids[g_wp_hidden_n++] = wid;
        if (is_dock) ++*out_dock; else ++*out_wp;
    }

    if (tx) {
        SLSTransactionCommit(tx, 0);
        CFRelease(tx);
    }
    CFRelease(all);
}

// NOTE: 0x19944 is Dock's own flag word at its single CGSHWCaptureWindowList call
// site (DockCore.DesktopWallpaperWindow); bit 16 skips the Screen-Recording preflight,
// which only holds because this runs inside Dock.
static CGImageRef wp_probe_capture(int cid, uint32_t wid)
{
    extern CFArrayRef SLSHWCaptureWindowList(int cid, const uint32_t *wids,
                                             uint32_t count, uint32_t options);

    if (!wid) return NULL;
    CFArrayRef imgs = SLSHWCaptureWindowList(cid, &wid, 1, 0x19944);
    if (!imgs) return NULL;
    CGImageRef image = CFArrayGetCount(imgs)
        ? (CGImageRef) CFRetain(CFArrayGetValueAtIndex(imgs, 0))
        : NULL;
    CFRelease(imgs);
    return image;
}

// Mint one display-sized stand-in at `level`. `proxy` picks stock yabai's
// window-animation proxy recipe (window_manager_create_window_proxy) over the plain
// SLSNewWindow one. Returns 0 on failure.
//
// NOTE: the two create calls disagree about where position lives —
// SLSNewWindow takes a SHAPE region at (0,0) plus x/y args, whereas
// SLSNewWindowWithOpaqueShapeAndContext takes the placed frame as the region and
// x/y of 0. Encoding the origin in both double-positions the window.
static uint32_t wp_probe_mint(int cid, CGRect r, bool proxy, int level,
                              uint32_t host_ctx, id adopt_host, CGImageRef shot,
                              struct wp_host_bind *hb)
{
    extern int          SLSNewWindow(int cid, int type, float x, float y,
                                     CFTypeRef region, uint32_t *wid);
    extern CGError      SLSSetWindowLayerContext(int cid, uint32_t wid, CGContextRef ctx);
    extern CGError      SLSNewWindowWithOpaqueShapeAndContext(int cid, int type, CFTypeRef region,
                                                              CFTypeRef opaque_shape, int options,
                                                              uint64_t *tags, float x, float y,
                                                              int tag_size, uint32_t *wid,
                                                              void *context);
    extern void         SLSSetWindowOpacity(int cid, uint32_t wid, bool isOpaque);
    extern CGError      SLSSetWindowResolution(int cid, uint32_t wid, double res);
    extern CGError      SLSSetWindowTitle(int cid, uint32_t wid, CFStringRef title);
    extern void         SLSWindowSetShadowProperties(uint32_t wid, CFDictionaryRef props);
    extern CGContextRef SLWindowContextCreate(int cid, uint32_t wid, int options);

    uint32_t wid = 0;

    if (host_ctx || adopt_host) {
        CGRect frame = CGRectMake(0.0, 0.0, r.size.width, r.size.height);

        Class CAContextCls   = NSClassFromString(@"CAContext");
        Class CALayerCls     = NSClassFromString(@"CALayer");
        Class CALayerHostCls = NSClassFromString(@"CALayerHost");
        id    ctx            = (CAContextCls && CALayerCls)
            ? ((id (*)(id, SEL, id)) objc_msgSend)(CAContextCls,
                                                   @selector(remoteContextWithOptions:), @{})
            : nil;
        if (!ctx) return 0;
        ((void (*)(id, SEL)) objc_msgSend)(ctx, @selector(retain));

        id root = ((id (*)(id, SEL)) objc_msgSend)(CALayerCls, @selector(layer));
        ((void (*)(id, SEL)) objc_msgSend)(root, @selector(retain));
        ((void (*)(id, SEL, CGRect)) objc_msgSend)(root, @selector(setFrame:), frame);

        // NOTE: canary. The hosted layer draws over this if it renders at all, so a
        // window that comes up orange proves the bind works and the CONTENT is empty —
        // black means the window/context never presented and says nothing about hosting.
        CGColorRef canary = CGColorCreateGenericRGB(1.0, 0.45, 0.0, 1.0);
        ((void (*)(id, SEL, CGColorRef)) objc_msgSend)(root, @selector(setBackgroundColor:), canary);
        CGColorRelease(canary);

        if (adopt_host) {
            id sup = ((id (*)(id, SEL)) objc_msgSend)(adopt_host, @selector(superlayer));
            ((void (*)(id, SEL)) objc_msgSend)(adopt_host, @selector(retain));
            if (sup) ((void (*)(id, SEL)) objc_msgSend)(sup, @selector(retain));

            ((void (*)(id, SEL)) objc_msgSend)(adopt_host, @selector(removeFromSuperlayer));
            ((void (*)(id, SEL, CGRect)) objc_msgSend)(adopt_host, @selector(setFrame:), frame);
            ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), adopt_host);

            hb->stolen       = adopt_host;
            hb->stolen_super = sup;
        } else if (CALayerHostCls) {
            id host = ((id (*)(id, SEL)) objc_msgSend)(
                ((id (*)(id, SEL)) objc_msgSend)(CALayerHostCls, @selector(alloc)), @selector(init));
            if (host) {
                ((void (*)(id, SEL, uint32_t)) objc_msgSend)(host, @selector(setContextId:), host_ctx);
                ((void (*)(id, SEL, BOOL)) objc_msgSend)(host, @selector(setResizesHostedContext:), YES);
                ((void (*)(id, SEL, CGRect)) objc_msgSend)(host, @selector(setFrame:), frame);
                ((void (*)(id, SEL, id)) objc_msgSend)(root, @selector(addSublayer:), host);
                ((void (*)(id, SEL)) objc_msgSend)(host, @selector(release));
            }
        }

        ((void (*)(id, SEL, id)) objc_msgSend)(ctx, @selector(setLayer:), root);

        // NOTE: payload_focus_surface_create's recipe — region is SHAPE at (0,0), screen
        // position goes in the x/y args, CAContext bound after. SLSGetWindowLayerContext
        // reads back NULL for a remote context that renders fine, so it is not an oracle.
        extern CGContextRef SLSGetWindowLayerContext(int cid, uint32_t wid);

        CGRect shape = CGRectMake(0.0, 0.0, r.size.width, r.size.height);
        CGSRegionRef region = NULL;
        if (CGSNewRegionWithRect(&shape, &region) != kCGErrorSuccess || !region) {
            ((void (*)(id, SEL)) objc_msgSend)(root, @selector(release));
            ((void (*)(id, SEL)) objc_msgSend)(ctx, @selector(release));
            return 0;
        }
        int rc = SLSNewWindow(cid, 5, r.origin.x, r.origin.y, region, &wid);
        CFRelease(region);
        if (rc != 0 || !wid) {
            ((void (*)(id, SEL)) objc_msgSend)(root, @selector(release));
            ((void (*)(id, SEL)) objc_msgSend)(ctx, @selector(release));
            return 0;
        }

        SLSSetWindowOpacity(cid, wid, 0);
        hb->bind = SLSSetWindowLayerContext(cid, wid, (CGContextRef)ctx);

        Class CATx = NSClassFromString(@"CATransaction");
        if (CATx) ((void (*)(id, SEL)) objc_msgSend)(CATx, @selector(flush));

        hb->bound_back = SLSGetWindowLayerContext(cid, wid) != NULL;
        SLSSetWindowSubLevel(cid, wid, -1);
        hb->ctx  = ctx;
        hb->root = root;
    } else if (proxy) {
        CGSRegionRef frame_region = NULL, empty_region = NULL;
        if (CGSNewRegionWithRect(&r, &frame_region) != kCGErrorSuccess || !frame_region) return 0;
        CGSNewEmptyRegion(&empty_region);

        uint64_t tags = 1ULL << 46;
        SLSNewWindowWithOpaqueShapeAndContext(cid, 2, frame_region, empty_region,
                                              13 | (1 << 18), &tags, 0, 0, 64, &wid, NULL);
        CFRelease(frame_region);
        if (empty_region) CFRelease(empty_region);
        if (!wid) return 0;

        CFIndex density = 0;
        CFNumberRef density_cf = CFNumberCreate(NULL, kCFNumberCFIndexType, &density);
        CFDictionaryRef shadow_props = CFDictionaryCreate(NULL,
            (const void *[]){CFSTR("com.apple.WindowShadowDensity")},
            (const void *[]){density_cf}, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        SLSWindowSetShadowProperties(wid, shadow_props);
        CFRelease(density_cf);
        CFRelease(shadow_props);

        SLSSetWindowOpacity(cid, wid, 0);
        SLSSetWindowAlpha(cid, wid, 1.0f);
        SLSSetWindowSubLevel(cid, wid, 0);
    } else {
        CGRect shape = CGRectMake(0.0, 0.0, r.size.width, r.size.height);
        CGSRegionRef region = NULL;
        if (CGSNewRegionWithRect(&shape, &region) != kCGErrorSuccess || !region) return 0;
        int rc = SLSNewWindow(cid, kCGBackingStoreBuffered,
                              r.origin.x, r.origin.y, region, &wid);
        CFRelease(region);
        if (rc != 0 || !wid) return 0;

        SLSSetWindowOpacity(cid, wid, 1);
    }

    SLSSetWindowResolution(cid, wid, 2.0);
    SLSSetWindowTitle(cid, wid, CFSTR("wallpaper-test"));
    SLSSetWindowLevel(cid, wid, level);

    // NOTE: a layer-context bind owns the window's surface — opening a CGContext on
    // top of it fights the CAContext for the same backing and blanks the hosted layer.
    if (host_ctx || adopt_host) return wid;

    CGContextRef ctx = SLWindowContextCreate(cid, wid, 0);
    if (ctx) {
        CGRect fill = CGRectMake(0.0, 0.0, r.size.width, r.size.height);
        if (shot) {
            CGContextDrawImage(ctx, fill, shot);
        } else {
            if (proxy) CGContextSetRGBFillColor(ctx, 0.72, 0.00, 0.55, 1.0);
            else       CGContextSetRGBFillColor(ctx, 0.00, 0.60, 0.60, 1.0);
            CGContextFillRect(ctx, fill);
        }
        CGContextFlush(ctx);
        CGContextRelease(ctx);
    }

    return wid;
}

#define WP_FLOOR_MAX 8

struct wp_floor_slot {
    uint64_t sid;              // parked space
    uint32_t wid;              // captured picture window living on it
    uint32_t did;
    CGRect   frame;
};

static struct wp_floor_slot g_wp_floor[WP_FLOOR_MAX];
static int                  g_wp_floor_n        = 0;
static bool                 g_wp_floor_hidden   = false;
static bool                 g_wp_floor_hid_dock = false;
static dispatch_queue_t     g_wp_floor_queue    = NULL;

// The floor sits one step below the ordinary level-0 spaces. Deeper works too, but
// -1 is the shallowest that was measured to sink below a live desktop picture.
#define WP_FLOOR_LEVEL (-1)

static bool wp_floor_is_active(void)
{
    return g_wp_floor_n > 0 && g_wp_floor_hid_dock && !g_wp_floor_hidden;
}

// One line of live floor state for the slide trace — the three fields that decide
// wp_floor_is_active(), plus each slot's wid/sid so a stranded floor is visible.
static void wp_floor_debug(char *buf, size_t cap)
{
    int cid = SLSMainConnectionID();
    int off = snprintf(buf, cap, "n=%d hid_dock=%d hidden=%d active=%d",
                       g_wp_floor_n, (int)g_wp_floor_hid_dock, (int)g_wp_floor_hidden,
                       (int)wp_floor_is_active());
    for (int i = 0; i < g_wp_floor_n && off < (int)cap; i++) {
        uint8_t ordered = 0;
        SLSWindowIsOrderedIn(cid, g_wp_floor[i].wid, &ordered);
        off += snprintf(buf + off, cap - off, " [%d wid=%u sid=%llu in=%u lvl=%d]",
                        i, g_wp_floor[i].wid, (unsigned long long)g_wp_floor[i].sid,
                        ordered, SLSSpaceGetAbsoluteLevel(cid, g_wp_floor[i].sid));
    }
}

static bool wp_floor_owns_wid(uint32_t wid)
{
    for (int i = 0; i < g_wp_floor_n; i++) if (g_wp_floor[i].wid == wid) return true;
    return false;
}

static CFArrayRef wp_floor_sid_array(void)
{
    if (!g_wp_floor_n) return NULL;
    uint64_t sids[WP_FLOOR_MAX];
    for (int i = 0; i < g_wp_floor_n; i++) sids[i] = g_wp_floor[i].sid;
    return cfarray_of_cfnumbers(sids, sizeof(uint64_t), g_wp_floor_n, kCFNumberSInt64Type);
}

// NOTE: the floor and Dock's real pictures are exact opposites — whenever one is
// visible the other must not be, or the pictures occlude the floor (normal use) or
// Mission Control renders every thumbnail black (MC). Both moves belong in here.
static void wp_floor_apply_hidden(bool hide)
{
    CFArrayRef sids = wp_floor_sid_array();
    if (!sids) return;

    int cid = SLSMainConnectionID();
    int dock = 0, off = 0;

    if (hide) {
        SLSHideSpaces(cid, sids);
        if (g_wp_floor_hid_dock) wp_probe_unhide_all(cid);
    } else {
        SLSShowSpaces(cid, sids);
        if (g_wp_floor_hid_dock) wp_probe_hide_families(cid, WP_HIDE_DOCK | WP_HIDE_WP, &dock, &off);
    }
    CFRelease(sids);

    g_wp_floor_hidden = hide;
    logpf("WP_FLOOR", "%s %d space(s)%s", hide ? "hide" : "show", g_wp_floor_n,
          g_wp_floor_hid_dock ? (hide ? " (dock pictures restored)" : " (dock pictures blanked)") : "");
}

// NOTE: dormant — the daemon-wire hide/show runs synchronously through
// do_wallpaper_floor. Kept for an in-payload caller, which would need this queue
// bounce rather than SLS work on whatever thread it hooks.
static void wp_floor_set_hidden(bool hide)
{
    if (!g_wp_floor_n || g_wp_floor_hidden == hide) return;
    if (!g_wp_floor_queue) {
        g_wp_floor_queue = dispatch_queue_create("com.koekeishiya.yabai.wp-floor", NULL);
    }
    dispatch_async(g_wp_floor_queue, ^{ wp_floor_apply_hidden(hide); });
}

static int wp_floor_teardown(void)
{
    extern CGError SLSReleaseWindow(int cid, uint32_t wid);

    int cid = SLSMainConnectionID();
    int n   = g_wp_floor_n;

    for (int i = 0; i < g_wp_floor_n; i++) {
        if (g_wp_floor[i].wid) SLSReleaseWindow(cid, g_wp_floor[i].wid);
        if (g_wp_floor[i].sid) SLSSpaceDestroy(cid, g_wp_floor[i].sid);
    }

    memset(g_wp_floor, 0, sizeof(g_wp_floor));
    g_wp_floor_n        = 0;
    g_wp_floor_hidden   = false;
    g_wp_floor_hid_dock = false;
    return n;
}

static int wp_floor_build(char *r, size_t rcap, bool hide_dock)
{
    int cid = SLSMainConnectionID();
    int off = 0;

    CGDirectDisplayID dids[WP_FLOOR_MAX];
    uint32_t dn = 0;
    if (CGGetActiveDisplayList(WP_FLOOR_MAX, dids, &dn) != kCGErrorSuccess || dn == 0) {
        return snprintf(r, rcap, "wallpaper_floor: CGGetActiveDisplayList failed\n");
    }

    int picture_level = CGWindowLevelForKey(2) - 1;

    // Pass 1: capture every display's picture while they are all still on screen.
    //
    // NOTE: payload.m declares CGDisplayCreateUUIDFromDisplayID as returning
    // CFStringRef; it returns a CFUUIDRef. The cast is what the string conversion
    // below needs — dropping it does not change the call, only the diagnostic.
    CGImageRef shots[WP_FLOOR_MAX]   = {0};
    uint32_t   real_wps[WP_FLOOR_MAX] = {0};
    uint64_t   curs[WP_FLOOR_MAX]     = {0};
    for (uint32_t i = 0; i < dn && i < WP_FLOOR_MAX; i++) {
        CFUUIDRef   u    = (CFUUIDRef) CGDisplayCreateUUIDFromDisplayID(dids[i]);
        CFStringRef uuid = u ? CFUUIDCreateString(NULL, u) : NULL;
        curs[i]     = uuid ? SLSManagedDisplayGetCurrentSpace(cid, uuid) : 0;
        real_wps[i] = curs[i] ? find_wallpaper_wid_for_space(curs[i]) : 0;
        shots[i]    = wp_probe_capture(cid, real_wps[i]);
        if (uuid) CFRelease(uuid);
        if (u) CFRelease(u);
    }

    // NOTE: blanking Dock's pictures BEFORE minting keeps the floor windows out of
    // wp_probe_hide_families' sweep — it matches on title+level, which the floor
    // shares with the real thing.
    int hid_dock = 0, hid_off = 0;
    if (hide_dock) {
        wp_probe_hide_families(cid, WP_HIDE_DOCK | WP_HIDE_WP, &hid_dock, &hid_off);
        g_wp_floor_hid_dock = true;
    }

    // Pass 2: mint and park.
    for (uint32_t i = 0; i < dn && g_wp_floor_n < WP_FLOOR_MAX; i++) {
        CGRect     frame   = CGDisplayBounds(dids[i]);
        uint64_t   cur     = curs[i];
        uint32_t   real_wp = real_wps[i];
        CGImageRef shot    = shots[i];

        struct wp_host_bind hb = {0};
        uint32_t wid = wp_probe_mint(cid, frame, false, picture_level, 0, nil, shot, &hb);
        if (shot) CGImageRelease(shot);

        if (!wid) {
            off += snprintf(r + off, rcap - off, "did=%u MINT FAILED\n", dids[i]);
            continue;
        }

        CFMutableDictionaryRef values = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int32_t     type     = 3;
        CFNumberRef type_num = CFNumberCreate(NULL, kCFNumberSInt32Type, &type);
        CFDictionarySetValue(values, CFSTR("type"), type_num);
        CFDictionarySetValue(values, CFSTR("uuid"), CFSTR("yabai-wallpaper-floor"));
        uint64_t floor_sid = SLSSpaceCreate(cid, 1, values);
        CFRelease(type_num);
        CFRelease(values);

        if (!floor_sid) {
            SLSReleaseWindow(cid, wid);
            off += snprintf(r + off, rcap - off, "did=%u SLSSpaceCreate FAILED\n", dids[i]);
            continue;
        }

        // op 0x1b moves add-first, so the window is never homeless mid-reparent.
        CFTypeRef txn = SLSTransactionCreate(cid);
        SLSTransactionAddWindowToSpaceAndRemoveFromSpaces(txn, wid, floor_sid, 0x7);
        SLSTransactionSetSpaceAbsoluteLevel(txn, floor_sid, WP_FLOOR_LEVEL);
        SLSTransactionShowSpace(txn, floor_sid);
        SLSTransactionCommit(txn, 1);
        CFRelease(txn);

        // NOTE: SLSNewWindow leaves the window ordered OUT — wp_probe_mint does not
        // do this for you, its callers do. Without it the floor is minted, captured
        // and parked, and never composites.
        SLSOrderWindow(cid, wid, 1, 0);

        // NOTE: must NOT start with "Wallpaper-" — that prefix is how both the
        // blanking sweep and find_wallpaper_wid_for_space identify a REAL Dock
        // picture, so the floor would blank itself and read back as a wallpaper.
        SLSSetWindowTitle(cid, wid, CFSTR("yabai-wallpaper-floor"));

        g_wp_floor[g_wp_floor_n].sid   = floor_sid;
        g_wp_floor[g_wp_floor_n].wid   = wid;
        g_wp_floor[g_wp_floor_n].did   = dids[i];
        g_wp_floor[g_wp_floor_n].frame = frame;
        g_wp_floor_n++;

        off += snprintf(r + off, rcap - off,
            "did=%u frame=(%.0f,%.0f,%.0fx%.0f) src_sid=%llu src_wp=%u shot=%s"
            " -> floor_sid=%llu wid=%u level=%d\n",
            dids[i], frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
            (unsigned long long)cur, real_wp, real_wp ? "yes" : "NONE",
            (unsigned long long)floor_sid, wid,
            SLSSpaceGetAbsoluteLevel(cid, floor_sid));
    }

    if (hide_dock) {
        off += snprintf(r + off, rcap - off,
            "blanked %d Dock picture(s) + %d offscreen buffer(s)\n", hid_dock, hid_off);
    }

    g_wp_floor_hidden = false;
    return off;
}

// Wire: [u8 clear][u8 hide][u8 show][u8 keep_dock][u8 refresh] — must match
// struct wallpaper_floor_req in sa_inc/sa_experimental.inc.m.
static void do_wallpaper_floor(int sockfd, char *message)
{
    struct __attribute__((packed)) { uint8_t clear, hide, show, keep_dock, refresh; } req = {0};
    if (message) memcpy(&req, message, sizeof req);

    char r[2048];
    int  off = 0;
    int  cid = SLSMainConnectionID();

    // Two things go stale as spaces come and go: a space minted after the build has
    // a fresh Dock picture the one-shot sweep never saw, and SLSShowSpaces state does
    // not survive a switch — the floor drops out of the composited set and the desktop
    // goes black. Re-show unconditionally; the g_wp_floor_hidden guard would swallow it.
    if (req.refresh) {
        int dock = 0, offs = 0;
        if (wp_floor_is_active()) {
            wp_probe_hide_families(cid, WP_HIDE_DOCK | WP_HIDE_WP, &dock, &offs);
            CFArrayRef sids = wp_floor_sid_array();
            if (sids) { SLSShowSpaces(cid, sids); CFRelease(sids); }
        }
        off = snprintf(r, sizeof r,
                       "wallpaper_floor: refresh blanked %d picture(s) + %d offscreen, re-showed %d space(s)\n",
                       dock, offs, wp_floor_is_active() ? g_wp_floor_n : 0);
        send(sockfd, r, off, 0);
        return;
    }

    if (req.clear) {
        int n         = wp_floor_teardown();
        int unhidden  = wp_probe_unhide_all(cid);
        off = snprintf(r, sizeof r,
                       "wallpaper_floor: tore down %d slot(s), restored %d picture(s)\n",
                       n, unhidden);
        send(sockfd, r, off, 0);
        return;
    }

    if (req.hide || req.show) {
        if (!g_wp_floor_n) {
            off = snprintf(r, sizeof r, "wallpaper_floor: no floor built\n");
            send(sockfd, r, off, 0);
            return;
        }
        g_wp_floor_hidden = !req.hide;   // force the apply through the guard
        wp_floor_apply_hidden(req.hide != 0);
        off = snprintf(r, sizeof r, "wallpaper_floor: %s %d space(s)\n",
                       req.hide ? "hid" : "showed", g_wp_floor_n);
        send(sockfd, r, off, 0);
        return;
    }

    if (g_wp_floor_n) {
        off += snprintf(r + off, sizeof r - off,
                        "wallpaper_floor: replacing %d existing slot(s)\n",
                        wp_floor_teardown());
        wp_probe_unhide_all(cid);
    }
    g_wp_floor_hid_dock = false;

    off += wp_floor_build(r + off, sizeof r - off, !req.keep_dock);
    off += snprintf(r + off, sizeof r - off,
        "built %d slot(s), hidden=%d dock_blanked=%d\n"
        "NOTE: floor spaces are NOT managed spaces, so they never appear in a\n"
        "      managed-space dump — the floor_sid/level line above is the read-back.\n"
        "NOTE: MC hide+show is driven daemon-side by mission_control_osl_observe (a\n"
        "      `log stream` child on Dock's pid).\n",
        g_wp_floor_n, (int)g_wp_floor_hidden, (int)g_wp_floor_hid_dock);

    send(sockfd, r, off, 0);
}
