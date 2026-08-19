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

// NOTE: a focus landing DURING Mission Control is stashed here (last-write-wins), not
// shown — a show would paint the thumbnail transform. MISSION_CONTROL_OSL_EXIT reveals it.
static uint32_t g_focus_ring_mc_deferred_wid = 0;

// NOTE: closing a native-tab window can transiently front-switch another app, hijacking
// focused_window_id before the sibling tab's SLS_ADDED_TO_SPACE arrives. WINDOW_DESTROYED
// stamps the closing owner here so that handler's same-owner tab-follow still recognizes it.
static int      g_closed_window_owner;
static uint64_t g_closed_window_time;
volatile bool __pending_gesture;
volatile uint64_t __last_gesture_time;
volatile uint64_t __last_cmd_tab_time;

// NOTE: SLSRequestNotificationsForWindows hard-fails (subscribes NOTHING) at
// count >= 1024, it does not truncate — so cap every loop at 1023, not the array
// size, or an overflowing rebuild silently drops all subscriptions.
#define WINDOW_NOTIFICATION_CAP 1023

static void update_window_notifications(void)
{
    int window_count = 0;
    uint32_t window_list[WINDOW_NOTIFICATION_CAP];

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        // NOTE(asmvik): Subscribe to all windows because of window_destroyed (and ordered) notifications
        table_for (struct window *window, g_window_manager.window, {
            if (window_count >= WINDOW_NOTIFICATION_CAP) break;
            window_list[window_count++] = window->id;
        })
    } else {
        // NOTE(asmvik): Subscribe to windows that have a feedback_border because of window_ordered notifications
        table_for (struct window_node *node, g_window_manager.insert_feedback, {
            if (window_count >= WINDOW_NOTIFICATION_CAP) break;
            window_list[window_count++] = node->window_order[0];
        })
    }

    // NOTE: SLSRequestNotificationsForWindows REPLACES the connection's subscription set —
    // every rebuild must re-include the native-tab wids (AX-hidden, never in
    // g_window_manager.window) or tab switches go silent.
    table_for (void *tab_ptr, g_window_manager.tab_window, {
        if (window_count >= WINDOW_NOTIFICATION_CAP) break;
        uint32_t tab_wid = (uint32_t)(uintptr_t) tab_ptr;
        if (window_manager_find_window(&g_window_manager, tab_wid)) continue;
        window_list[window_count++] = tab_wid;
    })

    SLSRequestNotificationsForWindows(g_connection, window_list, window_count);
}

static struct {
    uint32_t gen;
    bool     active;
    uint32_t did;        // display the in-flight slide is on (0 = unknown -> gate all)
    uint64_t deadline;   // read_os_timer() tick past which active() self-expires
} g_space_transition;

bool space_transition_active(void)
{
    if (!__atomic_load_n(&g_space_transition.active, __ATOMIC_RELAXED)) return false;
    uint64_t deadline = __atomic_load_n(&g_space_transition.deadline, __ATOMIC_RELAXED);
    if (deadline && read_os_timer() > deadline) return false;
    return true;
}

// NOTE: a slide runs on ONE display; fails closed both ways — sd==0 (slide display
// unknown) gates every display, and did==0 (target display unresolvable) is gated too.
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

// NOTE: focus-authority change tracker — logs LS front-UI app (menu-bar owner)
// and SLPS key-focus transitions, change-only. Fed by tagged resolver-site
// scans plus a 10ms main-queue poll (SHM / single mach call — noise-level).
static struct {
    pthread_mutex_t lock;
    bool front_init, key_init;
    pid_t front_pid;
    pid_t key_pid;
    uint8_t key_fb;
    char front_name[64];
    char key_name[64];
} g_focus_authority = { .lock = PTHREAD_MUTEX_INITIALIZER };

static void focus_authority_pid_name(pid_t pid, char *buf, size_t bufsz)
{
    if (pid > 0) {
        struct application *app = window_manager_find_application(&g_window_manager, pid);
        if (app && app->name) { snprintf(buf, bufsz, "%s", app->name); return; }
        char pn[128] = {0};
        if (proc_name(pid, pn, sizeof pn) > 0 && pn[0]) { snprintf(buf, bufsz, "%s", pn); return; }
        snprintf(buf, bufsz, "pid:%d", pid);
    } else {
        snprintf(buf, bufsz, "(none)");
    }
}

static void focus_authority_scan(const char *site)
{
    pid_t front_pid = 0;
    LSASNRef front_asn = _LSCopyFrontUIApplication(kLSDefaultSessionID);
    if (front_asn) {
        CFTypeRef pid_value = _LSCopyApplicationInformationItem(kLSDefaultSessionID, front_asn, CFSTR("pid"));
        if (pid_value) {
            if (CFGetTypeID(pid_value) == CFNumberGetTypeID()) {
                int32_t v = 0;
                CFNumberGetValue((CFNumberRef) pid_value, kCFNumberSInt32Type, &v);
                front_pid = (pid_t) v;
            }
            CFRelease(pid_value);
        }
        CFRelease(front_asn);
    }

    ProcessSerialNumber key_psn = {0};
    uint8_t key_fb = 0;
    pid_t key_pid = 0;
    if (SLPSGetKeyFocusProcess(&key_psn, &key_fb) == 0) GetProcessPID(&key_psn, &key_pid);

    uint32_t fwid = g_window_manager.focused_window_id;
    char fwid_owner[64] = "?";
    struct window *fw = fwid ? window_manager_find_window(&g_window_manager, fwid) : NULL;
    if (fw && fw->application && fw->application->name)
        snprintf(fwid_owner, sizeof fwid_owner, "%s", fw->application->name);
    else if (!fwid)
        snprintf(fwid_owner, sizeof fwid_owner, "none");

    pthread_mutex_lock(&g_focus_authority.lock);

    if (!g_focus_authority.front_init || front_pid != g_focus_authority.front_pid) {
        char name[64];
        focus_authority_pid_name(front_pid, name, sizeof name);
        if (g_focus_authority.front_init) {
            LOGFT("FRONT_UI_APPLICATION_CHANGED", "[%s] %s(%d) -> %s(%d) | fwid=%u(%s)",
                  site, g_focus_authority.front_name, g_focus_authority.front_pid,
                  name, front_pid, fwid, fwid_owner);
        }
        g_focus_authority.front_pid = front_pid;
        memcpy(g_focus_authority.front_name, name, sizeof name);
        g_focus_authority.front_init = true;
    }

    if (!g_focus_authority.key_init || key_pid != g_focus_authority.key_pid ||
        key_fb != g_focus_authority.key_fb) {
        char name[64];
        focus_authority_pid_name(key_pid, name, sizeof name);
        if (g_focus_authority.key_init) {
            LOGFT("KEY_FOCUS_PROCESS_CHANGED", "[%s] %s(%d) fb=%u -> %s(%d) fb=%u | fwid=%u(%s)",
                  site, g_focus_authority.key_name, g_focus_authority.key_pid,
                  g_focus_authority.key_fb, name, key_pid, key_fb, fwid, fwid_owner);
        }
        g_focus_authority.key_pid = key_pid;
        g_focus_authority.key_fb = key_fb;
        memcpy(g_focus_authority.key_name, name, sizeof name);
        g_focus_authority.key_init = true;
    }

    pthread_mutex_unlock(&g_focus_authority.lock);
}

