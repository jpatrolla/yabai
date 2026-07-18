extern struct event_loop g_event_loop;
extern enum mission_control_mode g_mission_control_mode;
extern volatile uint64_t __last_cmd_tab_time;
extern int g_connection;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static CONNECTION_CALLBACK(connection_handler)
{
    if (type == 1204) {
        event_loop_post(&g_event_loop, MISSION_CONTROL_ENTER, NULL, 0);
    } else if (type == 1327) {
        uint64_t sid; memcpy(&sid, data, sizeof(uint64_t));
        event_loop_post(&g_event_loop, SLS_SPACE_CREATED, (void *) (intptr_t) sid , 0);
    } else if (type == 1328) {
        uint64_t sid; memcpy(&sid, data, sizeof(uint64_t));
        event_loop_post(&g_event_loop, SLS_SPACE_DESTROYED, (void *) (intptr_t) sid, 0);
    } else if (type == 808) {
        uint32_t wid; memcpy(&wid, data, sizeof(uint32_t));
        event_loop_post(&g_event_loop, SLS_WINDOW_ORDERED, (void *) (intptr_t) wid, 0);
    } else if (type == 804) {
        uint32_t wid; memcpy(&wid, data, sizeof(uint32_t));
        event_loop_post(&g_event_loop, SLS_WINDOW_DESTROYED, (void *) (intptr_t) wid, 0);
    } else if (type == 805) {
        uint32_t wid; memcpy(&wid, data, sizeof(uint32_t));
        if (wid) event_loop_post(&g_event_loop, SLS_WINDOW_DISPLAY_CHANGED, (void *) (intptr_t) wid, 0);
    } else if (type == 806 || type == 807) {
        uint32_t wid; memcpy(&wid, data, sizeof(uint32_t));
        if (wid) event_loop_post(&g_event_loop, type == 807 ? SLS_WINDOW_RESIZED : SLS_WINDOW_MOVED,
                                 (void *) (intptr_t) wid, 0);
    } else if (type == 815 || type == 816) {
        uint32_t wid; memcpy(&wid, data, sizeof(uint32_t));
        if (wid) event_loop_post(&g_event_loop, type == 816 ? SLS_WINDOW_INVISIBLE : SLS_WINDOW_VISIBLE,
                                 (void *) (intptr_t) wid, 0);
    } else if (type == 1325) {
        // NOTE: kCGSWindowDidCreate payload (len 12) = { u64 sid; u32 wid at offset 8 }.
        // A native-tab switch fires ONLY this event (no 808/815/816, AX silent).
        uint32_t wid = 0;
        if (data && data_length >= 12) memcpy(&wid, (char *) data + 8, sizeof(uint32_t));
        if (wid) event_loop_post(&g_event_loop, SLS_WINDOW_CREATED, (void *) (intptr_t) wid, 0);
    } else if (type == 1202) {
        __atomic_store_n(&__last_cmd_tab_time, read_os_timer(), __ATOMIC_RELEASE);
    } else if (type == 1329) {
        // NOTE: an SA-driven slide commits the space in a raw SLS transaction and fires NO
        // NSWorkspace.activeSpaceDidChange — this 1329 (kCGSSpaceChange) leg is how the daemon
        // hears its own commit. Fires leave+enter per switch; post only on a real change.
        static uint64_t s_last_space_change_sid;
        uint64_t active = SLSGetActiveSpace(g_connection);
        if (active && active != s_last_space_change_sid) {
            s_last_space_change_sid = active;
            event_loop_post(&g_event_loop, SPACE_CHANGED, NULL, 0);
        }
    }
}
#pragma clang diagnostic pop

enum mission_control_mode
{
    MISSION_CONTROL_MODE_INACTIVE           = 0,
    MISSION_CONTROL_MODE_SHOW               = 1,
    MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS   = 2,
    MISSION_CONTROL_MODE_SHOW_FRONT_WINDOWS = 3,
    MISSION_CONTROL_MODE_SHOW_DESKTOP       = 4
};

static const char *mission_control_mode_str[] = {
    [MISSION_CONTROL_MODE_INACTIVE]           = "inactive",
    [MISSION_CONTROL_MODE_SHOW]               = "show",
    [MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS]   = "show-all-windows",
    [MISSION_CONTROL_MODE_SHOW_FRONT_WINDOWS] = "show-front-windows",
    [MISSION_CONTROL_MODE_SHOW_DESKTOP]       = "show-desktop"
};

static struct {
    AXUIElementRef ref;
    AXObserverRef observer_ref;
    bool is_observing;
} g_mission_control_observer;

static CFStringRef kAXExposeShowAllWindows   = CFSTR("AXExposeShowAllWindows");
static CFStringRef kAXExposeShowFrontWindows = CFSTR("AXExposeShowFrontWindows");
static CFStringRef kAXExposeShowDesktop      = CFSTR("AXExposeShowDesktop");
static CFStringRef kAXExposeExit             = CFSTR("AXExposeExit");

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static OBSERVER_CALLBACK(mission_control_notification_handler)
{
    if (CFEqual(notification, kAXExposeShowAllWindows)) {
        event_loop_post(&g_event_loop, MISSION_CONTROL_SHOW_ALL_WINDOWS, NULL, 0);
    } else if (CFEqual(notification, kAXExposeShowFrontWindows)) {
        event_loop_post(&g_event_loop, MISSION_CONTROL_SHOW_FRONT_WINDOWS, NULL, 0);
    } else if (CFEqual(notification, kAXExposeShowDesktop)) {
        event_loop_post(&g_event_loop, MISSION_CONTROL_SHOW_DESKTOP, NULL, 0);
    } else if (CFEqual(notification, kAXExposeExit)) {
        event_loop_post(&g_event_loop, MISSION_CONTROL_EXIT, NULL, 0);
    }
}
#pragma clang diagnostic pop

