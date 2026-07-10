// =========================================================================
// displaylink_ca.inc.m — payload-only CADisplayLink frame pump (SPA-6).
// =========================================================================
// A vsync-wired CADisplayLink built via the SkyLight SPI
//     extern id SLSGetDisplayLink(uint32_t did, id target, SEL sel);
// (the live CALocalDisplay path NSScreen uses internally). Unlike
// CVDisplayLink, a CADisplayLink
// fires its target/selector on whatever runloop it's added to, and that runloop
// must actually spin. We host it on a DEDICATED pthread running CFRunLoopRun()
// — never the SA handler thread (it blocks on recv) and not Dock's main thread
// (keeps our SLS commit + any autoreleased churn off it). This mirrors
// CVDisplayLink's
// own-thread model while gaining commit-deadline alignment for the Dock-local
// SLSTransaction commit.
//
// Multi-client frame pump. The link is built once on the spun thread and kept
// PAUSED when idle; ca_clock_register adds a frame client and ca_clock_resume
// unpauses (cross-thread, via CFRunLoopPerformBlock onto the spun runloop). Each
// VBL the trampoline steps every active client (drag_warp, the LB+T3D animator,
// …) and re-pauses the link only when ALL clients report "settled". The
// autoreleased link is retained (SA handler thread has no pool).
// =========================================================================

#include <pthread.h>
#include <unistd.h>

extern id SLSGetDisplayLink(uint32_t did, id target, SEL sel);
// Per-mode capability flags (exported wrappers; already used daemon-side in
// display.c). Used to gate the CADisplayLink preferredFrameRateRange — variable
// refresh panels (ProMotion / VRR) default conservative unless asked for the top.
extern bool SLSIsDisplayModeProMotion(uint32_t did, int mode_index);
extern bool SLSIsDisplayModeVRR(uint32_t did, int mode_index);

// CAFrameRateRange ABI (3 floats, HFA → passed in s0-s2 via objc_msgSend cast).
typedef struct { float minimum; float maximum; float preferred; } YBFrameRateRange;

#define CA_CLOCK_MAX_CLIENTS  8
#define CA_CLOCK_MAX_DISPLAYS 8

// A frame client: per-VBL step(ctx, tx, did) returns true once it has settled
// (the pump deactivates it). Clients are keyed by ctx so re-registering is
// idempotent.
//
// `tx` is the pump's SHARED per-VBL transaction (one per display per tick): a
// client buffers its alpha/transform setters into it so they commit in the SAME
// frame as every other client on this clock (LB+T3D motion, fade, mirror,
// xfade) — no per-client commit storm, no sub-frame skew. `tx` may be NULL when
// the pump's SLSTransactionCreate failed this tick: a client MUST tolerate that
// (skip its SLS work, advance no state it can't, return without settling so the
// pump retries next VBL). A client that needs its own commit cadence (drag_warp)
// may ignore `tx` and commit internally.
//
// `did` is the clock's display id — the stale-clock guard for GLOBAL-singleton
// clients (fade/mirror/xfade) that can be re-registered on a different display
// mid-animation: such a client returns true (settled) when `did` != its own
// current did, releasing the old clock's slot so it isn't double-ticked by two
// clocks. Per-display clients (LB+T3D, keyed by did via ctx) ignore it.
struct ca_client {
    bool        (*step)(void *, CFTypeRef, uint32_t);
    void         *ctx;
    volatile bool active;
};

struct ca_clock {
    pthread_t        thread;
    CFRunLoopRef     runloop;        // the spun thread's runloop (set on the thread)
    id               link;           // retained CADisplayLink (built on the thread)
    id               target;         // retained trampoline target
    struct ca_client clients[CA_CLOCK_MAX_CLIENTS];
    int              client_count;
    pthread_mutex_t  clients_lock;   // guards clients[] / client_count
    uint32_t         did;            // the display this clock is vsync-wired to
    float            refresh_hz;     // panel rate (for the ProMotion/VRR range)
    volatile bool    in_use;         // slot allocated
    volatile bool    ready;          // link built + runloop captured
    volatile bool    in_tick;        // AC-18: tick in flight (buffered writes not yet committed)
};

// One clock PER DISPLAY: each links to its own display's vblank and ticks at
// that panel's native rate. A single clock keyed to CGMainDisplayID() would
// drive every animation at the main display's refresh — judder when the
// animated window lives on a different-refresh panel.
static struct ca_clock g_ca_clocks[CA_CLOCK_MAX_DISPLAYS];
static pthread_mutex_t  g_ca_clocks_lock = PTHREAD_MUTEX_INITIALIZER;

