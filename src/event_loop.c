extern struct event_loop g_event_loop;
extern struct process_manager g_process_manager;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern enum mission_control_mode g_mission_control_mode;
extern int g_connection;
extern void *g_workspace_context;
extern int g_layer_below_window_level;
volatile bool __pending_window_focus;

// Focus ring: window focused DURING Mission Control. Painting the ring at a
// scaled thumbnail-transform rect looks wrong, so the focus sink stashes the wid
// here (last-write-wins) instead of showing; MISSION_CONTROL_EXIT reveals it at
// the settled real rect. 0 = no focus changed during MC.
static uint32_t g_focus_ring_mc_deferred_wid = 0;
volatile bool __pending_gesture;
volatile uint64_t __last_gesture_time;
volatile uint64_t __last_cmd_tab_time;

static void update_window_notifications(void)
{
    int window_count = 0;
    uint32_t window_list[1024] = {0};

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        // NOTE(asmvik): Subscribe to all windows because of window_destroyed (and ordered) notifications
        table_for (struct window *window, g_window_manager.window, {
            window_list[window_count++] = window->id;
        })
    } else {
        // NOTE(asmvik): Subscribe to windows that have a feedback_border because of window_ordered notifications
        table_for (struct window_node *node, g_window_manager.insert_feedback, {
            window_list[window_count++] = node->window_order[0];
        })
    }

    // Native-tab wids (AX-hidden, SLS-only) aren't in g_window_manager.window, so the
    // loops above miss them. Re-include the tab set on every rebuild — a full-list
    // re-declare (replace semantics) would otherwise drop their subscription and tab
    // switches would go silent. Deduped vs tracked (belt-and-braces; the set is
    // untracked-only by construction) and bounds-guarded against the fixed array.
    table_for (void *tab_ptr, g_window_manager.tab_window, {
        if (window_count >= 1024) break;
        uint32_t tab_wid = (uint32_t)(uintptr_t) tab_ptr;
        if (window_manager_find_window(&g_window_manager, tab_wid)) continue;
        window_list[window_count++] = tab_wid;
    })

    SLSRequestNotificationsForWindows(g_connection, window_list, window_count);
}

// Space-transition gate (FR-4). While a yabai-driven animated slide is in
// flight, every wid-based ring show is suppressed at the single choke point in
// focus_ring.m: the space COMMITS server-side while the payload slide is still
// playing, so the recall's WINDOW_FOCUSED lands mid-slide — and a show there
// resolves the window's untransformed final frame (SLSGetScreenRectForWindow
// reads the frame, not the slide transform), painting a stationary ring while
// everything else is still moving. begin() sets the flag synchronously on the
// caller thread so the gate is live before the slide's first frame; finish()
// (the slide's nominal end) re-shows the settled focus unless the deferred
// space-switch fade owns the reveal. A gen-guarded fallback inside begin()
// clears the gate even when the slide's own finish never lands.
//
// Threading: `active` is written on the event-loop/SA threads and read from the
// focus-ring dispatch queue. A relaxed atomic bool is enough for a visual gate —
// a one-frame stale read at most, self-healing on the next event.
static struct {
    uint32_t gen;
    bool     active;
    uint32_t did;        // display the in-flight slide is on (0 = unknown -> gate all)
    uint64_t deadline;   // read_os_timer() tick past which active() self-expires
} g_space_transition;

bool space_transition_active(void)
{
    if (!__atomic_load_n(&g_space_transition.active, __ATOMIC_RELAXED)) return false;
    // Self-expiry backstop. The normal clear is a main-queue timer
    // (space_transition_finish from space_manager.c's teardown, or begin()'s
    // fallback). A retarget bumps g_slide_animating_gen and can orphan that
    // teardown; if the paired clear is ever missed, this cap stops the flag
    // latching true for the whole session and suppressing the ring globally.
    // The deadline is the slide's own visual end, so this never fires early.
    uint64_t deadline = __atomic_load_n(&g_space_transition.deadline, __ATOMIC_RELAXED);
    if (deadline && read_os_timer() > deadline) return false;
    return true;
}

// True when the in-flight slide is on `did`. A slide runs on ONE display, so a
// ring show for a window on a DIFFERENT display must not be gated by it. Pair
// with space_transition_active(); fails closed (gates) both directions when a
// display can't be resolved: sd==0 (stored slide display unknown) gates all
// displays, and did==0 (target window's display unknown, e.g. window_display_id
// resolved nothing mid-transition) is gated too rather than treated as "not on
// this display".
bool space_transition_on_display(uint32_t did)
{
    uint32_t sd = __atomic_load_n(&g_space_transition.did, __ATOMIC_RELAXED);
    return sd == 0 || did == 0 || sd == did;
}

static void space_transition_reshow(const char *source)
{
    extern bool focus_ring_deferred_fade_pending(void);
    if (focus_ring_deferred_fade_pending()) return;   // the deferred fade owns the reveal
    uint32_t wid = g_window_manager.focused_window_id;
    debug("space_transition %s: re-show wid=%u\n", source, wid);
    if (wid) focus_ring_show_for_wid_settled(wid);
}

void space_transition_begin(int expected_ms, uint32_t did)
{
    uint32_t gen = __atomic_add_fetch(&g_space_transition.gen, 1, __ATOMIC_RELAXED);
    int delay_ms = expected_ms > 0 ? expected_ms : 800;
    __atomic_store_n(&g_space_transition.did, did, __ATOMIC_RELAXED);
    __atomic_store_n(&g_space_transition.deadline,
                     read_os_timer() + (uint64_t)delay_ms * read_os_freq() / 1000,
                     __ATOMIC_RELAXED);
    // active last, so a concurrent active() reader that observes active=true
    // reads a coherent deadline (relaxed is fine for a visual gate).
    __atomic_store_n(&g_space_transition.active, true, __ATOMIC_RELAXED);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay_ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        if (gen != __atomic_load_n(&g_space_transition.gen, __ATOMIC_RELAXED)) return;
        __atomic_store_n(&g_space_transition.active, false, __ATOMIC_RELAXED);
        space_transition_reshow("fallback");
    });
}

void space_transition_finish(void)
{
    __atomic_add_fetch(&g_space_transition.gen, 1, __ATOMIC_RELAXED);   // cancel the pending fallback
    __atomic_store_n(&g_space_transition.active, false, __ATOMIC_RELAXED);
    space_transition_reshow("finish");
}

static void window_did_receive_focus(struct window_manager *wm, struct mouse_state *ms, struct window *window)
{
    struct window *focused_window = window_manager_find_window(wm, wm->focused_window_id);
    if (focused_window && focused_window != window && window_space(focused_window->id) == window_space(window->id)) {
        window_manager_set_window_opacity(wm, focused_window, g_window_manager.normal_window_opacity);
    }

    window_manager_set_window_opacity(wm, window, wm->active_window_opacity);

    // mouse-follows-focus dedupe keyed on last_centered_wid, NOT focused_window_id: a
    // settle stamp (window_manager_update_focused_window) can move
    // focused_window_id to this window BEFORE this funnel runs (deterministic on
    // new-window / deminimize, where an 815 settle pre-stamps), which a
    // focused_window_id-keyed gate would read as "no change" and skip the warp.
    // last_centered_wid is written only here, so the settle path can't suppress mff.
    if (wm->last_centered_wid != window->id) {
        if (ms->ffm_window_id != window->id) {
            window_manager_center_mouse(wm, window);
            wm->last_centered_wid = window->id;
        }
    }

    if (wm->focused_window_id != window->id) {
        wm->last_window_id = wm->focused_window_id;
    }

    wm->focused_window_id = window->id;
    wm->focused_window_psn = window->application->psn;
    // Authoritative focus-display anchor: refocus_ring resolves the ring on THIS
    // display's space. This funnel is the only place a real focus change lands
    // (click/AX/app-front-switch/ffm/space-recovery), so it is the right place
    // to stamp it (plus the MOUSE_DOWN geometry pre-stamp and the 805 crossing
    // re-anchor for the paths that reach here late or not at all).
    wm->focused_display_id = window_display_id(window->id);
    ms->ffm_window_id = 0;

    // Per-space focus recall: record this window as its space's last-focused so
    // SPACE_CHANGED can restore it on re-entry. Lives here (the common focus sink)
    // rather than only in EVENT_HANDLER(WINDOW_FOCUSED) so INTER-app focus — which
    // arrives via APPLICATION_FRONT_SWITCHED, not the AX FocusedWindowChanged that
    // only fires intra-app — records recall too (single-window apps never fire the
    // AX event). Resolve the window's own space so the write lands for floats (never
    // in the node tree) and single-window apps alike.
    uint64_t focus_sid = window_space(window->id);
    if (focus_sid) {
        struct view *focus_view = space_manager_find_view(&g_space_manager, focus_sid);
        if (focus_view) focus_view->last_focused_wid = window->id;
    }

    // Focus ring follows the focused window. Placed before the early returns
    // below so floating + unmanaged windows are covered too. The call no-ops
    // internally during a space switch so it doesn't fight a slide.
    // Verbose-gated at the call site too: the sid/did arguments are SLS queries
    // and must not run per focus event when nobody reads the log.
    if (g_verbose) {
        focus_ring_log("focus_event", "wid=%u app=%s frame=(%.0f,%.0f %.0fx%.0f) sid=%llu did=%u",
                       window->id,
                       window->application ? window->application->name : "?",
                       window->frame.origin.x, window->frame.origin.y,
                       window->frame.size.width, window->frame.size.height,
                       (unsigned long long) window_space(window->id),
                       window_display_id(window->id));
    }
    // During Mission Control the window is a scaled thumbnail transform; painting
    // the ring now lands it at that rect. Stash the wid (MISSION_CONTROL_EXIT
    // reveals it at the settled real rect) — the ring's alpha is already 0 from
    // focus_ring_mc_hide(), so nothing shows meanwhile.
    if (mission_control_is_active()) {
        g_focus_ring_mc_deferred_wid = window->id;
    } else {
        focus_ring_show_for_wid(window->id);
        // The payload's `visible` master-alpha slot defaults to 0 (hidden) on a fresh
        // SA load and only flips to 1 on a SET_VISIBLE opcode — after a `--load-sa`
        // every SHOW would stamp the ring transparent (drawn, ordered-in, but never
        // composites). Re-assert the current enable state on each focus so a fresh
        // payload self-heals.
        focus_ring_set_visible_async(focus_ring_get_enabled());
    }

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (!view) return;

    struct window_node *node = view_find_window_node(view, window->id);
    if (node->window_count <= 1) return;

    for (int i = 0; i < node->window_count; ++i) {
        if (node->window_order[i] != window->id) continue;

        memmove(node->window_order + 1, node->window_order, sizeof(uint32_t) * i);
        node->window_order[0] = window->id;

        break;
    }
}