static void focus_authority_poll_begin(void)
{
    static dispatch_source_t s_timer;
    if (s_timer) return;
    s_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(s_timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 2 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(s_timer, ^{ focus_authority_scan("poll"); });
    dispatch_resume(s_timer);
}

static void window_did_receive_focus(struct window_manager *wm, struct mouse_state *ms, struct window *window)
{
    struct window *focused_window = window_manager_find_window(wm, wm->focused_window_id);
    if (focused_window && focused_window != window && window_space(focused_window->id) == window_space(window->id)) {
        window_manager_set_window_opacity(wm, focused_window, g_window_manager.normal_window_opacity);
    }

    window_manager_set_window_opacity(wm, window, wm->active_window_opacity);

    // NOTE: mff dedupe keys on last_centered_wid, not focused_window_id — a settle stamp
    // (window_manager_update_focused_window) can move focused_window_id here BEFORE this
    // funnel runs (new-window/deminimize), reading as "no change" and skipping the warp.
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
    wm->focused_display_id = window_display_id(window->id);
    ms->ffm_window_id = 0;

    // NOTE: recall is stamped here (the common sink), not in WINDOW_FOCUSED — inter-app
    // focus arrives via APPLICATION_FRONT_SWITCHED; AX FocusedWindowChanged is intra-app only.
    uint64_t focus_sid = window_space(window->id);
    if (focus_sid) {
        struct view *focus_view = space_manager_find_view(&g_space_manager, focus_sid);
        if (focus_view) focus_view->last_focused_wid = window->id;
    }

    if (g_verbose) {
        focus_ring_log("focus_event", "wid=%u app=%s frame=(%.0f,%.0f %.0fx%.0f) sid=%llu did=%u",
                       window->id,
                       window->application ? window->application->name : "?",
                       window->frame.origin.x, window->frame.origin.y,
                       window->frame.size.width, window->frame.size.height,
                       (unsigned long long) window_space(window->id),
                       window_display_id(window->id));
    }
    if (mission_control_is_active()) {
        g_focus_ring_mc_deferred_wid = window->id;
    } else {
        focus_ring_show_for_wid(window->id);
        // NOTE: a fresh SA load starts the payload's master-alpha slot at 0 — every show would
        // stamp the ring transparent. Re-asserting the enable state here self-heals it.
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

// NOTE: 808 is a wake hint (mostly demoted siblings); re-resolve identity from
// SLS key focus. Act on a 0 resolve only post-settle (815/816).
static void refocus_ring(uint32_t wake_wid, bool settled)
{
    if (!wake_wid) return;
    if (mission_control_is_active()) return;
    uint32_t did = g_window_manager.focused_display_id;
    if (space_transition_active() && space_transition_on_display(did)) return;
    uint64_t sid = did ? display_space_id(did) : SLSGetActiveSpace(g_connection);
    if (!sid || !space_is_visible(sid)) return;
    uint32_t wid = settled
                 ? window_manager_update_focused_window(&g_window_manager, sid)
                 : window_manager_space_key_focus_window(&g_window_manager, sid);
    if (wid) {
        focus_ring_show_for_wid(wid);
    } else if (settled) {
        focus_ring_hide_for_wid(focus_ring_get_target_wid(), "keyfocus-none");
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
// NOTE: table_find, not space_manager_find_view — that one creates a view for the sid it is
// handed, and window_space() answers 0 for a wid that is not on a space yet.
static bool tab_space_is_bsp(uint64_t sid)
{
    struct view *view = sid ? table_find(&g_space_manager.view, &sid) : NULL;
    return view && view->layout == VIEW_BSP;
}

// NOTE: AppKit never tabs a window whose app it does not consider tabbable, so no settle can
// be waiting on a tab signal for one — skip the buffer, the hold, and the AX bar read.
static bool tab_wid_uses_native_tabs(uint32_t wid)
{
    struct window *window = window_manager_find_window(&g_window_manager, wid);
    return !window || application_is_native_tabbable(window->application);
}

static bool mouse_left_button_down(void)
{
    return CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft);
}

// NOTE: a torn-off tab is ordered out for the whole drag and only materializes after mouse-up,
// so the drop target is read at MOUSE_UP and applied when its late tile runs. `wid` is the tab
// the gesture grabbed — a sibling reaches the tile first and would claim it; 0 = first-come.
static struct tab_drop { uint64_t sid; uint32_t target; int dir; uint32_t wid; uint64_t expires; } g_tab_drop;

// NOTE: a burst of tab creates retiles once per create and the take-over hands the node
// straight back — every tab signal re-arms this so nothing tiles until the burst goes
// quiet; only the timer resumes it.
#define TAB_SETTLE_BUFFER_MS 500
static uint64_t g_tab_settle_deadline;
static uint32_t g_tab_settle_gen;

static uint64_t tab_now_ns(void)
{
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * NSEC_PER_SEC + (uint64_t) ts.tv_nsec;
}

static bool tab_settle_buffered(void)
{
    return g_tab_settle_deadline && tab_now_ns() < g_tab_settle_deadline;
}

// NOTE: a drop dies with its gesture: dragging a tab onto another same-app window re-merges
// it, so the named wid never claims the drop and nothing else disarms it — and the claim
// path force-unlinks that wid from the group it legitimately rejoined.
#define TAB_DROP_TTL_MS 1500

static bool tab_drop_armed(void)
{
    if (!g_tab_drop.sid) return false;
    if (tab_now_ns() < g_tab_drop.expires) return true;
    memset(&g_tab_drop, 0, sizeof(g_tab_drop));
    return false;
}

// NOTE: the block runs on the main queue; every handler runs on the event-loop thread. Post
// rather than settle here — the pass frees windows the event thread is holding.
static void tab_settle_timer_post(uint32_t gen, int ms)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) ms * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        event_loop_post(&g_event_loop, TAB_SETTLE_TIMEOUT, (void *)(uintptr_t) gen, 0);
    });
}

// NOTE: WINDOW_CREATED picks the target space with window_space(), which can answer the
// previous (float) space before SLS commits membership — tile and add then both no-op on a
// float view with nothing to retry. Tab wids stay out: a demoted tab is unmanaged too.
static void late_tile_window(uint32_t wid)
{
    // NOTE: the drop is armed for the GESTURE, not for a wid — at MOUSE_UP the torn tab has not
    // re-entered yet, and the window the press landed on is a sibling it swapped away from. The
    // first wid to reach the tile claims it; every skip below leaves it armed for the next.
    struct tab_drop drop = tab_drop_armed() ? g_tab_drop : (struct tab_drop) {0};
    bool claims = drop.sid != 0 && (!drop.wid || drop.wid == wid);

    // An armed drop names its own target and is a gesture, not a burst — it is never buffered.
    if (!claims && tab_wid_uses_native_tabs(wid) && tab_settle_buffered()) {
        debug("%s: buffered wid=%d\n", __FUNCTION__, wid);
        return;
    }

    if (window_manager_is_tab_window(&g_window_manager, wid))     { debug("%s: skip benched wid=%d\n", __FUNCTION__, wid); return; }

    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window)                                                  { debug("%s: skip untracked wid=%d\n", __FUNCTION__, wid); return; }
    if (window_manager_find_managed_window(&g_window_manager, window)) { debug("%s: skip managed wid=%d\n", __FUNCTION__, wid); return; }

    // Honour the drop even when no member has taken the node over yet, or the group membership
    // outlives the tear-off and the torn tab is never tiled at all. Ahead of the group gate and
    // behind the managed one: only a window with no node of its own may be stripped.
    if (claims) window_manager_tab_group_unlink(&g_window_manager, wid);
    window_manager_tab_group_prune(&g_window_manager, wid);
    // NOTE: only a member that is ordered OUT is covered by its group — one that is ordered in is
    // a second window on screen holding no node, and nothing else places it: the reconcile calls a
    // node vacant only once its HOLDER leaves, so two visible members strand the one that is not it.
    uint8_t ordered_in = 0; SLSWindowIsOrderedIn(g_connection, wid, &ordered_in);
    if (!ordered_in) {
        if (window_manager_find_tab_group(&g_window_manager, wid)) { debug("%s: skip grouped wid=%d\n", __FUNCTION__, wid); return; }
        // NOTE: a burst outlives its own grouping — the link lands after the holds expire, so the
        // gate above cannot cover the tabs that need it most. Ordering in re-enters through the
        // displaced frame scan, which resolves the take-over without a group.
        if (tab_wid_uses_native_tabs(wid)) { debug("%s: skip ordered-out wid=%d\n", __FUNCTION__, wid); return; }
    }

    if (!window_manager_should_manage_window(window))             { debug("%s: skip unmanaged wid=%d\n", __FUNCTION__, wid); return; }

    // NOTE: window_space() answers the display's CURRENT space while a torn tab is still
    // stripped of membership, so for the wid the gesture named its own sid is the verdict —
    // trusting the lookup tiles a cross-display drop into the source display's tree.
    bool placed = claims;
    uint64_t sid = placed ? drop.sid : window_space(wid);
    struct view *view = space_manager_find_view(&g_space_manager, sid);
    if (!view || view->layout == VIEW_FLOAT)                      { debug("%s: skip non-bsp wid=%d\n", __FUNCTION__, wid); return; }

    // NOTE: consume the drop only once the tile is certain — every skip above has to leave it
    // armed, or an adoption that lags past this pass loses the placement for good.
    if (placed) memset(&g_tab_drop, 0, sizeof(g_tab_drop));

    uint32_t insertion = 0;
    struct window_node *node = placed ? view_find_window_node(view, drop.target) : NULL;
    if (node) {
        node->insert_dir = drop.dir;
        if (drop.dir == DIR_NORTH || drop.dir == DIR_SOUTH) node->split = SPLIT_X;
        if (drop.dir == DIR_EAST  || drop.dir == DIR_WEST)  node->split = SPLIT_Y;
        if (drop.dir == DIR_NORTH || drop.dir == DIR_WEST)  node->child = CHILD_FIRST;
        if (drop.dir == DIR_SOUTH || drop.dir == DIR_EAST)  node->child = CHILD_SECOND;
        insertion = drop.target;
    }

    debug("%s: late tile wid=%d sid=%lld drop_target=%d dir=%d\n", __FUNCTION__, wid, (long long) sid, insertion, node ? drop.dir : 0);
    struct view *dst = space_manager_tile_window_on_space_with_insertion_point(&g_space_manager, window, sid, insertion);
    window_manager_add_managed_window(&g_window_manager, window, dst);
}

// NOTE: a settle while the button is down acts under a live drag — the take-over's raise/flush
// takes the window off the cursor. Park the wid until MOUSE_UP and settle it there, before the
// drop logic, so the tear-off resolves first.
struct deferred_settle { uint32_t wid; bool retry_only; };
static struct deferred_settle *g_deferred_settles;

static void tab_settle_defer(uint32_t wid, bool retry_only)
{
    for (int i = 0; i < buf_len(g_deferred_settles); ++i) {
        if (g_deferred_settles[i].wid != wid) continue;
        if (!retry_only) g_deferred_settles[i].retry_only = false;
        return;
    }
    buf_push(g_deferred_settles, ((struct deferred_settle) { wid, retry_only }));
    debug("%s: settle deferred until mouse-up wid=%d\n", __FUNCTION__, wid);
}

