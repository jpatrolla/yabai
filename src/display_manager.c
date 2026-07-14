extern struct display_manager g_display_manager;
extern struct window_manager g_window_manager;
extern struct process_manager g_process_manager;
extern int g_connection;

bool display_manager_query_displays(FILE *rsp, uint64_t flags)
{
    TIME_FUNCTION;

    int count;
    uint32_t *display_list = display_manager_active_display_list(&count);
    if (!display_list) return false;

    fprintf(rsp, "[");
    for (int i = 0; i < count; ++i) {
        display_serialize(rsp, display_list[i], flags);
        fprintf(rsp, "%c", i < count - 1 ? ',' : ']');
    }
    fprintf(rsp, "\n");

    return true;
}

struct display_label *display_manager_get_label_for_display(struct display_manager *dm, uint32_t did)
{
    for (int i = 0; i < buf_len(dm->labels); ++i) {
        struct display_label *display_label = &dm->labels[i];
        if (display_label->did == did) {
            return display_label;
        }
    }

    return NULL;
}

struct display_label *display_manager_get_display_for_label(struct display_manager *dm, char *label)
{
    for (int i = 0; i < buf_len(dm->labels); ++i) {
        struct display_label *display_label = &dm->labels[i];
        if (string_equals(label, display_label->label)) {
            return display_label;
        }
    }

    return NULL;
}

bool display_manager_remove_label_for_display(struct display_manager *dm, uint32_t did)
{
    for (int i = 0; i < buf_len(dm->labels); ++i) {
        struct display_label *display_label = &dm->labels[i];
        if (display_label->did == did) {
            free(display_label->label);
            buf_del(dm->labels, i);
            return true;
        }
    }

    return false;
}

void display_manager_set_label_for_display(struct display_manager *dm, uint32_t did, char *label)
{
    display_manager_remove_label_for_display(dm, did);

    for (int i = 0; i < buf_len(dm->labels); ++i) {
        struct display_label *display_label = &dm->labels[i];
        if (string_equals(display_label->label, label)) {
            free(display_label->label);
            buf_del(dm->labels, i);
            break;
        }
    }

    buf_push(dm->labels, ((struct display_label) {
        .did   = did,
        .label = label
    }));
}

CFStringRef display_manager_main_display_uuid(void)
{
    uint32_t did = display_manager_main_display_id();
    return display_uuid(did);
}

uint32_t display_manager_main_display_id(void)
{
    return CGMainDisplayID();
}

CFStringRef display_manager_active_display_uuid(void)
{
    return SLSCopyActiveMenuBarDisplayIdentifier(g_connection);
}

uint32_t display_manager_active_display_id(void)
{
    CFStringRef uuid = display_manager_active_display_uuid();
    assert(uuid);

    uint32_t result = display_id(uuid);
    CFRelease(uuid);

    return result;
}

CFStringRef display_manager_dock_display_uuid(void)
{
    CGRect dock = display_manager_dock_rect();
    return SLSCopyBestManagedDisplayForRect(g_connection, dock);
}

uint32_t display_manager_dock_display_id(void)
{
    CFStringRef uuid = display_manager_dock_display_uuid();
    if (!uuid) return 0;

    uint32_t result = display_id(uuid);
    CFRelease(uuid);

    return result;
}

CFStringRef display_manager_point_display_uuid(CGPoint point)
{
    return SLSCopyBestManagedDisplayForPoint(g_connection, point);
}

uint32_t display_manager_point_display_id(CGPoint point)
{
    CFStringRef uuid = display_manager_point_display_uuid(point);
    if (!uuid) return 0;

    uint32_t result = display_id(uuid);
    CFRelease(uuid);

    return result;
}

static CFComparisonResult display_manager_coordinate_comparator(CFTypeRef a, CFTypeRef b, void *context)
{
    enum display_arrangement_order axis = (enum display_arrangement_order)(uintptr_t) context;

    uint32_t a_did = display_id(a);
    uint32_t b_did = display_id(b);

    CGPoint a_center = display_center(a_did);
    CGPoint b_center = display_center(b_did);

    float a_coord = axis == DISPLAY_ARRANGEMENT_ORDER_Y ? a_center.y : a_center.x;
    float b_coord = axis == DISPLAY_ARRANGEMENT_ORDER_Y ? b_center.y : b_center.x;

    if (a_coord < b_coord) return kCFCompareLessThan;
    if (a_coord > b_coord) return kCFCompareGreaterThan;

    a_coord = axis == DISPLAY_ARRANGEMENT_ORDER_Y ? a_center.x : a_center.y;
    b_coord = axis == DISPLAY_ARRANGEMENT_ORDER_Y ? b_center.x : b_center.y;

    if (a_coord < b_coord) return kCFCompareLessThan;
    if (a_coord > b_coord) return kCFCompareGreaterThan;

    return kCFCompareEqualTo;
}