// Focus-ring reconcile off an SLS focus-change signal (808 order-change, 815/816
// visibility settle).
// macOS carries the key-window identity in NO dedicated SLS event, and event payload wids
// are unreliable: a same-app multi-window / native-tab focus (e.g. a mouse click between two
// multi-tab Ghostty windows, where AX kAXFocusedWindowChangedNotification goes silent) emits
// a BURST of 808s — one per window whose z-index shifts — and most payloads are DEMOTED
// siblings, not the newly-focused window. So the payload wid is only a wake hint; the identity
// is re-resolved from the SLS KEY FOCUS (window_manager_space_key_focus_window: SLPS key PSN
// -> owner cid -> that owner's topmost NORMAL window on the space). Key focus is correct by
// construction where topmost-z is not: it returns 0 for the desktop / no-key case — the
// genuine "nothing focused" signal (topmost-z always names some background window) — and an
// overlay-panel steal (Raycast/Claude floating z-top while the app keeps key focus) resolves
// the KEY holder's window, not the overlay. Anchoring on focused_display_id (not the event
// window's own space) keeps the ring single-display: on a multi-display rig every display's
// current space passes space_is_visible, so a per-event-space resolve would let background churn
// on the OTHER display yank the ring off the focused window. Cross-display clicks stay covered by
// the MOUSE_DOWN geometry pre-stamp. Fallback before the first stamp: the global active space.
//
// `settled` marks the POST-SETTLE sites (815/816) apart from the pre-settle burst
// (808/created/deminimized): only settled sites act on a 0 resolve (hide the ring), because a
// transient 0 mid-burst — key app's cid not yet resolvable (app mid-launch/untracked) — must
// not blink the ring; the following 815 settles it. Ring-only: no focused_window_id / opacity
// / signal side effects. Idempotent with the async focus sink —
// focus_ring_show_for_wid's per-VBL coalesce + idempotent-rect skip dedupe the burst and any
// overlap with window_did_receive_focus.
static void refocus_ring(uint32_t wake_wid, bool settled)
{
    if (!wake_wid) return;
    // During Mission Control the key-focus process is Dock (unresolvable cid -> 0) and the ring
    // is owned by the MC hide/defer machinery (g_focus_ring_mc_deferred_wid); a resolve here
    // would stamp/hide against thumbnails.
    if (mission_control_is_active()) return;
    uint32_t did = g_window_manager.focused_display_id;
    // Mid-slide gate (mirrors the show-side gate in focus_ring.m): the outgoing space stays
    // space_is_visible until commit, so a mid-slide 815 resolved against it returns 0 (the new
    // key app's window is on the INCOMING space) and would hide the ring out from under the
    // SPA-21 exit-ride / strand space_transition_reshow. Fails closed per-display.
    if (space_transition_active() && space_transition_on_display(did)) return;
    uint64_t sid = did ? display_space_id(did) : SLSGetActiveSpace(g_connection);
    if (!sid || !space_is_visible(sid)) return;   // mid-transition/teardown -> skip
    // Settled sites (815/816) resolve through the stamping helper so focused_window_id
    // tracks real key focus through AX silence.
    // Burst sites (808/created/deminimized) use the raw resolver — they must NOT move the
    // tracked id (808 precedes AX; see window_manager_update_focused_window). Either way
    // exactly ONE resolve per event, and the ring keys off the returned wid.
    uint32_t wid = settled
                 ? window_manager_update_focused_window(&g_window_manager, sid)
                 : window_manager_space_key_focus_window(&g_window_manager, sid);
    if (wid) {
        focus_ring_show_for_wid(wid);
    } else if (settled) {
        // Pass the ring's committed target: focus_ring_hide_for_wid no-ops on 0 and only hides
        // a matching target, so the hide is race-safe against an in-flight show.
        focus_ring_hide_for_wid(focus_ring_get_target_wid(), "keyfocus-none");
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static EVENT_HANDLER(APPLICATION_LAUNCHED)
{
    struct process *process = context;

    if (__atomic_load_n(&process->terminated, __ATOMIC_RELAXED)) {
        debug("%s: %s (%d) terminated during launch\n", __FUNCTION__, process->name, process->pid);
        window_manager_remove_lost_front_switched_event(&g_window_manager, process->pid);
        return;
    }

    if (!__atomic_load_n(&process->ns_application, __ATOMIC_RELAXED)) {
        debug("%s: %s (%d) missing ns_application. fetching..\n", __FUNCTION__, process->name, process->pid);
        __atomic_store_n(&process->ns_application, workspace_application_create_running_ns_application(process), __ATOMIC_RELEASE);

        if (!__atomic_load_n(&process->ns_application, __ATOMIC_RELAXED)) {
            debug("%s: %s (%d) unable to fetch ns_application..\n", __FUNCTION__, process->name, process->pid);

            __block ProcessSerialNumber psn = process->psn;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                struct process *_process = process_manager_find_process(&g_process_manager, &psn);
                if (_process) event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, _process, 0);
            });

            return;
        }
    }

    if (!workspace_application_is_finished_launching(process)) {
        debug("%s: %s (%d) is not finished launching, subscribing to finishedLaunching changes\n", __FUNCTION__, process->name, process->pid);
        workspace_application_observe_finished_launching(g_workspace_context, process);

        //
        // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
        // Not actually sure if this can happen in practice..
        //

        if (workspace_application_is_finished_launching(process)) {
            @try {
                NSRunningApplication *application = __atomic_load_n(&process->ns_application, __ATOMIC_RELAXED);
                if (application && [application observationInfo]) {
                    [application removeObserver:g_workspace_context forKeyPath:@"finishedLaunching" context:process];
                }
            } @catch (NSException * __unused exception) {}
        } else { return; }
    }

    if (!workspace_application_is_observable(process)) {
        debug("%s: %s (%d) is not observable, subscribing to activationPolicy changes\n", __FUNCTION__, process->name, process->pid);
        workspace_application_observe_activation_policy(g_workspace_context, process);

        //
        // NOTE(asmvik): Do this again in case of race-conditions between the previous check and key-value observation subscription.
        // Not actually sure if this can happen in practice..
        //

        if (workspace_application_is_observable(process)) {
            @try {
                NSRunningApplication *application = __atomic_load_n(&process->ns_application, __ATOMIC_RELAXED);
                if (application && [application observationInfo]) {
                    [application removeObserver:g_workspace_context forKeyPath:@"activationPolicy" context:process];
                }
            } @catch (NSException * __unused exception) {}
        } else { return; }
    }

    //
    // NOTE(asmvik): If we somehow receive a duplicate launched event due to the subscription-timing-mess above,
    // simply ignore the event..
    //

    struct application *application = window_manager_find_application(&g_window_manager, process->pid);
    if (application) { return; } else { application = application_create(process); }

    if (!application_observe(application)) {
        bool ax_retry = application->ax_retry;

        application_unobserve(application);
        application_destroy(application);
        debug("%s: could not observe notifications for %s (%d) (%d)\n", __FUNCTION__, process->name, process->pid, ax_retry);

        if (ax_retry) {
            __block ProcessSerialNumber psn = process->psn;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                struct process *_process = process_manager_find_process(&g_process_manager, &psn);
                if (_process) event_loop_post(&g_event_loop, APPLICATION_LAUNCHED, _process, 0);
            });
        }

        return;
    }

    if (window_manager_find_lost_front_switched_event(&g_window_manager, process->pid)) {
        event_loop_post(&g_event_loop, APPLICATION_FRONT_SWITCHED, process, 0);
        window_manager_remove_lost_front_switched_event(&g_window_manager, process->pid);
    }

    debug("%s: %s (%d)\n", __FUNCTION__, process->name, process->pid);
    window_manager_add_application(&g_window_manager, application);
    event_signal_push(SIGNAL_APPLICATION_LAUNCHED, application);

    int window_count;
    struct window **window_list = window_manager_add_application_windows(&g_space_manager, &g_window_manager, application, &window_count);
    uint32_t prev_window_id = g_window_manager.focused_window_id;

    uint64_t sid;
    bool default_origin = g_window_manager.window_origin_mode == WINDOW_ORIGIN_DEFAULT;

    if (!default_origin) {
        if (g_window_manager.window_origin_mode == WINDOW_ORIGIN_FOCUSED) {
            sid = g_space_manager.current_space_id;
        } else /* if (g_window_manager.window_origin_mode == WINDOW_ORIGIN_CURSOR) */ {
            sid = space_manager_cursor_space();
        }
    }

    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];

        if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
            if (default_origin) sid = window_space(window->id);

            struct view *view = space_manager_find_view(&g_space_manager, sid);
            if (view->layout != VIEW_FLOAT) {
                //
                // @cleanup
                //
                // :AXBatching
                //
                // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
                // making sure that each window is only moved and resized a single time, when the final layout has been computed.
                // This is necessary to make sure that we do not call the AX API for each modification to the tree.
                //

                window_manager_adjust_layer(window, LAYER_BELOW);
                view_add_window_node_with_insertion_point(view, window, prev_window_id);
                window_manager_add_managed_window(&g_window_manager, window, view);

                view_set_flag(view, VIEW_IS_DIRTY);
                view_list[view_count++] = view;

                prev_window_id = window->id;
            }
        }

        if (window_manager_is_window_eligible(window)) {
            event_signal_push(SIGNAL_WINDOW_CREATED, window);
        }
    }

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    for (int i = 0; i < view_count; ++i) {
        struct view *view = view_list[i];
        if (!space_is_visible(view->sid)) continue;
        if (!view_is_dirty(view))         continue;

        window_node_flush(view->root);
        view_clear_flag(view, VIEW_IS_DIRTY);
    }

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }
}

static EVENT_HANDLER(APPLICATION_TERMINATED)
{
    struct process *process = context;
    struct application *application = window_manager_find_application(&g_window_manager, process->pid);

    if (!application) {
        debug("%s: %s (%d) (not observed)\n", __FUNCTION__, process->name, process->pid);
        goto out;
    }

    debug("%s: %s (%d)\n", __FUNCTION__, process->name, process->pid);
    event_signal_push(SIGNAL_APPLICATION_TERMINATED, application);
    window_manager_remove_application(&g_window_manager, application->pid);

    for (int i = 0; i < buf_len(g_window_manager.applications_to_refresh); ++i) {
        if (application == g_window_manager.applications_to_refresh[i]) {
            buf_del(g_window_manager.applications_to_refresh, i);
            break;
        }
    }

    int window_count;
    struct window **window_list = window_manager_find_application_windows(&g_window_manager, application, &window_count);

    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];

        if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, NULL)) {
            window->application = NULL;
            continue;
        }

        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        if (view) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            view_remove_window_node(view, window);
            window_manager_remove_managed_window(&g_window_manager, window->id);

            view_set_flag(view, VIEW_IS_DIRTY);
            view_list[view_count++] = view;
        }

        if (g_mouse_state.window == window) g_mouse_state.window = NULL;
        if (g_mouse_state.ffm_window_id == window->id) g_mouse_state.ffm_window_id = 0;

        if (window->is_eligible) {
            event_signal_push(SIGNAL_WINDOW_DESTROYED, window);
        }

        window_manager_remove_scratchpad_for_window(&g_window_manager, window, false);
        window_manager_remove_window(&g_window_manager, window->id);
        window_unobserve(window);
        window_destroy(window);
    }

    application_unobserve(application);
    application_destroy(application);

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    for (int i = 0; i < view_count; ++i) {
        struct view *view = view_list[i];
        if (!space_is_visible(view->sid)) continue;
        if (!view_is_dirty(view))         continue;

        window_node_flush(view->root);
        view_clear_flag(view, VIEW_IS_DIRTY);
    }

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