// NOTE: a rapid create lands its 1325 before AppKit names the tab AND before the displaced
// sibling is ordered out, so neither the group nor the frame scan can answer A yet. Suppress
// the tile: once B is tiled it is managed, and no later evidence can hand it the group's node.
struct pending_settle { uint32_t wid; uint32_t a_wid; uint64_t expires; };
static struct pending_settle *g_pending_settles;

// NOTE: a hold expires on the clock, never on a pass count — the buffer swallows passes, so a
// burst that went quiet early stranded every hold it had queued. Nothing else re-runs the pass
// once the burst ends, so arming the wake here is what makes the deadline real.
#define TAB_HOLD_MS 600

static void tab_settle_hold(uint32_t wid, uint32_t a_wid)
{
    for (int i = 0; i < buf_len(g_pending_settles); ++i) {
        if (g_pending_settles[i].wid == wid) return;
    }
    buf_push(g_pending_settles, ((struct pending_settle) { wid, a_wid, tab_now_ns() + (uint64_t) TAB_HOLD_MS * NSEC_PER_MSEC }));
    debug("%s: tile held for wid=%d a=%d\n", __FUNCTION__, wid, a_wid);
    tab_settle_timer_post(0, TAB_HOLD_MS);
}

static bool tab_settle_is_queued(uint32_t wid)
{
    for (int i = 0; i < buf_len(g_pending_settles); ++i) {
        if (g_pending_settles[i].wid == wid) return true;
    }
    for (int i = 0; i < buf_len(g_deferred_settles); ++i) {
        if (g_deferred_settles[i].wid == wid) return true;
    }
    return false;
}

// NOTE: a tab that leaves its group only after the settle already declined it holds no node,
// and nothing re-derives one — a space change is the sole heal today. Skip any wid whose own
// settle is still owed, or this pass tiles what the hold is there to suppress.
static void tab_reclaim_orphans(void)
{
    uint32_t *orphans = NULL;

    table_for (struct window *w, g_window_manager.window, {
        if (window_manager_find_managed_window(&g_window_manager, w)) continue;
        if (!window_manager_should_manage_window(w)) continue;
        if (window_manager_is_tab_window(&g_window_manager, w->id)) continue;
        window_manager_tab_group_prune(&g_window_manager, w->id);
        if (window_manager_find_tab_group(&g_window_manager, w->id)) continue;
        if (tab_settle_is_queued(w->id)) continue;
        if (!__sync_bool_compare_and_swap(&w->id_ptr, &w->id, &w->id)) continue;

        uint8_t in = 0; SLSWindowIsOrderedIn(g_connection, w->id, &in);
        if (!in) continue;

        struct view *view = space_manager_find_view(&g_space_manager, window_space(w->id));
        if (!view || view->layout != VIEW_BSP) continue;

        buf_push(orphans, w->id);
    })

    for (int i = 0; i < buf_len(orphans); ++i) {
        debug("%s: orphan wid=%d\n", __FUNCTION__, orphans[i]);
        late_tile_window(orphans[i]);
    }
    buf_free(orphans);
}

// NOTE: every tab notification is a hint to re-resolve, never the answer — the 1325 can outrun
// both the AX name and the displaced tab's 816, and whichever lands last completes the pair.
// A held tile is one hypothesis the pass re-derives, dropped once its wid lands a node.
static void tab_reconcile_now(void)
{
    if (mission_control_is_active()) return;

    struct tab_hypothesis hints[16];
    int hint_count = 0;
    for (int i = 0; i < buf_len(g_pending_settles) && hint_count < 16; ++i) {
        hints[hint_count++] = (struct tab_hypothesis) { g_pending_settles[i].a_wid, g_pending_settles[i].wid };
    }

    // NOTE: no torn wid here — a tear is only legible once the window re-enters at the cursor,
    // which is after MOUSE_UP. window_manager_tab_group_torn_off names it then, off the frame
    // divergence; a vacancy resolved now is a plain switch and takes the take-over shape.
    window_manager_tab_reconcile(&g_window_manager, hints, hint_count, 0, tab_drop_armed() ? g_tab_drop.wid : 0);

    uint64_t now = tab_now_ns();
    int keep = 0;
    for (int i = 0; i < buf_len(g_pending_settles); ++i) {
        struct pending_settle p = g_pending_settles[i];
        struct window *b = window_manager_find_window(&g_window_manager, p.wid);
        if (!b) {  continue; }
        if (window_manager_find_managed_window(&g_window_manager, b)) {
            continue;
        }
        if (now < p.expires) { g_pending_settles[keep++] = p; continue; }
        late_tile_window(p.wid);
    }
    if (g_pending_settles) buf__hdr(g_pending_settles)->len = keep;

    if (!mouse_left_button_down()) tab_reclaim_orphans();
}

// NOTE: every hand-off flushes the node it moves, so reconciling per signal walks the group's
// node through every intermediate owner. Event handlers come through here; tab_reconcile_now()
// is only for a gesture end that must land now.
static void tab_reconcile(void)
{
    if (!tab_drop_armed() && tab_settle_buffered()) {
        debug("%s: buffered\n", __FUNCTION__);
        return;
    }
    tab_reconcile_now();
}

static void tab_settle_buffer_arm(void)
{
    g_tab_settle_deadline = tab_now_ns() + (uint64_t) TAB_SETTLE_BUFFER_MS * NSEC_PER_MSEC;

    uint32_t gen = ++g_tab_settle_gen;
    tab_settle_timer_post(gen, TAB_SETTLE_BUFFER_MS);
}

static EVENT_HANDLER(TAB_SETTLE_TIMEOUT)
{
    // NOTE: gen 0 is a hold expiry, not a buffer arm — it has to run whatever the buffer did
    // in the meantime, or the hold that asked for the wake is never released.
    uint32_t gen = (uint32_t)(uintptr_t) context;
    if (gen && gen != g_tab_settle_gen) {  return; }

    // The deadline has already lapsed, so every other settle path is live again; a gesture
    // still owns its own settle and MOUSE_UP runs the pass once the button comes up.
    if (mouse_left_button_down()) {  return; }

    // NOTE: a hold deadline is absolute from its arm while the buffer slides on every signal,
    // so the two cross on any burst that outruns one hold. Discharging here would clear the
    // deadline out from under the rest of the burst, and late_tile_window re-buffers anyway.
    if (!gen && tab_settle_buffered()) {
        uint64_t left = g_tab_settle_deadline - tab_now_ns();
        tab_settle_timer_post(0, (int)(left / NSEC_PER_MSEC) + 1);
        return;
    }

    const char *tag = gen ? "buffer.quiet" : "hold.wake";
    g_tab_settle_deadline = 0;
    debug("tab_settle_buffer: %s gen=%d — settling\n", tag, gen);
    tab_reconcile_now();
}

// NOTE: the menu names a create before any 1325 and without a focus pair, which is the pair the
// sibling arm cannot supply mid-burst. Arm only — a pid is not a wid, so there is nothing to hold
// yet, and Prefer Tabs makes the app's New-Window item a tab create too.
static EVENT_HANDLER(MENU_ITEM_SELECTED_NEW)
{
    if (!tab_space_is_bsp(space_manager_active_space())) return;
    debug("%s: pid=%d\n", __FUNCTION__, (pid_t)(intptr_t) context);
    tab_settle_buffer_arm();
}

// NOTE: a same-app managed window that is ordered OUT is the group's node standing vacant —
// the signature of a tab arriving, and unlike the incoming bounds it is not junk at 1325 time.
// A plain new window leaves its siblings on screen, so this stays false for one.
static bool tab_vacancy_on_space(uint32_t wid, int owner, uint64_t sid)
{
    if (!owner || !sid) return false;

    bool vacant = false;
    table_for (struct window *w, g_window_manager.window, {
        if (vacant || w->id == wid) continue;
        if (!window_manager_find_managed_window(&g_window_manager, w)) continue;
        if (window_space(w->id) != sid) continue;

        int wo = 0; SLSGetWindowOwner(g_connection, w->id, &wo);
        if (wo != owner) continue;

        uint8_t in = 0; SLSWindowIsOrderedIn(g_connection, w->id, &in);
        if (!in) vacant = true;
    })
    return vacant;
}

// NOTE: a hold hands the window a node some other member is vacating — with every managed
// window on the space still on screen there is nothing to inherit, and the hold strands it
// untiled on top of its neighbour. Vetoes both bar-driven holds.
static bool tab_node_awaiting_handover(uint32_t wid, uint64_t sid)
{
    if (!sid) return false;

    bool waiting = false;
    table_for (struct window *w, g_window_manager.window, {
        if (waiting || w->id == wid) continue;
        if (!window_manager_find_managed_window(&g_window_manager, w)) continue;
        if (window_space(w->id) != sid) continue;

        uint8_t in = 0; SLSWindowIsOrderedIn(g_connection, w->id, &in);
        if (!in) waiting = true;
    })
    return waiting;
}

// NOTE: SLSGetWindowOwner answers a CONNECTION id, not a pid — the application table is
// keyed by pid, so the tab bar is unreachable without this hop.
static AXUIElementRef tab_app_ref(int owner)
{
    pid_t pid = 0;
    if (!owner || SLSConnectionGetPID(owner, &pid) != kCGErrorSuccess || !pid) return NULL;

    struct application *app = window_manager_find_application(&g_window_manager, pid);
    return app ? app->ref : NULL;
}

