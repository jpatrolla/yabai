extern struct event_loop g_event_loop;
extern volatile bool __pending_window_focus;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
// NOTE: match prefix + keyword, never a whole title — the app puts its own name in the middle
// ("New Finder Window"), and Prefer Tabs turns that same item into a tab create.
static bool menu_title_is_tab_create(CFStringRef title)
{
    if (!CFStringHasPrefix(title, CFSTR("New "))) return false;
    return CFStringFind(title, CFSTR("Window"), 0).location != kCFNotFound ||
           CFStringFind(title, CFSTR("Tab"), 0).location != kCFNotFound;
}

static OBSERVER_CALLBACK(application_notification_handler)
{
    if (CFEqual(notification, kAXCreatedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_CREATED, (void *) CFRetain(element), 0);
    } else if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        __atomic_store_n(&__pending_window_focus, true, __ATOMIC_RELEASE);

        // NOTE: param1 = "AppKit named this window UNTABBED" — the name -[NSApplication
        // _setKeyWindow:] picks off [newKeyWindow _isTabbedWithOtherWindows]. Not always a
        // detach (see WINDOW_FOCUSED); the inline call from TABGROUP_UPDATED passes 0.
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) ax_window_id(element), 1);
    } else if (CFEqual(notification, ax_application_notification[AX_APPLICATION_WINDOW_FOCUSED_TAB_INDEX])) {
        event_loop_post(&g_event_loop, TABGROUP_UPDATED, (void *)(intptr_t) ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXWindowMovedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_MOVED, (void *)(intptr_t) ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXWindowResizedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_RESIZED, (void *)(intptr_t) ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXTitleChangedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_TITLE_CHANGED, (void *)(intptr_t) ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXMenuOpenedNotification)) {
        event_loop_post(&g_event_loop, MENU_OPENED, (void *)(intptr_t) ax_window_id(element), 0);
    } else if (CFEqual(notification, kAXMenuClosedNotification)) {
        event_loop_post(&g_event_loop, MENU_CLOSED, NULL, 0);
    } else if (CFEqual(notification, kAXMenuItemSelectedNotification)) {
        // NOTE: stamp arrival before the AXTitle read — that read is a synchronous IPC into
        // the target app and would otherwise be charged to the notification's latency.
        uint64_t arrive_ns = read_os_timer();

        CFTypeRef title_ref = NULL;
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute, &title_ref);
        uint64_t read_ns = read_os_timer() - arrive_ns;

        if (title_ref) {
            if (CFGetTypeID(title_ref) == CFStringGetTypeID() &&
                menu_title_is_tab_create((CFStringRef) title_ref)) {
                char title[256] = {0};
                CFStringGetCString((CFStringRef) title_ref, title, sizeof(title), kCFStringEncodingUTF8);

                struct application *notif_application = context;
                debug("AX_MENU_ITEM_SELECTED: \"%s\" app=%s pid=%d arrive_ns=%llu ax_read_us=%llu\n",
                      title,
                      notif_application ? notif_application->name : "?",
                      notif_application ? notif_application->pid : 0,
                      arrive_ns, read_ns / 1000);

                event_loop_post(&g_event_loop, MENU_ITEM_SELECTED_NEW,
                                (void *)(intptr_t)(notif_application ? notif_application->pid : 0), 0);
            }

            CFRelease(title_ref);
        }
    } else if (CFEqual(notification, kAXWindowMiniaturizedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_MINIMIZED, context, 0);
    } else if (CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        event_loop_post(&g_event_loop, WINDOW_DEMINIMIZED, context, 0);
    } else if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        struct window *window = context;

        //
        // NOTE(asmvik): Flag events that are already queued, but not yet processed,
        // so that they will be ignored; the memory we allocated is still valid and will
        // be freed when this event is handled.
        //

        if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, NULL)) return;

        event_loop_post(&g_event_loop, WINDOW_DESTROYED, window, 0);
    }
}
#pragma clang diagnostic pop

// NOTE: +[NSWindow _addWindowTabsMenuItemsIfNeeded] installs the tabbing items only when
// allowsAutomaticWindowTabbing holds AND some visible window passes _supportsTabbing, so the
// item's PRESENCE answers "can this app tab" before any tab exists. Match on the shortcut:
// titles are localized, Show All Tabs is always cmdchar '\' with modifiers 1. Presence only —
// the enabled flag re-validates against the key window and is stale the moment it is cached.
static bool ax_menu_item_is_show_all_tabs(AXUIElementRef item)
{
    char ch[8] = {0};
    ax_copy_string(item, CFSTR("AXMenuItemCmdChar"), ch, sizeof(ch));
    if (strcmp(ch, "\\") != 0) return false;
    return ax_copy_int(item, CFSTR("AXMenuItemCmdModifiers")) == 1;
}

static bool ax_menu_has_show_all_tabs(AXUIElementRef element, int depth)
{
    if (depth > 3) return false;

    CFTypeRef children = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXChildrenAttribute, &children) != kAXErrorSuccess) return false;
    if (!children) return false;
    if (CFGetTypeID(children) != CFArrayGetTypeID()) { CFRelease(children); return false; }

    bool result = false;
    CFIndex count = CFArrayGetCount(children);
    for (CFIndex i = 0; i < count && !result; ++i) {
        AXUIElementRef child = (AXUIElementRef) CFArrayGetValueAtIndex(children, i);
        result = ax_menu_item_is_show_all_tabs(child) || ax_menu_has_show_all_tabs(child, depth + 1);
    }

    CFRelease(children);
    return result;
}