out:
    process_destroy(process);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static EVENT_HANDLER(APPLICATION_FRONT_SWITCHED)
{
    struct process *process = context;
    struct application *application = window_manager_find_application(&g_window_manager, process->pid);

    if (!application) {
        window_manager_add_lost_front_switched_event(&g_window_manager, process->pid);
        return;
    }

    if (g_space_manager.skip_window_focus_animation) {
        uint64_t psn_sid = process_manager_active_space_for_psn(application->connection);

        uint64_t last_cmd_tab_time = __atomic_load_n(&__last_cmd_tab_time, __ATOMIC_RELAXED);
        float dt = ((float) read_os_timer() - last_cmd_tab_time) * (1000.0f / (float)read_os_freq());
        if (dt > 1500.0f) {
            CFTypeRef dummy = NULL;
            AXUIElementCopyAttributeValue(application->ref, CFSTR("__fence"), &dummy);
        }

        if (__atomic_load_n(&__pending_window_focus, __ATOMIC_RELAXED) == false) {
            if (psn_sid && !space_is_visible(psn_sid)) {
                SLSSpaceSetFrontPSN(g_connection, psn_sid, process->psn);
                space_manager_focus_space_using_gesture(space_display_id(psn_sid), psn_sid);
            }
        }
    }

    struct application *deactivated_application = window_manager_find_application(&g_window_manager, g_process_manager.front_pid);
    if (deactivated_application) event_signal_push(SIGNAL_APPLICATION_DEACTIVATED, deactivated_application);

    debug("%s: %s (%d)\n", __FUNCTION__, process->name, process->pid);
    event_signal_push(SIGNAL_APPLICATION_ACTIVATED, application);
    g_process_manager.switch_event_time = GetCurrentEventTime();
    g_process_manager.last_front_pid = g_process_manager.front_pid;
    g_process_manager.front_pid = process->pid;
    event_signal_push(SIGNAL_APPLICATION_FRONT_SWITCHED, NULL);

    for (int i = 0; i < buf_len(g_window_manager.applications_to_refresh); ++i) {
        if (application == g_window_manager.applications_to_refresh[i]) {
            debug("%s: %s has windows that are not yet resolved\n", __FUNCTION__, application->name);
            window_manager_add_existing_application_windows(&g_space_manager, &g_window_manager, application, i);
            break;
        }
    }

    uint32_t application_focused_window_id = application_focused_window(application);
    if (!application_focused_window_id) {
        struct window *focused_window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
        if (focused_window) {
            window_manager_set_window_opacity(&g_window_manager, focused_window, g_window_manager.normal_window_opacity);
        }

        g_window_manager.last_window_id = g_window_manager.focused_window_id;
        g_window_manager.focused_window_id = 0;
        g_window_manager.focused_window_psn = application->psn;
        g_mouse_state.ffm_window_id = 0;
        return;
    }

    struct window *window = window_manager_find_window(&g_window_manager, application_focused_window_id);
    if (!window) {
        struct window *focused_window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
        if (focused_window) {
            window_manager_set_window_opacity(&g_window_manager, focused_window, g_window_manager.normal_window_opacity);
        }

        window_manager_add_lost_focused_event(&g_window_manager, application_focused_window_id);
        return;
    }

    window_did_receive_focus(&g_window_manager, &g_mouse_state, window);
    event_signal_push(SIGNAL_WINDOW_FOCUSED, window);
    __atomic_store_n(&__pending_window_focus, false, __ATOMIC_RELEASE);
}
#pragma clang diagnostic pop

static EVENT_HANDLER(APPLICATION_VISIBLE)
{
    struct application *application = window_manager_find_application(&g_window_manager, (pid_t)(intptr_t) context);
    if (!application) return;

    debug("%s: %s\n", __FUNCTION__, application->name);
    application->is_hidden = false;

    int window_count;
    struct window **window_list = window_manager_find_application_windows(&g_window_manager, application, &window_count);
    uint32_t prev_window_id = g_window_manager.last_window_id;

    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];

        if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
            struct view *view = space_manager_find_view(&g_space_manager, window_space(window->id));
            if (view->layout == VIEW_FLOAT) continue;

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            window_manager_adjust_layer(window, LAYER_BELOW);
            view_add_window_node_with_insertion_point(view, window, prev_window_id);
            window_manager_add_managed_window(&g_window_manager, window, view);

            view_set_flag(view, VIEW_IS_DIRTY);
            view_list[view_count++] = view;

            prev_window_id = window->id;
        }
    }

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    for (int i = 0; i < view_count; ++i) {
        struct view *view = view_list[i];
        if (!space_is_visible(view->sid)) continue;
        if (!view_is_dirty(view))         continue;

        window_node_flush(view->root);
        view_clear_flag(view, VIEW_IS_DIRTY);
    }

    event_signal_push(SIGNAL_APPLICATION_VISIBLE, application);
}

static EVENT_HANDLER(APPLICATION_HIDDEN)
{
    struct application *application = window_manager_find_application(&g_window_manager, (pid_t)(intptr_t) context);
    if (!application) return;

    debug("%s: %s\n", __FUNCTION__, application->name);
    application->is_hidden = true;

    int window_count;
    struct window **window_list = window_manager_find_application_windows(&g_window_manager, application, &window_count);

    int view_count = 0;
    struct view **view_list = ts_alloc_list(struct view *, window_count);

    for (int i = 0; i < window_count; ++i) {
        struct window *window = window_list[i];

        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        if (view) {

            //
            // @cleanup
            //
            // :AXBatching
            //
            // NOTE(asmvik): Batch all operations and mark the view as dirty so that we can perform a single flush,
            // making sure that each window is only moved and resized a single time, when the final layout has been computed.
            // This is necessary to make sure that we do not call the AX API for each modification to the tree.
            //

            window_manager_adjust_layer(window, LAYER_NORMAL);
            view_remove_window_node(view, window);
            window_manager_remove_managed_window(&g_window_manager, window->id);
            window_manager_purify_window(&g_window_manager, window);

            view_set_flag(view, VIEW_IS_DIRTY);
            view_list[view_count++] = view;
        }
    }

    //
    // @cleanup
    //
    // :AXBatching
    //
    // NOTE(asmvik): Flush previously batched operations if the view is marked as dirty.
    // This is necessary to make sure that we do not call the AX API for each modification to the tree.
    //

    for (int i = 0; i < view_count; ++i) {
        struct view *view = view_list[i];
        if (!space_is_visible(view->sid)) continue;
        if (!view_is_dirty(view))         continue;

        window_node_flush(view->root);
        view_clear_flag(view, VIEW_IS_DIRTY);
    }

    event_signal_push(SIGNAL_APPLICATION_HIDDEN, application);
}

static EVENT_HANDLER(WINDOW_CREATED)
{
    uint32_t window_id = ax_window_id(context);
    if (!window_id) { CFRelease(context); return; }

    struct window *existing_window = window_manager_find_window(&g_window_manager, window_id);
    if (existing_window) { CFRelease(context); return; }

    pid_t window_pid = ax_window_pid(context);
    if (!window_pid) { CFRelease(context); return; }

    struct application *application = window_manager_find_application(&g_window_manager, window_pid);
    if (!application) { CFRelease(context); return; }

    struct window *window = window_manager_create_and_add_window(&g_space_manager, &g_window_manager, application, context, window_id, true);
    if (!window) return;

    int rule_len = buf_len(g_window_manager.rules);
    for (int i = 0; i < rule_len; ++i) {
        if (rule_check_flag(&g_window_manager.rules[i], RULE_ONE_SHOT_REMOVE)) {
            rule_destroy(&g_window_manager.rules[i]);
            if (buf_del(g_window_manager.rules, i)) {
                --i;
                --rule_len;
            }
        }
    }

    if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
        uint64_t sid;

        if (g_window_manager.window_origin_mode == WINDOW_ORIGIN_DEFAULT) {
            sid = window_space(window->id);
        } else if (g_window_manager.window_origin_mode == WINDOW_ORIGIN_FOCUSED) {
            sid = g_space_manager.current_space_id;
        } else /* if (g_window_manager.window_origin_mode == WINDOW_ORIGIN_CURSOR) */ {
            sid = space_manager_cursor_space();
        }

        struct view *view = space_manager_tile_window_on_space(&g_space_manager, window, sid);
        window_manager_add_managed_window(&g_window_manager, window, view);
    }

    if (window_manager_is_window_eligible(window)) {
        event_signal_push(SIGNAL_WINDOW_CREATED, window);
    }

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    // A fresh window can take focus with no AX FocusedWindowChanged (e.g. same-app
    // new window, iTerm cmd+N). Wake hint only: refocus_ring re-resolves the topmost
    // window on the focused display's space, so an off-display create is a no-op show.
    refocus_ring(window->id, false);
}
static EVENT_HANDLER(WINDOW_DESTROYED)
{
    struct window *window = context;
    if (!window || window->id == 0) {
        debug("%s: window has already been destroyed, ignoring event..\n", __FUNCTION__);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application ? window->application->name : "<unknown>", window->id);

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    // Capture the window's space (view->sid for tiled; the current active space for
    // float — valid here because we only advance focus when this window was focused,
    // i.e. on the active display) before the untile/removal below mutates state.
    uint64_t destroyed_sid = view ? view->sid : g_space_manager.current_space_id;
    bool was_focused = g_window_manager.focused_window_id == window->id;
    if (view) {
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(&g_window_manager, window->id);
    }

    if (g_mouse_state.window == window) g_mouse_state.window = NULL;
    if (g_mouse_state.ffm_window_id == window->id) g_mouse_state.ffm_window_id = 0;

    // Focus ring: clear it if it was framing this window. Conditional (no-ops unless
    // the ring's committed target is still this wid), mirroring the minimize path — a
    // survivor's re-show drains ahead on the ring queue and supersedes.
    focus_ring_hide_for_wid(window->id, "destroy");

    if (window->is_eligible) {
        event_signal_push(SIGNAL_WINDOW_DESTROYED, window);
    }

    // Focus advance: macOS keeps a windowless app front and won't move keyboard focus
    // when the app's LAST window on a space closes, so focus (and the ring) would
    // strand on the dead window. When the destroyed window was focused and its app has
    // no surviving window on that same space, advance to the space's z-topmost window
    // of any process — else the Finder desktop. Scoped to destroyed_sid (one space =
    // one display), so a same-process window on another display never wins. If the app
    // still has a window here, macOS focuses it and fires WINDOW_FOCUSED — leave it be.
    if (was_focused && window->application) {
        uint32_t survivor = window_manager_space_application_window(&g_window_manager, window->application, destroyed_sid);
        if (!survivor || survivor == window->id) {
            // Topmost tracked window on the space (rich query, dying wid filtered) —
            // else the Finder desktop when the space has no other normal window.
            struct window *next = window_manager_space_topmost_tracked_window(&g_window_manager, destroyed_sid, window->id);
            if (next) {
                window_manager_focus_window_with_raise(&next->application->psn, next->id, next->ref);
            } else {
                _SLPSSetFrontProcessWithOptions(&g_process_manager.finder_psn, 0, kCPSNoWindows);
            }
        }
    }

    window_manager_remove_scratchpad_for_window(&g_window_manager, window, false);
    window_manager_remove_window(&g_window_manager, window->id);
    window_unobserve(window);
    window_destroy(window);

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }
}

static EVENT_HANDLER(WINDOW_FOCUSED)
{
    __atomic_store_n(&__pending_window_focus, false, __ATOMIC_RELEASE);
    uint32_t window_id = (uint32_t)(intptr_t) context;

    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) {
        window_manager_add_lost_focused_event(&g_window_manager, window_id);
        return;
    }

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    if (window_check_flag(window, WINDOW_MINIMIZE)) {
        window_manager_add_lost_focused_event(&g_window_manager, window->id);
        return;
    }

    if (!application_is_frontmost(window->application)) {
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);

    if (g_space_manager.skip_window_focus_animation) {
        uint64_t sid = window_space(window->id);
        if (sid && !space_is_visible(sid)) {
            SLSSpaceSetFrontPSN(g_connection, sid, window->application->psn);
            space_manager_focus_space_using_gesture(space_display_id(sid), sid);
        }
    }

    // Per-space focus recall is stamped inside window_did_receive_focus (the common
    // focus sink) so inter-app/front-switched focus records it too — see there.
    window_did_receive_focus(&g_window_manager, &g_mouse_state, window);
    event_signal_push(SIGNAL_WINDOW_FOCUSED, window);
}