static void tab_settle_space_add(uint32_t wid)
{

    // NOTE: a wid the drop names is a torn tab re-entering at its placement, not a member
    // joining a group. It has already left, so nothing will ever bench for it and the hold
    // below runs to expiry every time — the tab sits untiled for the buffer plus the hold.
    if (tab_drop_armed() && g_tab_drop.wid == wid) {
        late_tile_window(wid);
        return;
    }

    // NOTE: the sibling arm at tabbed_focus is the only other one, and it needs a focus pair —
    // fwid drops to 0 for a burst into a space with no focus history, so nothing buffers the
    // creates. A benched 1325 is the same churn named without one. Policy mirrors that site.
    if (!tab_drop_armed() && window_manager_is_tab_window(&g_window_manager, wid) &&
        tab_space_is_bsp(window_space(wid)) &&
        (!window_manager_find_tab_group(&g_window_manager, wid) || tab_settle_buffered())) {
        tab_settle_buffer_arm();
    }

    int owner = 0;  SLSGetWindowOwner(g_connection, wid, &owner);
    uint32_t fwid = g_window_manager.focused_window_id;
    int fowner = 0; if (fwid) SLSGetWindowOwner(g_connection, fwid, &fowner);
    bool same_owner = owner && owner == fowner;

    struct window *b0 = window_manager_find_window(&g_window_manager, wid);
    bool loose = (!b0 || !window_manager_find_managed_window(&g_window_manager, b0)) &&
                 tab_space_is_bsp(window_space(wid)) && !tab_drop_armed() &&
                 (!b0 || application_is_native_tabbable(b0->application));

    // NOTE: a rapid create stamps focus onto the incoming tab before its 1325 lands, so wid ==
    // fwid is a tab, not a plain window — tiling it splits the node the reconciler is about to
    // hand over. A false positive is released by the settle grace a few passes later.
    if (loose && same_owner && wid == fwid) {
        struct tab_ax_info ax = {0};
        tab_ax_read_app(tab_app_ref(owner), &ax);

        // NOTE: the bar runs a tab ahead of SLS here, so a group of two or more is the direct
        // answer where the vacancy is only its shadow — and the vacancy reads false whenever
        // the 1325 outruns the outgoing tab's order-out. The fallback is for AX declining.
        if (!tab_node_awaiting_handover(wid, window_space(wid))) {
        } else if (ax.count >= 2 || tab_vacancy_on_space(wid, owner, window_space(wid))) {
            tab_settle_hold(wid, 0);
            return;
        }
    }

    // NOTE: focused_window_id drops to 0 mid-burst once the outgoing tab goes untracked, taking
    // same_owner with it. The bar belongs to the app, so AXValue==1 still names the tab on
    // screen; only that exact answer may act without a focus pair to corroborate it.
    if (loose && !same_owner) {
        struct tab_ax_info ax = {0};
        tab_ax_read_app(tab_app_ref(owner), &ax);

        if (ax.count >= 2 && ax.selected == wid && !tab_node_awaiting_handover(wid, window_space(wid))) {
        } else if (ax.count >= 2 && ax.selected == wid) {
            tab_settle_hold(wid, 0);
            return;
        }
    }

    if (same_owner && wid != fwid) {
        struct window *b = window_manager_find_window(&g_window_manager, wid);
        bool eligible = b && !window_manager_find_managed_window(&g_window_manager, b) && tab_space_is_bsp(window_space(wid));
        struct window *torn = eligible ? window_manager_tab_group_torn_off(&g_window_manager, b) : NULL;
        if (torn && window_manager_tab_inherit_node(&g_window_manager, torn, b)) {
            debug("%s: tab tear-off: %d keeps the node, %d left the group\n", __FUNCTION__, b->id, torn->id);
            window_manager_tab_group_unlink(&g_window_manager, torn->id);
            late_tile_window(torn->id);
        } else {
            if (eligible) tab_reconcile();
            if (b && window_manager_find_managed_window(&g_window_manager, b)) return;

            // NOTE: hold only for an app that is demonstrably tabbing — the focused window
            // already belongs to a group. Without that, every plain new window opened while a
            // same-app window holds focus would be held, which is the common case, not a tab.
            struct window *f = window_manager_find_window(&g_window_manager, fwid);
            uint8_t f_in = 0; SLSWindowIsOrderedIn(g_connection, fwid, &f_in);
            if (eligible && f && f_in && window_manager_find_managed_window(&g_window_manager, f) &&
                window_manager_find_tab_group(&g_window_manager, fwid) &&
                window_space(fwid) == window_space(wid)) {
                tab_settle_hold(wid, fwid);
                return;
            }
            debug("%s: tab-follow wid=%d (focus was %d)\n", __FUNCTION__, wid, fwid);
        }
    }

    late_tile_window(wid);
}

static void tab_settle_deferred(void)
{
    for (int i = 0; i < buf_len(g_deferred_settles); ++i) {
        struct deferred_settle d = g_deferred_settles[i];
        debug("%s: replaying wid=%d%s\n", __FUNCTION__, d.wid, d.retry_only ? " (815 retry)" : "");
        if (d.retry_only) tab_reconcile();
        else              tab_settle_space_add(d.wid);
    }
    if (g_deferred_settles) buf__hdr(g_deferred_settles)->len = 0;
}

static bool tab_drag_torn(void)
{
    return ax_probe_click_torn();
}

// NOTE: a hand-off landing mid-drag demotes, collapses or swaps the grabbed window out from
// under the gesture; the group outlives all three, so resolve the vacated node through it
// rather than through g_mouse_state.window.
static struct window_node *tab_drag_source_node(struct window *t, struct view **out_view)
{
    if (!t) return NULL;

    struct view *view = window_manager_find_managed_window(&g_window_manager, t);
    struct window_node *node = view ? view_find_window_node(view, t->id) : NULL;

    struct tab_group *group = node ? NULL : window_manager_find_tab_group(&g_window_manager, t->id);
    for (int i = 0; group && i < buf_len(group->members) && !node; ++i) {
        struct window *m = window_manager_find_window(&g_window_manager, group->members[i]);
        if (!m || m == t) continue;
        view = window_manager_find_managed_window(&g_window_manager, m);
        if (view) node = view_find_window_node(view, m->id);
    }

    if (!node) return NULL;
    *out_view = view;
    return node;
}

// NOTE: AppKit claims the target's OWN tab bar for a same-owner tab drop — re-homing there is
// its business, not the grid's. The bar does not move under the drag; cache per target.
static struct { uint32_t wid; CGRect bar; bool has_bar; } g_tab_drop_bar;

static bool tab_drop_on_target_bar(struct window *window, CGPoint point)
{
    if (g_tab_drop_bar.wid != window->id) {
        g_tab_drop_bar.wid     = window->id;
        g_tab_drop_bar.has_bar = tab_ax_bar_bounds(window->ref, &g_tab_drop_bar.bar);
    }
    return g_tab_drop_bar.has_bar && CGRectContainsPoint(g_tab_drop_bar.bar, point);
}

static struct window_node *tab_drop_resolve(CGPoint point, struct view **out_view, struct window **out_window, int *out_dir)
{
    // NOTE: g_mouse_state.window is the window UNDER the press, which on a non-selected tab is
    // not the one being dragged and which a hand-off can move or null besides. The probe names
    // the grabbed wid at mouse-down; fall back only when it is untracked.
    uint32_t grab = ax_probe_click_wid();
    struct window *t = grab ? window_manager_find_window(&g_window_manager, grab) : NULL;
    if (!t) t = g_mouse_state.window;
    pid_t t_pid = t ? t->application->pid : 0;
    struct view *src_view = NULL;
    struct window_node *a_node = tab_drag_source_node(t, &src_view);
    if (!a_node) { return NULL; }

    uint64_t sid = display_space_id(display_manager_point_display_id(point));
    struct view *view = space_manager_find_view(&g_space_manager, sid);
    if (!view || view->layout != VIEW_BSP) { return NULL; }

    // NOTE: while torn, a same-owner drag proxy rides under the cursor and AppKit orders it in
    // as a real window — step past any same-owner window above the drag that owns no node.
    bool below_proxy = false;
    struct window *window = window_manager_find_window_at_point(&g_window_manager, point);
    if (!window || (window != t && window->application->pid == t_pid &&
                    !window_manager_find_managed_window(&g_window_manager, window))) {
        CGPoint wp; uint32_t top = 0; int cid = 0; pid_t pid = 0;
        SLSFindWindowAndOwner(g_connection, 0, 1, 0, &point, &wp, &top, &cid);
        for (int i = 0; i < 3 && top && cid == g_connection; ++i) SLSFindWindowAndOwner(g_connection, top, -1, 0, &point, &wp, &top, &cid);
        if (top) SLSConnectionGetPID(cid, &pid);
        if (top && (!t || top != t->id) && pid == t_pid) {
            window = window_manager_find_window_at_point_filtering_window(&g_window_manager, point, top);
            below_proxy = true;
        }
    }
    // NOTE: the self-drop rule below is inherited from dragging an ordinary window, which cannot
    // target itself; a torn tab is LEAVING this node, so a drop back onto it targets the
    // current occupant instead of refusing.
    struct area sa = a_node->area;
    bool reclaiming = false;
    if ((!window || window == t) && view == src_view && a_node->window_count > 0 &&
        CGRectContainsPoint(((CGRect) { { sa.x, sa.y }, { sa.w, sa.h } }), point)) {
        struct window *occupant = window_manager_find_window(&g_window_manager, a_node->window_order[0]);
        if (occupant && occupant != t) { window = occupant; reclaiming = true; }
    }

