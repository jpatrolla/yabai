// AX client driver — Dock's Accessibility grant lets the payload drive foreign
// windows via the AX client API (dlsym'd at first use). NOTE: AX calls are
// synchronous cross-process IPC — never on the CA tick thread or under the animator lock.

#include <dlfcn.h>

typedef CFTypeRef AXRef;
static AXRef     (*g_AXCreateApp)(pid_t);
static int       (*g_AXCopyAttr)(AXRef, CFStringRef, CFTypeRef *);
static int       (*g_AXSetAttr)(AXRef, CFStringRef, CFTypeRef);
static CFTypeRef (*g_AXValMake)(uint32_t, const void *);
static bool      (*g_AXValGet)(CFTypeRef, uint32_t, void *);
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

// NOTE: mover half of the move-first recipe — position must land before the
// resize, or AppKit's edge-resize clamp cuts the frame at the OLD origin
// (a combined AX setFrame does exactly that: it sets AXSize first).
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

// NOTE: wakes Chromium's lazy AX tree. Deliberately AXManualAccessibility,
// not AXEnhancedUserInterface — EUI also makes AppKit animate every resize.
// Non-Chromium apps return attribute-unsupported (harmless).
static void payload_ax_enable_manual_a11y(int32_t pid)
{
    payload_ax_init();
    if (!g_ax_ready) return;
    AXRef app = payload_ax_app(pid);
    if (app && g_AXSetAttr)
        g_AXSetAttr(app, CFSTR("AXManualAccessibility"), (CFTypeRef)kCFBooleanTrue);
}

static void payload_ax_set_eui(int32_t pid, bool on)
{
    payload_ax_init();
    if (!g_ax_ready) return;
    AXRef app = payload_ax_app(pid);
    if (app) g_AXSetAttr(app, CFSTR("AXEnhancedUserInterface"),
                         on ? (CFTypeRef)kCFBooleanTrue : (CFTypeRef)kCFBooleanFalse);
}

// NOTE: reports presence + value so release restores the app's PRIOR EUI —
// forcing true would leave EUI-off-baseline apps (Chrome) permanently animated.
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
