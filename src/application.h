#ifndef APPLICATION_H
#define APPLICATION_H

#define OBSERVER_CALLBACK(name) void name(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context)
typedef OBSERVER_CALLBACK(observer_callback);

#define AX_APPLICATION_WINDOW_CREATED_INDEX       0
#define AX_APPLICATION_WINDOW_FOCUSED_INDEX       1
#define AX_APPLICATION_WINDOW_MOVED_INDEX         2
#define AX_APPLICATION_WINDOW_RESIZED_INDEX       3
#define AX_APPLICATION_WINDOW_TITLE_CHANGED_INDEX 4
#define AX_APPLICATION_WINDOW_MENU_OPENED_INDEX   5
#define AX_APPLICATION_WINDOW_MENU_CLOSED_INDEX   6
#define AX_APPLICATION_WINDOW_FOCUSED_TAB_INDEX   7
#define AX_APPLICATION_MENU_ITEM_SELECTED_INDEX   8

#define AX_APPLICATION_WINDOW_CREATED       (1 << AX_APPLICATION_WINDOW_CREATED_INDEX)
#define AX_APPLICATION_WINDOW_FOCUSED       (1 << AX_APPLICATION_WINDOW_FOCUSED_INDEX)
#define AX_APPLICATION_WINDOW_MOVED         (1 << AX_APPLICATION_WINDOW_MOVED_INDEX)
#define AX_APPLICATION_WINDOW_RESIZED       (1 << AX_APPLICATION_WINDOW_RESIZED_INDEX)
#define AX_APPLICATION_WINDOW_TITLE_CHANGED (1 << AX_APPLICATION_WINDOW_TITLE_CHANGED_INDEX)
#define AX_APPLICATION_ALL                  (AX_APPLICATION_WINDOW_CREATED |\
                                             AX_APPLICATION_WINDOW_FOCUSED |\
                                             AX_APPLICATION_WINDOW_MOVED |\
                                             AX_APPLICATION_WINDOW_RESIZED |\
                                             AX_APPLICATION_WINDOW_TITLE_CHANGED)

static const char *ax_error_str[] =
{
    [-kAXErrorSuccess]                           = "kAXErrorSuccess",
    [-kAXErrorFailure]                           = "kAXErrorFailure",
    [-kAXErrorIllegalArgument]                   = "kAXErrorIllegalArgument",
    [-kAXErrorInvalidUIElement]                  = "kAXErrorInvalidUIElement",
    [-kAXErrorInvalidUIElementObserver]          = "kAXErrorInvalidUIElementObserver",
    [-kAXErrorCannotComplete]                    = "kAXErrorCannotComplete",
    [-kAXErrorAttributeUnsupported]              = "kAXErrorAttributeUnsupported",
    [-kAXErrorActionUnsupported]                 = "kAXErrorActionUnsupported",
    [-kAXErrorNotificationUnsupported]           = "kAXErrorNotificationUnsupported",
    [-kAXErrorNotImplemented]                    = "kAXErrorNotImplemented",
    [-kAXErrorNotificationAlreadyRegistered]     = "kAXErrorNotificationAlreadyRegistered",
    [-kAXErrorNotificationNotRegistered]         = "kAXErrorNotificationNotRegistered",
    [-kAXErrorAPIDisabled]                       = "kAXErrorAPIDisabled",
    [-kAXErrorNoValue]                           = "kAXErrorNoValue",
    [-kAXErrorParameterizedAttributeUnsupported] = "kAXErrorParameterizedAttributeUnsupported",
    [-kAXErrorNotEnoughPrecision]                = "kAXErrorNotEnoughPrecision"
};