int display_manager_display_id_arrangement(uint32_t did)
{
    int result = 0;

    CFStringRef uuid = display_uuid(did);
    if (!uuid) goto out;

    CFArrayRef displays = SLSCopyManagedDisplays(g_connection);
    if (!displays) goto err;

    int count = CFArrayGetCount(displays);
    if (!count) goto empty;

    if (g_display_manager.order != DISPLAY_ARRANGEMENT_ORDER_DEFAULT) {
        CFMutableArrayRef mut_displays = CFArrayCreateMutableCopy(NULL, count, displays);
        CFArraySortValues(mut_displays, CFRangeMake(0, count), &display_manager_coordinate_comparator, (void *)(uintptr_t) g_display_manager.order);
        CFRelease(displays); displays = mut_displays;
    }

    for (int i = 0; i < count; ++i) {
        if (CFEqual(CFArrayGetValueAtIndex(displays, i), uuid)) {
            result = i + 1;
            break;
        }
    }

empty:
    CFRelease(displays);
err:
    CFRelease(uuid);
out:
    return result;
}

CFStringRef display_manager_arrangement_display_uuid(int arrangement)
{
    CFStringRef result = NULL;
    CFArrayRef displays = SLSCopyManagedDisplays(g_connection);

    int count = CFArrayGetCount(displays);
    int index = arrangement - 1;

    if (in_range_ie(index, 0, count)) {
        if (g_display_manager.order != DISPLAY_ARRANGEMENT_ORDER_DEFAULT) {
            CFMutableArrayRef mut_displays = CFArrayCreateMutableCopy(NULL, count, displays);
            CFArraySortValues(mut_displays, CFRangeMake(0, count), &display_manager_coordinate_comparator, (void *)(uintptr_t) g_display_manager.order);
            CFRelease(displays); displays = mut_displays;
        }

        result = CFRetain(CFArrayGetValueAtIndex(displays, index));
    }

    CFRelease(displays);
    return result;
}

uint32_t display_manager_arrangement_display_id(int arrangement)
{
    CFStringRef uuid = display_manager_arrangement_display_uuid(arrangement);
    if (!uuid) return 0;

    uint32_t result = display_id(uuid);
    CFRelease(uuid);

    return result;
}

uint32_t display_manager_cursor_display_id(void)
{
    CGPoint cursor;
    SLSGetCurrentCursorLocation(g_connection, &cursor);
    return display_manager_point_display_id(cursor);
}

uint32_t display_manager_prev_display_id(uint32_t did)
{
    int arrangement = display_manager_display_id_arrangement(did);
    if (arrangement <= 1) return 0;

    return display_manager_arrangement_display_id(arrangement - 1);
}

uint32_t display_manager_next_display_id(uint32_t did)
{
    int arrangement = display_manager_display_id_arrangement(did);
    if (arrangement >= display_manager_active_display_count()) return 0;

    return display_manager_arrangement_display_id(arrangement + 1);
}

uint32_t display_manager_first_display_id(void)
{
    return display_manager_arrangement_display_id(1);
}

uint32_t display_manager_last_display_id(void)
{
    int arrangement = display_manager_active_display_count();
    return display_manager_arrangement_display_id(arrangement);
}

uint32_t display_manager_find_closest_display_in_direction(uint32_t source_did, int direction)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return 0;

    uint32_t best_did = 0;
    int best_distance = INT_MAX;

    struct area source_area = area_from_cgrect(CGDisplayBounds(source_did));
    CGPoint source_area_max = area_max_point(source_area);

    for (int i = 0; i < display_count; ++i) {
        uint32_t did = display_list[i];
        if (did == source_did) continue;

        struct area target_area = area_from_cgrect(CGDisplayBounds(did));
        CGPoint target_area_max = area_max_point(target_area);

        if (area_is_in_direction(&source_area, source_area_max, &target_area, target_area_max, direction)) {
            int distance = area_distance_in_direction(&source_area, source_area_max, &target_area, target_area_max, direction);
            if (distance < best_distance) {
                best_did = did;
                best_distance = distance;
            }
        }
    }

    return best_did;
}

bool display_manager_menu_bar_hidden(void)
{
    int status = 0;
    SLSGetMenuBarAutohideEnabled(g_connection, &status);
    return status;
}