// Trampoline method (-caTick:). Runs on a clock's spun runloop thread per VBL.
// The link arg identifies WHICH display ticked → find that clock and step only
// its clients. Re-pauses the link when none remain active.
static void ca_clock_objc_tick(id self, SEL _cmd, id link)
{
    (void)self; (void)_cmd;
    struct ca_clock *cc = NULL;
    for (int i = 0; i < CA_CLOCK_MAX_DISPLAYS; ++i)
        if (g_ca_clocks[i].in_use && g_ca_clocks[i].link == link) { cc = &g_ca_clocks[i]; break; }
    if (!cc) return;

    // ONE transaction per VBL, shared by every client on this display's clock, so
    // their setters commit atomically in the same frame (the AC-7 win: fade alpha
    // lands in the same commit as LB+T3D motion). Built here, committed OUTSIDE
    // clients_lock below — SLSTransactionCommit is a mach_msg round-trip to
    // WindowServer and holding the lock across it would stall this clock's
    // register path; same AC-4 rationale as anim's build-under-lock/commit-out.
    // tx may be NULL on create failure; clients tolerate it (see struct comment).
    // in_tick brackets buffer-to-commit: a client's writes gated (anim_owns) at
    // buffer time are not on the server until the commit below, and a terminal
    // restore committed from another thread in that window would be stomped by
    // this tick's stale frame. ca_clock_wait_tick_idle lets those paths order
    // their commits after ours (AC-18).
    __atomic_store_n(&cc->in_tick, true, __ATOMIC_RELEASE);
    CFTypeRef tx = SLSTransactionCreate(SLSMainConnectionID());

    bool any_active = false;
    pthread_mutex_lock(&cc->clients_lock);
    for (int i = 0; i < cc->client_count; ++i) {
        struct ca_client *c = &cc->clients[i];
        if (!c->active) continue;
        bool settled = c->step ? c->step(c->ctx, tx, cc->did) : true;
        if (settled) c->active = false;
        else         any_active = true;
    }
    pthread_mutex_unlock(&cc->clients_lock);

    if (tx) { SLSTransactionCommit(tx, 0); CFRelease(tx); }
    __atomic_store_n(&cc->in_tick, false, __ATOMIC_RELEASE);

    if (!any_active && cc->link) {
        // All clients settled → stop ticking until the next register/resume.
        ((void (*)(id, SEL, BOOL))objc_msgSend)(cc->link, sel_registerName("setPaused:"), YES);
    }
}

static void *ca_clock_thread_main(void *arg)
{
    struct ca_clock *cc = (struct ca_clock *)arg;

    // Threads are spawned serially under g_ca_clocks_lock (the creator waits for
    // ready), so the class is created exactly once — no concurrent registration.
    Class tramp = objc_getClass("YBCAClockTarget");
    if (!tramp) {
        tramp = objc_allocateClassPair(objc_getClass("NSObject"), "YBCAClockTarget", 0);
        class_addMethod(tramp, sel_registerName("caTick:"), (IMP)ca_clock_objc_tick, "v@:@");
        objc_registerClassPair(tramp);
    }
    id (*msgId)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    cc->target = msgId(msgId((id)tramp, sel_registerName("alloc")), sel_registerName("init"));

    id link = SLSGetDisplayLink(cc->did, cc->target, sel_registerName("caTick:"));
    if (link) {
        msgId(link, sel_registerName("retain"));                          // SA thread has no pool
        ((void (*)(id, SEL, BOOL))objc_msgSend)(link, sel_registerName("setPaused:"), YES);
        // ProMotion / VRR panels default to a conservative preferred rate — ask
        // for the panel's top explicitly. Fixed-rate panels auto-track at their
        // native rate, so the per-display link alone already paces them right.
        if (cc->refresh_hz > 1.0f &&
            (SLSIsDisplayModeProMotion(cc->did, 0) || SLSIsDisplayModeVRR(cc->did, 0))) {
            YBFrameRateRange range = { cc->refresh_hz, cc->refresh_hz, cc->refresh_hz };
            ((void (*)(id, SEL, YBFrameRateRange))objc_msgSend)(
                link, sel_registerName("setPreferredFrameRateRange:"), range);
            logpf("PAYLOAD", "ca_clock: display 0x%x ProMotion/VRR → preferredFrameRateRange %.0fHz", cc->did, cc->refresh_hz);
        }
        Class RL = objc_getClass("NSRunLoop");
        id cur = msgId((id)RL, sel_registerName("currentRunLoop"));
        ((void (*)(id, SEL, id, id))objc_msgSend)(link, sel_registerName("addToRunLoop:forMode:"),
                                                  cur, (id)kCFRunLoopDefaultMode);
    } else {
        logpf("PAYLOAD", "ca_clock: SLSGetDisplayLink(0x%x) returned nil — CA clock inert", cc->did);
    }
    cc->link    = link;
    cc->runloop = CFRunLoopGetCurrent();

    // Keepalive source so CFRunLoopRun() never exits even while the link is paused
    // (a paused CADisplayLink may leave the runloop with no input source).
    CFRunLoopSourceContext src_ctx = {0};
    CFRunLoopSourceRef keepalive = CFRunLoopSourceCreate(NULL, 0, &src_ctx);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), keepalive, kCFRunLoopDefaultMode);

    __atomic_store_n(&cc->ready, true, __ATOMIC_RELEASE);
    CFRunLoopRun();   // spins for the life of the payload
    return NULL;
}