static const char *ax_application_notification_str[] =
{
    [AX_APPLICATION_WINDOW_CREATED_INDEX]       = "kAXCreatedNotification",
    [AX_APPLICATION_WINDOW_FOCUSED_INDEX]       = "kAXFocusedWindowChangedNotification",
    [AX_APPLICATION_WINDOW_MOVED_INDEX]         = "kAXWindowMovedNotification",
    [AX_APPLICATION_WINDOW_RESIZED_INDEX]       = "kAXWindowResizedNotification",
    [AX_APPLICATION_WINDOW_TITLE_CHANGED_INDEX] = "kAXTitleChangedNotification",
    [AX_APPLICATION_WINDOW_MENU_OPENED_INDEX]   = "kAXMenuOpenedNotification",
    [AX_APPLICATION_WINDOW_MENU_CLOSED_INDEX]   = "kAXMenuClosedNotification",
    [AX_APPLICATION_WINDOW_FOCUSED_TAB_INDEX]   = "AXFocusedTabChanged",
    [AX_APPLICATION_MENU_ITEM_SELECTED_INDEX]   = "kAXMenuItemSelectedNotification"
};

// NOTE: AXFocusedTabChanged is a private AppKit string, deliberately absent from
// AX_APPLICATION_ALL — application_observe reports failure unless every ALL member registers,
// and an app that rejects it must not count as unobservable.
static CFStringRef ax_application_notification[] =
{
    [AX_APPLICATION_WINDOW_CREATED_INDEX]       = kAXCreatedNotification,
    [AX_APPLICATION_WINDOW_FOCUSED_INDEX]       = kAXFocusedWindowChangedNotification,
    [AX_APPLICATION_WINDOW_MOVED_INDEX]         = kAXWindowMovedNotification,
    [AX_APPLICATION_WINDOW_RESIZED_INDEX]       = kAXWindowResizedNotification,
    [AX_APPLICATION_WINDOW_TITLE_CHANGED_INDEX] = kAXTitleChangedNotification,
    [AX_APPLICATION_WINDOW_MENU_OPENED_INDEX]   = kAXMenuOpenedNotification,
    [AX_APPLICATION_WINDOW_MENU_CLOSED_INDEX]   = kAXMenuClosedNotification,
    [AX_APPLICATION_WINDOW_FOCUSED_TAB_INDEX]   = CFSTR("AXFocusedTabChanged"),
    [AX_APPLICATION_MENU_ITEM_SELECTED_INDEX]   = kAXMenuItemSelectedNotification
};

struct application
{
    AXUIElementRef ref;
    int connection;
    ProcessSerialNumber psn;
    pid_t pid;
    char *name;
    AXObserverRef observer_ref;
    // NOTE: one bit per ax_application_notification[] entry — index 15 is the last that fits.
    uint16_t notification;
    bool is_observing;
    bool is_hidden;
    bool ax_retry;
    // NOTE: EUI cache for AX_ENHANCED_UI_WORKAROUND_CACHED (helpers.h); refreshed
    // at window_create — apps set EUI lazily / a launch AX timeout reads stale false.
    bool ax_eui_cached;
    // NOTE: -1 unresolved, 0 no, 1 yes — AppKit's NSWindow tabbing specifically, not "has tabs":
    // Chrome draws its own tab strip and answers no. App-level ONLY, since AppKit installs the
    // menu items when ANY visible window passes _supportsTabbing.
    int8_t native_tabbable;
};

bool application_is_frontmost(struct application *application);
bool application_is_hidden(struct application *application);
uint32_t application_main_window(struct application *application);
uint32_t application_focused_window(struct application *application);
CFArrayRef application_window_list(struct application *application);
bool application_observe(struct application *application);
bool application_is_native_tabbable(struct application *application);

// NOTE: never resolves — application_is_native_tabbable walks the menu bar, and this runs on the
// mouse-down path. Unresolved answers yes, the same as a failed read.
static inline bool application_native_tabbable_cached(struct application *application)
{
    return !application || application->native_tabbable != 0;
}
void application_unobserve(struct application *application);
struct application *application_create(struct process *process);
void application_destroy(struct application *application);

#endif