// NOTE: this defaults key force-installs the items for every app, which would make the menu
// answer yes universally — fall back to assuming tabbable, the behaviour before this cache.
static bool ax_native_tab_menu_signal_usable(void)
{
    static int usable = -1;
    if (usable < 0) {
        Boolean valid = false;
        Boolean forced = CFPreferencesGetAppBooleanValue(CFSTR("NSMenuAlwaysInstallWindowTabItems"),
                                                         kCFPreferencesAnyApplication, &valid);
        usable = (valid && forced) ? 0 : 1;
    }
    return usable == 1;
}

// NOTE: an unresolved read leaves the cache at -1 and answers YES — a menu bar the app has not
// published yet is not a no, and sticking it false gates tab handling off for the app's life.
bool application_is_native_tabbable(struct application *application)
{
    if (!application)                return true;
    if (application->native_tabbable >= 0)  return application->native_tabbable == 1;
    if (!ax_native_tab_menu_signal_usable()) { application->native_tabbable = 1; return true; }

    CFTypeRef menubar = NULL;
    if (AXUIElementCopyAttributeValue(application->ref, kAXMenuBarAttribute, &menubar) != kAXErrorSuccess) return true;
    if (!menubar) return true;

    application->native_tabbable = ax_menu_has_show_all_tabs((AXUIElementRef) menubar, 0) ? 1 : 0;
    CFRelease(menubar);

    debug("%s: %s native_tabbable=%d\n", __FUNCTION__, application->name, application->native_tabbable);
    return application->native_tabbable == 1;
}

bool application_observe(struct application *application)
{
    if (AXObserverCreate(application->pid, application_notification_handler, &application->observer_ref) == kAXErrorSuccess) {
        for (int i = 0; i < array_count(ax_application_notification); ++i) {
            AXError result = AXObserverAddNotification(application->observer_ref, application->ref, ax_application_notification[i], application);
            if (result == kAXErrorSuccess || result == kAXErrorNotificationAlreadyRegistered) {
                application->notification |= 1 << i;
            } else {
                if (result == kAXErrorCannotComplete) application->ax_retry = true;
                debug("%s: %s failed with error %s for application '%s'\n", __FUNCTION__, ax_application_notification_str[i], ax_error_str[-result], application->name);
            }
        }

        application->is_observing = true;
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(application->observer_ref), kCFRunLoopDefaultMode);
    }

    return (application->notification & AX_APPLICATION_ALL) == AX_APPLICATION_ALL;
}

void application_unobserve(struct application *application)
{
    if (application->is_observing) {
        for (int i = 0; i < array_count(ax_application_notification); ++i) {
            if (!(application->notification & (1 << i))) continue;

            AXObserverRemoveNotification(application->observer_ref, application->ref, ax_application_notification[i]);
            application->notification &= ~(1 << i);
        }

        application->is_observing = false;
        CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(application->observer_ref));
        CFRelease(application->observer_ref);
    }
}

uint32_t application_main_window(struct application *application)
{
    CFTypeRef window_ref = NULL;
    AXUIElementCopyAttributeValue(application->ref, kAXMainWindowAttribute, &window_ref);
    if (!window_ref) return 0;

    uint32_t window_id = ax_window_id(window_ref);
    CFRelease(window_ref);

    return window_id;
}

uint32_t application_focused_window(struct application *application)
{
    CFTypeRef window_ref = NULL;
    AXUIElementCopyAttributeValue(application->ref, kAXFocusedWindowAttribute, &window_ref);
    if (!window_ref) return 0;

    uint32_t window_id = ax_window_id(window_ref);
    CFRelease(window_ref);

    return window_id;
}

bool application_is_frontmost(struct application *application)
{
    ProcessSerialNumber psn = {0};
    _SLPSGetFrontProcess(&psn);
    return psn_equals(&psn, &application->psn);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool application_is_hidden(struct application *application)
{
    return IsProcessVisible(&application->psn) == 0;
}
#pragma clang diagnostic pop

CFArrayRef application_window_list(struct application *application)
{
    CFTypeRef window_list_ref = NULL;
    AXUIElementCopyAttributeValue(application->ref, kAXWindowsAttribute, &window_list_ref);
    return window_list_ref;
}

struct application *application_create(struct process *process)
{
    struct application *application = malloc(sizeof(struct application));
    memset(application, 0, sizeof(struct application));

    application->ref = AXUIElementCreateApplication(process->pid);
    application->psn = process->psn;
    application->pid = process->pid;
    application->name = process->name;
    application->is_hidden = application_is_hidden(application);
    SLSGetConnectionIDForPSN(g_connection, &application->psn, &application->connection);

    application->ax_eui_cached = ax_enhanced_userinterface(application->ref);
    application->native_tabbable = -1;

    return application;
}

void application_destroy(struct application *application)
{
    CFRelease(application->ref);
    free(application);
}