static EVENT_HANDLER(WINDOW_MOVED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) return;

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    if (window->application->is_hidden) {
        debug("%s: %d was moved while the application is hidden, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    CGPoint new_origin = window_ax_origin(window);
    if (CGPointEqualToPoint(new_origin, window->frame.origin)) {
        debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);
    event_signal_push(SIGNAL_WINDOW_MOVED, window);
    bool windowed_fullscreen = CGRectEqualToRect(window->windowed_frame, window->frame);
    window->frame.origin = new_origin;

    if (!windowed_fullscreen) {
        window_clear_flag(window, WINDOW_WINDOWED);

        if (!g_mouse_state.window || g_mouse_state.window != window) {
            // Suppress the AX-diff flush while this window is in an active
            // animation context. The payload CA pump drives an AX setFrame every
            // frame; each intermediate commit lands here as a MOVED event whose
            // new_origin diverges from node->area (the FINAL target), and without
            // this guard window_node_flush would re-seed a fresh animation every
            // VBL — that is the BSP jank. The animation itself ends at node->area,
            // so no catch-up flush is needed afterward.
            if (!window_manager_is_animating(window->id)) {
                struct view *view = window_manager_find_managed_window(&g_window_manager, window);
                if (view) {
                    struct window_node *node = view_find_window_node(view, window->id);
                    if (node && (AX_DIFF(node->area.x, new_origin.x) ||
                                 AX_DIFF(node->area.y, new_origin.y))
                             &&
                       (!node->zoom || AX_DIFF(node->zoom->area.x, new_origin.x) ||
                                       AX_DIFF(node->zoom->area.y, new_origin.y))) {
                        if (space_is_visible(view->sid)) {
                            window_node_flush(node);
                        } else {
                            view_set_flag(view, VIEW_IS_DIRTY);
                        }
                    }
                }
            }
        }
    }

    // Focus ring live-follow: track the framed window to its new position. Gated
    // on !is_animating for the same reason as the AX-diff flush above — the
    // animation's geo-rider owns the ring mid-animation, so this must not chase
    // per-frame AX rects. No-ops unless the ring's committed target IS this
    // window (guard inside focus_ring_reposition_for_wid).
    if (!window_manager_is_animating(window->id))
        focus_ring_reposition_for_wid(window->id);
}

static EVENT_HANDLER(WINDOW_RESIZED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) return;

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    if (window->application->is_hidden) {
        debug("%s: %d was resized while the application is hidden, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    CGRect new_frame = window_ax_frame(window);
    if (CGRectEqualToRect(new_frame, window->frame)) {
        debug("%s:DEBOUNCED %s %d\n", __FUNCTION__, window->application->name, window->id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);
    event_signal_push(SIGNAL_WINDOW_RESIZED, window);

    bool was_fullscreen = window_check_flag(window, WINDOW_FULLSCREEN);

    bool is_fullscreen = window_is_fullscreen(window);
    if (is_fullscreen) {
        window_set_flag(window, WINDOW_FULLSCREEN);
    } else {
        window_clear_flag(window, WINDOW_FULLSCREEN);
    }

    if (was_fullscreen != is_fullscreen) {
        if (window_ax_can_move(window)) {
            window_set_flag(window, WINDOW_MOVABLE);
        } else {
            window_clear_flag(window, WINDOW_MOVABLE);
        }

        if (window_ax_can_resize(window)) {
            window_set_flag(window, WINDOW_RESIZABLE);
        } else {
            window_clear_flag(window, WINDOW_RESIZABLE);
        }

        if (window->role) CFRelease(window->role);
        window->role = window_ax_role(window);

        if (window->subrole) CFRelease(window->subrole);
        window->subrole = window_ax_subrole(window);
    }

    bool windowed_fullscreen = CGRectEqualToRect(window->windowed_frame, window->frame);
    window->frame = new_frame;

    if (!was_fullscreen && is_fullscreen) {
        struct view *view = window_manager_find_managed_window(&g_window_manager, window);
        if (view) {
            space_manager_untile_window(view, window);
            window_manager_remove_managed_window(&g_window_manager, window->id);
            window_manager_purify_window(&g_window_manager, window);
        }
    } else if (was_fullscreen && !is_fullscreen) {
        window_manager_wait_for_native_fullscreen_transition(window);

        if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
            struct view *view = space_manager_tile_window_on_space(&g_space_manager, window, window_space(window->id));
            window_manager_add_managed_window(&g_window_manager, window, view);
        }
    } else if (!was_fullscreen == !is_fullscreen) {
        if (g_mouse_state.current_action == MOUSE_MODE_MOVE && g_mouse_state.window == window) {
            g_mouse_state.window_frame.size = g_mouse_state.window->frame.size;
        }

        if (!windowed_fullscreen) {
            window_clear_flag(window, WINDOW_WINDOWED);

            if (!g_mouse_state.window || g_mouse_state.window != window) {
                // Suppress the AX-diff flush while this window is animating — same
                // rationale as WINDOW_MOVED: per-frame pump commits diverge from
                // node->area, and flushing would restart the animation every VBL.
                if (!window_manager_is_animating(window->id)) {
                    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
                    if (view) {
                        struct window_node *node = view_find_window_node(view, window->id);
                        if (node && (AX_DIFF(node->area.x, new_frame.origin.x)   ||
                                     AX_DIFF(node->area.y, new_frame.origin.y)   ||
                                     AX_DIFF(node->area.w, new_frame.size.width) ||
                                     AX_DIFF(node->area.h, new_frame.size.height))
                                 &&
                           (!node->zoom || AX_DIFF(node->zoom->area.x, new_frame.origin.x)   ||
                                           AX_DIFF(node->zoom->area.y, new_frame.origin.y)   ||
                                           AX_DIFF(node->zoom->area.w, new_frame.size.width) ||
                                           AX_DIFF(node->zoom->area.h, new_frame.size.height))) {
                            if (space_is_visible(view->sid)) {
                                window_node_flush(node);
                            } else {
                                view_set_flag(view, VIEW_IS_DIRTY);
                            }
                        }
                    }
                }
            }
        }
    }

    // Focus ring live-follow: track the framed window to its new size. Same
    // !is_animating gate + committed-target guard as WINDOW_MOVED.
    if (!window_manager_is_animating(window->id))
        focus_ring_reposition_for_wid(window->id);
}

static EVENT_HANDLER(WINDOW_MINIMIZED)
{
    struct window *window = context;

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window->id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);
    window_set_flag(window, WINDOW_MINIMIZE);

    // Focus ring: if the ring is framing this window, clear it now — the next
    // WINDOW_FOCUSED re-shows it on whatever gains focus. Conditional (no-ops
    // unless the ring's committed target is still this wid), so minimizing a
    // background window can't wipe the ring off the still-focused one, and a
    // same-app survivor's show drains ahead of this hide and supersedes it.
    focus_ring_hide_for_wid(window->id, "minimize");

    if (window_ax_can_move(window)) {
        window_set_flag(window, WINDOW_MOVABLE);
    } else {
        window_clear_flag(window, WINDOW_MOVABLE);
    }

    if (window_ax_can_resize(window)) {
        window_set_flag(window, WINDOW_RESIZABLE);
    } else {
        window_clear_flag(window, WINDOW_RESIZABLE);
    }

    if (window->role) CFRelease(window->role);
    window->role = window_ax_role(window);

    if (window->subrole) CFRelease(window->subrole);
    window->subrole = window_ax_subrole(window);

    if (window->id == g_window_manager.last_window_id) {
        g_window_manager.last_window_id = g_window_manager.focused_window_id;
    }

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    if (view) {
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(&g_window_manager, window->id);
        window_manager_purify_window(&g_window_manager, window);
    }

    event_signal_push(SIGNAL_WINDOW_MINIMIZED, window);
}

static EVENT_HANDLER(WINDOW_DEMINIMIZED)
{
    struct window *window = context;

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window->id);
        window_manager_remove_lost_focused_event(&g_window_manager, window->id);
        return;
    }

    window_clear_flag(window, WINDOW_MINIMIZE);

    if (window_ax_can_move(window)) {
        window_set_flag(window, WINDOW_MOVABLE);
    } else {
        window_clear_flag(window, WINDOW_MOVABLE);
    }

    if (window_ax_can_resize(window)) {
        window_set_flag(window, WINDOW_RESIZABLE);
    } else {
        window_clear_flag(window, WINDOW_RESIZABLE);
    }

    if (window->role) CFRelease(window->role);
    window->role = window_ax_role(window);

    if (window->subrole) CFRelease(window->subrole);
    window->subrole = window_ax_subrole(window);

    uint64_t sid = space_manager_active_space();
    if (space_manager_is_window_on_space(sid, window)) {
        debug("%s: window %s %d is deminimized on active space\n", __FUNCTION__, window->application->name, window->id);
        if (window_manager_should_manage_window(window) && !window_manager_find_managed_window(&g_window_manager, window)) {
            struct window *last_window = window_manager_find_window(&g_window_manager, g_window_manager.last_window_id);
            uint32_t insertion_point = last_window && last_window->application->pid != window->application->pid ? last_window->id : 0;
            struct view *view = space_manager_tile_window_on_space_with_insertion_point(&g_space_manager, window, sid, insertion_point);
            window_manager_add_managed_window(&g_window_manager, window, view);
        }
    } else {
        debug("%s: window %s %d is deminimized on inactive space\n", __FUNCTION__, window->application->name, window->id);
    }

    if (window_manager_find_lost_focused_event(&g_window_manager, window->id)) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
        window_manager_remove_lost_focused_event(&g_window_manager, window->id);
    }

    event_signal_push(SIGNAL_WINDOW_DEMINIMIZED, window);

    // A restored window may take focus; if the app stayed frontmost the AX focus
    // event can be silent. Wake hint only — resolves on the focused display's space.
    // (The lost-focused replay above covers the case where a WINDOW_FOCUSED was
    // queued; this covers when it wasn't.)
    refocus_ring(window->id, false);
}

static EVENT_HANDLER(WINDOW_TITLE_CHANGED)
{
    uint32_t window_id = (uint32_t)(intptr_t) context;
    struct window *window = window_manager_find_window(&g_window_manager, window_id);
    if (!window) return;

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, window_id);
        return;
    }

    debug("%s: %s %d\n", __FUNCTION__, window->application->name, window->id);

    if (window->title) CFRelease(window->title);

    window->title = window_title(window);

    event_signal_push(SIGNAL_WINDOW_TITLE_CHANGED, window);
}

static EVENT_HANDLER(SLS_WINDOW_ORDERED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    struct window_node *node = table_find(&g_window_manager.insert_feedback, &wid);
    if (node) SLSOrderWindow(g_connection, node->feedback_window.id, 1, node->window_order[0]);

    // The AX FocusedWindowChanged path goes silent for same-app clicks between
    // multi-tab Ghostty windows; 808 still fires — reconcile the ring off it.
    // refocus_ring re-resolves the key-focus window itself, so this (often
    // demoted-sibling) payload wid is only a wake hint.
    refocus_ring(wid, false);
}

// kCGSWindowIsVisible (815) — the POST-SETTLE focus signal. 815 fires once a window's
// order/visibility has settled, LATER than the 808 order-change burst, so its
// re-resolve lands on the newly-focused window rather than the pre-settle one. This is
// what closes the "one focus behind" lag when AX is silent (multi-tab same-app clicks):
// 808 alone re-resolves mid-burst; 815 re-resolves after. refocus_ring ignores this
// payload wid (re-resolves the key-focus window itself); the per-VBL/idempotent-rect dedupe
// in focus_ring_show_for_wid absorbs the 808+815 overlap and 815's per-window volume.
static EVENT_HANDLER(SLS_WINDOW_VISIBLE)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    refocus_ring(wid, true);
}

// kCGSWindowIsInvisible (816) — a sibling going invisible (e.g. a deselected tab, or a
// window ordered out) promotes another to topmost; re-resolve so the ring follows the
// survivor.
static EVENT_HANDLER(SLS_WINDOW_INVISIBLE)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    refocus_ring(wid, true);
}

// NOTE: 806 arrives for EVERY subscribed wid -- the ring-target filter lives here,
// not at intake. Runs alongside the AX WINDOW_MOVED path; the per-VBL throttle in
// focus_ring_show_for_wid dedupes the overlap.
static EVENT_HANDLER(SLS_WINDOW_MOVED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    if (!wid || wid != focus_ring_get_target_wid()) return;
    debug("%s: %d\n", __FUNCTION__, wid);
    focus_ring_reposition_for_wid(wid);
}

