extern struct window_manager g_window_manager;
extern int g_connection;

static TABLE_HASH_FUNC(hash_view)
{
    return *(uint64_t *) key;
}

static TABLE_COMPARE_FUNC(compare_view)
{
    return *(uint64_t *) key_a == *(uint64_t *) key_b;
}

bool space_manager_query_space(FILE *rsp, uint64_t sid, uint64_t flags)
{
    TIME_FUNCTION;

    struct view *view = space_manager_query_view(&g_space_manager, sid);
    if (!view) return false;

    view_serialize(rsp, view, flags);
    fprintf(rsp, "\n");
    return true;
}

bool space_manager_query_spaces_for_window(FILE *rsp, struct window *window, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count;
    uint64_t *space_list = window_space_list(window->id, &space_count);
    if (!space_list) return false;

    fprintf(rsp, "[");
    for (int i = 0; i < space_count; ++i) {
        struct view *view = space_manager_query_view(&g_space_manager, space_list[i]);
        if (!view) continue;

        view_serialize(rsp, view, flags);
        fprintf(rsp, "%c", i < space_count - 1 ? ',' : ']');
    }
    fprintf(rsp, "\n");

    return true;
}

bool space_manager_query_spaces_for_display(FILE *rsp, uint32_t did, uint64_t flags)
{
    TIME_FUNCTION;

    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return false;

    fprintf(rsp, "[");
    for (int i = 0; i < space_count; ++i) {
        struct view *view = space_manager_query_view(&g_space_manager, space_list[i]);
        if (!view) continue;

        view_serialize(rsp, view, flags);
        fprintf(rsp, "%c", i < space_count - 1 ? ',' : ']');
    }
    fprintf(rsp, "\n");

    return true;
}

bool space_manager_query_spaces_for_displays(FILE *rsp, uint64_t flags)
{
    TIME_FUNCTION;

    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return false;

    fprintf(rsp, "[");
    for (int i = 0; i < display_count; ++i) {
        int space_count;
        uint64_t *space_list = display_space_list(display_list[i], &space_count);
        if (!space_list) continue;

        for (int j = 0; j < space_count; ++j) {
            struct view *view = space_manager_query_view(&g_space_manager, space_list[j]);
            if (!view) continue;

            view_serialize(rsp, view, flags);
            if (j < space_count - 1) fprintf(rsp, ",");
        }

        fprintf(rsp, "%c", i < display_count - 1 ? ',' : ']');
    }
    fprintf(rsp, "\n");

    return true;
}

struct view *space_manager_query_view(struct space_manager *sm, uint64_t sid)
{
    if (sm->did_begin) return space_manager_find_view(sm, sid);
    return table_find(&sm->view, &sid);
}

struct view *space_manager_find_view(struct space_manager *sm, uint64_t sid)
{
    struct view *view = table_find(&sm->view, &sid);
    if (!view) {
        view = view_create(sid);
        table_add(&sm->view, &sid, view);
    }
    return view;
}

void space_manager_refresh_view(struct space_manager *sm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return;

    view_update(view);
    view_flush(view);
}

void space_manager_mark_view_invalid(struct space_manager *sm,  uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return;

    view_clear_flag(view, VIEW_IS_VALID);
}

void space_manager_untile_window(struct view *view, struct window *window)
{
    if (view->layout == VIEW_FLOAT) return;

    window_manager_adjust_layer(window, LAYER_NORMAL);
    struct window_node *node = view_remove_window_node(view, window);
    if (!node) return;

    if (space_is_visible(view->sid)) {
        window_node_flush(node);
    } else {
        view_set_flag(view, VIEW_IS_DIRTY);
    }
}

struct space_label *space_manager_get_label_for_space(struct space_manager *sm, uint64_t sid)
{
    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (space_label->sid == sid) {
            return space_label;
        }
    }

    return NULL;
}

struct space_label *space_manager_get_space_for_label(struct space_manager *sm, char *label)
{
    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (string_equals(label, space_label->label)) {
            return space_label;
        }
    }

    return NULL;
}

bool space_manager_remove_label_for_space(struct space_manager *sm, uint64_t sid)
{
    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (space_label->sid == sid) {
            free(space_label->label);
            buf_del(sm->labels, i);
            return true;
        }
    }

    return false;
}

void space_manager_set_label_for_space(struct space_manager *sm, uint64_t sid, char *label)
{
    space_manager_remove_label_for_space(sm, sid);

    for (int i = 0; i < buf_len(sm->labels); ++i) {
        struct space_label *space_label = &sm->labels[i];
        if (string_equals(space_label->label, label)) {
            free(space_label->label);
            buf_del(sm->labels, i);
            break;
        }
    }

    buf_push(sm->labels, ((struct space_label) {
        .sid   = sid,
        .label = label
    }));
}

void space_manager_set_layout_for_space(struct space_manager *sm, uint64_t sid, enum view_type layout)
{
    struct view *view = space_manager_find_view(sm, sid);
    view->layout = layout;
    view_clear(view);

    if (view->layout != VIEW_FLOAT) {
        window_manager_validate_and_check_for_windows_on_space(sm, &g_window_manager, sid);
    }
}

bool space_manager_set_gap_for_space(struct space_manager *sm, uint64_t sid, int type, int gap)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (type == TYPE_ABS) {
        view->window_gap = gap;
    } else if (type == TYPE_REL) {
        view->window_gap = add_and_clamp_to_zero(view->window_gap, gap);
    }

    view_update(view);
    view_flush(view);

    return true;
}

bool space_manager_toggle_gap_for_space(struct space_manager *sm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (view_check_flag(view, VIEW_ENABLE_GAP)) {
        view_clear_flag(view, VIEW_ENABLE_GAP);
    } else {
        view_set_flag(view, VIEW_ENABLE_GAP);
    }

    view_update(view);
    view_flush(view);

    return true;
}

void space_manager_toggle_mission_control(uint64_t sid, bool thumbnails_enabled)
{
    static CGPoint saved_mouse_position = {0, 0};
    bool is_in_mc = mission_control_is_active();

    if (!is_in_mc) {
        if (thumbnails_enabled) {
            // Reveal the spaces thumbnail strip: store the cursor, nudge it to
            // the top-center of the active display as Mission Control opens (which
            // expands the strip), then restore it.
            CGEventRef event = CGEventCreate(NULL);
            saved_mouse_position = CGEventGetLocation(event);
            CFRelease(event);

            CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);

            uint32_t did = display_manager_active_display_id();
            CGRect bounds = CGDisplayBounds(did);
            CGPoint top_center = {
                .x = bounds.origin.x + bounds.size.width / 2,
                .y = bounds.origin.y + 20
            };
            CGWarpMouseCursorPosition(top_center);

            usleep(10000);
            CGWarpMouseCursorPosition(saved_mouse_position);
        } else {
            // Activate Mission Control without revealing the thumbnail strip.
            CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
        }
    } else {
        CoreDockSendNotification(CFSTR("com.apple.expose.awake"), 0);
        space_manager_focus_space(sid);
    }
}

void space_manager_toggle_show_desktop(uint64_t sid)
{
    space_manager_focus_space(sid);
    CoreDockSendNotification(CFSTR("com.apple.showdesktop.awake"), 0);
}

void space_manager_set_layout_for_all_spaces(struct space_manager *sm, enum view_type layout)
{
    sm->layout = layout;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_LAYOUT)) {
            if (space_is_user(view->sid)) {
                view->layout = layout;
                view_clear(view);

                if (view->layout != VIEW_FLOAT) {
                    window_manager_validate_and_check_for_windows_on_space(sm, &g_window_manager, view->sid);
                }
            }
        }
    })
}

