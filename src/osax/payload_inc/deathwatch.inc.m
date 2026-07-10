// payload_inc/deathwatch.inc.m
//
// Deathwatch — resets BSP sub-level demotions when the yabai daemon dies.
//
// yabai demotes managed windows to a non-zero sub-level via do_window_layer
// (SLSSetWindowSubLevel). Nothing un-demotes them when the daemon quits or
// crashes, so they stay stranded below their peers. A daemon-side handler
// cannot cover SIGKILL or crashes (SLS calls are not async-signal-safe), so
// detection lives here in the payload (inside Dock), which sees the death
// externally and uniformly regardless of signal.
//
// Mechanism:
//   - do_window_layer calls deathwatch_record(wid, sublevel) on every layer
//     change, maintaining the EXACT set of wids currently at a non-zero
//     sub-level. No sub-level READ is ever needed — this sidesteps the Tahoe
//     SLSGetWindowSubLevel fragility (the daemon needs a raw-mach-message
//     workaround for reads; the payload never reads).
//   - The SA accept loop reads the daemon pid (LOCAL_PEERPID) and arms a
//     kqueue EVFILT_PROC/NOTE_EXIT watch.
//   - A dedicated watcher thread fires on process exit (TERM, KILL, crash)
//     and resets the recorded set to sub-level 0.

#include <sys/event.h>

extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sub_level);

#define DW_MAX 512

static pthread_mutex_t g_dw_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t        g_dw_wids[DW_MAX];
static int             g_dw_count;

static int             g_dw_kq = -1;       // kqueue fd
static pid_t           g_dw_pid;           // currently-armed daemon pid (0 = none)
static pthread_t       g_dw_thread;        // watcher thread

// --- tracked set -----------------------------------------------------------
// Add wid when it lands at a non-zero sub-level; drop it when reset to 0.
static void deathwatch_record(uint32_t wid, int sublevel)
{
    if (!wid) return;
    pthread_mutex_lock(&g_dw_lock);

    int idx = -1;
    for (int i = 0; i < g_dw_count; ++i) {
        if (g_dw_wids[i] == wid) { idx = i; break; }
    }

    if (sublevel != 0) {
        if (idx == -1 && g_dw_count < DW_MAX) g_dw_wids[g_dw_count++] = wid;
    } else if (idx != -1) {
        g_dw_wids[idx] = g_dw_wids[--g_dw_count];   // swap-remove
    }

    pthread_mutex_unlock(&g_dw_lock);
}

// --- death action ----------------------------------------------------------
// Returns the number of windows reset — the tracked set is exactly the wids
// yabai demoted to a non-zero sub-level (BSP LAYER_BELOW = -20), so this count
// is "how many stranded windows the death restored".
static int deathwatch_reset_sublevels(void)
{
    int cid = SLSMainConnectionID();
    pthread_mutex_lock(&g_dw_lock);
    int n = g_dw_count;
    for (int i = 0; i < n; ++i) {
        SLSSetWindowSubLevel(cid, g_dw_wids[i], 0);
    }
    g_dw_count = 0;                          // idempotent: clears the set
    pthread_mutex_unlock(&g_dw_lock);
    logpf("DEATHWATCH", "reset %d window(s) to sub-level 0", n);
    return n;
}

// Git branch + short SHA of the tree this payload was built from, baked in by
// the Makefile (-DPAYLOAD_BRANCH / -DPAYLOAD_SHA); surfaces in the dev log so a
// stale or foreign payload is identifiable. Empty inject -> "unknown"/"nogit".
#ifndef PAYLOAD_BRANCH
#define PAYLOAD_BRANCH "unknown"
#endif
#ifndef PAYLOAD_SHA
#define PAYLOAD_SHA "nogit"
#endif

static void deathwatch_fire(void)
{
    logpf("DEATHWATCH", "yabai death detected — running teardown");
    deathwatch_reset_sublevels();
}

// --- detector --------------------------------------------------------------
// Re-arm the kqueue watch when the observed daemon pid changes. g_dw_pid only
// advances on a SUCCESSFUL arm, so an early call before deathwatch_init (kq
// == -1) is a clean no-op that still re-arms once the kq exists.
static void deathwatch_arm(pid_t pid)
{
    if (pid <= 0 || g_dw_kq == -1) return;

    pthread_mutex_lock(&g_dw_lock);
    if (pid == g_dw_pid) { pthread_mutex_unlock(&g_dw_lock); return; }

    struct kevent ev;
    EV_SET(&ev, pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(g_dw_kq, &ev, 1, NULL, 0, NULL) == -1) {
        logpf("DEATHWATCH", "arm failed for pid %d (errno %d)", pid, errno);
    } else {
        g_dw_pid = pid;
        logpf("DEATHWATCH", "armed NOTE_EXIT watch on yabai pid %d", pid);
    }
    pthread_mutex_unlock(&g_dw_lock);
}

// Read the daemon pid off an accepted SA connection and (re)arm. The SA socket
// is chmod 0600 on a fixed path and only the daemon's scripting-addition layer
// connects to it, so LOCAL_PEERPID here is the yabai daemon.
static void deathwatch_observe_peer(int sockfd)
{
    pid_t peer = 0;
    socklen_t len = sizeof(peer);
    if (getsockopt(sockfd, SOL_LOCAL, LOCAL_PEERPID, &peer, &len) == 0) {
        deathwatch_arm(peer);
    }
}

static void *deathwatch_thread_proc(void *unused)
{
    for (;;) {
        struct kevent out;
        int n = kevent(g_dw_kq, NULL, 0, &out, 1, NULL);
        if (n <= 0) continue;
        if (out.filter == EVFILT_PROC && (out.fflags & NOTE_EXIT)) {
            deathwatch_fire();
            pthread_mutex_lock(&g_dw_lock);
            g_dw_pid = 0;                    // allow re-arm on next yabai launch
            pthread_mutex_unlock(&g_dw_lock);
        }
    }
    return NULL;
}

// Create the kqueue and spawn the watcher thread. MUST run before the SA
// accept loop starts, so g_dw_kq is set before any deathwatch_arm call.
static void deathwatch_init(void)
{
    g_dw_kq = kqueue();
    if (g_dw_kq == -1) {
        logpf("DEATHWATCH", "kqueue() failed (errno %d) — detector disabled", errno);
        return;
    }
    pthread_create(&g_dw_thread, NULL, &deathwatch_thread_proc, NULL);
    pthread_detach(g_dw_thread);
    logpf("DEATHWATCH", "initialized — waiting for yabai pid");
}