// NOTE: intentionally distinct from SLS_WINDOW_MOVED -- resize (807) and move (806)
// must stay separable downstream; do not re-funnel.
static EVENT_HANDLER(SLS_WINDOW_RESIZED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    if (!wid || wid != focus_ring_get_target_wid()) return;
    debug("%s: %d\n", __FUNCTION__, wid);
    focus_ring_reposition_for_wid(wid);
}

// NOTE: queue order runs this ahead of the same-move 806/808/815 burst, so
// refocus_ring resolves the DESTINATION display's space, not the source's.
static EVENT_HANDLER(SLS_WINDOW_DISPLAY_CHANGED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    if (!wid || wid != g_window_manager.focused_window_id) return;
    uint32_t did = window_display_id(wid);
    debug("%s: %d -> did=%d\n", __FUNCTION__, wid, did);
    if (did) g_window_manager.focused_display_id = did;
}

// kCGSWindowDidCreate (1325). A native-tab switch silently (to AX) materializes the
// incoming tab as a NEW wid on the same space + owner as its siblings, at the
// IDENTICAL frame — and fires ONLY this event (no 808/815/816/WINDOW_FOCUSED), so
// 1325 is the sole signal for tracking native-tab wids and following keyboard tab
// switches.
static EVENT_HANDLER(SLS_WINDOW_CREATED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;

    // The tab-follow gate below needs only the two owners; the window's full
    // geometry readout is diagnostic and runs under --verbose only, so a
    // system-wide window create costs two SLS queries, not seven (untracked
    // wids pay one more for the tab-set level gate).
    int owner = 0;  SLSGetWindowOwner(g_connection, wid, &owner);
    uint32_t fwid = g_window_manager.focused_window_id;
    int fowner = 0; if (fwid) SLSGetWindowOwner(g_connection, fwid, &fowner);
    bool same_owner = owner && owner == fowner;

    if (g_verbose) {
        uint8_t ordered_in = 0;
        SLSWindowIsOrderedIn(g_connection, wid, &ordered_in);
        int level = 0;  SLSGetWindowLevel(g_connection, wid, &level);
        CGRect r = {0}; SLSGetWindowBounds(g_connection, wid, &r);
        CFArrayRef assoc = SLSCopyAssociatedWindows(g_connection, wid);
        long assoc_n = assoc ? CFArrayGetCount(assoc) : 0;
        if (assoc) CFRelease(assoc);
        debug("%s: wid=%d owner=%d sid=%lld did=%d ordered_in=%d level=%d assoc=%ld "
              "frame=(%.0f,%.0f %.0fx%.0f) | focus=%d fowner=%d same_owner=%d\n",
              __FUNCTION__, wid, owner, (long long) window_space(wid), window_display_id(wid),
              ordered_in, level, assoc_n, r.origin.x, r.origin.y, r.size.width, r.size.height,
              fwid, fowner, same_owner);
    }

    // Catch SLS-only (untracked) creates here — a genuine new WINDOW is tracked via AX
    // WINDOW_CREATED -> create_and_add_window and subscribed through
    // update_window_notifications(); native-tab wids are AX-hidden, never tracked, so
    // they'd otherwise go unsubscribed. Record the wid in the tab set (NEW vs
    // re-materialize = whether it was already present) and, only for a genuinely new
    // tab, re-declare the full subscription list. Never a single-wid request: under
    // replace semantics that would wipe every other window's subscription; a
    // re-materialize is already subscribed, so it needs no rebuild.
    if (!window_manager_find_window(&g_window_manager, wid)) {
        // Normal-level wids only, mirroring the seed path's filter — without
        // it the sweep claims desktop-level chrome (e.g. a reconnected
        // display's freshly minted Finder desktop window) as a native tab. A
        // level that reads 0 mid-materialization (query not yet answerable)
        // falls through to the add, same as before this gate; the topology
        // re-track's tab-set eviction covers that case.
        int wlevel = 0; SLSGetWindowLevel(g_connection, wid, &wlevel);
        if (wlevel == 0) {
            bool is_new = window_manager_add_tab_window(&g_window_manager, wid);
            debug("%s: %s tab wid=%d owner=%d\n", __FUNCTION__, is_new ? "NEW" : "re-materialized", wid, owner);
            if (is_new) update_window_notifications();
        } else {
            debug("%s: skipping tab-set add for wid=%d (level=%d)\n", __FUNCTION__, wid, wlevel);
        }
    }

    // Native-tab follow, KEYBOARD path. A tab switch re-materializes the incoming
    // tab's STABLE wid via 1325 and fires NO 815/816, so this 1325 is the only trigger
    // for keyboard switches (cmd+shift+[ / cmd+N — no mouse event); click-driven
    // switches settle key focus through the normal mouse path.
    // RE-RESOLVE key focus through refocus_ring's settled path rather than binding the
    // raw 1325 wid: 1325 only TRIGGERS — a direct show/stamp on the raw payload wid
    // no-ops. The resolve is space-scoped by owner cid (space_window_for_owner) — after
    // the swap the newly-active tab is the owner's ONLY in-space window, so
    // window_manager_update_focused_window returns it. refocus_ring(settled) carries the
    // MC / space-transition guards, the key-focus stamp, and the ring show off
    // the resolved wid.
    // Gate = same_owner && wid != fwid: scope to creates by the currently-focused app,
    // and debounce a same-tab re-materialize burst.
    if (same_owner && wid != fwid) {
        debug("%s: tab-follow wid=%d (focus was %d)\n", __FUNCTION__, wid, fwid);
        refocus_ring(wid, true);
    }
}

static EVENT_HANDLER(SLS_WINDOW_DESTROYED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);

    // Untracked tab wid going away: drop it from the tab set and re-declare the
    // subscription list so the dead wid isn't carried on the next rebuild.
    if (window_manager_remove_tab_window(&g_window_manager, wid)) {
        debug("%s: removed tab wid=%d from tab set\n", __FUNCTION__, wid);
        update_window_notifications();
        return;
    }

    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window) return;

    if (!__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, wid);
        return;
    }

    EVENT_HANDLER_WINDOW_DESTROYED(window, 0);
}

static EVENT_HANDLER(SLS_SPACE_CREATED)
{
    uint64_t sid = (uint64_t)(intptr_t) context;
    int type = SLSSpaceGetType(g_connection, sid);

    if (type == 0 || type == 4) {
        debug("%s: %lld, %d\n", __FUNCTION__, sid, type);
        space_manager_find_view(&g_space_manager, sid);
        event_signal_push(SIGNAL_SPACE_CREATED, context);
    }
}

static EVENT_HANDLER(SLS_SPACE_DESTROYED)
{
    uint64_t sid = (uint64_t)(intptr_t) context;
    struct view *view = table_find(&g_space_manager.view, &sid);
    if (view) {
        debug("%s: %lld\n", __FUNCTION__, sid);
        space_manager_remove_label_for_space(&g_space_manager, sid);
        table_remove(&g_space_manager.view, &sid);
        view_destroy(view);
        free(view);
        event_signal_push(SIGNAL_SPACE_DESTROYED, context);
    }
}

static EVENT_HANDLER(SPACE_CHANGED)
{
    g_space_manager.last_space_id = g_space_manager.current_space_id;
    g_space_manager.current_space_id = space_manager_active_space();

    if (g_window_manager.menubar_opacity != 1.0f) {
        float alpha = space_is_fullscreen(g_space_manager.current_space_id) ? 1.0f : g_window_manager.menubar_opacity;
        SLSSetMenuBarInsetAndAlpha(g_connection, 0, 1, alpha);
    }

    debug("%s: %lld\n", __FUNCTION__, g_space_manager.current_space_id);
    struct view *view = space_manager_find_view(&g_space_manager, g_space_manager.current_space_id);

    if (space_manager_refresh_application_windows(&g_space_manager)) {
        struct window *focused_window = window_manager_focused_window(&g_window_manager);
        if (focused_window && window_manager_find_lost_focused_event(&g_window_manager, focused_window->id)) {
            window_did_receive_focus(&g_window_manager, &g_mouse_state, focused_window);
            window_manager_remove_lost_focused_event(&g_window_manager, focused_window->id);
        }
    }

    if (!mission_control_is_active() && space_is_user(g_space_manager.current_space_id)) {
        window_manager_validate_and_check_for_windows_on_space(&g_space_manager, &g_window_manager, g_space_manager.current_space_id);

        if (view_is_invalid(view)) {
            view_update(view);
        }

        if (view_is_dirty(view)) {
            window_node_flush(view->root);
            view_clear_flag(view, VIEW_IS_DIRTY);
        }
    }

    // Focus recall at the committed space. An SA-driven animated slide commits
    // the space without any app activating a window, so focus can stay on the
    // outgoing space until the next click; re-assert it on the destination here.
    // Prefer the space's last-focused window; fall back to its first window.
    if (view && !mission_control_is_active()) {
        struct window *target = NULL;
        if (view->last_focused_wid) {
            struct window *recall = window_manager_find_window(&g_window_manager, view->last_focused_wid);
            // A minimized window still reports its original space, and the raise
            // below (kAXRaiseAction + make-key) would restore it — entering a
            // space must never deminimize its last-focused window. Same for a
            // hidden app's window, which the raise would unhide.
            if (recall && window_space(recall->id) == g_space_manager.current_space_id
                && !window_check_flag(recall, WINDOW_MINIMIZE)
                && !recall->application->is_hidden) {
                target = recall;
            }
        }
        if (!target) {
            // Rich SLS query — normal windows only (sticky/hidden/minimized excluded),
            // first tracked in z-order — so an overlay/sticky window can't win focus
            // on the committed space.
            target = window_manager_space_topmost_tracked_window(&g_window_manager, g_space_manager.current_space_id, 0);
        }
        if (target && target->id != g_window_manager.focused_window_id) {
            window_manager_focus_window_with_raise(&target->application->psn, target->id, target->ref);
        }
    }

    // Reconcile the tracked focus id to the committed space's REAL key focus — AFTER
    // the recall raise above, never before. Recall's raise gate (target->id !=
    // focused_window_id) must compare against the PRE-switch id: stamping first would
    // suppress the raise — and its AX side effects (opacity swap, mff center, recall
    // write) — whenever macOS already granted key to the recall target (the common
    // case). Stamped after, this reads the pre-raise key focus (the raise is async
    // through WindowServer + app); the raise's own AX event — or, when AX is silent
    // (tabbed Ghostty), the switch-in 815 settle — brings the final truth. The
    // resolve is space-scoped to current_space_id, so a
    // lingering outgoing-app key PSN resolves to that app's window ON THIS space or 0,
    // never an outgoing-space wid. Empty destination stamps 0, so space_transition_reshow
    // correctly skips the finish re-show for a window on the departed space. MC-gated:
    // during a Mission-Control space change the key-focus process is Dock (resolves 0)
    // — don't wipe the id mid-MC. DISPLAY_CHANGED is deliberately NOT stamped here —
    // its display anchor stamp + the switch-in 815s cover display hops.
    if (!mission_control_is_active()) {
        window_manager_update_focused_window(&g_window_manager, g_space_manager.current_space_id);
    }

    event_signal_push(SIGNAL_SPACE_CHANGED, NULL);

    // SPA-2: reconcile the optimistic logical target against the just-committed
    // space, then drain any queued hop. current_space_id was set at the top of
    // this handler to the committed space. Both run on the event-loop thread —
    // the same thread as every FIFO push — so no lock is needed. The drain seeds
    // the next queued hop the instant this slide commits, giving a continuous
    // chain for rapid `space --focus next/prev`.
    space_manager_reconcile_optimistic_target(g_space_manager.current_space_id);
    space_manager_drain_pending_focus();
}