CGRect display_manager_menu_bar_rect(uint32_t did)
{
    CGRect bounds = {0};

#ifdef __x86_64__
    SLSGetRevealedMenuBarBounds(&bounds, g_connection, display_space_id(did));
#elif __arm64__

    //
    // NOTE(asmvik): SLSGetRevealedMenuBarBounds is broken on Apple Silicon,
    // but we expected it to return the full display bounds along with the menubar
    // height. Combine this information ourselves using two separate functions..
    //

    uint32_t height = 0;
    SLSGetDisplayMenubarHeight(did, &height);

    bounds = CGDisplayBounds(did);
    bounds.size.height = height;
#endif

    //
    // NOTE(asmvik): Height needs to be offset by 1 because that is the actual
    // position on the screen that windows can be positioned at..
    //

    bounds.size.height += 1;
    return bounds;
}

bool display_manager_dock_hidden(void)
{
    return CoreDockGetAutoHideEnabled();
}

int display_manager_dock_orientation(void)
{
    int pinning = 0;
    int orientation = 0;
    CoreDockGetOrientationAndPinning(&orientation, &pinning);
    return orientation;
}

CGRect display_manager_dock_rect(void)
{
    int reason = 0;
    CGRect bounds = {0};
    SLSGetDockRectWithReason(g_connection, &bounds, &reason);
    return bounds;
}

bool display_manager_active_display_is_animating(void)
{
    if (workspace_is_macos_bigsur()   ||
        workspace_is_macos_monterey() ||
        workspace_is_macos_ventura())
    {
        CFStringRef uuid = display_manager_active_display_uuid();
        assert(uuid);

        bool result = SLSManagedDisplayIsAnimating(g_connection, uuid);
        CFRelease(uuid);

        return result;
    }

    return false; // This does not return a correct result on modern macOS versions.
}

bool display_manager_display_is_animating(uint32_t did)
{
    if (workspace_is_macos_bigsur()   ||
        workspace_is_macos_monterey() ||
        workspace_is_macos_ventura())
    {
        CFStringRef uuid = display_uuid(did);
        if (!uuid) return false;

        bool result = SLSManagedDisplayIsAnimating(g_connection, uuid);
        CFRelease(uuid);

        return result;
    }

    return false; // This does not return a correct result on modern macOS versions.
}

int display_manager_active_display_count(void)
{
    uint32_t count;
    CGGetActiveDisplayList(0, NULL, &count);
    return (int)count;
}

uint32_t *display_manager_active_display_list(int *count)
{
    int display_count = display_manager_active_display_count();
    uint32_t *result = ts_alloc_list(uint32_t, display_count);
    CGGetActiveDisplayList(display_count, result, (uint32_t*)count);
    return result;
}