void space_manager_set_window_gap_for_all_spaces(struct space_manager *sm, int window_gap)
{
    sm->window_gap = window_gap;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_WINDOW_GAP)) {
            view->window_gap = window_gap;
            view_update(view);
            view_flush(view);
        }
    })
}

void space_manager_set_top_padding_for_all_spaces(struct space_manager *sm, int top_padding)
{
    sm->top_padding = top_padding;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_TOP_PADDING)) {
            view->top_padding = top_padding;
            view_update(view);
            view_flush(view);
        }
    })
}

void space_manager_set_bottom_padding_for_all_spaces(struct space_manager *sm, int bottom_padding)
{
    sm->bottom_padding = bottom_padding;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_BOTTOM_PADDING)) {
            view->bottom_padding = bottom_padding;
            view_update(view);
            view_flush(view);
        }
    })
}

void space_manager_set_left_padding_for_all_spaces(struct space_manager *sm, int left_padding)
{
    sm->left_padding = left_padding;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_LEFT_PADDING)) {
            view->left_padding = left_padding;
            view_update(view);
            view_flush(view);
        }
    })
}

void space_manager_set_right_padding_for_all_spaces(struct space_manager *sm, int right_padding)
{
    sm->right_padding = right_padding;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_RIGHT_PADDING)) {
            view->right_padding = right_padding;
            view_update(view);
            view_flush(view);
        }
    })
}

void space_manager_set_split_type_for_all_spaces(struct space_manager *sm, enum window_node_split split_type)
{
    sm->split_type = split_type;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_SPLIT_TYPE)) {
            view->split_type = split_type;
        }
    })
}

void space_manager_set_auto_balance_for_all_spaces(struct space_manager *sm, uint32_t auto_balance)
{
    sm->auto_balance = auto_balance;
    table_for (struct view *view, sm->view, {
        if (!view_check_flag(view, VIEW_AUTO_BALANCE)) {
            view->auto_balance = auto_balance;
        }
    })
}

bool space_manager_set_padding_for_space(struct space_manager *sm, uint64_t sid, int type, int top, int bottom, int left, int right)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (type == TYPE_ABS) {
        view->top_padding    = top;
        view->bottom_padding = bottom;
        view->left_padding   = left;
        view->right_padding  = right;
    } else if (type == TYPE_REL) {
        view->top_padding    = add_and_clamp_to_zero(view->top_padding, top);
        view->bottom_padding = add_and_clamp_to_zero(view->bottom_padding, bottom);
        view->left_padding   = add_and_clamp_to_zero(view->left_padding, left);
        view->right_padding  = add_and_clamp_to_zero(view->right_padding, right);
    }

    view_update(view);
    view_flush(view);

    return true;
}

bool space_manager_toggle_padding_for_space(struct space_manager *sm, uint64_t sid)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return false;

    if (view_check_flag(view, VIEW_ENABLE_PADDING)) {
        view_clear_flag(view, VIEW_ENABLE_PADDING);
    } else {
        view_set_flag(view, VIEW_ENABLE_PADDING);
    }

    view_update(view);
    view_flush(view);

    return true;
}

bool space_manager_rotate_space(struct space_manager *sm, uint64_t sid, int degrees)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout != VIEW_BSP) return false;

    window_node_rotate(view->root, degrees);
    view_update(view);
    view_flush(view);

    return true;
}

bool space_manager_mirror_space(struct space_manager *sm, uint64_t sid, enum window_node_split axis)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout != VIEW_BSP) return false;

    window_node_mirror(view->root, axis);
    view_update(view);
    view_flush(view);

    return true;
}

bool space_manager_equalize_space(struct space_manager *sm, uint64_t sid, uint32_t axis_flag)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout != VIEW_BSP) return false;

    window_node_equalize(view->root, axis_flag);
    view_update(view);
    view_flush(view);

    return true;
}

bool space_manager_balance_space(struct space_manager *sm, uint64_t sid, uint32_t axis_flag)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout != VIEW_BSP) return false;

    window_node_balance(view->root, axis_flag);
    view_update(view);
    view_flush(view);

    return true;
}

struct view *space_manager_tile_window_on_space_with_insertion_point(struct space_manager *sm, struct window *window, uint64_t sid, uint32_t insertion_point)
{
    struct view *view = space_manager_find_view(sm, sid);
    if (view->layout == VIEW_FLOAT) return view;

    window_manager_adjust_layer(window, LAYER_BELOW);
    struct window_node *node = view_add_window_node_with_insertion_point(view, window, insertion_point);
    assert(node);

    if (space_is_visible(view->sid)) {
        window_node_flush(node);
    } else {
        view_set_flag(view, VIEW_IS_DIRTY);
    }

    return view;
}

struct view *space_manager_tile_window_on_space(struct space_manager *sm, struct window *window, uint64_t sid)
{
    return space_manager_tile_window_on_space_with_insertion_point(sm, window, sid, 0);
}

void space_manager_toggle_window_split(struct space_manager *sm, struct window *window)
{
    struct view *view = space_manager_find_view(sm, window_space(window->id));
    if (view->layout != VIEW_BSP) return;

    struct window_node *node = view_find_window_node(view, window->id);
    if (node && window_node_is_intermediate(node)) {
        node->parent->split = node->parent->split == SPLIT_Y ? SPLIT_X : SPLIT_Y;

        if (view->auto_balance != SPLIT_NONE) {
            window_node_balance(view->root, view->auto_balance);
            view_update(view);
            view_flush(view);
        } else {
            window_node_update(view, node->parent);
            if (space_is_visible(view->sid)) {
                window_node_flush(node->parent);
            } else {
                view_set_flag(view, VIEW_IS_DIRTY);
            }
        }
    }
}

int space_manager_mission_control_index(uint64_t sid)
{
    uint64_t result = 0;
    int desktop_cnt = 1;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) return 0;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        int spaces_count = CFArrayGetCount(spaces_ref);

        for (int j = 0; j < spaces_count; ++j) {
            CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
            CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
            CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &result);
            if (sid == result) goto out;

            ++desktop_cnt;
        }
    }

    desktop_cnt = 0;
out:
    CFRelease(display_spaces_ref);
    return desktop_cnt;
}

uint64_t space_manager_mission_control_space(int desktop_id)
{
    uint64_t result = 0;
    int desktop_cnt = 1;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) return 0;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        int spaces_count = CFArrayGetCount(spaces_ref);

        for (int j = 0; j < spaces_count; ++j) {
            CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
            CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
            CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &result);
            if (desktop_cnt == desktop_id) goto out;

            ++desktop_cnt;
        }
    }

    result = 0;
out:
    CFRelease(display_spaces_ref);
    return result;
}

uint64_t space_manager_cursor_space(void)
{
    uint32_t did = display_manager_cursor_display_id();
    return display_space_id(did);
}

uint64_t space_manager_prev_space(uint64_t sid)
{
    uint64_t p_sid = 0;
    uint64_t n_sid = 0;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) return 0;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        int spaces_count = CFArrayGetCount(spaces_ref);

        for (int j = 0; j < spaces_count; ++j) {
            CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
            CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
            CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &n_sid);
            if (n_sid == sid) goto out;

            p_sid = n_sid;
        }
    }

out:
    CFRelease(display_spaces_ref);
    return p_sid != sid ? p_sid : 0;
}

uint64_t space_manager_next_space(uint64_t sid)
{
    uint64_t n_sid = 0;
    bool found_sid = false;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) return 0;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    for (int i = 0; i < display_spaces_count; ++i) {
        CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, i);
        CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
        int spaces_count = CFArrayGetCount(spaces_ref);

        for (int j = 0; j < spaces_count; ++j) {
            CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, j);
            CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
            CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &n_sid);
            if (found_sid) goto out;

            found_sid = n_sid == sid;
        }
    }