static EVENT_HANDLER(DISPLAY_CHANGED)
{
    uint32_t new_did = display_manager_active_display_id();
    if (g_display_manager.current_display_id == new_did) {
        debug("%s: newly activated display %d was already active (%d)! ignoring event..\n", __FUNCTION__, g_display_manager.current_display_id, new_did);
        return;
    }

    g_display_manager.last_display_id = g_display_manager.current_display_id;
    g_display_manager.current_display_id = new_did;

    // Focus-display anchor follows explicit display activation. Covers the
    // empty-display case where no window focus lands afterwards to re-stamp it
    // via window_did_receive_focus.
    g_window_manager.focused_display_id = new_did;

    g_space_manager.last_space_id = g_space_manager.current_space_id;
    g_space_manager.current_space_id = display_space_id(g_display_manager.current_display_id);

    uint32_t expected_display_id = space_display_id(g_space_manager.current_space_id);
    if (g_display_manager.current_display_id != expected_display_id) {
        debug("%s: %d %lld did not match %d! ignoring event..\n", __FUNCTION__, g_display_manager.current_display_id, g_space_manager.current_space_id, expected_display_id);
        return;
    }

    if (g_window_manager.menubar_opacity != 1.0f) {
        float alpha = space_is_fullscreen(g_space_manager.current_space_id) ? 1.0f : g_window_manager.menubar_opacity;
        SLSSetMenuBarInsetAndAlpha(g_connection, 0, 1, alpha);
    }

    debug("%s: %d %lld\n", __FUNCTION__, g_display_manager.current_display_id, g_space_manager.current_space_id);
    struct view *view = space_manager_find_view(&g_space_manager, g_space_manager.current_space_id);

    if (space_manager_refresh_application_windows(&g_space_manager)) {
        struct window *focused_window = window_manager_focused_window(&g_window_manager);
        if (focused_window && window_manager_find_lost_focused_event(&g_window_manager, focused_window->id)) {
            window_did_receive_focus(&g_window_manager, &g_mouse_state, focused_window);
            window_manager_remove_lost_focused_event(&g_window_manager, focused_window->id);
        }
    }

    if (!mission_control_is_active() && space_is_user(g_space_manager.current_space_id)) {
        window_manager_validate_and_check_for_windows_on_space(&g_space_manager, &g_window_manager, g_space_manager.current_space_id);

        if (view_is_invalid(view)) {
            view_update(view);
        }

        if (view_is_dirty(view)) {
            window_node_flush(view->root);
            view_clear_flag(view, VIEW_IS_DIRTY);
        }
    }

    event_signal_push(SIGNAL_DISPLAY_CHANGED, NULL);
}

static EVENT_HANDLER(DISPLAY_ADDED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    space_manager_handle_display_add(&g_space_manager, did);
    window_manager_handle_display_add_and_remove(&g_space_manager, &g_window_manager, did);

    // A (re)connected display gets a freshly minted Finder desktop window —
    // the startup-only tracking never sees it. Re-track (idempotent) so it is
    // focus-targetable again and evicted from the tab set if the untracked-wid
    // sweep in SLS_WINDOW_CREATED already claimed it.
    window_manager_track_role_windows(&g_window_manager);

    event_signal_push(SIGNAL_DISPLAY_ADDED, context);
}

static EVENT_HANDLER(DISPLAY_REMOVED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    display_manager_remove_label_for_display(&g_display_manager, did);
    window_manager_handle_display_add_and_remove(&g_space_manager, &g_window_manager, display_manager_main_display_id());

    // The arrangement rebuild after a removal can rotate surviving displays'
    // desktop wids too; re-track (idempotent) to catch replacements. A wid
    // minted after this handler runs is picked up on the next DISPLAY_ADDED
    // re-track or daemon restart.
    window_manager_track_role_windows(&g_window_manager);

    event_signal_push(SIGNAL_DISPLAY_REMOVED, context);
}

static EVENT_HANDLER(DISPLAY_MOVED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    space_manager_mark_spaces_invalid(&g_space_manager);
    event_signal_push(SIGNAL_DISPLAY_MOVED, context);
}

static EVENT_HANDLER(DISPLAY_RESIZED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    space_manager_mark_spaces_invalid_for_display(&g_space_manager, did);
    event_signal_push(SIGNAL_DISPLAY_RESIZED, context);
}

static EVENT_HANDLER(MOUSE_DOWN)
{
    if (mission_control_is_active())                     goto out;
    if (g_mouse_state.current_action != MOUSE_MODE_NONE) goto out;

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f focused_window_id: %d\n", __FUNCTION__, point.x, point.y, g_window_manager.focused_window_id);

    // Resolver cross-display anchor (race-proof). Stamp the focus display from the
    // click-point GEOMETRY now — before this click's focus events drain — so a
    // stale background 808/815 from the display being left (its windows redraw as
    // they deactivate) can't be resolved against a not-yet-updated anchor.
    // window_did_receive_focus also stamps it, but only once its posted event
    // drains, which can lose the race against the SLS notify thread. Geometry-
    // based, so an empty-desktop click (no window hit below) re-anchors too.
    // Keyboard focus paths keep the window-based stamp in window_did_receive_focus.
    uint32_t click_did = display_manager_point_display_id(point);
    if (click_did) g_window_manager.focused_display_id = click_did;

    struct window *window = window_manager_find_window_at_point(&g_window_manager, point);
    if (!window || window_check_flag(window, WINDOW_FULLSCREEN)) goto out;

    // Mouse click → focus the GEOMETRICALLY clicked window.
    // The hit-test is immune to the z-order confounds that corrupt the topmost
    // query (-20 BSP sublevel, sticky at index 0) — and it is the ONLY click-
    // synchronous signal that names the target at all: a same-app cross-display
    // click onto a window already topmost on its own space emits NO 808/815
    // (nothing reorders) and Ghostty's AX stays silent, so without this post
    // nothing lands the focus and focused_window_id + the ring stay stranded on
    // the previous display. Route through WINDOW_FOCUSED so the canonical
    // cascade runs (window_did_receive_focus → focused_window_id, opacity,
    // ring, signal) under the handler's own dedupe/validity/minimize/frontmost
    // guards: same-app clicks pass the frontmost guard and land immediately;
    // cross-app clicks drop there and land via APPLICATION_FRONT_SWITCHED as
    // before. Gated on a real change to avoid redundant queue churn.
    if (window->id != g_window_manager.focused_window_id) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
    }

    g_mouse_state.window = window;
    g_mouse_state.window_frame = g_mouse_state.window->frame;
    g_mouse_state.down_location = point;
    g_mouse_state.direction = 0;

    // Focus-ring live-follow: a window was grabbed -> a drag may follow. Flip the
    // ring into drag-follow so focus_ring_show_for_wid bypasses the 16ms focus-change
    // coalesce and the SLS-806-driven reposition tracks the drag at VBL rate. (The
    // coalesce only exists to absorb focus-CHANGE bounces -- during a same-wid drag
    // it is pure lag.) Cleared on MOUSE_UP.
    focus_ring_set_drag_follow(true);

    int64_t button = CGEventGetIntegerValueField(context, kCGMouseEventButtonNumber);
    uint8_t mod = (uint8_t) param1;

    if (button == kCGMouseButtonLeft && g_mouse_state.modifier == mod) {
        g_mouse_state.current_action = g_mouse_state.action1;
    } else if (button == kCGMouseButtonRight && g_mouse_state.modifier == mod) {
        g_mouse_state.current_action = g_mouse_state.action2;
    }

    if (g_mouse_state.current_action == MOUSE_MODE_RESIZE) {
        CGPoint frame_mid = { CGRectGetMidX(g_mouse_state.window_frame), CGRectGetMidY(g_mouse_state.window_frame) };
        if (point.x < frame_mid.x) g_mouse_state.direction |= HANDLE_LEFT;
        if (point.y < frame_mid.y) g_mouse_state.direction |= HANDLE_TOP;
        if (point.x > frame_mid.x) g_mouse_state.direction |= HANDLE_RIGHT;
        if (point.y > frame_mid.y) g_mouse_state.direction |= HANDLE_BOTTOM;
    }

out:
    CFRelease(context);
}

static EVENT_HANDLER(MOUSE_UP)
{
    // Drag over: drop the ring's drag-follow (re-arm the focus-change coalesce).
    focus_ring_set_drag_follow(false);

    if (mission_control_is_active()) goto out;

    if (!g_mouse_state.window)       goto res;

    if (!__sync_bool_compare_and_swap(&g_mouse_state.window->id_ptr, &g_mouse_state.window->id, &g_mouse_state.window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, g_mouse_state.window->id);
        goto err;
    }

    if (window_check_flag(g_mouse_state.window, WINDOW_FULLSCREEN)) {
        debug("%s: %d is transitioning into native-fullscreen mode, ignoring event..\n", __FUNCTION__, g_mouse_state.window->id);
        goto err;
    }

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f\n", __FUNCTION__, point.x, point.y);

    struct view *src_view = window_manager_find_managed_window(&g_window_manager, g_mouse_state.window);
    if (!src_view) goto err;

    struct mouse_window_info info;
    mouse_window_info_populate(&g_mouse_state, &info);

    if (info.changed_position && !info.changed_size) {
        uint64_t cursor_sid = display_space_id(display_manager_point_display_id(point));
        struct view *dst_view = space_manager_find_view(&g_space_manager, cursor_sid);

        struct window *window = window_manager_find_window_at_point_filtering_window(&g_window_manager, point, g_mouse_state.window->id);
        if (!window) window = window_manager_find_window_at_point(&g_window_manager, point);
        if (window == g_mouse_state.window) window = NULL;

        struct window_node *a_node = view_find_window_node(src_view, g_mouse_state.window->id);
        struct window_node *b_node = window ? view_find_window_node(dst_view, window->id) : NULL;

        if (a_node && b_node && a_node != b_node) {
            if (g_mouse_state.feedback_node) {
                g_mouse_state.feedback_node->insert_dir = 0;
                insert_feedback_destroy(g_mouse_state.feedback_node);
                g_mouse_state.feedback_node = NULL;
            }

            enum mouse_drop_action drop_action = mouse_determine_drop_action(&g_mouse_state, a_node, window, point);
            switch (drop_action) {
            case MOUSE_DROP_ACTION_STACK: {
                mouse_drop_action_stack(&g_window_manager, src_view, g_mouse_state.window, dst_view, window);
            } break;
            case MOUSE_DROP_ACTION_SWAP: {
                mouse_drop_action_swap(&g_window_manager, src_view, a_node, g_mouse_state.window, dst_view, b_node, window);
            } break;
            case MOUSE_DROP_ACTION_WARP_TOP: {
                mouse_drop_action_warp(&g_window_manager, src_view, a_node, g_mouse_state.window, dst_view, b_node, window, SPLIT_X, CHILD_FIRST);
            } break;
            case MOUSE_DROP_ACTION_WARP_RIGHT: {
                mouse_drop_action_warp(&g_window_manager, src_view, a_node, g_mouse_state.window, dst_view, b_node, window, SPLIT_Y, CHILD_SECOND);
            } break;
            case MOUSE_DROP_ACTION_WARP_BOTTOM: {
                mouse_drop_action_warp(&g_window_manager, src_view, a_node, g_mouse_state.window, dst_view, b_node, window, SPLIT_X, CHILD_SECOND);
            } break;
            case MOUSE_DROP_ACTION_WARP_LEFT: {
                mouse_drop_action_warp(&g_window_manager, src_view, a_node, g_mouse_state.window, dst_view, b_node, window, SPLIT_Y, CHILD_FIRST);
            } break;
            case MOUSE_DROP_ACTION_NONE: {
                /* silence compiler warning.. */
            } break;
            }
        } else if (a_node) {
            mouse_drop_no_target(&g_space_manager, &g_window_manager, src_view, dst_view, g_mouse_state.window, a_node);
        }
    } else if (info.changed_position || info.changed_size) {
        mouse_drop_try_adjust_bsp_grid(&g_window_manager, src_view, g_mouse_state.window, &info);
    }

err:
    g_mouse_state.window = NULL;
res:
    g_mouse_state.current_action = MOUSE_MODE_NONE;
out:
    CFRelease(context);
}

