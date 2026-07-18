extern struct event_loop g_event_loop;
extern int g_connection;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static DISPLAY_EVENT_HANDLER(display_handler)
{
    if (flags & kCGDisplayAddFlag) {
        event_loop_post(&g_event_loop, DISPLAY_ADDED, (void *)(intptr_t) did, 0);
    } else if (flags & kCGDisplayRemoveFlag) {
        event_loop_post(&g_event_loop, DISPLAY_REMOVED, (void *)(intptr_t) did, 0);
    } else if (flags & kCGDisplayMovedFlag) {
        event_loop_post(&g_event_loop, DISPLAY_MOVED, (void *)(intptr_t) did, 0);
    } else if (flags & kCGDisplayDesktopShapeChangedFlag) {
        event_loop_post(&g_event_loop, DISPLAY_RESIZED, (void *)(intptr_t) did, 0);
    }
}
#pragma clang diagnostic pop

void display_serialize(FILE *rsp, uint32_t did, uint64_t flags)
{
    TIME_FUNCTION;

    if (flags == 0x0) flags |= ~flags;

    bool did_output = false;
    fprintf(rsp, "{\n");

    if (flags & DISPLAY_PROPERTY_ID) {
        fprintf(rsp, "\t\"id\":%d", did);
        did_output = true;
    }

    if (flags & DISPLAY_PROPERTY_UUID) {
        if (did_output) fprintf(rsp, ",\n");

        char *uuid = NULL;
        CFStringRef uuid_ref = display_uuid(did);
        if (uuid_ref) {
            uuid = ts_cfstring_copy(uuid_ref);
            CFRelease(uuid_ref);
        }

        fprintf(rsp, "\t\"uuid\":\"%s\"", uuid ? uuid : "<unknown>");
        did_output = true;
    }

    if (flags & DISPLAY_PROPERTY_INDEX) {
        if (did_output) fprintf(rsp, ",\n");

        fprintf(rsp, "\t\"index\":%d", display_manager_display_id_arrangement(did));
        did_output = true;
    }

    if (flags & DISPLAY_PROPERTY_LABEL) {
        if (did_output) fprintf(rsp, ",\n");

        struct display_label *display_label = display_manager_get_label_for_display(&g_display_manager, did);
        fprintf(rsp, "\t\"label\":\"%s\"", display_label ? display_label->label : "");
        did_output = true;
    }

    if (flags & DISPLAY_PROPERTY_FRAME) {
        if (did_output) fprintf(rsp, ",\n");

        CGRect frame = CGDisplayBounds(did);
        fprintf(rsp, "\t\"frame\":{\n\t\t\"x\":%.4f,\n\t\t\"y\":%.4f,\n\t\t\"w\":%.4f,\n\t\t\"h\":%.4f\n\t}", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
        did_output = true;
    }

    if (flags & DISPLAY_PROPERTY_SPACES) {
        if (did_output) fprintf(rsp, ",\n");

        int count;
        uint64_t *space_list = display_space_list(did, &count);

        fprintf(rsp, "\t\"spaces\":[");
        if (space_list) {
            int first_mci = space_manager_mission_control_index(space_list[0]);
            for (int i = 0; i < count; ++i) {
                if (i < count - 1) {
                    fprintf(rsp, "%d, ", first_mci + i);
                } else {
                    fprintf(rsp, "%d", first_mci + i);
                }
            }
        }
        fprintf(rsp, "]");
        did_output = true;
    }

    if (flags & DISPLAY_PROPERTY_HAS_FOCUS) {
        if (did_output) fprintf(rsp, ",\n");

        fprintf(rsp, "\t\"has-focus\":%s", json_bool(did == g_display_manager.current_display_id));
    }

    fprintf(rsp, "\n}");
}

inline CFStringRef display_uuid(uint32_t did)
{
    CFUUIDRef uuid_ref = CGDisplayCreateUUIDFromDisplayID(did);
    if (!uuid_ref) return NULL;

    CFStringRef uuid_str = CFUUIDCreateString(NULL, uuid_ref);
    CFRelease(uuid_ref);

    return uuid_str;
}

inline uint32_t display_id(CFStringRef uuid)
{
    CFUUIDRef uuid_ref = CFUUIDCreateFromString(NULL, uuid);
    if (!uuid_ref) return 0;

    uint32_t did = CGDisplayGetDisplayIDFromUUID(uuid_ref);
    CFRelease(uuid_ref);

    return did;
}

CGRect display_bounds_constrained(uint32_t did, bool ignore_external_bar)
{
    CGRect frame = CGDisplayBounds(did);
    int effective_ext_top_padding = 0;

    if (!ignore_external_bar) {
        if ((g_display_manager.mode == EXTERNAL_BAR_MAIN &&
             did == display_manager_main_display_id()) ||
            (g_display_manager.mode == EXTERNAL_BAR_ALL)) {
            effective_ext_top_padding = g_display_manager.top_padding;

            frame.origin.y    += effective_ext_top_padding;
            frame.size.height -= effective_ext_top_padding;
            frame.size.height -= g_display_manager.bottom_padding;
        }
    }

    if (display_manager_menu_bar_hidden()) {
        int notch_height = workspace_display_notch_height(did);
        if (notch_height > effective_ext_top_padding) {
             frame.origin.y    += (notch_height - effective_ext_top_padding);
             frame.size.height -= (notch_height - effective_ext_top_padding);
        }
    } else {
        CGRect menu = display_manager_menu_bar_rect(did);
        frame.origin.y    += menu.size.height;
        frame.size.height -= menu.size.height;
    }

    if (!display_manager_dock_hidden()) {
        if (did == display_manager_dock_display_id()) {
            CGRect dock = display_manager_dock_rect();
            switch (display_manager_dock_orientation()) {
            case DOCK_ORIENTATION_LEFT: {
                frame.origin.x   += dock.size.width;
                frame.size.width -= dock.size.width;
            } break;
            case DOCK_ORIENTATION_RIGHT: {
                frame.size.width -= dock.size.width;
            } break;
            case DOCK_ORIENTATION_BOTTOM: {
                frame.size.height -= dock.size.height;
            } break;
            }
        }
    }

    return frame;
}

CGPoint display_center(uint32_t did)
{
    CGRect bounds = CGDisplayBounds(did);
    return (CGPoint) { bounds.origin.x + bounds.size.width/2, bounds.origin.y + bounds.size.height/2 };
}

inline uint64_t display_space_id(uint32_t did)
{
    CFStringRef uuid = display_uuid(did);
    if (!uuid) return 0;

    uint64_t sid = SLSManagedDisplayGetCurrentSpace(g_connection, uuid);
    CFRelease(uuid);

    return sid;
}

int display_space_count(uint32_t did)
{
    int space_count = 0;

    CFStringRef uuid = display_uuid(did);
    if (!uuid) goto out;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) goto err;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFStringRef identifier = CFDictionaryGetValue(display_ref, CFSTR("Display Identifier"));
        if (!CFEqual(uuid, identifier)) continue;

        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        space_count = CFArrayGetCount(spaces_ref);
        break;
    }

    CFRelease(display_spaces_ref);