out:
    CFRelease(display_spaces_ref);
    return n_sid != sid ? n_sid : 0;
}

uint64_t space_manager_first_space(void)
{
    uint64_t sid = 0;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) return 0;

    CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, 0);
    CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));

    CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, 0);
    CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
    CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &sid);

    CFRelease(display_spaces_ref);
    return sid;
}

uint64_t space_manager_last_space(void)
{
    uint64_t sid = 0;

    CFArrayRef display_spaces_ref = SLSCopyManagedDisplaySpaces(g_connection);
    if (!display_spaces_ref) return 0;

    int display_spaces_count = CFArrayGetCount(display_spaces_ref);
    CFDictionaryRef display_ref = CFArrayGetValueAtIndex(display_spaces_ref, display_spaces_count-1);
    CFArrayRef spaces_ref = CFDictionaryGetValue(display_ref, CFSTR("Spaces"));
    int spaces_count = CFArrayGetCount(spaces_ref);

    CFDictionaryRef space_ref = CFArrayGetValueAtIndex(spaces_ref, spaces_count-1);
    CFNumberRef sid_ref = CFDictionaryGetValue(space_ref, CFSTR("id64"));
    CFNumberGetValue(sid_ref, CFNumberGetType(sid_ref), &sid);

    CFRelease(display_spaces_ref);
    return sid;
}

uint64_t space_manager_active_space(void)
{
    uint32_t did = 0;
    struct window *window = window_manager_focused_window(&g_window_manager);

    if (window) did = window_display_id(window->id);
    if (!did)   did = display_manager_active_display_id();
    if (!did)   return 0;

    return display_space_id(did);
}

void space_manager_move_window_list_to_space(uint64_t sid, uint32_t *window_list, int window_count)
{
    if (SLSPerformAsynchronousBridgedWindowManagementOperation) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(window_list, sizeof(uint32_t), window_count, kCFNumberSInt32Type);
        Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        SEL sel = sel_registerName("initWithWindows:spaceID:");
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], sel, (__bridge id)window_list_ref, sid);
        SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
        [operation release];
        CFRelease(window_list_ref);
    } else if (!workspace_use_macos_space_workaround()) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(window_list, sizeof(uint32_t), window_count, kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);
    } else if (!scripting_addition_move_window_list_to_space(sid, window_list, window_count)) {
        SLSSpaceSetCompatID(g_connection, sid, 0x79616265);
        SLSSetWindowListWorkspace(g_connection, window_list, window_count, 0x79616265);
        SLSSpaceSetCompatID(g_connection, sid, 0x0);
    }
}

void space_manager_move_window_to_space(uint64_t sid, struct window *window)
{
    if (SLSPerformAsynchronousBridgedWindowManagementOperation) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&window->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
        SEL sel = sel_registerName("initWithWindows:spaceID:");
        id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)([cls alloc], sel, (__bridge id)window_list_ref, sid);
        SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
        [operation release];
        CFRelease(window_list_ref);
    } else if (!workspace_use_macos_space_workaround()) {
        CFArrayRef window_list_ref = cfarray_of_cfnumbers(&window->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
        SLSMoveWindowsToManagedSpace(g_connection, window_list_ref, sid);
        CFRelease(window_list_ref);
    } else if (!scripting_addition_move_window_to_space(sid, window->id)) {
        SLSSpaceSetCompatID(g_connection, sid, 0x79616265);
        SLSSetWindowListWorkspace(g_connection, &window->id, 1, 0x79616265);
        SLSSpaceSetCompatID(g_connection, sid, 0x0);
    }
}

static inline uint64_t space_manager_find_first_user_space_for_display(uint32_t did)
{
    int count;
    uint64_t *space_list = display_space_list(did, &count);
    if (!space_list) return 0;

    for (int i = 0; i < count; ++i) {
        uint64_t sid = space_list[i];

        if (space_is_user(sid)) {
            return sid;
        }
    }

    return 0;
}

static inline bool space_manager_is_space_last_user_space(uint64_t sid)
{
    bool result = true;

    int count;
    uint64_t *space_list = display_space_list(space_display_id(sid), &count);
    if (!space_list) return true;

    for (int i = 0; i < count; ++i) {
        uint64_t c_sid = space_list[i];
        if (sid == c_sid) continue;

        if (space_is_user(c_sid)) {
            result = false;
            break;
        }
    }

    return result;
}

static enum space_op_error space_manager_swap_space_with_space_on_display(uint32_t a_did, uint64_t a_sid, uint32_t b_did, uint64_t b_sid)
{
    if (display_manager_display_is_animating(a_did)) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;
    if (display_manager_display_is_animating(b_did)) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    float window_animation_duration = g_window_manager.window_animation_duration;
    g_window_manager.window_animation_duration = 0.0f;
    __asm__ __volatile__ ("" ::: "memory");

    int a_window_list_count = 0;
    uint32_t *a_window_list = space_window_list(a_sid, &a_window_list_count, true);

    int b_window_list_count = 0;
    uint32_t *b_window_list = space_window_list(b_sid, &b_window_list_count, true);

    struct view *a_view = table_find(&g_space_manager.view, &a_sid);
    struct view *b_view = table_find(&g_space_manager.view, &b_sid);

    table_remove(&g_space_manager.view, &a_sid);
    table_remove(&g_space_manager.view, &b_sid);

    a_view->sid = b_sid;
    b_view->sid = a_sid;

    CFStringRef tmp = a_view->uuid;
    a_view->uuid    = b_view->uuid;
    b_view->uuid    = tmp;

    table_add(&g_space_manager.view, &a_sid, b_view);
    table_add(&g_space_manager.view, &b_sid, a_view);

    if (a_window_list_count) {
        space_manager_move_window_list_to_space(b_sid, a_window_list, a_window_list_count);
    }

    if (b_window_list_count) {
        space_manager_move_window_list_to_space(a_sid, b_window_list, b_window_list_count);
    }

    for (int i = 0; i < buf_len(g_space_manager.labels); ++i) {
        struct space_label *label = &g_space_manager.labels[i];
        if      (label->sid == a_sid) label->sid = b_sid;
        else if (label->sid == b_sid) label->sid = a_sid;
    }

    view_update(a_view);
    view_update(b_view);

    view_flush(a_view);
    view_flush(b_view);

