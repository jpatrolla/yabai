// =========================================================================
// payload_ax.inc.m — AX client driver for the payload (Branch B).
// =========================================================================
// Dock holds Accessibility (TCC) so the payload can drive foreign windows via
// the AX *client* API directly (live-verified). dlsym the client fns once (Dock
// loads HIServices for its own provider-side AX, so RTLD_DEFAULT resolves
// them); cache the app element per pid; re-resolve the window element per call
// (windows come and go). Used by the LB+T3D animator's in-payload AX fires —
// always called off the CA tick thread (AX setFrame is synchronous and can
// block).
// =========================================================================

#include <dlfcn.h>

typedef CFTypeRef AXRef;
static AXRef     (*g_AXCreateApp)(pid_t);
static int       (*g_AXCopyAttr)(AXRef, CFStringRef, CFTypeRef *);
static int       (*g_AXSetAttr)(AXRef, CFStringRef, CFTypeRef);
static CFTypeRef (*g_AXValMake)(uint32_t, const void *);
static bool      (*g_AXValGet)(CFTypeRef, uint32_t, void *);  // AXValueGetValue — read counterpart of AXValueCreate
static int       (*g_AXGetWindow)(AXRef, uint32_t *);
static bool      g_ax_ready;
static const uint32_t kAXValueCGPointType_ = 1;
static const uint32_t kAXValueCGSizeType_  = 2;

static void payload_ax_init(void)
{
    if (g_ax_ready) return;
    g_AXCreateApp = dlsym(RTLD_DEFAULT, "AXUIElementCreateApplication");
    g_AXCopyAttr  = dlsym(RTLD_DEFAULT, "AXUIElementCopyAttributeValue");
    g_AXSetAttr   = dlsym(RTLD_DEFAULT, "AXUIElementSetAttributeValue");
    g_AXValMake   = dlsym(RTLD_DEFAULT, "AXValueCreate");
    g_AXValGet    = dlsym(RTLD_DEFAULT, "AXValueGetValue");
    g_AXGetWindow = dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    g_ax_ready = g_AXCreateApp && g_AXCopyAttr && g_AXSetAttr && g_AXValMake;
}

#define PAYLOAD_AX_CACHE 64
static struct { int32_t pid; AXRef app; } g_ax_apps[PAYLOAD_AX_CACHE];
static pthread_mutex_t g_ax_apps_lock = PTHREAD_MUTEX_INITIALIZER;

static AXRef payload_ax_app(int32_t pid)
{
    AXRef app = NULL;
    pthread_mutex_lock(&g_ax_apps_lock);
    for (int i = 0; i < PAYLOAD_AX_CACHE; i++)
        if (g_ax_apps[i].pid == pid) { app = g_ax_apps[i].app; break; }
    if (!app && g_AXCreateApp) {
        app = g_AXCreateApp((pid_t)pid);
        if (app) for (int i = 0; i < PAYLOAD_AX_CACHE; i++)
            if (g_ax_apps[i].pid == 0) { g_ax_apps[i].pid = pid; g_ax_apps[i].app = app; break; }
    }
    pthread_mutex_unlock(&g_ax_apps_lock);
    return app;
}

// Returns a +1-retained AX window element for wid, or NULL. Caller releases.
static AXRef payload_ax_window(AXRef app, uint32_t wid)
{
    if (!app) return NULL;
    CFArrayRef wins = NULL;
    if (g_AXCopyAttr(app, CFSTR("AXWindows"), (CFTypeRef *)&wins) != 0 || !wins) return NULL;
    AXRef target = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(wins); i++) {
        AXRef w = (AXRef)CFArrayGetValueAtIndex(wins, i);
        uint32_t ww = 0;
        if (g_AXGetWindow && g_AXGetWindow(w, &ww) == 0 && ww == wid) { target = (AXRef)CFRetain(w); break; }
    }
    CFRelease(wins);
    return target;
}

// Set a window's frame via AX (position + size). Returns true when both rc==0.
static bool payload_ax_set_frame(int32_t pid, uint32_t wid, CGRect rect)
{
    payload_ax_init();
    if (!g_ax_ready) return false;
    AXRef win = payload_ax_window(payload_ax_app(pid), wid);
    if (!win) return false;
    CGPoint p = rect.origin;
    CGSize  s = rect.size;
    CFTypeRef axp = g_AXValMake(kAXValueCGPointType_, &p);
    CFTypeRef axs = g_AXValMake(kAXValueCGSizeType_,  &s);
    int rs = axs ? g_AXSetAttr(win, CFSTR("AXSize"),     axs) : -1;
    int rp = axp ? g_AXSetAttr(win, CFSTR("AXPosition"), axp) : -1;
    if (axp) CFRelease(axp);
    if (axs) CFRelease(axs);
    CFRelease(win);
    return rp == 0 && rs == 0;
}

// Resize-only AX commit (AXSize). The origin is held by the top-left-anchored
// resize semantics, so endpin's seated end origin stays put. For
// ENDPIN_RESIZE_ONLY mid fires — one AX IPC instead of two.
static bool payload_ax_set_size(int32_t pid, uint32_t wid, float w, float h)
{
    payload_ax_init();
    if (!g_ax_ready) return false;
    AXRef win = payload_ax_window(payload_ax_app(pid), wid);
    if (!win) return false;
    CGSize s = CGSizeMake(w, h);
    CFTypeRef axs = g_AXValMake(kAXValueCGSizeType_, &s);
    int rs = axs ? g_AXSetAttr(win, CFSTR("AXSize"), axs) : -1;
    if (axs) CFRelease(axs);
    CFRelease(win);
    return rs == 0;
}