err:
    CFRelease(uuid);
out:
    return space_count;
}

uint64_t *display_space_list(uint32_t did, int *count)
{
    uint64_t *space_list = NULL;

    CFStringRef uuid = display_uuid(did);
    if (!uuid) goto out;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) goto err;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFStringRef identifier = CFDictionaryGetValue(display_ref, CFSTR("Display Identifier"));
        if (!CFEqual(uuid, identifier)) continue;

        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        int spaces_count = CFArrayGetCount(spaces_ref);

        space_list = ts_alloc_list(uint64_t, spaces_count);
        *count = spaces_count;

        for (int j = 0; j < spaces_count; ++j) {
            CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
            CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
            CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &space_list[j]);
        }
    }

    CFRelease(display_spaces_ref);
err:
    CFRelease(uuid);
out:
    return space_list;
}

static struct display_timing g_display_timing[DISPLAY_TIMING_MAX];
static int g_display_timing_count = 0;
static pthread_mutex_t g_display_timing_lock = PTHREAD_MUTEX_INITIALIZER;

static void display_timing_populate_locked(void)
{
    g_display_timing_count = 0;
    uint32_t display_count = 0;
    CGDirectDisplayID display_list[DISPLAY_TIMING_MAX] = {0};
    if (CGGetActiveDisplayList(DISPLAY_TIMING_MAX, display_list, &display_count) != kCGErrorSuccess) return;
    if (display_count > DISPLAY_TIMING_MAX) display_count = DISPLAY_TIMING_MAX;
    for (uint32_t i = 0; i < display_count; ++i) {
        struct display_timing *e = &g_display_timing[g_display_timing_count++];
        e->did = display_list[i];
        double hz = 0.0;
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display_list[i]);
        if (mode) { hz = CGDisplayModeGetRefreshRate(mode); CGDisplayModeRelease(mode); }
        if (hz <= 0.0) hz = 60.0;   // built-in panels report 0 via CG -> engine-safe default
        e->refresh_rate_hz     = hz;
        e->refresh_interval_ns = (uint64_t)(1000000000.0 / hz);
        e->is_promotion        = (hz > 60.0);
        e->is_vrr              = false;
        e->valid               = true;
    }
}

void display_timing_table_init(void)
{
    pthread_mutex_lock(&g_display_timing_lock);
    display_timing_populate_locked();
    pthread_mutex_unlock(&g_display_timing_lock);
}

void display_timing_table_refresh_if_needed(void) { display_timing_table_init(); }
void display_timing_table_refresh_force(void)     { display_timing_table_init(); }

struct display_timing *display_timing_get(uint32_t did)
{
    pthread_mutex_lock(&g_display_timing_lock);
    if (g_display_timing_count == 0) display_timing_populate_locked();
    struct display_timing *result = NULL;
    for (int i = 0; i < g_display_timing_count; ++i) {
        if (g_display_timing[i].did == did) { result = &g_display_timing[i]; break; }
    }
    pthread_mutex_unlock(&g_display_timing_lock);
    return result;
}

struct display_timing *display_timing_get_all(int *out_count)
{
    pthread_mutex_lock(&g_display_timing_lock);
    if (g_display_timing_count == 0) display_timing_populate_locked();
    if (out_count) *out_count = g_display_timing_count;
    struct display_timing *result = g_display_timing;
    pthread_mutex_unlock(&g_display_timing_lock);
    return result;
}

bool display_is_animating(uint32_t did)
{
    CFStringRef uuid = display_uuid(did);
    if (!uuid) return false;

    bool animating = SLSManagedDisplayIsAnimating(g_connection, uuid);
    CFRelease(uuid);

    return animating;
}