static EVENT_HANDLER(MOUSE_DRAGGED)
{
    if (mission_control_is_active()) goto out;
    if (!g_mouse_state.window)       goto out;

    if (!__sync_bool_compare_and_swap(&g_mouse_state.window->id_ptr, &g_mouse_state.window->id, &g_mouse_state.window->id)) {
        debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, g_mouse_state.window->id);
        g_mouse_state.window = NULL;
        g_mouse_state.current_action = MOUSE_MODE_NONE;
        CFRelease(context);
        return;
    }

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f\n", __FUNCTION__, point.x, point.y);

    if (g_mouse_state.current_action == MOUSE_MODE_MOVE) {
        CGPoint new_point = { g_mouse_state.window_frame.origin.x + (point.x - g_mouse_state.down_location.x),
                              g_mouse_state.window_frame.origin.y + (point.y - g_mouse_state.down_location.y) };

        uint32_t did = display_manager_point_display_id(new_point);
        if (did) {
            CGRect bounds = display_bounds_constrained(did, false);
            if (new_point.y < bounds.origin.y) new_point.y = bounds.origin.y;
        }

        if (!scripting_addition_move_window(g_mouse_state.window->id, new_point.x, new_point.y)) {
            window_manager_move_window(g_mouse_state.window, new_point.x, new_point.y);
        }
    } else if (g_mouse_state.current_action == MOUSE_MODE_RESIZE) {
        uint64_t event_time = read_os_timer();
        float dt = ((float) event_time - g_mouse_state.last_moved_time) * (1000.0f / (float)read_os_freq());
        if (dt < 67.67f) goto out;

        int dx = point.x - g_mouse_state.down_location.x;
        int dy = point.y - g_mouse_state.down_location.y;

        window_manager_resize_window_relative_internal(g_mouse_state.window, g_mouse_state.window->frame, g_mouse_state.direction, dx, dy, false);

        g_mouse_state.last_moved_time = event_time;
        g_mouse_state.down_location = point;
    }

    struct view *src_view = window_manager_find_managed_window(&g_window_manager, g_mouse_state.window);
    if (!src_view) goto out;

    struct mouse_window_info info;
    mouse_window_info_populate(&g_mouse_state, &info);

    if (info.changed_position && !info.changed_size) {
        uint64_t cursor_sid = display_space_id(display_manager_point_display_id(point));
        struct view *dst_view = space_manager_find_view(&g_space_manager, cursor_sid);

        struct window *window = window_manager_find_window_at_point_filtering_window(&g_window_manager, point, g_mouse_state.window->id);
        if (!window) window = window_manager_find_window_at_point(&g_window_manager, point);
        if (window == g_mouse_state.window) window = NULL;

        struct window_node *a_node = view_find_window_node(src_view, g_mouse_state.window->id);
        struct window_node *b_node = window ? view_find_window_node(dst_view, window->id) : NULL;

        if (a_node && b_node && a_node != b_node) {
            if (g_mouse_state.feedback_node && g_mouse_state.feedback_node != b_node) {
                g_mouse_state.feedback_node->insert_dir = 0;
                insert_feedback_destroy(g_mouse_state.feedback_node);
            }

            int insert_dir = 0;
            enum mouse_drop_action drop_action = mouse_determine_drop_action(&g_mouse_state, a_node, window, point);
            switch (drop_action) {
            case MOUSE_DROP_ACTION_STACK: {
                insert_dir = STACK;
            } break;
            case MOUSE_DROP_ACTION_SWAP: {
                insert_dir = STACK;
            } break;
            case MOUSE_DROP_ACTION_WARP_TOP: {
                insert_dir = DIR_NORTH;
            } break;
            case MOUSE_DROP_ACTION_WARP_RIGHT: {
                insert_dir = DIR_EAST;
            } break;
            case MOUSE_DROP_ACTION_WARP_BOTTOM: {
                insert_dir = DIR_SOUTH;
            } break;
            case MOUSE_DROP_ACTION_WARP_LEFT: {
                insert_dir = DIR_WEST;
            } break;
            case MOUSE_DROP_ACTION_NONE: {
                /* silence compiler warning.. */
            } break;
            }

            if (b_node->insert_dir != insert_dir) {
                b_node->insert_dir = insert_dir;
                insert_feedback_show(b_node);
                g_mouse_state.feedback_node = b_node;
            }
        } else if (!b_node) {
            if (g_mouse_state.feedback_node) {
                g_mouse_state.feedback_node->insert_dir = 0;
                insert_feedback_destroy(g_mouse_state.feedback_node);
                g_mouse_state.feedback_node = NULL;
            }
        }
    }

out:
    CFRelease(context);
}

static EVENT_HANDLER(MOUSE_MOVED)
{
    // Mouse activity is the most recent focus modality — `smart`
    // space_focus_target_display uses this to target the cursor's display on
    // the next defaulted space --focus. Recorded for every move (cheap store),
    // ahead of the ffm/mission-control early-outs which gate focus-follows-mouse
    // only.
    g_window_manager.last_focus_method = FOCUS_METHOD_MOUSE;

    if (g_window_manager.ffm_mode == FFM_DISABLED) goto out;
    if (mission_control_is_active())               goto out;
    if (g_mouse_state.ffm_window_id)               goto out;

    if (__atomic_load_n(&__pending_gesture, __ATOMIC_RELAXED)) goto out;
    uint64_t last_gesture_time = __atomic_load_n(&__last_gesture_time, __ATOMIC_RELAXED);
    float dt = ((float) read_os_timer() - last_gesture_time) * (1000.0f / (float)read_os_freq());
    if (dt < 1250.0f) goto out;

    CGPoint point = CGEventGetLocation(context);
    struct window *window = window_manager_find_window_at_point(&g_window_manager, point);

    if (window) {
        if (window->id == g_window_manager.focused_window_id) goto out;
        if (!window_manager_is_window_eligible(window))       goto out;

        if (g_window_manager.ffm_mode == FFM_AUTOFOCUS) {

            //
            // NOTE(asmvik): Look for a window with role AXSheet or AXDrawer
            // and forward focus to it because we are not allowed to focus the main
            // window in these cases.
            //

            CFArrayRef window_list = SLSCopyAssociatedWindows(g_connection, window->id);
            if (window_list) {
                int window_count = CFArrayGetCount(window_list);

                uint32_t child_wid;
                for (int i = 0; i < window_count; ++i) {
                    CFNumberGetValue(CFArrayGetValueAtIndex(window_list, i), kCFNumberSInt32Type, &child_wid);
                    struct window *child = window_manager_find_window(&g_window_manager, child_wid);
                    if (!child) continue;

                    CFTypeRef role = window_role(child);
                    if (!role) continue;

                    bool valid = CFEqual(role, kAXSheetRole) || CFEqual(role, kAXDrawerRole);
                    CFRelease(role);

                    if (valid) {
                        window = child;
                        break;
                    }
                }

                CFRelease(window_list);
            }

            window_manager_focus_window_without_raise(&window->application->psn, window->id);
            g_mouse_state.ffm_window_id = window->id;
        } else if (g_window_manager.ffm_mode == FFM_AUTORAISE) {

            //
            // NOTE(asmvik): If any **floating** window would be fully occluded by
            // autoraising the window below the cursor we do not actually perform the
            // focus change, as it is likely that the user is trying to reach for the
            // smaller window that sits on top of the window we would otherwise raise.
            //

            bool occludes_window = false;

            int window_count;
            uint32_t *window_list = space_window_list(g_space_manager.current_space_id, &window_count, false);

            if (window_list) {
                for (int i = 0; i < window_count; ++i) {
                    uint32_t wid = window_list[i];
                    if (wid == window->id) break;

                    struct window *sub_window = window_manager_find_window(&g_window_manager, wid);
                    if (!sub_window) continue;

                    if (!window_check_flag(sub_window, WINDOW_FLOAT))                     continue;
                    if (window_level(window->id) != window_level(sub_window->id))         continue;
                    if (window_sub_level(window->id) != window_sub_level(sub_window->id)) continue;

                    if (CGRectContainsRect(window->frame, sub_window->frame)) {
                        occludes_window = true;
                        break;
                    }
                }
            }

            if (!occludes_window) {
                window_manager_focus_window_with_raise(&window->application->psn, window->id, window->ref);
                g_mouse_state.ffm_window_id = window->id;
            }
        }
    } else {
        uint32_t cursor_did = display_manager_point_display_id(point);
        if (g_display_manager.current_display_id == cursor_did) goto out;

        CGRect bounds = display_bounds_constrained(cursor_did, false);
        if (!cgrect_contains_point(bounds, point)) goto out;

        uint32_t wid = display_manager_focus_display_with_window_at_point(point);
        if (!wid) display_manager_set_active_display_id(cursor_did);
        g_mouse_state.ffm_window_id = wid;
    }

out:
    CFRelease(context);
}

// Mission Control hides the focus ring's alpha on entry (a scaled thumbnail
// transform would mis-place the stroke) and restores it on exit. Only the payload
// SYSTEM-alpha slot moves — geometry and the daemon `enabled` config are untouched.
// Async so the event thread never blocks on the SA round-trip.
static inline void focus_ring_mc_hide(void)    { focus_ring_set_visible_async(false); }
static inline void focus_ring_mc_restore(void) { focus_ring_set_visible_async(focus_ring_get_enabled()); }

static EVENT_HANDLER(MISSION_CONTROL_SHOW_ALL_WINDOWS)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS;
    LOGFT(__func__, "hide via OSL\n");   // the _OSL_ handler owns the hide
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

static EVENT_HANDLER(MISSION_CONTROL_SHOW_FRONT_WINDOWS)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW_FRONT_WINDOWS;
    LOGFT(__func__, "hide via OSL\n");
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

static EVENT_HANDLER(MISSION_CONTROL_SHOW_DESKTOP)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW_DESKTOP;
    LOGFT(__func__, "hide via OSL\n");
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

static EVENT_HANDLER(MISSION_CONTROL_ENTER)
{
    debug("%s:\n", __FUNCTION__);
    g_mission_control_mode = MISSION_CONTROL_MODE_SHOW;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, MISSION_CONTROL_CHECK_FOR_EXIT, NULL, 0);
    });

    LOGFT(__func__, "hide via OSL\n");
    event_signal_push(SIGNAL_MISSION_CONTROL_ENTER, (void*)(uintptr_t)g_mission_control_mode);
}

// Dock expose-mode names for the OSL param1: 0=showAllWindows (Mission Control),
// 1=showFrontWindows (app-Exposé), 2=showDesktop.
static const char *osl_mc_mode_name(int mode)
{
    switch (mode) {
        case 0: return "showAllWindows";
        case 1: return "showFrontWindows";
        case 2: return "showDesktop";
        default: return "?";
    }
}

