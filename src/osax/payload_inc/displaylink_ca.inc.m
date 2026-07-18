// displaylink_ca.inc.m — per-display CADisplayLink frame pump (SLSGetDisplayLink SPI).
// NOTE: a CADisplayLink fires on the runloop it's added to, and that runloop must spin —
// hosted on a dedicated pthread, never the SA handler thread (blocks on recv) or Dock main.
// Link is autoreleased: retain it (the SA thread has no pool). Idle clocks stay paused.

#include <pthread.h>
#include <unistd.h>

extern id SLSGetDisplayLink(uint32_t did, id target, SEL sel);
extern bool SLSIsDisplayModeProMotion(uint32_t did, int mode_index);
extern bool SLSIsDisplayModeVRR(uint32_t did, int mode_index);

// CAFrameRateRange ABI (3 floats, HFA → passed in s0-s2 via objc_msgSend cast).
typedef struct { float minimum; float maximum; float preferred; } YBFrameRateRange;

#define CA_CLOCK_MAX_CLIENTS  8
#define CA_CLOCK_MAX_DISPLAYS 8

// Frame client contract: step(ctx, tx, did) -> true when settled (pump deactivates it);
// keyed by ctx, re-register is idempotent. `tx` = the SHARED per-VBL transaction (all
// clients commit in the same frame); it MAY BE NULL on create failure — skip SLS work,
// return unsettled so the pump retries. A client owning its own cadence may ignore tx.
// `did` = this clock's display: a GLOBAL-singleton client re-registered onto another
// display must return settled when did != its own, or two clocks double-tick it.
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

// one clock per display — a single main-display clock judders panels at other refresh rates
static struct ca_clock g_ca_clocks[CA_CLOCK_MAX_DISPLAYS];
static pthread_mutex_t  g_ca_clocks_lock = PTHREAD_MUTEX_INITIALIZER;

static void ca_clock_objc_tick(id self, SEL _cmd, id link)
{
    (void)self; (void)_cmd;
    struct ca_clock *cc = NULL;
    for (int i = 0; i < CA_CLOCK_MAX_DISPLAYS; ++i)
        if (g_ca_clocks[i].in_use && g_ca_clocks[i].link == link) { cc = &g_ca_clocks[i]; break; }
    if (!cc) return;

    // NOTE: shared tx built here, committed OUTSIDE clients_lock — the commit is a mach_msg
    // round-trip and would stall the register path. in_tick brackets buffer->commit for
    // ca_clock_wait_tick_idle's ordering guarantee.
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
        ((void (*)(id, SEL, BOOL))objc_msgSend)(cc->link, sel_registerName("setPaused:"), YES);
    }
}

static void *ca_clock_thread_main(void *arg)
{
    struct ca_clock *cc = (struct ca_clock *)arg;

    // spawned serially under g_ca_clocks_lock -> the class pair is created exactly once
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
        // ProMotion/VRR panels default conservative — ask for the panel's top rate explicitly
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

    // keepalive source: a paused CADisplayLink can leave the runloop sourceless -> CFRunLoopRun exits
    CFRunLoopSourceContext src_ctx = {0};
    CFRunLoopSourceRef keepalive = CFRunLoopSourceCreate(NULL, 0, &src_ctx);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), keepalive, kCFRunLoopDefaultMode);

    __atomic_store_n(&cc->ready, true, __ATOMIC_RELEASE);
    CFRunLoopRun();   // spins for the life of the payload
    return NULL;
}

// serialized: each display's thread + link built exactly once; NULL when the registry is full
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

// keyed by ctx — re-registering updates step and re-activates (idempotent across begins)
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

// callable from any thread — hops to the spun runloop; no-op without a clock
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

// NOTE: bounded wait for the in-flight tick's COMMIT. Token bumps can't recall writes
// already buffered into an uncommitted tick — terminal-restore paths call this after
// staling tokens and BEFORE committing, so the stale frame lands first. Bounded: the SA
// handler thread must never wedge Dock.
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