    if (!window)      { return NULL; }
    if (window == t)  { return NULL; }

    // NOTE: AppKit only merges within one app (_findWindowUnderMouse gates on the owning
    // connection), so a cross-app target is always the grid's. For a same-app target AppKit
    // claims its tab bar and takes the drop first, so never offer a split there. Exempt the
    // node the tab is vacating.
    if (!reclaiming && t && window->application == t->application &&
        tab_drop_on_target_bar(window, point)) {
        return NULL;
    }

    struct window_node *node = view_find_window_node(view, window->id);

    // NOTE: the tab that takes over during the drag holds no node until the reconcile runs, and
    // that trails MOUSE_UP by ~15ms — a drop landing in the gap names nothing. Its group still
    // carries the member the node belongs to, and that node is where the take-over lands.
    struct tab_group *wg = node ? NULL : window_manager_find_tab_group(&g_window_manager, window->id);
    for (int i = 0; wg && i < buf_len(wg->members) && !node; ++i) {
        if (t && wg->members[i] == t->id) continue;
        node = view_find_window_node(view, wg->members[i]);
    }

    if (!node && below_proxy && view == src_view && t) {
        struct tab_group *group = window_manager_find_tab_group(&g_window_manager, t->id);
        if (group && group == window_manager_find_tab_group(&g_window_manager, window->id)) node = a_node;
    }
    if (!node) { return NULL; }

    int dir = 0;
    switch (mouse_determine_drop_action(&g_mouse_state, a_node, window, point)) {
    case MOUSE_DROP_ACTION_STACK:       dir = STACK;     break;
    case MOUSE_DROP_ACTION_SWAP:        dir = 0;         break;
    case MOUSE_DROP_ACTION_WARP_TOP:    dir = DIR_NORTH; break;
    case MOUSE_DROP_ACTION_WARP_RIGHT:  dir = DIR_EAST;  break;
    case MOUSE_DROP_ACTION_WARP_BOTTOM: dir = DIR_SOUTH; break;
    case MOUSE_DROP_ACTION_WARP_LEFT:   dir = DIR_WEST;  break;
    case MOUSE_DROP_ACTION_NONE: return NULL;
    }

    *out_view = view;
    *out_window = window;
    *out_dir = dir;
    return node;
}

static void tab_drag_feedback_clear(void)
{
    if (!g_mouse_state.feedback_node) return;
    g_mouse_state.feedback_node->insert_dir = 0;
    insert_feedback_destroy(g_mouse_state.feedback_node);
    g_mouse_state.feedback_node = NULL;
}

// NOTE: with nothing of its own to swap, a centre drop is drawn as the whole-node cue and
// tiles as an auto split at the target; the cue is ordered above the hovered window because
// the node's own window (the torn tab) is off screen.
static struct window_node *tab_drag_feedback(CGPoint point, struct view **view, struct window **window, int *dir)
{
    struct window_node *node = tab_drop_resolve(point, view, window, dir);
    if (g_mouse_state.feedback_node != node) tab_drag_feedback_clear();
    if (!node) return NULL;

    int cue = *dir ? *dir : STACK;
    if (node->insert_dir != cue) {
        node->insert_dir = cue;
        insert_feedback_set_hittest(true);
        insert_feedback_show(node);
        insert_feedback_set_hittest(false);
        SLSSetWindowLevel(g_connection, node->feedback_window.id, window_level((*window)->id));
        SLSSetWindowSubLevel(g_connection, node->feedback_window.id, window_sub_level((*window)->id));
        g_mouse_state.feedback_node = node;
    }

    // NOTE: relative order holds only within a level and only until the next raise, and the drag
    // raises the window under the cursor. Over the node it is vacating that window IS
    // window_order[0], the one case insert_feedback_show's create-time order already covered.
    if (node->feedback_window.id) SLSOrderWindow(g_connection, node->feedback_window.id, 1, (*window)->id);
    return node;
}

static void tab_drop_arm(CGPoint point)
{
    struct view *view = NULL; struct window *window = NULL; int dir = 0;
    struct window_node *node = tab_drag_feedback(point, &view, &window, &dir);
    tab_drag_feedback_clear();
    if (!node) return;

    g_tab_drop = (struct tab_drop) { view->sid, window->id, dir, ax_probe_click_wid(),
                                     tab_now_ns() + (uint64_t) TAB_DROP_TTL_MS * NSEC_PER_MSEC };
    debug("%s: drop armed at %d dir=%d for wid=%d\n", __FUNCTION__, g_tab_drop.target, dir, g_tab_drop.wid);
}

static EVENT_HANDLER(APPLICATION_LAUNCHED)
{
    struct process *process = context;

    // NOTE: pids wrap at 99999, so a launch is the one moment a surviving hint for this
    // pid is known to name someone else's connection.
    window_manager_evict_wm_connection(&g_window_manager, process->pid);

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

    window_manager_seed_tab_windows(&g_window_manager, application);

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }
}

