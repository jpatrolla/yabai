extern struct event_loop g_event_loop;
extern enum mission_control_mode g_mission_control_mode;
extern volatile uint64_t __last_cmd_tab_time;

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
    } else if (type == 815) {
        uint32_t wid; memcpy(&wid, data, sizeof(uint32_t));
        if (wid) event_loop_post(&g_event_loop, SLS_WINDOW_VISIBLE, (void *) (intptr_t) wid, 0);
    } else if (type == 1325 || type == 1326) {
        // NOTE: space-membership payload is { u64 sid; u32 wid }, so the wid sits at offset 8.
        uint32_t wid = 0;
        if (data && data_length >= 12) memcpy(&wid, (char *) data + 8, sizeof(uint32_t));
        if (wid) event_loop_post(&g_event_loop, type == 1326 ? SLS_REMOVED_FROM_SPACE : SLS_ADDED_TO_SPACE,
                                 (void *) (intptr_t) wid, 0);
    } else if (type == 1202) {
        __atomic_store_n(&__last_cmd_tab_time, read_os_timer(), __ATOMIC_RELEASE);
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