    __asm__ __volatile__ ("" ::: "memory");
    g_window_manager.window_animation_duration = window_animation_duration;
    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_swap_space_with_space(uint64_t acting_sid, uint64_t selector_sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint32_t acting_did = space_display_id(acting_sid);
    uint32_t selector_did = space_display_id(selector_sid);

    if (acting_sid == selector_sid) return SPACE_OP_ERROR_SAME_SPACE;
    if (acting_did != selector_did) return space_manager_swap_space_with_space_on_display(acting_did, acting_sid, selector_did, selector_sid);

    bool is_animating = display_manager_display_is_animating(acting_did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint64_t acting_prev_sid = space_manager_prev_space(acting_sid);
    uint64_t selector_prev_sid = space_manager_prev_space(selector_sid);

    uint32_t acting_prev_did = acting_prev_sid ? space_display_id(acting_prev_sid) : 0;
    uint32_t selector_prev_did = selector_prev_sid ? space_display_id(selector_prev_sid) : 0;

    bool acting_sid_is_first = !acting_prev_sid || acting_prev_did != acting_did;
    bool selector_sid_is_first = !selector_prev_sid || selector_prev_did != selector_did;

    int acting_mci = space_manager_mission_control_index(acting_sid);
    int selector_mci = space_manager_mission_control_index(selector_sid);
    bool success = true;

    if (acting_sid_is_first && !selector_sid_is_first && selector_mci - acting_mci == 1) {
        success = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
    } else if (!acting_sid_is_first && selector_sid_is_first && acting_mci - selector_mci == 1) {
        success = scripting_addition_move_space_after_space(selector_sid, acting_sid, selector_sid == space_manager_active_space());
    } else if (acting_sid_is_first && !selector_sid_is_first) {
        success  = scripting_addition_move_space_after_space(selector_sid, acting_sid, false);
        success &= scripting_addition_move_space_after_space(acting_sid, selector_prev_sid, acting_sid == space_manager_active_space());
    } else if (!acting_sid_is_first && selector_sid_is_first) {
        success  = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
        success &= scripting_addition_move_space_after_space(selector_sid, acting_prev_sid, false);
    } else if (!acting_sid_is_first && !selector_sid_is_first) {
        if (acting_mci > selector_mci) {
            success  = scripting_addition_move_space_after_space(selector_sid, acting_sid, false);
            success &= scripting_addition_move_space_after_space(acting_sid, selector_prev_sid, acting_sid == space_manager_active_space());
        } else {
            success  = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
            success &= scripting_addition_move_space_after_space(selector_sid, acting_prev_sid, false);
        }
    }

    if (!success) return SPACE_OP_ERROR_SCRIPTING_ADDITION;
    space_manager_dock_rebuild_strip();   // rebuild the MC strip after the byte-pattern-free reorder
    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_move_space_to_space(uint64_t acting_sid, uint64_t selector_sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint32_t acting_did = space_display_id(acting_sid);
    uint32_t selector_did = space_display_id(selector_sid);

    if (acting_sid == selector_sid) return SPACE_OP_ERROR_SAME_SPACE;
    if (acting_did != selector_did) return SPACE_OP_ERROR_SAME_DISPLAY;

    bool is_animating = display_manager_display_is_animating(acting_did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint64_t acting_prev_sid = space_manager_prev_space(acting_sid);
    uint64_t selector_prev_sid = space_manager_prev_space(selector_sid);

    uint32_t acting_prev_did = acting_prev_sid ? space_display_id(acting_prev_sid) : 0;
    uint32_t selector_prev_did = selector_prev_sid ? space_display_id(selector_prev_sid) : 0;

    bool acting_sid_is_first = !acting_prev_sid || acting_prev_did != acting_did;
    bool selector_sid_is_first = !selector_prev_sid || selector_prev_did != selector_did;
    bool success = true;

    if (acting_sid_is_first && !selector_sid_is_first) {
        success = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
    } else if (!acting_sid_is_first && selector_sid_is_first) {
        success  = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
        success &= scripting_addition_move_space_after_space(selector_sid, acting_sid, false);
    } else if (!acting_sid_is_first && !selector_sid_is_first) {
        if (space_manager_mission_control_index(acting_sid) > space_manager_mission_control_index(selector_sid)) {
            success = scripting_addition_move_space_after_space(acting_sid, selector_prev_sid, acting_sid == space_manager_active_space());
        } else {
            success = scripting_addition_move_space_after_space(acting_sid, selector_sid, acting_sid == space_manager_active_space());
        }
    }

    if (!success) return SPACE_OP_ERROR_SCRIPTING_ADDITION;
    space_manager_dock_rebuild_strip();   // rebuild the MC strip after the byte-pattern-free reorder
    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_move_space_to_display(struct space_manager *sm, uint64_t sid, uint32_t did)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;
    if (!sid)     return SPACE_OP_ERROR_MISSING_SRC;

    uint32_t s_did = space_display_id(sid);
    if (s_did == did) return SPACE_OP_ERROR_INVALID_DST;

    bool is_src_animating = display_manager_display_is_animating(s_did);
    if (is_src_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    bool last_space = space_manager_is_space_last_user_space(sid);
    if (last_space) return SPACE_OP_ERROR_INVALID_SRC;

    bool is_dst_animating = display_manager_display_is_animating(did);
    if (is_dst_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    uint64_t d_sid = display_space_id(did);
    if (!d_sid) return SPACE_OP_ERROR_MISSING_DST;

    bool focus_space = sid == space_manager_active_space();

    if (scripting_addition_move_space_to_display(sid, d_sid,  focus_space ? space_manager_prev_space(sid) : 0, focus_space ? 1 : 0)) {
        space_manager_mark_view_invalid(sm, sid);
        if (focus_space) {
            space_manager_focus_space(sid);
        }
        space_manager_dock_rebuild_strip();   // rebuild the MC strip after the byte-pattern-free cross-display move
        return SPACE_OP_ERROR_SUCCESS;
    }

    return SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool space_manager_focus_space_using_gesture(uint32_t new_did, uint64_t new_sid)
{
    int cur_index = space_manager_mission_control_index(display_space_id(new_did));
    int new_index = space_manager_mission_control_index(new_sid);

    int count = abs(new_index - cur_index);
    if (count == 0) {
        display_manager_focus_display(new_did, new_sid);
        return true;
    }

    CGPoint point = display_center(new_did);
    uint32_t cur_did = display_manager_cursor_display_id();

    bool focus_display = cur_did != new_did;
    if (focus_display) CGWarpMouseCursorPosition(point);

    //
    // NOTE(asmvik): MacOS does not have an API that allows for space activation.
    // However, we can synthesize a sequence of high velocity gestures to skip the
    // animation instead.
    //
    // :Attribution
    // https://github.com/jurplel/InstantSpaceSwitcher
    // https://github.com/thenickdude/wacom-driver-fix/blob/bdfda9a788934c88d09d31ea6a42664b9ba1471e/Readme.md
    // Technique first observed in practice, and reverse-engineered from, BetterTouchTool.
    //

    CGEventRef event_dock_control = CGEventCreate(NULL);
    if (!event_dock_control) return false;

    float sign = (new_index - cur_index) > 0 ? 1.0 : -1.0;
    CGEventSetIntegerValueField(event_dock_control, /* kCGSEventTypeField            */  55, /* kCGSEventDockControl       */ 30);
    CGEventSetIntegerValueField(event_dock_control, /* kCGEventGestureHIDType        */ 110, /* kIOHIDEventTypeDockSwipe   */ 23);
    CGEventSetIntegerValueField(event_dock_control, /* kCGEventGestureSwipeMotion    */ 123, /* kCGGestureMotionHorizontal */  1);
    CGEventSetDoubleValueField(event_dock_control,  /* kCGEventGestureSwipeProgress  */ 124, sign);
    CGEventSetDoubleValueField(event_dock_control,  /* kCGEventGestureSwipeVelocityX */ 129, sign * 9999.0);

    for (int i = 0; i < count; ++i) {
        CGEventSetIntegerValueField(event_dock_control, /* kCGEventGesturePhase */ 132, /* kCGSGesturePhaseBegan */ 1);
        CGEventPost(kCGSessionEventTap, event_dock_control);
        CGEventSetIntegerValueField(event_dock_control, /* kCGEventGesturePhase */ 132, /* kCGSGesturePhaseEnded */ 4);
        CGEventPost(kCGSessionEventTap, event_dock_control);
    }
    CFRelease(event_dock_control);

    if (focus_display) {
        display_manager_set_active_display_id(new_did);
        if (space_manager_active_space() != new_sid) {
            CGPostMouseEvent(point, false, 1, true);
            CGPostMouseEvent(point, false, 1, false);
        }
    }

    return true;
}
#pragma clang diagnostic pop

// --- Quick consecutive space-focus stacking (SPA-2) -------------------------
// Rapid `space --focus next/prev` must chain S1->S2->S3->... as one continuous
// slide-burst. The catch: while a slide is in flight the SLS-committed active
// space is FROZEN at the burst origin (the payload commits the switch only at
// the slide's midpoint), so relative nav can't walk from the live active space
// — it would re-resolve the SAME first hop every press. We track an OPTIMISTIC
// logical target instead and walk from it, sending each next hop straight
// through to the (interruptible) payload animator, which snaps the running slide
// to its end and retargets.
//
// NB: display_manager_display_is_animating() cannot gate "slide active" here —
// that SLS read is a constant false on modern macOS — so the slide is bracketed
// purely by this optimistic state: set at seed, cleared at commit (reconcile)
// or by the seed's teardown safety timer.
static uint64_t g_anim_logical_sid;    // in-flight slide's optimistic target
static uint64_t g_anim_origin_sid;     // its start space (committed or prior target)
static uint32_t g_anim_did;            // display the burst is scoped to
static uint64_t g_slide_animating_gen; // bumped per seed; gen-guards the teardown timer

// Slack past the nominal slide end before the teardown safety timer fires.
#define SPACE_ANIM_TIMER_TAIL_S 0.10

// Forward decl — definition lives further down this file.
static enum space_op_error space_manager_focus_space_ex(uint64_t sid, bool allow_animate);

// True while one of OUR slides is mid-flight on `did`.
static inline bool space_slide_active_on(uint32_t did)
{
    return g_anim_did == did && g_anim_logical_sid != 0;
}

// Walk cursor for relative/adjacency math during a burst: the last hop already
// queued (FIFO tail) if any, else the in-flight slide's optimistic target.
static inline uint64_t space_pending_cursor_sid(void)
{
    struct space_manager *sm = &g_space_manager;
    return sm->pending_focus_count > 0
         ? sm->pending_focus_fifo[sm->pending_focus_count - 1]
         : g_anim_logical_sid;
}

// True while hops are still queued for `did` — keeps presses "in the burst"
// during the one-frame gap after a hop commits (reconcile clears the optimistic
// target) but before the next slide seeds.
static inline bool space_pending_has_hops_for(uint32_t did)
{
    struct space_manager *sm = &g_space_manager;
    return sm->pending_focus_count > 0
        && space_display_id(sm->pending_focus_fifo[sm->pending_focus_count - 1]) == did;
}

static void space_pending_focus_push(uint64_t sid)
{
    struct space_manager *sm = &g_space_manager;
    if (sid == 0) return;
    // Drop a push identical to the current tail — it would be a zero-distance hop.
    if (sm->pending_focus_count > 0 &&
        sm->pending_focus_fifo[sm->pending_focus_count - 1] == sid) return;
    if (sm->pending_focus_count < SPACE_PENDING_FOCUS_CAP) {
        sm->pending_focus_fifo[sm->pending_focus_count++] = sid;
    } else {
        // Bounded — collapse the tail to latest-wins. The final landing target is
        // preserved; only the last queued hop may become a multi-space jump.
        sm->pending_focus_fifo[SPACE_PENDING_FOCUS_CAP - 1] = sid;
    }
}

static uint64_t space_pending_focus_pop(void)
{
    struct space_manager *sm = &g_space_manager;
    if (sm->pending_focus_count == 0) return 0;
    uint64_t sid = sm->pending_focus_fifo[0];
    for (int i = 1; i < sm->pending_focus_count; ++i) {
        sm->pending_focus_fifo[i - 1] = sm->pending_focus_fifo[i];
    }
    --sm->pending_focus_count;
    return sid;
}

// Called on every committed space change (SPACE_CHANGED). If the commit matches
// our optimistic target the burst landed -> clear. If it is neither the target
// nor the origin, an external/Mission-Control switch superseded us -> abort so
// the next press starts fresh. commit == origin is a mid-burst intermediate
// (the interruptible snap of the prior hop) -> leave state intact.
void space_manager_reconcile_optimistic_target(uint64_t committed_sid)
{
    if (g_anim_logical_sid == 0) return;
    if (committed_sid == g_anim_logical_sid) {
        g_anim_logical_sid = 0; g_anim_origin_sid = 0; g_anim_did = 0;
    } else if (committed_sid != g_anim_origin_sid) {
        g_anim_logical_sid = 0; g_anim_origin_sid = 0; g_anim_did = 0;
    }
}

// Space-slide seed. The vendored payload animator
// (osax/payload_inc/space_animation.inc.m) commits the active-space change at
// its own midpoint, so we DON'T call scripting_addition_focus_space here — we
// just hand it the geometry and let it slide. It is interruptible: a second
// seed snaps the in-flight slide to its end and retargets.
//
// out/in_active_stage = -1 (no per-stage thumbnail filtering); ring_wid is
// resolved from the destination's focused window (FR-9 geo-rider) when the
// ring is enabled, else 0. gap/menubar use conservative defaults; easing
// reuses the window-animation curve so one config lever governs both.
// direction: +1 toward the previous space, -1 toward the next (mirrors the
// caller's geometry).
static enum space_op_error space_manager_focus_space_animated(uint64_t out_sid,
                                                              uint64_t in_sid,
                                                              int direction)
{
    uint32_t did = space_display_id(out_sid);
    if (!did) return SPACE_OP_ERROR_INVALID_SRC;

    CGRect bounds = CGDisplayBounds(did);
    double width = bounds.size.width;
    if (width <= 0.0) return SPACE_OP_ERROR_INVALID_SRC;

    // Track the optimistic origin/target so rapid relative nav can walk from the
    // in-flight slide instead of the frozen committed space. On a retarget (a
    // seed while a slide is already active) out_sid is the prior hop's target
    // (the cursor); the payload snaps to it before starting this one, so the snap
    // commits out_sid -> reconcile sees committed==origin -> "in-progress", then
    // this hop's commit lands on in_sid==logical. See space_slide_active_on.
    g_anim_origin_sid  = out_sid;
    g_anim_did         = did;
    g_anim_logical_sid = in_sid;

    // Teardown safety net. Normally reconcile (SPACE_CHANGED) clears the
    // optimistic state at the slide's commit; if that commit is ever missed, drop
    // it here so a stale cursor can't wedge the burst path. gen-guarded so a newer
    // seed (which bumps the gen) invalidates this timer.
    uint64_t gen = ++g_slide_animating_gen;
    double hold_s = (double)g_window_manager.space_animation_duration + SPACE_ANIM_TIMER_TAIL_S;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(hold_s * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != g_slide_animating_gen) return;   // superseded by a newer slide
        if (g_anim_did == did) { g_anim_logical_sid = 0; g_anim_origin_sid = 0; g_anim_did = 0; }
        // FR-4: the slide reached its nominal end — close the transition window
        // and reveal the settled focus (a pending deferred fade owns the reveal
        // instead when focus_ring_fade is on).
        space_transition_finish();
    });

    // Ship the panel rate so the payload cross-fade rides this display's ca_clock
    // pump at its native cadence (60Hz fallback when timing is unknown).
    struct display_timing *dt = display_timing_get(did);
    float refresh_hz = (dt && dt->valid) ? (float)dt->refresh_rate_hz : 60.0f;

    // SPA fade lever (SPACE_FADE_* bitmask): master gate + independent per-side
    // control. Master off → 0 (pure slide). On → set the enabled sides so the
    // payload fades only the incoming (ENTER) and/or outgoing (EXIT) windows.
    uint8_t fade = 0;
    if (g_window_manager.space_animation_fade) {
        if (g_window_manager.space_animation_fade_exit)  fade |= SPACE_FADE_EXIT;
        if (g_window_manager.space_animation_fade_enter) fade |= SPACE_FADE_ENTER;
    }

    // FR-9 geo-rider: resolve the destination space's focused-window ring so the
    // payload parks a ring there and rides it IN with the entering windows (GEO
    // only; the focus_ring fade owns ALPHA). ring_wid==0 (ring disabled / dest
    // has no window) keeps the plain no-rider slide. MUST run on this (event)
    // thread — focus_ring_resolve_dest uses the single-thread ts_alloc arena.
    uint32_t ring_wid = 0; CGRect ring_rect = CGRectZero; float ring_radius = 0.0f;
    if (focus_ring_get_enabled()) {
        focus_ring_resolve_dest(in_sid, &ring_wid, &ring_rect, &ring_radius);
    }

    bool ok = scripting_addition_animate_space(out_sid, in_sid, (int32_t)direction,
                                               g_window_manager.space_animation_duration,
                                               width,
                                               0.0,        // gap
                                               (uint8_t)g_window_manager.space_animation_background,   // wallpaper rides the slide (off = static backdrop)
                                               0,          // animate_menubar
                                               did, refresh_hz,
                                               -1, -1,     // out/in active stage: no filtering
                                               (uint8_t)g_window_manager.window_animation_easing,
                                               fade,       // SPACE_FADE_* bitmask (enter/exit cross-fade)
                                               ring_wid,   // FR-9: focus-ring geo-rider dest (0 = none)
                                               (float)ring_rect.origin.x,    (float)ring_rect.origin.y,
                                               (float)ring_rect.size.width,  (float)ring_rect.size.height,
                                               ring_radius,
                                               // SPA-20 fullscreen-abyss levers — no config keys wired;
                                               // hardcoded defaults:
                                               1,          // fs_enabled
                                               0.0f,       // fs_scale: shrink to a point
                                               0,          // fs_easing: linear
                                               -1.0f,      // fs_duration: track the slide
                                               0.0f,       // fs_delay
                                               1,          // fs_fade
                                               g_window_manager.space_animation_enter_delay,  // slide stagger (s)
                                               g_window_manager.space_animation_exit_delay,
                                               g_window_manager.space_animation_fade_enter_delay,  // fade sub-timeline (s)
                                               g_window_manager.space_animation_fade_exit_delay,
                                               g_window_manager.space_animation_fade_enter_dur,
                                               g_window_manager.space_animation_fade_exit_dur);

    // FR-9: drive the focus ring across the slide — hide the outgoing space's
    // ring now, then park + fade the incoming space's ring on its focused
    // window. Gated on the ring master-enable ONLY — space_nav_observer_get_enabled()
    // is stubbed false here, so adding it to the gate would dead-code this path.
    // Only fire on a seeded slide (ok).
    if (ok && focus_ring_get_enabled()) {
        focus_ring_space_switch(out_sid, in_sid, /*animated=*/true);
        // FR-4: open the space-transition window for our own animated slide.
        // The space COMMITS while the payload slide is still playing, so the
        // recall's WINDOW_FOCUSED lands mid-slide and would paint a stationary
        // ring at the target's final frame; the gate suppresses those shows
        // until the finish (hold_s timer above) reveals the settled focus.
        space_transition_begin((int)((hold_s + 0.15) * 1000.0), did);
    }

    return ok ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

// Fixed duration (seconds) of the multi_display_edge_guard spring-back nudge.
#define MULTI_DISPLAY_EDGE_GUARD_DURATION_S 0.4f

// Edge-of-display guard nudge: translate the active space's content by (dx, dy)
// and spring back. Feedback for `space --focus next/prev` at a display boundary
// (the next/prev space lives on another display). Sends SA_OPCODE_SPACE_NUDGE to
// the payload (edge_guard.inc.m). Returns false if the SA call failed.
bool space_manager_multi_display_edge_guard(int dx, int dy)
{
    float dur_s = MULTI_DISPLAY_EDGE_GUARD_DURATION_S;

    uint64_t sid = space_manager_active_space();
    if (!sid) return false;

    uint32_t did = space_display_id(sid);
    struct display_timing *t = display_timing_get(did);
    double rate_hz = (t && t->valid) ? t->refresh_rate_hz : 60.0;

    uint32_t duration_ms = (uint32_t)(dur_s * 1000.0f);
    int steps = (int)((rate_hz * (double)duration_ms / 1000.0) + 10);
    if (steps < 12)  steps = 12;
    if (steps > 240) steps = 240;

    return scripting_addition_animate_edge_nudge(sid, dx, dy, duration_ms, (uint32_t)steps);
}

// Resolves which space a *defaulted* `space --focus` (prev/next) should act on,
// per the space_focus_target_display config gate. `default` (and any
// cursor-resolution failure) returns space_manager_active_space(). `mouse`
// always targets the display under the live cursor. `smart` targets the
// cursor's display only when the last focus change came from the mouse; a
// keyboard-driven focus keeps the active display.
uint64_t space_manager_focus_target_space(void)
{
    bool want_mouse =
        (g_window_manager.space_focus_target_display == SPACE_FOCUS_TARGET_DISPLAY_MOUSE) ||
        (g_window_manager.space_focus_target_display == SPACE_FOCUS_TARGET_DISPLAY_SMART &&
         g_window_manager.last_focus_method == FOCUS_METHOD_MOUSE);

    if (want_mouse) {
        CGEventRef event = CGEventCreate(NULL);
        CGPoint point = CGEventGetLocation(event);
        CFRelease(event);

        uint32_t did = display_manager_point_display_id(point);
        uint64_t sid = did ? display_space_id(did) : 0;
        if (sid) return sid;
    }

    return space_manager_active_space();
}

// Resolve `space --focus prev/next` with display-aware semantics. `dir` is +1
// (next) or -1 (prev). When the next/prev space is on the SAME display, focus
// it. At a display edge (no in-display target): when multi_display_edge_guard is
// on, nudge the active space back and stop (never cross displays); when off,
// fall through to stock behavior — focus the next/prev space even on another
// display. SUCCESS for guard-only outcomes (designed no-ops, not errors).
enum space_op_error space_manager_focus_relative_space(uint64_t from_sid, int dir)
{
    if (!from_sid || (dir != +1 && dir != -1)) return SPACE_OP_ERROR_INVALID_SRC;

    uint32_t from_did = space_display_id(from_sid);

    // Mid-slide burst: walk from the in-flight slide's optimistic target (the
    // committed space is frozen until settle) and SEND the next hop straight
    // through. The payload animator is interruptible — a mid-slide seed snaps the
    // running slide to its end and starts this one — so spamming flicks through
    // spaces in real time. No drain scheduled here: a slide is in flight and its
    // commit (or the next press) drives the chain. Runs on the event-loop thread,
    // so the FIFO needs no lock.
    if (space_slide_active_on(from_did) || space_pending_has_hops_for(from_did)) {
        uint64_t cursor = space_pending_cursor_sid();
        uint64_t next_logical = (dir > 0) ? space_manager_next_space(cursor)
                                          : space_manager_prev_space(cursor);
        if (!next_logical || space_display_id(next_logical) != from_did) {
            return SPACE_OP_ERROR_SUCCESS;   // edge clamp — no repeated nudge mid-burst
        }
        int geometric_dir = (dir > 0) ? -1 : +1;   // next=-1, prev=+1 (matches focus_space)
        return space_manager_focus_space_animated(cursor, next_logical, geometric_dir);
    }

    uint64_t mc_target = (dir > 0) ? space_manager_next_space(from_sid)
                                   : space_manager_prev_space(from_sid);

    // Same-display target → focus it.
    if (mc_target && space_display_id(mc_target) == from_did) {
        return space_manager_focus_space(mc_target);
    }

    // Edge of this display's spaces — no in-display target.
    if (g_window_manager.multi_display_edge_guard) {
        // ON: guard the boundary — nudge the active space back and stop.
        int nudge_distance = 100;
        int dx_nudge = (dir > 0) ? -nudge_distance : nudge_distance;  // content slides opposite to press
        space_manager_multi_display_edge_guard(dx_nudge, 0);
        return SPACE_OP_ERROR_SUCCESS;
    }

    // OFF: stock — walk to the next/prev space even across the display boundary.
    if (mc_target) return space_manager_focus_space(mc_target);
    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_focus_space(uint64_t sid)
{
    return space_manager_focus_space_ex(sid, true);
}

// allow_animate=false forces an INSTANT switch (no cross-fade) — used by the
// drain for fast intermediates (only the final landing animates).
static enum space_op_error space_manager_focus_space_ex(uint64_t sid, bool allow_animate)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint64_t cur_sid = space_manager_active_space();
    if (cur_sid == sid) return SPACE_OP_ERROR_SAME_SPACE;

    uint32_t cur_did = space_display_id(cur_sid);
    uint32_t new_did = space_display_id(sid);
    bool focus_display = cur_did != new_did;

    // Don't hard-reject mid-slide: if one of OUR slides is in flight on the
    // destination display, queue this absolute target on the bounded stack
    // rather than dropping it. The commit-driven drain seeds it off the running
    // slide's SPACE_CHANGED, continuing the chain. (No
    // display_manager_display_is_animating gate — that read is a constant false
    // on modern macOS; the optimistic-state gate is the real one.)
    if (space_slide_active_on(new_did)) {
        space_pending_focus_push(sid);
        return SPACE_OP_ERROR_SUCCESS;
    }

    // Animated adjacent same-display slide (opt-in via space_animation_duration).
    // On success the payload commits the space change itself, so we return
    // without the instant scripting_addition_focus_space below. Suppressed when
    // allow_animate is false (the drain's fast intermediates switch instantly).
    // Cross-display or non-adjacent targets, or an animator refusal, fall through
    // to the instant switch.
    if (allow_animate && g_window_manager.space_animation_duration > 0.0f && !focus_display) {
        int direction = 0;
        if (sid == space_manager_prev_space(cur_sid))      direction = +1;
        else if (sid == space_manager_next_space(cur_sid)) direction = -1;
        if (direction != 0) {
            enum space_op_error rc = space_manager_focus_space_animated(cur_sid, sid, direction);
            if (rc == SPACE_OP_ERROR_SUCCESS) return SPACE_OP_ERROR_SUCCESS;
        }
    }

    if (scripting_addition_focus_space(sid)) {
        if (focus_display) {
            display_manager_focus_display(new_did, sid);
        }
    } else {
        space_manager_focus_space_using_gesture(new_did, sid);
    }

    return SPACE_OP_ERROR_SUCCESS;
}

// Commit-driven drain — seeds the next queued hop as soon as the previous one
// commits (its real visual end), giving a continuous chain. Called from the
// SPACE_CHANGED handler on the event-loop thread (same thread as every push, so
// the FIFO is lock-free). No-op when empty.
void space_manager_drain_pending_focus(void)
{
    struct space_manager *sm = &g_space_manager;

    // Loop so a queued hop that turns out to be a no-op (already current -> no
    // SPACE_CHANGED to re-drive us) doesn't stall the rest.
    while (sm->pending_focus_count != 0) {
        uint64_t front = sm->pending_focus_fifo[0];
        uint32_t did   = space_display_id(front);

        // A real slide is still mid-flight -> leave the queue; its commit will
        // re-enter this drain and seed the next hop.
        if (did && space_slide_active_on(did)) return;

        space_pending_focus_pop();

        // Fast intermediates: if more hops are still queued behind this one, it's
        // an intermediate — switch INSTANTLY (no cross-fade); only the LAST hop
        // gets the full animated slide. Each instant switch still commits ->
        // SPACE_CHANGED re-enters this drain for the next hop.
        bool more = (sm->pending_focus_count != 0);
        enum space_op_error rc = space_manager_focus_space_ex(front, /*allow_animate=*/!more);

        // The hop that actually started a switch ends this pass — its commit
        // drives the next. Only keep looping past a no-op (already there), which
        // produces no commit to continue the chain.
        if (rc != SPACE_OP_ERROR_SAME_SPACE) return;
    }
}

enum space_op_error space_manager_switch_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    uint64_t cur_sid = space_manager_active_space();
    if (cur_sid == sid) return SPACE_OP_ERROR_SAME_SPACE;

    uint32_t cur_did = space_display_id(cur_sid);
    uint32_t did     = space_display_id(sid);

    bool is_src_animating = display_manager_display_is_animating(cur_did);
    if (is_src_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    bool is_dst_animating = display_manager_display_is_animating(did);
    if (is_dst_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    if (cur_did != did) {
        space_manager_swap_space_with_space_on_display(cur_did, cur_sid, did, sid);
        display_manager_focus_display(cur_did, cur_sid);
        return SPACE_OP_ERROR_SUCCESS;
    }

    return scripting_addition_focus_space(sid) ? SPACE_OP_ERROR_SUCCESS : SPACE_OP_ERROR_SCRIPTING_ADDITION;
}

// Rebuild Dock's Mission-Control strip after a byte-pattern-free server-side space op (create /
// move / destroy). Invokes the named @objc -[Spaces handleDisplayReconfig] in the SA payload — a
// NON-Mission-Control rebuild path that reaches Dock's per-display rebuild helper directly: no
// expose cycle, no flash, no residual MC scale nudge, and no transient 1327/1328 for yabai's own
// sls_event_handler to observe. handleDisplayReconfig rebuilds the strip unconditionally; its only
// internal gate defers while a space switch is mid-flight, and every caller already rejects
// MC-active (SPACE_OP_ERROR_IN_MISSION_CONTROL), so no guard is needed here.
void space_manager_dock_rebuild_strip(void)
{
    scripting_addition_spaces_reconfig();
}

enum space_op_error space_manager_destroy_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;

    if (!sid) return SPACE_OP_ERROR_MISSING_SRC;
    if (!space_is_user(sid)) return SPACE_OP_ERROR_INVALID_TYPE;
    if (space_manager_is_space_last_user_space(sid)) return SPACE_OP_ERROR_INVALID_SRC;

    uint32_t did = space_display_id(sid);

    bool is_animating = display_manager_display_is_animating(did);
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    // Destination for the doomed space's windows (and the display's fallback if sid is the
    // visible space): the first user space on sid's display that ISN'T sid. Guaranteed to
    // exist — we ruled out the last-user-space case above. (display_space_list is arena
    // memory; copy out the scalar dest_sid before the nested space_window_list arena call.)
    uint64_t dest_sid = 0;
    int display_space_count = 0;
    uint64_t *display_spaces = display_space_list(did, &display_space_count);
    if (display_spaces) {
        for (int i = 0; i < display_space_count; ++i) {
            if (display_spaces[i] != sid && space_is_user(display_spaces[i])) {
                dest_sid = display_spaces[i];
                break;
            }
        }
    }
    if (!dest_sid) return SPACE_OP_ERROR_INVALID_SRC;

    // SLSSpaceDestroy does NOT migrate windows (native Dock removeSpace does this itself before
    // tearing the space down). Move the doomed space's windows to dest_sid first so they aren't
    // orphaned onto a non-existent space. include_minimized=true so minimized windows assigned
    // to the space follow too.
    int window_count = 0;
    uint32_t *window_list = space_window_list(sid, &window_count, true);   // arena — do NOT free
    if (window_list && window_count > 0) {
        space_manager_move_window_list_to_space(dest_sid, window_list, window_count);
    }

    bool success = scripting_addition_destroy_space(sid, dest_sid);
    if (!success) return SPACE_OP_ERROR_SCRIPTING_ADDITION;

    window_manager_validate_and_check_for_windows_on_space(&g_space_manager, &g_window_manager, dest_sid);

    // The SA payload destroyed the space server-side (byte-pattern-free); rebuild the MC strip
    // via handleDisplayReconfig (non-MC path — no expose cycle).
    space_manager_dock_rebuild_strip();
    return SPACE_OP_ERROR_SUCCESS;
}

enum space_op_error space_manager_add_space(uint64_t sid)
{
    bool is_in_mc = mission_control_is_active();
    if (is_in_mc) return SPACE_OP_ERROR_IN_MISSION_CONTROL;
    if (!sid)     return SPACE_OP_ERROR_MISSING_SRC;

    bool is_animating = display_manager_display_is_animating(space_display_id(sid));
    if (is_animating) return SPACE_OP_ERROR_DISPLAY_IS_ANIMATING;

    if (!scripting_addition_create_space(sid)) return SPACE_OP_ERROR_SCRIPTING_ADDITION;

    // The SA payload created the space server-side + set the wallpaper dirty flag byte-pattern-free;
    // rebuild the MC strip via handleDisplayReconfig (non-MC path — no expose cycle).
    space_manager_dock_rebuild_strip();
    return SPACE_OP_ERROR_SUCCESS;
}

void space_manager_assign_process_to_space(pid_t pid, uint64_t sid)
{
    SLSProcessAssignToSpace(g_connection, pid, sid);
}

void space_manager_assign_process_to_all_spaces(pid_t pid)
{
    SLSProcessAssignToAllSpaces(g_connection, pid);
}

bool space_manager_is_window_on_active_space(struct window *window)
{
    uint64_t sid = space_manager_active_space();
    bool result = space_manager_is_window_on_space(sid, window);
    return result;
}

bool space_manager_is_window_on_space(uint64_t sid, struct window *window)
{
    int space_count;
    uint64_t *space_list = window_space_list(window->id, &space_count);
    if (!space_list) return false;

    for (int i = 0; i < space_count; ++i) {
        if (sid == space_list[i]) {
            return true;
        }
    }

    return false;
}

void space_manager_mark_spaces_invalid_for_display(struct space_manager *sm, uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return;

    uint64_t sid = display_space_id(did);
    for (int i = 0; i < space_count; ++i) {
        if (space_list[i] == sid) {
            space_manager_refresh_view(sm, sid);
        } else {
            space_manager_mark_view_invalid(sm, space_list[i]);
        }
    }
}

void space_manager_mark_spaces_invalid(struct space_manager *sm)
{
    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    for (int i = 0; i < display_count; ++i) {
        space_manager_mark_spaces_invalid_for_display(sm, display_list[i]);
    }
}

bool space_manager_refresh_application_windows(struct space_manager *sm)
{
    int refresh_count = buf_len(g_window_manager.applications_to_refresh);
    if (!refresh_count) return false;
    int window_count = g_window_manager.window.count;
    for (int i = 0; i < refresh_count; ++i) {
        struct application *application = g_window_manager.applications_to_refresh[i];
        debug("%s: %s has windows that are not yet resolved\n", __FUNCTION__, application->name);
        bool result = window_manager_add_existing_application_windows(sm, &g_window_manager, application, i);
        if (result) {
            --refresh_count;
            --i;
        }
    }
    return window_count != g_window_manager.window.count;
}

void space_manager_handle_display_add(struct space_manager *sm, uint32_t did)
{
    int space_count;
    uint64_t *space_list = display_space_list(did, &space_count);
    if (!space_list) return;

    int list_count = 0;
    struct view *view_list[sm->view.count];
    CFStringRef uuid_list[sm->view.count];

    table_for (struct view *view, sm->view, {
        view_list[list_count] = view;
        uuid_list[list_count] = view->uuid;
        ++list_count;
    })

    for (int i = 0; i < space_count; ++i) {
        uint64_t sid = space_list[i];
        CFStringRef uuid = SLSSpaceCopyName(g_connection, sid);
        if (!uuid) continue;

        for (int j = 0; j < list_count; ++j) {
            CFStringRef view_uuid = uuid_list[j];
            if (!view_uuid) continue;

            if (CFEqual(view_uuid, uuid)) {
                struct view *view = view_list[j];

                uuid_list[j] = NULL;
                view_list[j] = NULL;

                table_remove(&sm->view, &view->sid);
                CFRelease(view->uuid);

                struct space_label *label = space_manager_get_label_for_space(sm, view->sid);
                if (label) label->sid = sid;

                view->sid = sid;
                view->uuid = CFRetain(uuid);

                table_add(&sm->view, &sid, view);
                break;
            }
        }

        CFRelease(uuid);
    }

    sm->current_space_id = space_manager_active_space();
    sm->last_space_id = sm->current_space_id;
}

void space_manager_begin(struct space_manager *sm)
{
    sm->layout = VIEW_FLOAT;
    sm->split_ratio = 0.5f;
    sm->auto_balance = SPLIT_NONE;
    sm->split_type = SPLIT_AUTO;
    sm->window_placement = CHILD_SECOND;
    sm->window_insertion_point = INSERT_FOCUSED;
    sm->window_zoom_persist = true;
    sm->labels = NULL;
    sm->skip_window_focus_animation = false;
    sm->mission_control_thumbnails_enabled = false;
    table_init(&sm->view, 23, hash_view, compare_view);

    int display_count;
    uint32_t *display_list = display_manager_active_display_list(&display_count);
    if (!display_list) return;

    for (int i = 0; i < display_count; ++i) {
        int space_count;
        uint64_t *space_list = display_space_list(display_list[i], &space_count);
        if (!space_list) continue;

        for (int j = 0; j < space_count; ++j) {
            struct view *view = view_create(space_list[j]);
            table_add(&sm->view, &space_list[j], view);
        }
    }

    sm->current_space_id = space_manager_active_space();
    sm->last_space_id = sm->current_space_id;
    sm->did_begin = true;
}

uint32_t space_manager_preferred_focus_wid(uint64_t sid, const char **out_source, uint32_t *out_view_last)
{
    if (out_source)    *out_source = "none";
    if (out_view_last) *out_view_last = 0;
    if (!sid) return 0;

    struct view *view = space_manager_find_view(&g_space_manager, sid);

    // Priority 1: the space's own focus recall, mirroring the SPACE_CHANGED
    // handler so the ring parks where the post-commit recall will land focus.
    // Same guard as the recall: never nominate a minimized window (it still
    // reports its original space) or a hidden app's window.
    if (view && out_view_last) *out_view_last = view->last_focused_wid;
    if (view && view->last_focused_wid) {
        struct window *recall = window_manager_find_window(&g_window_manager, view->last_focused_wid);
        if (recall && window_space(recall->id) == sid
            && !window_check_flag(recall, WINDOW_MINIMIZE)
            && !recall->application->is_hidden) {
            if (out_source) *out_source = "view_last";
            return recall->id;
        }
    }

    // Priority 2: first yabai-tracked window in the space's rich-query z-order —
    // normal windows only (sticky/hidden/minimized excluded server-side), topmost
    // first, any process. Covers floats, which never enter the view's node tree,
    // and an overlay/sticky window can't win the park (mirrors the SPACE_CHANGED
    // focus fallback that lands focus here).
    struct window *topmost = window_manager_space_topmost_tracked_window(&g_window_manager, sid, 0);
    if (topmost) {
        if (out_source) *out_source = "space_query";
        return topmost->id;
    }
    return 0;
}
