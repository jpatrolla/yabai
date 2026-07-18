// Deathwatch — when the yabai daemon dies, reset the sub-level demotions it
// left behind. Lives payload-side because a daemon-side handler cannot cover
// SIGKILL or crashes. NOTE: the tracked set is maintained from writes only —
// sub-level read-backs are deliberately never issued (unreliable on Tahoe).

#include <sys/event.h>

extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sub_level);

#define DW_MAX 512

static pthread_mutex_t g_dw_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t        g_dw_wids[DW_MAX];
static int             g_dw_count;

static int             g_dw_kq = -1;
static pid_t           g_dw_pid;
static pthread_t       g_dw_thread;

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
        g_dw_wids[idx] = g_dw_wids[--g_dw_count];
    }

    pthread_mutex_unlock(&g_dw_lock);
}

static int deathwatch_reset_sublevels(void)
{
    int cid = SLSMainConnectionID();
    pthread_mutex_lock(&g_dw_lock);
    int n = g_dw_count;
    for (int i = 0; i < n; ++i) {
        SLSSetWindowSubLevel(cid, g_dw_wids[i], 0);
    }
    g_dw_count = 0;
    pthread_mutex_unlock(&g_dw_lock);
    logpf("DEATHWATCH", "reset %d window(s) to sub-level 0", n);
    return n;
}

// Baked in by the Makefile (-DPAYLOAD_BRANCH/-DPAYLOAD_SHA); identifies a stale payload in the log.
#ifndef PAYLOAD_BRANCH
#define PAYLOAD_BRANCH "unknown"
#endif
#ifndef PAYLOAD_SHA
#define PAYLOAD_SHA "nogit"
#endif

static void deathwatch_fire(void)
{
    logpf("DEATHWATCH", "yabai death detected — running teardown");

    payload_focus_ring_destroy_all();

    deathwatch_reset_sublevels();
}

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
            g_dw_pid = 0;
            pthread_mutex_unlock(&g_dw_lock);
        }
    }
    return NULL;
}

// NOTE: must run before the SA accept loop so the first connection can arm the watch.
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