// OSLog-driven MC-enter trigger: posted by the mission_control.c reader thread
// when Dock logs "Changing from mode .none to .show*" (~0.2-4ms after emit).
// param1 carries the expose mode (0/1/2). Sole ring-hide trigger for MC enter
// across all three modes; the AX SHOW_* handlers above only track mode + push
// signals, and their LOGFT markers record the OSL-vs-AX arrival delta.
static EVENT_HANDLER(MISSION_CONTROL_OSL_ENTER)
{
    // Ride the focused window's live enter transform: fade the ring OUT while its band
    // shrinks with the window into the thumbnail, then park it hidden — the mirror image
    // of the exit ride. Falls back to a plain snap-hide when disabled, no focused window,
    // or (payload-side) the enter transform isn't readable.
    // The ride animates the RING's band, so it MUST target the window the band is on:
    // focus_ring_get_target_wid() (the ring's last committed SHOW), NOT focused_window_id.
    // After a space switch the 815/816 refocus updates the ring's target but can leave
    // focused_window_id naming the OLD-space window; arming the ride off that stale id
    // rides a window the band isn't on — the payload's stroke_track target-guard bails
    // and the band freezes at full size. Use the ring's own target so ride == band.
    uint32_t enter_wid = focus_ring_get_target_wid();
    LOGFT(__func__, "mode=%d(%s) ride-out wid=%u\n", param1, osl_mc_mode_name(param1), enter_wid);
    if (focus_ring_get_enabled() && enter_wid) focus_ring_mc_enter_ride_async(enter_wid);
    else                                       focus_ring_mc_hide();
}

// OSLog-driven MC-exit trigger: posted by the reader thread when Dock logs
// "Changing from mode .show* to .none" (~0.2-4ms after emit). Symmetric inverse
// of MISSION_CONTROL_OSL_ENTER — owns the ring restore; the AX MISSION_CONTROL_EXIT
// handler keeps menubar/mode reset + window correction. If a focus landed during
// MC, reveal at that window's SETTLED real rect (reposition-then-reveal, so no
// flash at the stale thumbnail rect); otherwise just restore visibility. NOTE:
// fires at exit-START, concurrently with the AX MISSION_CONTROL_EXIT teardown —
// ordering vs correct_for_mission_control_changes is not synchronized; the
// settled/async machinery tolerates the early fire.
static EVENT_HANDLER(MISSION_CONTROL_OSL_EXIT)
{
    // Ride the focused window's live exit transform back to full instead of popping
    // the ring at the final rect. ride_wid = the focus that landed during MC
    // (deferred), else the ring's committed target — same ride==band invariant as
    // OSL_ENTER (never the space-switch-stale focused_window_id). The deferred wid,
    // when set, is retargeted onto the band below (focus_ring_show_for_wid_settled),
    // so both branches keep the ride and band on the same wid.
    uint32_t ride_wid = g_focus_ring_mc_deferred_wid ? g_focus_ring_mc_deferred_wid
                                                     : focus_ring_get_target_wid();

    LOGFT(__func__, "mode=%d(%s) ride wid=%u\n", param1, osl_mc_mode_name(param1), ride_wid);

    // A focus that landed during MC: re-target the ring's stroke to that window while
    // it's still hidden (visible=false from the MC-enter hide), so the reveal rides the
    // RIGHT window. Deliberately no visibility change here — the ride owns the reveal.
    if (g_focus_ring_mc_deferred_wid) {
        g_focus_ring_mc_deferred_wid = 0;
        focus_ring_show_for_wid_settled(ride_wid);
    }

    // The MC ride owns the reveal: it positions the band at the window's thumbnail rect
    // FIRST, then raises alpha in the same synchronous pass, so the ring is never shown
    // at its stale full-size band. Do NOT pre-raise alpha here — reveal-then-reposition
    // is the frame-0 flash. Gate on enabled so a disabled ring stays hidden (the ride,
    // which reveals, is only armed when enabled).
    if (focus_ring_get_enabled()) focus_ring_mc_ride_async(ride_wid);
    else                          focus_ring_mc_restore();
}

static EVENT_HANDLER(MISSION_CONTROL_CHECK_FOR_EXIT)
{
    if (!mission_control_is_active()) return;

    CFArrayRef window_list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, 0);
    int window_count = CFArrayGetCount(window_list);
    bool found = false;

    for (int i = 0; i < window_count; ++i) {
        CFDictionaryRef dictionary = CFArrayGetValueAtIndex(window_list, i);

        CFStringRef name = CFDictionaryGetValue(dictionary, kCGWindowName);
        if (name) continue;

        CFStringRef owner = CFDictionaryGetValue(dictionary, kCGWindowOwnerName);
        if (!owner) continue;

        CFNumberRef layer_ref = CFDictionaryGetValue(dictionary, kCGWindowLayer);
        if (!layer_ref) continue;

        uint64_t layer = 0;
        CFNumberGetValue(layer_ref, CFNumberGetType(layer_ref), &layer);
        if (layer != 18) continue;

        if (CFEqual(CFSTR("Dock"), owner)) {
            found = true;
            break;
        }
    }

    if (found) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1f * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            event_loop_post(&g_event_loop, MISSION_CONTROL_CHECK_FOR_EXIT, NULL, 0);
        });
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.0f), dispatch_get_main_queue(), ^{
            event_loop_post(&g_event_loop, MISSION_CONTROL_EXIT, NULL, 0);
        });
    }

    CFRelease(window_list);
}

static EVENT_HANDLER(MISSION_CONTROL_EXIT)
{
    debug("%s:\n", __FUNCTION__);

    if (g_window_manager.menubar_opacity != 1.0f) {
        float alpha = space_is_fullscreen(g_space_manager.current_space_id) ? 1.0f : g_window_manager.menubar_opacity;
        SLSSetMenuBarInsetAndAlpha(g_connection, 0, 1, alpha);
    }

    if (g_mission_control_mode == MISSION_CONTROL_MODE_SHOW || g_mission_control_mode == MISSION_CONTROL_MODE_SHOW_ALL_WINDOWS) {
        window_manager_correct_for_mission_control_changes(&g_space_manager, &g_window_manager);
    }

    event_signal_push(SIGNAL_MISSION_CONTROL_EXIT, (void*)(uintptr_t)g_mission_control_mode);
    g_mission_control_mode = MISSION_CONTROL_MODE_INACTIVE;

    // Ring restore (incl. the deferred-focus reveal) is driven by the OSLog
    // "... to .none" line (MISSION_CONTROL_OSL_EXIT); this handler keeps mode reset
    // + window correction. The marker logs AX-exit arrival for the OSL-vs-AX delta.
    LOGFT(__func__, "restore via OSL\n");   // the _OSL_ handler owns the restore
}

static EVENT_HANDLER(DOCK_DID_RESTART)
{
    debug("%s:\n", __FUNCTION__);

    if (workspace_is_macos_monterey() ||
        workspace_is_macos_ventura() ||
        workspace_is_macos_sonoma() ||
        workspace_is_macos_sequoia() ||
        workspace_is_macos_tahoe()) {
        mission_control_unobserve();
        mission_control_observe();
        mission_control_osl_unobserve(); // re-target the `log` child at the new Dock pid
        mission_control_osl_observe();
    }

    event_signal_push(SIGNAL_DOCK_DID_RESTART, NULL);
}

static enum ffm_mode ffm_value;
static int is_menu_open = 0;

static EVENT_HANDLER(MENU_OPENED)
{
    debug("%s\n", __FUNCTION__);
    ++is_menu_open;

    if (is_menu_open == 1) {
        ffm_value = g_window_manager.ffm_mode;
        g_window_manager.ffm_mode = FFM_DISABLED;
    }
}

static EVENT_HANDLER(MENU_CLOSED)
{
    debug("%s\n", __FUNCTION__);
    --is_menu_open;

    if (is_menu_open == 0) {
        g_window_manager.ffm_mode = ffm_value;
    } else if (is_menu_open < 0) {
        is_menu_open = 0;
    }
}

static EVENT_HANDLER(MENU_BAR_HIDDEN_CHANGED)
{
    debug("%s:\n", __FUNCTION__);
    space_manager_mark_spaces_invalid(&g_space_manager);
    event_signal_push(SIGNAL_MENU_BAR_HIDDEN_CHANGED, NULL);
}

static EVENT_HANDLER(DOCK_DID_CHANGE_PREF)
{
    debug("%s:\n", __FUNCTION__);
    space_manager_mark_spaces_invalid(&g_space_manager);
    event_signal_push(SIGNAL_DOCK_DID_CHANGE_PREF, NULL);
}

static EVENT_HANDLER(SYSTEM_WOKE)
{
    debug("%s:\n", __FUNCTION__);

    struct window *focused_window = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
    if (focused_window) {
        window_manager_set_window_opacity(&g_window_manager, focused_window, g_window_manager.active_window_opacity);
        window_manager_center_mouse(&g_window_manager, focused_window);
    }

    event_signal_push(SIGNAL_SYSTEM_WOKE, NULL);
}

static EVENT_HANDLER(DAEMON_MESSAGE)
{
    TIME_FUNCTION;

    FILE *rsp         = NULL;
    int bytes_read    = 0;
    int bytes_to_read = 0;

    if (read(param1, &bytes_to_read, sizeof(int)) == sizeof(int)) {
        char *message = ts_alloc_unaligned(bytes_to_read);

        do {
            int cur_read = read(param1, message+bytes_read, bytes_to_read-bytes_read);
            if (cur_read <= 0) break;

            bytes_read += cur_read;
        } while (bytes_read < bytes_to_read);

        if ((bytes_read == bytes_to_read) && (rsp = fdopen(param1, "w"))) {
            debug_message(__FUNCTION__, message);
            handle_message(rsp, message);

            fflush(rsp);
            fclose(rsp);

            return;
        }
    }

    socket_close(param1);
}
#pragma clang diagnostic pop

static void *event_loop_run(void *context)
{
    struct event *head, *next;
    struct event_loop *event_loop = context;

    while (event_loop->is_running) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

        for (;;) {
            profile_begin();

            do {
                head = __atomic_load_n(&event_loop->head, __ATOMIC_RELAXED);
                next = __atomic_load_n(&head->next, __ATOMIC_RELAXED);
                if (!next) goto empty;
            } while (!__sync_bool_compare_and_swap(&event_loop->head, head, next));

            switch (__atomic_load_n(&next->type, __ATOMIC_RELAXED)) {
#define EVENT_TYPE_ENTRY(value) case value: EVENT_HANDLER_##value(__atomic_load_n(&next->context, __ATOMIC_RELAXED), __atomic_load_n(&next->param1, __ATOMIC_RELAXED)); break;
                EVENT_TYPE_LIST
#undef EVENT_TYPE_ENTRY
            }

            event_signal_flush();
            ts_reset();

            profile_end_and_print();
        }

empty:
        [pool drain];
        sem_wait(event_loop->semaphore);
    }

    return NULL;
}

void event_loop_post(struct event_loop *event_loop, enum event_type type, void *context, int param1)
{
    bool success;
    struct event *tail, *new_tail;

    new_tail = memory_pool_push(&event_loop->pool, sizeof(struct event));
    __atomic_store_n(&new_tail->type, type, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->param1, param1, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->context, context, __ATOMIC_RELEASE);
    __atomic_store_n(&new_tail->next, NULL, __ATOMIC_RELEASE);
    __asm__ __volatile__ ("" ::: "memory");

    do {
        tail = __atomic_load_n(&event_loop->tail, __ATOMIC_RELAXED);
        success = __sync_bool_compare_and_swap(&tail->next, NULL, new_tail);
    } while (!success);
    __sync_bool_compare_and_swap(&event_loop->tail, tail, new_tail);

    sem_post(event_loop->semaphore);
}

bool event_loop_begin(struct event_loop *event_loop)
{
    if (!memory_pool_init(&event_loop->pool, KILOBYTES(512))) return false;

    event_loop->semaphore = sem_open("yabai_event_loop_semaphore", O_CREAT, 0600, 0);
    sem_unlink("yabai_event_loop_semaphore");
    if (event_loop->semaphore == SEM_FAILED) return false;

    event_loop->head = memory_pool_push(&event_loop->pool, sizeof(struct event));
    event_loop->head->next = NULL;
    event_loop->tail = event_loop->head;

    event_loop->is_running = true;
    pthread_create(&event_loop->thread, NULL, &event_loop_run, event_loop);

    return true;
}