void mission_control_observe(void)
{
    if (!g_mission_control_observer.is_observing) {
        uint32_t pid = workspace_get_dock_pid();
        g_mission_control_observer.ref = AXUIElementCreateApplication(pid);

        if (pid && g_mission_control_observer.ref) {
            if (AXObserverCreate(pid, mission_control_notification_handler, &g_mission_control_observer.observer_ref) == kAXErrorSuccess) {
                AXObserverAddNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeShowAllWindows, NULL);
                AXObserverAddNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeShowFrontWindows, NULL);
                AXObserverAddNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeShowDesktop, NULL);
                AXObserverAddNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeExit, NULL);

                g_mission_control_observer.is_observing = true;
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(g_mission_control_observer.observer_ref), kCFRunLoopDefaultMode);
            }
        }
    }
}

void mission_control_unobserve(void)
{
    if (g_mission_control_observer.is_observing) {
        AXObserverRemoveNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeShowAllWindows);
        AXObserverRemoveNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeShowFrontWindows);
        AXObserverRemoveNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeShowDesktop);
        AXObserverRemoveNotification(g_mission_control_observer.observer_ref, g_mission_control_observer.ref, kAXExposeExit);

        g_mission_control_observer.is_observing = false;
        CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(g_mission_control_observer.observer_ref));
        CFRelease(g_mission_control_observer.observer_ref);
        CFRelease(g_mission_control_observer.ref);
    }
}

static inline bool mission_control_is_active(void)
{
    return g_mission_control_mode != MISSION_CONTROL_MODE_INACTIVE;
}

// NOTE: Dock logs "Changing from mode <a> to <b>" as an MC transition starts; `log
// stream` delivers it in ~0.2-4ms, ahead of the AX observer. The in-process stream SPI
// is entitlement-gated (com.apple.private.logging.stream) — hence the /usr/bin/log child.
extern char **environ;

static struct {
    pthread_t thread;
    pid_t child;      // the /usr/bin/log subprocess
    int read_fd;      // pipe read end (owned by the reader thread)
    volatile bool running;
} g_mc_osl_observer;

static void *mission_control_osl_reader(void *unused)
{
    (void)unused;
    FILE *stream = fdopen(g_mc_osl_observer.read_fd, "r");
    if (!stream) return NULL;

    static const struct { const char *pat; enum event_type ev; int mode; } MC_MODES[] = {
        { ".none to .showAllWindows",   MISSION_CONTROL_OSL_ENTER, 0 },  // Mission Control
        { ".none to .showFrontWindows", MISSION_CONTROL_OSL_ENTER, 1 },  // app-Exposé
        { ".none to .showDesktop",      MISSION_CONTROL_OSL_ENTER, 2 },  // Show Desktop
        { ".showAllWindows to .none",   MISSION_CONTROL_OSL_EXIT,  0 },
        { ".showFrontWindows to .none", MISSION_CONTROL_OSL_EXIT,  1 },
        { ".showDesktop to .none",      MISSION_CONTROL_OSL_EXIT,  2 },
    };
    char line[8192];
    while (__atomic_load_n(&g_mc_osl_observer.running, __ATOMIC_ACQUIRE) &&
           fgets(line, sizeof line, stream)) {
        for (int i = 0; i < (int)(sizeof MC_MODES / sizeof MC_MODES[0]); i++) {
            if (strstr(line, MC_MODES[i].pat)) {
                event_loop_post(&g_event_loop, MC_MODES[i].ev, NULL, MC_MODES[i].mode);
                break;
            }
        }
    }

    fclose(stream); // also closes read_fd
    return NULL;
}

void mission_control_osl_observe(void)
{
    if (__atomic_load_n(&g_mc_osl_observer.running, __ATOMIC_ACQUIRE)) return;

    uint32_t pid = workspace_get_dock_pid();
    if (!pid) return;

    int fds[2];
    if (pipe(fds) != 0) return;

    char pidbuf[16];
    snprintf(pidbuf, sizeof pidbuf, "%u", pid);

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&fa, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);

    char *argv[] = {
        "/usr/bin/log", "stream",
        "--process",   pidbuf,
        "--style",     "ndjson",
        "--predicate", "eventMessage CONTAINS \"Changing from mode\"",
        NULL
    };

    pid_t child;
    int rc = posix_spawn(&child, "/usr/bin/log", &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(fds[1]); // parent keeps only the read end

    if (rc != 0) {
        LOGFT("MC_OSL", "posix_spawn(/usr/bin/log) failed rc=%d -- MC-enter ring hide disabled\n", rc);
        close(fds[0]);
        return;
    }

    g_mc_osl_observer.child = child;
    g_mc_osl_observer.read_fd = fds[0];
    __atomic_store_n(&g_mc_osl_observer.running, true, __ATOMIC_RELEASE);
    pthread_create(&g_mc_osl_observer.thread, NULL, mission_control_osl_reader, NULL);
}

void mission_control_osl_unobserve(void)
{
    if (!__atomic_load_n(&g_mc_osl_observer.running, __ATOMIC_ACQUIRE)) return;

    __atomic_store_n(&g_mc_osl_observer.running, false, __ATOMIC_RELEASE);
    if (g_mc_osl_observer.child) kill(g_mc_osl_observer.child, SIGTERM); // -> stdout EOF -> reader exits
    pthread_join(g_mc_osl_observer.thread, NULL);
    g_mc_osl_observer.child = 0;
    g_mc_osl_observer.read_fd = -1;
}