static AXUIElementRef display_manager_find_element_at_point(CGPoint point)
{
    AXUIElementRef element_ref = NULL;
    AXUIElementCopyElementAtPosition(g_window_manager.system_element, point.x, point.y, &element_ref);
    if (!element_ref) return NULL;

    CFTypeRef role = NULL;
    AXUIElementCopyAttributeValue(element_ref, kAXRoleAttribute, &role);
    if (!role) return NULL;

    if (CFEqual(role, kAXWindowRole)) {
        CFRelease(role);
        return element_ref;
    }

    CFTypeRef window_ref = NULL;
    AXUIElementCopyAttributeValue(element_ref, kAXWindowAttribute, &window_ref);
    CFRelease(element_ref);
    CFRelease(role);
    return window_ref;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
uint32_t display_manager_focus_display_with_window_at_point(CGPoint point)
{
    int element_connection;
    ProcessSerialNumber element_psn;

    AXUIElementRef element_ref = display_manager_find_element_at_point(point);
    if (!element_ref) goto out;

    uint32_t element_id = ax_window_id(element_ref);
    if (!element_id) goto err_ref;

    SLSGetWindowOwner(g_connection, element_id, &element_connection);
    SLSGetConnectionPSN(element_connection, &element_psn);
    window_manager_focus_window_with_raise(&element_psn, element_id, element_ref);
    CFRelease(element_ref);
    return element_id;

err_ref:
    CFRelease(element_ref);
out:
    return 0;
}
#pragma clang diagnostic pop

void display_manager_set_active_display_id(uint32_t did)
{
    CFStringRef uuid = display_uuid(did);
    // The 3rd arg is an event timestamp; ~0ULL makes the server clamp it to the
    // current event time. Upstream passes the uuid pointer here, which can read
    // as a stale stamp and be rejected — silently dropping the switch.
    SLSSetActiveMenuBarDisplayIdentifier(g_connection, uuid, ~0ULL);
    CFRelease(uuid);
}

static bool display_manager_window_resides_on_display(uint32_t did, uint32_t wid)
{
    CGRect bounds;
    if (SLSGetWindowBounds(g_connection, wid, &bounds) != kCGErrorSuccess) return false;
    CGPoint mid = { CGRectGetMidX(bounds), CGRectGetMidY(bounds) };
    return CGRectContainsPoint(CGDisplayBounds(did), mid);
}

// Fallback desktop-window hunt: scan `sid`'s full window list (options 0x7 —
// chrome included) for a Finder-owned window in the desktop band (negative
// window level; Finder owns no other sub-zero windows) that resides on `did`.
static uint32_t display_manager_desktop_window_on_space(uint32_t did, uint64_t sid)
{
    uint32_t result = 0;

    CFNumberRef sid_num = CFNumberCreate(NULL, kCFNumberSInt64Type, &sid);
    if (!sid_num) return 0;
    CFArrayRef space_list = CFArrayCreate(NULL, (const void **)&sid_num, 1, &kCFTypeArrayCallBacks);
    CFRelease(sid_num);
    if (!space_list) return 0;

    uint64_t set_tags = 0, clear_tags = 0;
    CFArrayRef window_list = SLSCopyWindowsWithOptionsAndTags(g_connection, 0, space_list, 0x7, &set_tags, &clear_tags);
    CFRelease(space_list);
    if (!window_list) return 0;

    for (int i = 0, count = CFArrayGetCount(window_list); i < count && !result; ++i) {
        CFNumberRef num = CFArrayGetValueAtIndex(window_list, i);
        uint32_t wid = 0;
        if (num && CFGetTypeID(num) == CFNumberGetTypeID()) {
            CFNumberGetValue(num, kCFNumberSInt32Type, &wid);
        }
        if (!wid) continue;

        int level = 0;
        if (SLSGetWindowLevel(g_connection, wid, &level) != kCGErrorSuccess || level >= 0) continue;

        int wcid = 0;
        ProcessSerialNumber psn = {0};
        if (SLSGetWindowOwner(g_connection, wid, &wcid) != kCGErrorSuccess) continue;
        if (SLSGetConnectionPSN(wcid, &psn) != kCGErrorSuccess) continue;
        if (!psn_equals(&psn, &g_process_manager.finder_psn)) continue;

        if (display_manager_window_resides_on_display(did, wid)) result = wid;
    }
    CFRelease(window_list);
    return result;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Last-resort desktop-window hunt via PUBLIC CGWindowList. Finder's
// desktop-icon windows are join-all-spaces chrome with NO per-space
// association — sid-scoped SLS window lists miss them entirely
// (live-verified: `debug desktop_residency` shows only WindowServer strips
// and wallpaper windows in the desktop band of a space's list) — but
// CGWindowListCopyWindowInfo enumerates them with owner pid, layer, and
// bounds regardless of space. Runs only on the (rare) empty-display focus
// path, so the heavier copy is acceptable.
static uint32_t display_manager_desktop_window_via_cgwindowlist(uint32_t did)
{
    pid_t finder_pid = 0;
    GetProcessPID(&g_process_manager.finder_psn, &finder_pid);
    if (!finder_pid) return 0;

    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID);
    if (!list) return 0;

    uint32_t result = 0;
    CGRect display_frame = CGDisplayBounds(did);
    for (int i = 0, count = CFArrayGetCount(list); i < count && !result; ++i) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, i);
        if (!info || CFGetTypeID(info) != CFDictionaryGetTypeID()) continue;

        int64_t pid = 0, layer = 0, wid = 0;
        CFNumberRef num;
        if (!(num = CFDictionaryGetValue(info, kCGWindowOwnerPID)) ||
            !CFNumberGetValue(num, kCFNumberSInt64Type, &pid) || pid != finder_pid) continue;
        if (!(num = CFDictionaryGetValue(info, kCGWindowLayer)) ||
            !CFNumberGetValue(num, kCFNumberSInt64Type, &layer) || layer >= 0) continue;
        if (!(num = CFDictionaryGetValue(info, kCGWindowNumber)) ||
            !CFNumberGetValue(num, kCFNumberSInt64Type, &wid) || !wid) continue;

        CFDictionaryRef bounds_dict = CFDictionaryGetValue(info, kCGWindowBounds);
        CGRect bounds;
        if (!bounds_dict || !CGRectMakeWithDictionaryRepresentation(bounds_dict, &bounds)) continue;

        CGPoint mid = { CGRectGetMidX(bounds), CGRectGetMidY(bounds) };
        if (CGRectContainsPoint(display_frame, mid)) result = (uint32_t)wid;
    }
    CFRelease(list);
    return result;
}
#pragma clang diagnostic pop