// Position-only AX commit (kAXPosition). The mover half of the MOVE-FIRST
// recipe (anim.inc.m endpin / jello warp rows): get the origin to the end
// FIRST so the subsequent kAXSize resize lands at the on-screen origin and
// AppKit's constrainFrameRect can't clamp it. payload_ax_set_frame CANNOT be
// the mover — it sets AXSize BEFORE AXPosition, so a combined setFrame
// resizes at the OLD origin (the clamp). One AX IPC, position only.
static bool payload_ax_set_position(int32_t pid, uint32_t wid, float x, float y)
{
    payload_ax_init();
    if (!g_ax_ready) return false;
    AXRef win = payload_ax_window(payload_ax_app(pid), wid);
    if (!win) return false;
    CGPoint p = CGPointMake(x, y);
    CFTypeRef axp = g_AXValMake(kAXValueCGPointType_, &p);
    int rp = axp ? g_AXSetAttr(win, CFSTR("AXPosition"), axp) : -1;
    if (axp) CFRelease(axp);
    CFRelease(win);
    return rp == 0;
}

// READ a window's frame via AX (kAXPosition + kAXSize). The read counterpart of
// payload_ax_set_frame — lets a caller compare what AX reports against the SLS
// getters (stale AX tree vs real constraint-clamp). Both AXCopyAttributeValue
// calls are synchronous cross-process IPC into the owning app — so this must
// NEVER run under g_anim_lock (AC-4). Returns true when both reads + both
// AXValueGetValue extracts succeed; writes the frame to *out. Gated separately
// on g_AXValGet, which payload_ax_init resolves but g_ax_ready does not require.
static bool payload_ax_get_frame(int32_t pid, uint32_t wid, CGRect *out)
{
    payload_ax_init();
    if (!g_ax_ready || !g_AXValGet) return false;
    AXRef win = payload_ax_window(payload_ax_app(pid), wid);
    if (!win) return false;
    CFTypeRef axp = NULL, axs = NULL;
    CGPoint p = {0}; CGSize s = {0};
    bool ok = false;
    if (g_AXCopyAttr(win, CFSTR("AXPosition"), &axp) == 0 && axp &&
        g_AXCopyAttr(win, CFSTR("AXSize"),     &axs) == 0 && axs &&
        g_AXValGet(axp, kAXValueCGPointType_, &p) &&
        g_AXValGet(axs, kAXValueCGSizeType_,  &s)) {
        out->origin = p; out->size = s; ok = true;
    }
    if (axp) CFRelease(axp);
    if (axs) CFRelease(axs);
    CFRelease(win);
    return ok;
}

// Wake a Chromium/Electron app's lazy accessibility tree. Chromium-based apps
// only BUILD their AX tree once an assistive client signals intent — until then
// AXWindows is empty and every AXPosition/AXSize read+write silently no-ops.
// Chromium watches two attributes for that signal: AXEnhancedUserInterface —
// which ALSO makes AppKit animate every NSWindow resize (the jank the
// animator's EUI-off dance exists to suppress) — and the Chromium-specific
// AXManualAccessibility, which enables the a11y engine with NO AppKit
// side-effect. So we set the latter, not EUI. Non-Chromium apps return
// kAXErrorAttributeUnsupported → harmless no-op. The build is async, so a
// stone-cold app may still miss the first frame or two; the animation's later
// frames + the terminal end fire then land. Caller gates this on the daemon's
// `config window_animation_ax_wake` (SA_T3D_FLAG_AX_WAKE). NOTE: a window on an
// INACTIVE/hidden space has an empty AXWindows regardless (normal AX scoping,
// affects native apps too) — this only helps the genuine lazy-Chromium case,
// and that case remains unverified live.
static void payload_ax_enable_manual_a11y(int32_t pid)
{
    payload_ax_init();
    if (!g_ax_ready) return;
    AXRef app = payload_ax_app(pid);
    if (app && g_AXSetAttr)
        g_AXSetAttr(app, CFSTR("AXManualAccessibility"), (CFTypeRef)kCFBooleanTrue);
}

// EUI off during the animation → the app commits atomic (non-reflowing) resizes;
// LB+T3D do the visual smoothing. Restore at finalize.
static void payload_ax_set_eui(int32_t pid, bool on)
{
    payload_ax_init();
    if (!g_ax_ready) return;
    AXRef app = payload_ax_app(pid);
    if (app) g_AXSetAttr(app, CFSTR("AXEnhancedUserInterface"),
                         on ? (CFTypeRef)kCFBooleanTrue : (CFTypeRef)kCFBooleanFalse);
}

// Read the app-level AXEnhancedUserInterface. Returns true if the attribute is
// present (writing its bool value to *out_on); false if unsupported/unreadable.
// Used at hold time to capture the app's PRIOR EUI so release restores it
// instead of forcing true — Chrome's baseline is false, and restore-to-true
// would leave it permanently EUI-on (AppKit-animated resizes).
static bool payload_ax_get_eui(int32_t pid, bool *out_on)
{
    payload_ax_init();
    if (!g_ax_ready) return false;
    AXRef app = payload_ax_app(pid);
    if (!app) return false;
    CFTypeRef v = NULL;
    if (g_AXCopyAttr(app, CFSTR("AXEnhancedUserInterface"), &v) != 0 || !v) return false;
    bool present = (CFGetTypeID(v) == CFBooleanGetTypeID());
    if (present && out_on) *out_on = CFBooleanGetValue((CFBooleanRef)v);
    CFRelease(v);
    return present;
}