static EVENT_HANDLER(APPLICATION_TERMINATED)
{
    struct process *process = context;
    struct application *application = window_manager_find_application(&g_window_manager, process->pid);

    window_manager_evict_wm_connection(&g_window_manager, process->pid);

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
    focus_authority_scan("front_switched");
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

// NOTE: a leaf holding an ordered-out window is what `vacant` counts, so never hand one out
// while a tab burst is buffered. Over-holding costs at most the buffer — hold.expired falls
// back to late_tile_window — while tiling early is unrecoverable once the group link lands.
static bool tab_settle_buffered_ordered_out(uint32_t wid)
{
    if (!tab_settle_buffered()) return false;
    uint8_t in = 0; SLSWindowIsOrderedIn(g_connection, wid, &in);
    return !in;
}

static void window_created_log(const char *fn, struct window *window, const char *outcome)
{
    if (!g_verbose) return;

    uint8_t in = 0; SLSWindowIsOrderedIn(g_connection, window->id, &in);
    int level = 0;  SLSGetWindowLevel(g_connection, window->id, &level);
    CGRect r = {0}; SLSGetWindowBounds(g_connection, window->id, &r);

    uint32_t fwid = g_window_manager.focused_window_id;
    struct window *f = fwid ? window_manager_find_window(&g_window_manager, fwid) : NULL;

    debug("%s: wid=%d %-14s [%s] level=%d in=%d sid=%lld frame=(%.0f,%.0f %.0fx%.0f) "
          "focus=%d same_owner=%d bench=%d grp=%d buffered=%d\n",
          fn, window->id, outcome, window->application->name, level, in,
          (long long) window_space(window->id),
          r.origin.x, r.origin.y, r.size.width, r.size.height,
          fwid, f && f->application == window->application ? 1 : 0,
          window_manager_is_tab_window(&g_window_manager, window->id) ? 1 : 0,
          window_manager_find_tab_group(&g_window_manager, window->id) ? 1 : 0,
          tab_settle_buffered() ? 1 : 0);
}

static EVENT_HANDLER(WINDOW_CREATED)
{
    uint32_t window_id = ax_window_id(context);
    if (!window_id) { debug("%s: no wid on the AX ref\n", __FUNCTION__); CFRelease(context); return; }

    struct window *existing_window = window_manager_find_window(&g_window_manager, window_id);
    if (existing_window) { window_created_log(__FUNCTION__, existing_window, "skip.tracked"); CFRelease(context); return; }

    pid_t window_pid = ax_window_pid(context);
    if (!window_pid) { debug("%s: wid=%d skip.nopid\n", __FUNCTION__, window_id); CFRelease(context); return; }

    struct application *application = window_manager_find_application(&g_window_manager, window_pid);
    if (!application) { debug("%s: wid=%d skip.noapp pid=%d\n", __FUNCTION__, window_id, window_pid); CFRelease(context); return; }

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

    bool should_manage = window_manager_should_manage_window(window);
    bool already_managed = window_manager_find_managed_window(&g_window_manager, window) != NULL;

    if (should_manage && !already_managed) {
        // NOTE: a new native tab's AX window arrives BEFORE its 1325; tiling it fresh
        // splits the group's node before the 1325 take-over runs. Frame-match (focus still
        // on the displaced tab) means take over the group's node instead of splitting.
        struct window *displaced = (window->id != g_window_manager.focused_window_id && tab_space_is_bsp(window_space(window->id)))
            ? window_manager_tab_group_displaced_window(&g_window_manager, window)
            : NULL;
        uint32_t displaced_id = displaced ? displaced->id : 0;
        if (displaced && window_manager_tab_take_over_node(&g_window_manager, displaced, window)) {
            window_created_log(__FUNCTION__, window, "ok.take-over");
            debug("%s: tab take-over (AX) A=%d -> B=%d\n", __FUNCTION__, displaced_id, window->id);
        } else if (tab_settle_buffered_ordered_out(window->id) ||
                   (tab_settle_buffered() && window_manager_find_tab_group(&g_window_manager, window->id)) ||
                   tab_settle_is_queued(window->id)) {
            // NOTE: the displaced scan misses mid-burst whenever focus is already stamped on B
            // or the sibling has yet to order out, and the group link lands after the burst —
            // an ordered-out arrival under a live buffer is the leaf that would read vacant.
            window_created_log(__FUNCTION__, window, "ok.held");
            debug("%s: wid=%d held for the settle (displaced=%d)\n", __FUNCTION__, window->id, displaced_id);
            tab_settle_hold(window->id, displaced_id);
        } else {
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
            window_created_log(__FUNCTION__, window, view && view->layout == VIEW_BSP ? "ok.tiled" : "ok.float");
        }
    } else {
        window_created_log(__FUNCTION__, window, already_managed ? "skip.managed" : "skip.unmanaged");
    }

    if (window_manager_is_window_eligible(window)) {
        event_signal_push(SIGNAL_WINDOW_CREATED, window);
    }

    if (workspace_is_macos_sequoia() || workspace_is_macos_tahoe()) {
        update_window_notifications();
    }

    refocus_ring(window->id, false);
}
static EVENT_HANDLER(WINDOW_DESTROYED)
{
    struct window *window = context;
    if (!window || window->id == 0) {
        debug("%s: window has already been destroyed, ignoring event..\n", __FUNCTION__);
        return;
    }
    uint32_t wid   = window->id;
    uint64_t sid   = SLSGetActiveSpace(g_connection);
    uint64_t start = read_os_timer();
    uint32_t last  = 0;
    printf("1326_probe: START destroyed_wid=%u sid=%lld\n", wid, (long long) sid);
    fflush(stdout);
    for (int i = 0; ; ++i) {
        uint64_t elapsed = read_os_timer() - start;
        if (elapsed >= 50000000ull) break;
        uint32_t now = window_manager_space_key_focus_window(&g_window_manager, sid);
        // printf("1326_probe: [+%7.1f ms] #%02d key_focus=%u%s\n",
        //        elapsed / 1.0e6, i, now, (i && now != last) ? "  <-- CHANGED" : "");
        fflush(stdout);
        last = now;
        usleep(16000);
    }
    printf("1326_probe: END\n");
    fflush(stdout);

    debug("%s: %s %d\n", __FUNCTION__, window->application ? window->application->name : "<unknown>", window->id);

    struct view *view = window_manager_find_managed_window(&g_window_manager, window);
    uint64_t destroyed_sid = view ? view->sid : g_space_manager.current_space_id;
    bool was_focused = g_window_manager.focused_window_id == window->id;

    // NOTE: closing the selected tab of a group is a HAND-OFF, not a vacancy — macOS
    // promotes a sibling into the same screen real estate. Untiling would collapse the node
    // and re-tile the survivor somewhere else, reshaping the tree on every close.
    if (view && window_manager_adopt_tab_group_members(&g_space_manager, &g_window_manager, window)) {
        update_window_notifications();
    }

    struct window *heir = view ? window_manager_tab_group_heir(&g_window_manager, window) : NULL;
    if (heir && window_manager_tab_inherit_node(&g_window_manager, window, heir)) {
        debug("%s: tab close %d -> heir %d inherits the node\n", __FUNCTION__, window->id, heir->id);
        window_manager_focus_window_with_raise(&heir->application->psn, heir->id, heir->ref);
        window_manager_stamp_focused_window(&g_window_manager, heir->id);
        view = NULL;
    }

    // NOTE: unlink eagerly on ANY destroy — the server recycles wids, and a stale member
    // aims a take-over at the wrong window. Dropping a live tab only costs the group its
    // identity until the next switch re-links it, which is the pre-group-table behaviour.
    window_manager_tab_group_unlink(&g_window_manager, window->id);

    if (view) {
        space_manager_untile_window(view, window);
        window_manager_remove_managed_window(&g_window_manager, window->id);
    }

    if (g_mouse_state.window == window) g_mouse_state.window = NULL;
    if (g_mouse_state.ffm_window_id == window->id) g_mouse_state.ffm_window_id = 0;

    focus_ring_hide_for_wid(window->id, "destroy");

    if (window->is_eligible) {
        event_signal_push(SIGNAL_WINDOW_DESTROYED, window);
    }

    // NOTE: when an app's last window on a space closes, macOS keeps the windowless app
    // front and moves no keyboard focus — advance to the space's topmost tracked window,
    // else the Finder desktop. With a same-space survivor macOS refocuses on its own.
    if (was_focused && window->application) {
        uint32_t survivor = window_manager_space_application_window(&g_window_manager, window->application, destroyed_sid);
        if (!survivor || survivor == window->id) {
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
    focus_authority_scan("window_focused");

    // NOTE: AppKit names a window untabbed as it focuses one it is about to tab, so the wid
    // TABGROUP_UPDATED just stamped is a rename, not a detach. Reading it as one unlinks the
    // member the create is mid-flight on, and the create then splits the group's node.
    bool tab_renamed = param1 && window_id && window_id == g_window_manager.tab_focused_wid;
    if (param1) g_window_manager.tab_focused_wid = 0;
    if (tab_renamed) debug("%s: %d was just named a tab — rename, not a detach\n", __FUNCTION__, window_id);

    // Detach on AppKit's own predicate (application.c), ahead of every early return below:
    // the fact is about tabbedness, not about whether this wid is tracked or focusable.
    if (param1 && !tab_renamed && window_manager_tab_group_unlink(&g_window_manager, window_id)) {
        debug("%s: %d left its tab group\n", __FUNCTION__, window_id);
    }

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

    window_did_receive_focus(&g_window_manager, &g_mouse_state, window);
    event_signal_push(SIGNAL_WINDOW_FOCUSED, window);
}

// NOTE: AppKit substitutes AXFocusedTabChanged for kAXFocusedWindowChanged on any window
// whose tab group holds more than one member (-[NSApplication _setKeyWindow:]), so a tabbed
// window NEVER reaches WINDOW_FOCUSED. It is the FIRST event of a switch — ahead of the
// AppKit frame sync, the 815/816 pair and the 1325/1326 space shuffle — which is what makes
// focused_window_id still the OUTGOING tab here: the authoritative pair arrives complete.
static EVENT_HANDLER(TABGROUP_UPDATED)
{
    uint32_t wid = (uint32_t)(intptr_t) context;
    if (!wid) return;

    g_window_manager.tab_focused_wid = wid;

    // NOTE: a rapid create stamps focus onto the incoming tab before AppKit names it, so
    // focused_window_id is the window itself; last_window_id still holds the tab it displaced.
    uint32_t prev = g_window_manager.focused_window_id;
    if (prev == wid) prev = g_window_manager.last_window_id;

    int owner = 0;  SLSGetWindowOwner(g_connection, wid, &owner);
    int powner = 0; if (prev) SLSGetWindowOwner(g_connection, prev, &powner);
    bool same_owner = owner && owner == powner && prev != wid;

    uint8_t b_in = 0; SLSWindowIsOrderedIn(g_connection, wid, &b_in);
    uint8_t p_in = 0; if (prev) SLSWindowIsOrderedIn(g_connection, prev, &p_in);
    struct window *b = window_manager_find_window(&g_window_manager, wid);

    // NOTE: a sibling pair means the incoming tab was OFF screen. A tracked, ordered-in incoming
    // is a separate window the app keyed (click, Cmd-`, promotion on close); ordered-in is
    // space-invariant, so an off-space window still reads foreign. A mouse select can order the
    // pair before this post lands, so a tracked incoming is foreign only while prev is still on
    // screen too — and a prev the app just minimized has the same signature.
    struct window *p = prev ? window_manager_find_window(&g_window_manager, prev) : NULL;
    bool foreign = b && ((b_in && p_in) || window_check_flag(b, WINDOW_MINIMIZE));
    bool sibling = same_owner && (p_in || b_in) && !foreign && !(p && window_check_flag(p, WINDOW_MINIMIZE));

    debug("%s: %s %d -> %s prev=%d (in=%d prev_in=%d same_owner=%d)\n", __FUNCTION__,
          b ? "Tracked" : window_manager_is_tab_window(&g_window_manager, wid) ? "Benched" : "Unknown",
          wid, sibling ? "sibling" : "foreign", prev, b_in, p_in, same_owner);

    // NOTE: two ESTABLISHED groups fusing is the tear-off / re-home false pair — the source and
    // destination windows each swap a tab mid-drag, and the next name crosses them. Only that
    // branch pays for the bar read; a plain insert cannot over-merge.
    struct tab_group *ga = prev ? window_manager_find_tab_group(&g_window_manager, prev) : NULL;
    struct tab_group *gb = window_manager_find_tab_group(&g_window_manager, wid);
    bool would_merge = sibling && ga && gb && ga != gb;

    struct tab_ax_info ax = { .count = -1, .selected = 0 };
    if (g_verbose || would_merge) {
        tab_ax_read_app(tab_app_ref(owner), &ax);
    }

    // Members past the bar's own tab count cannot be one group; a lagging group reads under it.
    int merged = would_merge ? window_manager_tab_group_member_count(&g_window_manager, prev) +
                               window_manager_tab_group_member_count(&g_window_manager, wid) : 0;
    if (would_merge && ax.count >= 0 && merged > ax.count) {
        debug("%s: Refused merge %d <-> %d (%d members > %d tabs)\n", __FUNCTION__, prev, wid, merged, ax.count);
    } else if (sibling) {
        // NOTE: no group yet means a create, which arms the buffer; a switch only re-arms one in
        // flight. Anchor the space on prev — its membership survives the drag-time strip, where
        // window_space(wid) would answer the display's current space.
        bool created = !gb;
        if ((created || tab_settle_buffered()) &&
            tab_space_is_bsp(window_space(p ? prev : wid))) tab_settle_buffer_arm();
        if (window_manager_tab_group_link(&g_window_manager, prev, wid)) {
            debug("%s: Linked %d <-> %d\n", __FUNCTION__, prev, wid);
            // A name that lands after the 1325 is the group's first answer: settle it now.
            if (mouse_left_button_down()) tab_settle_defer(wid, true);
            else                          tab_reconcile();
        }
    } else if (b && b_in && wid != prev) {
        // NOTE: for a multi-member group this IS the focus notification (application.h), so a
        // foreign pair must land focus itself, and inline: a tab-bar click on another window
        // queues activation and select back-to-back, and the select reads prev from here. A
        // sibling pair leaves focus to the take-over, which stamps B once the node has moved.
        EVENT_HANDLER_WINDOW_FOCUSED((void *)(intptr_t) wid, 0);
    }

    // Earliest possible adopt: the 1325/815 sites retry this, but landing it here means the
    // take-over they run finds a tracked B on its first attempt.
    if (window_manager_adopt_tab_window(&g_space_manager, &g_window_manager, wid)) {
        debug("%s: Adopted %d\n", __FUNCTION__, wid);
        update_window_notifications();
    }
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
    if (window_flags_changed(&g_window_manager, window))
        event_signal_push(SIGNAL_WINDOW_FLAGS_CHANGED, window);

    bool windowed_fullscreen = CGRectEqualToRect(window->windowed_frame, window->frame);
    window->frame.origin = new_origin;

    if (!windowed_fullscreen) {
        window_clear_flag(window, WINDOW_WINDOWED);

        if (!g_mouse_state.window || g_mouse_state.window != window) {
            // NOTE: no AX-diff flush while animating — each commit lands here with new_origin !=
            // node->area and would re-seed.
            if (!window_manager_is_animating(window->id) &&
                !window_manager_stepped_active(window->id)) {
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

    // NOTE: stepped resizes retarget the ring up front (fire-and-forget);
    // reacting to per-step AX events here would fight the payload-side band
    // animation. The settle truth-up runs when the stepped tick completes.
    if (!window_manager_is_animating(window->id) &&
        !window_manager_stepped_active(window->id))
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
                if (!window_manager_is_animating(window->id) &&
                    !window_manager_stepped_active(window->id)) {
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

    if (window_flags_changed(&g_window_manager, window))
        event_signal_push(SIGNAL_WINDOW_FLAGS_CHANGED, window);

    if (!window_manager_is_animating(window->id) &&
        !window_manager_stepped_active(window->id))
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
    focus_authority_scan("window_ordered");
    struct window_node *node = table_find(&g_window_manager.insert_feedback, &wid);
    if (node) SLSOrderWindow(g_connection, node->feedback_window.id, 1, node->window_order[0]);

    struct window *ordered = window_manager_find_window(&g_window_manager, wid);
    if (ordered && window_flags_changed(&g_window_manager, ordered)) {
        event_signal_push(SIGNAL_WINDOW_FLAGS_CHANGED, ordered);
    }

    struct window *focused = window_manager_find_window(&g_window_manager, g_window_manager.focused_window_id);
    if (focused && focused != ordered && window_flags_changed(&g_window_manager, focused)) {
        event_signal_push(SIGNAL_WINDOW_FLAGS_CHANGED, focused);
    }

    // The AX FocusedWindowChanged path goes silent for same-app clicks between
    // multi-tab Ghostty windows; 808 still fires — reconcile the ring off it.
    // refocus_ring re-resolves the key-focus window itself, so this (often
    // demoted-sibling) payload wid is only a wake hint.
    refocus_ring(wid, false);
}

// NOTE: cold-tab AX adoption retry — a click-switch 1325 can race the app's AX window list,
// and the settling 815 is the second shot (keyboard switches fire no 815).
static EVENT_HANDLER(SLS_WINDOW_VISIBLE)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    focus_authority_scan("window_visible");

    if (window_manager_adopt_tab_window(&g_space_manager, &g_window_manager, wid)) {
        debug("%s: adopted tab wid=%d into AX tracking\n", __FUNCTION__, wid);
        update_window_notifications();
    }

    // Retry gated on tracked-but-unmanaged, not on a fresh adopt: a 1325 whose adopt already
    // succeeded but whose bounds hadn't settled leaves B tracked yet floating, so a later 815
    // for the same wid must still be able to complete the take-over.
    if (mouse_left_button_down()) tab_settle_defer(wid, true);
    else                          tab_reconcile();

    refocus_ring(wid, true);
}

// NOTE: the ordered-OUT edge (816) — the outgoing tab's node standing vacant, pushed. Without
// it the vacancy is only found by polling SLSWindowIsOrderedIn() once the settle timer fires,
// so a switch landing between two arms holds its node until the next quiet period.
static EVENT_HANDLER(SLS_WINDOW_INVISIBLE)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    focus_authority_scan("window_invisible");

    if (mouse_left_button_down()) tab_settle_defer(wid, true);
    else                          tab_reconcile();

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

// NOTE: space-membership ADD (1325) — the one signal every native-tab switch emits. A
// click-switch also settles an 815; a keyboard switch does not.
static EVENT_HANDLER(SLS_ADDED_TO_SPACE)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    focus_authority_scan("added_to_space");

    int owner = 0;  SLSGetWindowOwner(g_connection, wid, &owner);
    uint32_t fwid = g_window_manager.focused_window_id;
    int fowner = 0; if (fwid) SLSGetWindowOwner(g_connection, fwid, &fowner);
    bool same_owner = owner && owner == fowner;

    // NOTE: normal-level wids only — menus, popovers, help tags and status items never carry
    // a tab or a tile, and without this gate a reconnected display's desktop-level Finder
    // chrome was swept into the tab set.
    int level = 0; SLSGetWindowLevel(g_connection, wid, &level);

    if (g_verbose) {
        uint8_t ordered_in = 0;
        SLSWindowIsOrderedIn(g_connection, wid, &ordered_in);
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

    if (level != 0) {
        debug("%s: skipping tab handling for wid=%d (level=%d)\n", __FUNCTION__, wid, level);
    } else {
        if (!window_manager_find_window(&g_window_manager, wid)) {
            bool is_new = window_manager_add_tab_window(&g_window_manager, wid);
            bool adopted = window_manager_adopt_tab_window(&g_space_manager, &g_window_manager, wid);
            debug("%s: %s tab wid=%d owner=%d adopted=%d\n", __FUNCTION__,
                  is_new ? "NEW" : "re-materialized", wid, owner, adopted);
            if (is_new || adopted) update_window_notifications();
        }

        if (mouse_left_button_down()) tab_settle_defer(wid, false);
        else                          tab_settle_space_add(wid);
    }

    if (same_owner && wid != fwid) {
        debug("%s: tab-follow wid=%d (focus was %d)\n", __FUNCTION__, wid, fwid);
        refocus_ring(wid, true);
    }

    window_manager_instant_fullscreen_follow(wid);
}

// NOTE: space-membership REMOVE (1326). Fires on a genuine space-leave (send-to-space,
// transfer, destroy) — NOT tab de-select; redundant with 804's remove on a real close.
static EVENT_HANDLER(SLS_REMOVED_FROM_SPACE)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);
    if (window_manager_remove_tab_window(&g_window_manager, wid))
        update_window_notifications();
}

static EVENT_HANDLER(SLS_WINDOW_DESTROYED)
{
    uint32_t wid = (uint64_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, wid);

    if (window_manager_remove_tab_window(&g_window_manager, wid)) {
        window_manager_tab_group_unlink(&g_window_manager, wid);
        debug("%s: removed tab wid=%d from tab set\n", __FUNCTION__, wid);
        update_window_notifications();
        return;
    }

    struct window *window = window_manager_find_window(&g_window_manager, wid);
    if (!window || !__sync_bool_compare_and_swap(&window->id_ptr, &window->id, &window->id)) {
        if (window) debug("%s: %d has been marked invalid by the system, ignoring event..\n", __FUNCTION__, wid);
        window_manager_tab_group_unlink(&g_window_manager, wid);
        return;
    }

    // NOTE: WINDOW_DESTROYED scans the dying window's group for an heir and unlinks only after —
    // unlinking here first empties the group, so a managed tab falls through to untile and
    // collapses a node its siblings are still using.
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

        // Dock mints this space its own picture, which the floor's build-time sweep
        // never saw — unblanked, it occludes the floor on the new space.
        if (g_window_manager.wallpaper_floor) wallpaper_floor_refresh();
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
    focus_authority_scan("space_changed");

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

    // NOTE: an SA slide commits the space with no app activation, so focus stays on the
    // outgoing space — recall the space's last-focused window, else its topmost. Never
    // raise a minimized/hidden recall target: entering a space must not deminimize/unhide.
    if (view && !mission_control_is_active()) {
        struct window *target = NULL;
        if (view->last_focused_wid) {
            struct window *recall = window_manager_find_window(&g_window_manager, view->last_focused_wid);
            if (recall && window_space(recall->id) == g_space_manager.current_space_id
                && !window_check_flag(recall, WINDOW_MINIMIZE)
                && !recall->application->is_hidden) {
                target = recall;
            }
        }
        if (!target) {
            target = window_manager_space_topmost_tracked_window(&g_window_manager, g_space_manager.current_space_id, 0);
        }
        if (target && target->id != g_window_manager.focused_window_id) {
            window_manager_focus_window_with_raise(&target->application->psn, target->id, target->ref);
        }
    }

    // NOTE: stamp AFTER the recall raise — its gate compares against the pre-switch id, and
    // stamping first suppresses the raise (macOS usually already granted key to the target).
    // MC-gated: mid-MC the key process is Dock and would wipe the id to 0.
    if (!mission_control_is_active()) {
        window_manager_update_focused_window(&g_window_manager, g_space_manager.current_space_id);
    }

    event_signal_push(SIGNAL_SPACE_CHANGED, NULL);

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

// NOTE: one display power-cycle emits ADDED/REMOVED plus TWO MOVED, and the
// MOVED that re-lays-out the surviving displays lands after ADDED — rebuilding
// per event would thrash and would capture pre-move geometry. Coalesce, and
// rebuild only what the user already raised (build supersedes live slots).
static uint32_t g_wallpaper_floor_reconfigure_gen;

static void wallpaper_floor_reconfigure(void)
{
    if (!g_window_manager.wallpaper_floor) return;
    uint32_t gen = __atomic_add_fetch(&g_wallpaper_floor_reconfigure_gen, 1,
                                      __ATOMIC_RELAXED);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5f * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != __atomic_load_n(&g_wallpaper_floor_reconfigure_gen, __ATOMIC_RELAXED)) return;
        if (!g_window_manager.wallpaper_floor) return;
        wallpaper_floor_build();
    });
}

static EVENT_HANDLER(DISPLAY_ADDED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    space_manager_handle_display_add(&g_space_manager, did);
    window_manager_handle_display_add_and_remove(&g_space_manager, &g_window_manager, did);

    // NOTE: a (re)connected display mints a fresh Finder desktop wid the startup-only
    // tracking never saw — re-track (idempotent) so it is focus-targetable / not a "tab".
    window_manager_track_role_windows(&g_window_manager);

    wallpaper_floor_reconfigure();
    event_signal_push(SIGNAL_DISPLAY_ADDED, context);
}

static EVENT_HANDLER(DISPLAY_REMOVED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    display_manager_remove_label_for_display(&g_display_manager, did);
    window_manager_handle_display_add_and_remove(&g_space_manager, &g_window_manager, display_manager_main_display_id());

    window_manager_track_role_windows(&g_window_manager);

    wallpaper_floor_reconfigure();
    event_signal_push(SIGNAL_DISPLAY_REMOVED, context);
}

static EVENT_HANDLER(DISPLAY_MOVED)
{
    uint32_t did = (uint32_t)(intptr_t) context;
    debug("%s: %d\n", __FUNCTION__, did);
    space_manager_mark_spaces_invalid(&g_space_manager);
    wallpaper_floor_reconfigure();
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
    memset(&g_tab_drop, 0, sizeof(g_tab_drop));
    memset(&g_tab_drop_bar, 0, sizeof(g_tab_drop_bar));
    tab_drag_feedback_clear();

    if (mission_control_is_active())                     goto out;
    if (g_mouse_state.current_action != MOUSE_MODE_NONE) goto out;

    CGPoint point = CGEventGetLocation(context);
    debug("%s: %.2f, %.2f focused_window_id: %d\n", __FUNCTION__, point.x, point.y, g_window_manager.focused_window_id);

    // NOTE: stamp the focus display from click GEOMETRY before this click's focus events
    // drain — a stale 808/815 off the departed display would resolve against the old anchor.
    uint32_t click_did = display_manager_point_display_id(point);
    if (click_did) g_window_manager.focused_display_id = click_did;

    // NOTE: the AX hit-test costs ~96ms p90, so pay it only where a tab bar can exist.
    struct window *under = window_manager_find_window_at_point(&g_window_manager, point);
    ax_probe_click_target(point, CGEventGetType(context) == kCGEventRightMouseDown,
                          application_native_tabbable_cached(under ? under->application : NULL));

    struct window *window = window_manager_find_window_at_point(&g_window_manager, point);
    if (!window || window_check_flag(window, WINDOW_FULLSCREEN)) goto out;

    // NOTE: a same-app cross-display click onto a window already topmost on its own space
    // emits no 808/815 and AX stays silent — this post is the only signal that lands the
    // focus. Routed through WINDOW_FOCUSED so the canonical cascade and its guards run.
    if (window->id != g_window_manager.focused_window_id) {
        event_loop_post(&g_event_loop, WINDOW_FOCUSED, (void *)(intptr_t) window->id, 0);
    }

    g_mouse_state.window = window;
    g_mouse_state.window_frame = g_mouse_state.window->frame;
    g_mouse_state.down_location = point;
    g_mouse_state.direction = 0;

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
    focus_ring_set_drag_follow(false);

    // NOTE: arm before the teardown — a gesture can show the overlay all the way down and
    // still fail to resolve at the release point, which is what decides where the window lands.
    CGPoint up = CGEventGetLocation(context);
    bool on_bar = ax_probe_click_in_bar(up);
    if (tab_drag_torn() && !on_bar) tab_drop_arm(up);

    // NOTE: the arm clears the overlay, but an on-bar release skips it and was_tab_drag skips
    // the generic teardown below — and this overlay accepts events, so outliving its drag means
    // swallowing real clicks until the node is next retiled.
    tab_drag_feedback_clear();

    bool was_tab_drag = ax_probe_click_was_tab();
    ax_probe_click_end();

    tab_settle_deferred();
    tab_reconcile_now();

    if (mission_control_is_active()) goto out;

    // NOTE: a tab drag moves a TAB, never the window the press landed on, but it looks like an
    // ordinary window drag to everything below — same mousedown, same moved position — so the
    // generic drop path would swap or warp g_mouse_state.window on a gesture the tab side has
    // already resolved, or deliberately declined.
    if (was_tab_drag)                goto res;

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
    ax_probe_click_drag(CGEventGetLocation(context));

    if (mission_control_is_active()) goto out;

    // NOTE: ahead of the g_mouse_state.window guard on purpose — the tear-off is named by the
    // bar exit, and a hand-off that nulls the pointer must not take the gesture with it.
    if (tab_drag_torn()) {
        struct view *view; struct window *window; int dir;
        tab_drag_feedback(CGEventGetLocation(context), &view, &window, &dir);
        goto out;
    }

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
    // NOTE: ahead of the ffm/MC early-outs — `smart` display targeting reads this for every move.
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

static const char *osl_mc_mode_name(int mode)
{
    switch (mode) {
        case 0: return "showAllWindows";
        case 1: return "showFrontWindows";
        case 2: return "showDesktop";
        default: return "?";
    }
}

// OSLog MC-enter (param1 = expose mode): sole ring-hide trigger; the AX SHOW_* handlers
// only track mode + signals.
// NOTE: the parked wallpaper floor is a space member sunk below level 0, so it
// survives every space switch on its own; Mission Control is the one transition
// that composites all spaces at once and would reveal it.
static EVENT_HANDLER(MISSION_CONTROL_OSL_ENTER)
{
    if (g_window_manager.wallpaper_floor) wallpaper_floor_set_hidden(true);

    // NOTE: the enter ride animates the ring's BAND, so it targets focus_ring_get_target_wid(),
    // never focused_window_id — after a space switch the latter can name the old-space window
    // and the payload's target-guard bails, freezing the band at full size.
    uint32_t enter_wid = focus_ring_get_target_wid();
    LOGFT(__func__, "mode=%d(%s) ride-out wid=%u\n", param1, osl_mc_mode_name(param1), enter_wid);
    if (focus_ring_get_enabled() && enter_wid) focus_ring_mc_enter_ride_async(enter_wid);
    else                                       focus_ring_mc_hide();
}

// OSLog MC-exit: owns the ring restore; the AX EXIT handler keeps mode reset + window
// correction. Fires at exit-START, unsynchronized with the AX teardown.
static EVENT_HANDLER(MISSION_CONTROL_OSL_EXIT)
{
    if (g_window_manager.wallpaper_floor) wallpaper_floor_set_hidden(false);

    // NOTE: a focus deferred during MC re-targets the band while still hidden, and the ride
    // owns the reveal (position, then alpha, one pass) — pre-raising alpha here is the
    // frame-0 flash at the stale rect. Same band==ride target rule as OSL_ENTER.
    uint32_t ride_wid = g_focus_ring_mc_deferred_wid ? g_focus_ring_mc_deferred_wid
                                                     : focus_ring_get_target_wid();

    LOGFT(__func__, "mode=%d(%s) ride wid=%u\n", param1, osl_mc_mode_name(param1), ride_wid);

    if (g_focus_ring_mc_deferred_wid) {
        g_focus_ring_mc_deferred_wid = 0;
        focus_ring_show_for_wid_settled(ride_wid);
    }

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

    // The floor's spaces and windows were Dock-owned and died with it; the payload's
    // slot table is stale either way, so build from scratch once it has re-injected.
    if (g_window_manager.wallpaper_floor) wallpaper_floor_build();

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

    focus_authority_poll_begin();

    return true;
}