// The Finder desktop ("role-1") window that actually RESIDES on `did`.
// SLSManagedDisplaysCopyRoleWindows is not display-faithful: it can answer a
// display's UUID with the OTHER display's desktop window (live-verified —
// display 1's UUID returning display 2's desktop, the stale one-shot
// registration; see documentation in the main tree), and keying that window
// yanks focus to the wrong display. Accept an SPI candidate only if its
// bounds sit on `did`; otherwise fall back to the space-scoped desktop-band
// scan, then to the CGWindowList hunt (the space scan misses Finder's
// desktop windows on builds where they are join-all-spaces chrome — the
// CGWindowList tier is the one that actually fires there).
uint32_t display_manager_resident_desktop_window(uint32_t did, uint64_t sid)
{
    uint32_t result = 0;

    CFStringRef uuid = display_uuid(did);
    if (uuid) {
        const void *uvals[1] = { uuid };
        CFArrayRef uarr = CFArrayCreate(NULL, uvals, 1, &kCFTypeArrayCallBacks);
        if (uarr) {
            CFArrayRef rws = SLSManagedDisplaysCopyRoleWindows(g_connection, uarr, 1);
            if (rws) {
                for (int i = 0, count = CFArrayGetCount(rws); i < count && !result; ++i) {
                    CFNumberRef num = CFArrayGetValueAtIndex(rws, i);
                    uint32_t wid = 0;
                    if (num && CFGetTypeID(num) == CFNumberGetTypeID()) {
                        CFNumberGetValue(num, kCFNumberSInt32Type, &wid);
                    }
                    if (wid && display_manager_window_resides_on_display(did, wid)) result = wid;
                }
                CFRelease(rws);
            }
            CFRelease(uarr);
        }
        CFRelease(uuid);
    }

    if (!result) result = display_manager_desktop_window_on_space(did, sid);
    if (!result) result = display_manager_desktop_window_via_cgwindowlist(did);
    return result;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
void display_manager_focus_display(uint32_t did, uint64_t sid)
{
    struct window *window = window_manager_find_window_on_space_by_rank_filtering_window(&g_window_manager, sid, 1, 0);
    if (window) {
        window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
        window_manager_center_mouse(&g_window_manager, window);
        display_manager_set_active_display_id(did);
    } else {
        // No app window on the target display (desktop only). Key the display's
        // OWN Finder desktop window (role-1) via the SLPS front + make-key idiom.
        // A bare front-process call or cursor warp does NOT land focus on an
        // empty display — keying the RESIDENT desktop window + the
        // active-display switch does. Resident is the operative word: the raw
        // role-windows SPI can answer with the other display's desktop (see
        // display_manager_resident_desktop_window), and keying that window
        // yanks focus to THAT display instead of this one.
        uint32_t role_wid = display_manager_resident_desktop_window(did, sid);
        if (role_wid) {
            int wcid = 0;
            ProcessSerialNumber psn = {0};
            SLSGetWindowOwner(g_connection, role_wid, &wcid);
            SLSGetConnectionPSN(wcid, &psn);
            // Pure SLPS idiom (no raise): desktop windows have no AX ref, and
            // the sls focus method's Dock hand-off does not land on them.
            window_manager_focus_window_without_raise(&psn, role_wid);
        }
        display_manager_set_active_display_id(did);
    }
}
#pragma clang diagnostic pop

enum space_op_error display_manager_focus_space(uint32_t did, uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    bool is_animating = display_manager_display_is_animating(did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint32_t space_did = space_display_id(sid);
    if (space_did != did) return SPACE_OP_ERROR_SAME_DISPLAY;

    return scripting_addition_focus_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

bool display_manager_begin(struct display_manager *dm)
{
    dm->current_display_id = display_manager_active_display_id();
    dm->last_display_id = dm->current_display_id;
    dm->order = DISPLAY_ARRANGEMENT_ORDER_DEFAULT;
    dm->mode = EXTERNAL_BAR_OFF;
    dm->top_padding = 0;
    dm->bottom_padding = 0;
    return CGDisplayRegisterReconfigurationCallback(display_handler, NULL) == kCGErrorSuccess;
}