// Find (or lazily create) the clock for a display. refresh_hz drives the
// ProMotion/VRR range on first creation. Serialized so each display's thread +
// link are built exactly once. Returns NULL if the registry is full.
static struct ca_clock *ca_clock_for_did(uint32_t did, float refresh_hz)
{
    pthread_mutex_lock(&g_ca_clocks_lock);
    struct ca_clock *cc = NULL;
    for (int i = 0; i < CA_CLOCK_MAX_DISPLAYS; ++i)
        if (g_ca_clocks[i].in_use && g_ca_clocks[i].did == did) { cc = &g_ca_clocks[i]; break; }
    if (!cc) {
        for (int i = 0; i < CA_CLOCK_MAX_DISPLAYS; ++i)
            if (!g_ca_clocks[i].in_use) { cc = &g_ca_clocks[i]; break; }
        if (cc) {
            memset(cc, 0, sizeof(*cc));
            cc->did        = did;
            cc->refresh_hz = refresh_hz;
            cc->in_use     = true;
            pthread_mutex_init(&cc->clients_lock, NULL);
            pthread_create(&cc->thread, NULL, ca_clock_thread_main, cc);
            while (!__atomic_load_n(&cc->ready, __ATOMIC_ACQUIRE)) usleep(200);
        }
    }
    pthread_mutex_unlock(&g_ca_clocks_lock);
    return cc;
}

// Register (or re-activate) a frame client on the clock for `did`, keyed by ctx.
// Re-registering the same ctx updates its step fn and re-activates it (idempotent
// across animation begins). Returns the slot index, or -1 on failure.
static int ca_clock_register(uint32_t did, float refresh_hz, bool (*step)(void *, CFTypeRef, uint32_t), void *ctx)
{
    struct ca_clock *cc = ca_clock_for_did(did, refresh_hz);
    if (!cc) { logpf("PAYLOAD", "ca_clock_register: no clock for did 0x%x (display registry full)", did); return -1; }

    pthread_mutex_lock(&cc->clients_lock);
    int idx = -1;
    for (int i = 0; i < cc->client_count; ++i)
        if (cc->clients[i].ctx == ctx) { idx = i; break; }
    if (idx < 0 && cc->client_count < CA_CLOCK_MAX_CLIENTS) idx = cc->client_count++;
    if (idx >= 0) {
        cc->clients[idx].step   = step;
        cc->clients[idx].ctx    = ctx;
        cc->clients[idx].active = true;
    }
    pthread_mutex_unlock(&cc->clients_lock);

    if (idx < 0) logpf("PAYLOAD", "ca_clock_register: client registry full (%d) — dropped", CA_CLOCK_MAX_CLIENTS);
    return idx;
}

// Unpause the clock for `did` from any thread: enqueue setPaused:NO onto its
// spun runloop. No-op if no clock exists for that display yet.
static void ca_clock_resume(uint32_t did)
{
    struct ca_clock *cc = NULL;
    pthread_mutex_lock(&g_ca_clocks_lock);
    for (int i = 0; i < CA_CLOCK_MAX_DISPLAYS; ++i)
        if (g_ca_clocks[i].in_use && g_ca_clocks[i].did == did) { cc = &g_ca_clocks[i]; break; }
    pthread_mutex_unlock(&g_ca_clocks_lock);
    if (!cc || !cc->runloop || !cc->link) return;
    CFRunLoopPerformBlock(cc->runloop, kCFRunLoopDefaultMode, ^{
        ((void (*)(id, SEL, BOOL))objc_msgSend)(cc->link, sel_registerName("setPaused:"), NO);
    });
    CFRunLoopWakeUp(cc->runloop);
}

// AC-18: wait (bounded) for the clock's in-flight tick to finish COMMITTING its
// shared transaction. anim_owns gates per-frame writes at BUFFER time; a token
// bump can't recall writes already buffered into an uncommitted tick. Terminal
// restore paths (xfade handoff/seed) call this after staling their tokens and
// BEFORE committing/reading, so the stale frame lands first and the restore
// wins — instead of the reverse, which stranded windows at mid-fade alpha.
// Bounded: the SA handler thread must never wedge Dock (a tick is step+commit,
// ~1-3ms; 20ms covers a pathological commit). No clock for `did` → no-op.
static void ca_clock_wait_tick_idle(uint32_t did)
{
    struct ca_clock *cc = NULL;
    pthread_mutex_lock(&g_ca_clocks_lock);
    for (int i = 0; i < CA_CLOCK_MAX_DISPLAYS; ++i)
        if (g_ca_clocks[i].in_use && g_ca_clocks[i].did == did) { cc = &g_ca_clocks[i]; break; }
    pthread_mutex_unlock(&g_ca_clocks_lock);
    if (!cc) return;
    for (int spins = 0; spins < 100; ++spins) {   // 100 * 200µs = 20ms cap
        if (!__atomic_load_n(&cc->in_tick, __ATOMIC_ACQUIRE)) return;
        usleep(200);
    }
    logpf("PAYLOAD", "ca_clock_wait_tick_idle: did 0x%x still mid-tick after 20ms — proceeding", did);
}
