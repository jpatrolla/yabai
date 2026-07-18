// anim_owner.inc.m — per-wid animation ownership registry: cross-animator
// arbitration via generation tokens (claim -> gated per-frame writes -> release).
// NOTE: GEO = T3D + LockedBounds + AX as ONE channel — the composed resize
// recipe is non-substitutable, so its parts are never owned separately.
// Generations are monotonic and never reset (no ABA). g_anim_owner_lock is a
// strict leaf: no SLS calls and no animator lock while held. anim_claim /
// anim_set_terminal: SA handler thread only, never the pump; anim_release: any
// context except the pump hot path; anim_owns: lock-free, pump-safe.

#define ANIM_OWNER_MAX 1024

enum anim_channel {
    ANIM_CH_GEO   = 0,
    ANIM_CH_ALPHA = 1,
    ANIM_CH_COUNT = 2
};

enum anim_owner_tag {
    ANIM_OWNER_NONE = 0,
    ANIM_OWNER_LB_T3D,
    ANIM_OWNER_XFADE,
    ANIM_OWNER_FOCUS_FADE,
    ANIM_OWNER_DRAG_WARP,
    ANIM_OWNER_WINDOW_FADE,
    ANIM_OWNER_ONESHOT
};

enum anim_terminal {
    ANIM_TERMINAL_IDENTITY = 0,   // settle → identity / LB clear
    ANIM_TERMINAL_PERSIST  = 1    // settle leaves the matrix (stage thumbs)
};

struct anim_claim_row {
    _Atomic uint32_t wid;                    // row key; 0 = unused slot
    _Atomic uint64_t gen[ANIM_CH_COUNT];     // monotonic per row, never reset
    uint8_t          owner[ANIM_CH_COUNT];   // enum anim_owner_tag, lock-guarded
    uint8_t          terminal;               // enum anim_terminal (GEO intent)
    float            baseline_alpha;         // steady-state alpha (SPA-9 captures)
    bool             baseline_known;
};

static struct anim_claim_row g_anim_owner[ANIM_OWNER_MAX];
static _Atomic int           g_anim_owner_hwm;   // rows [0, hwm) are keyed
static pthread_mutex_t       g_anim_owner_lock = PTHREAD_MUTEX_INITIALIZER;

static const char *anim_owner_tag_name(uint8_t tag)
{
    switch (tag) {
    case ANIM_OWNER_NONE:        return "none";
    case ANIM_OWNER_LB_T3D:      return "lb_t3d";
    case ANIM_OWNER_XFADE:       return "xfade";
    case ANIM_OWNER_FOCUS_FADE:  return "focus_fade";
    case ANIM_OWNER_DRAG_WARP:   return "drag_warp";
    case ANIM_OWNER_WINDOW_FADE: return "window_fade";
    case ANIM_OWNER_ONESHOT:     return "oneshot";
    default:                     return "?";
    }
}

// Caller holds g_anim_owner_lock. NOTE: re-key only fully released rows, and
// keep the row's gens across a re-key (monotonic per ROW, not per wid) so a
// token from the slot's previous life can never match.
static struct anim_claim_row *anim_row_find_or_create(uint32_t wid)
{
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_relaxed) == wid)
            return &g_anim_owner[i];
    }

    struct anim_claim_row *r = NULL;
    if (hwm < ANIM_OWNER_MAX) {
        r = &g_anim_owner[hwm];
        atomic_store_explicit(&g_anim_owner_hwm, hwm + 1, memory_order_release);
    } else {
        for (int i = 0; i < ANIM_OWNER_MAX; ++i) {
            if (g_anim_owner[i].owner[ANIM_CH_GEO]   == ANIM_OWNER_NONE &&
                g_anim_owner[i].owner[ANIM_CH_ALPHA] == ANIM_OWNER_NONE) { r = &g_anim_owner[i]; break; }
        }
        if (!r) r = &g_anim_owner[0];
        logpf("ANIM", "anim_owner: table full — re-keyed a row for wid=%u", wid);
        r->terminal       = ANIM_TERMINAL_IDENTITY;
        r->baseline_alpha = 0.0f;
        r->baseline_known = false;
    }
    atomic_store_explicit(&r->wid, wid, memory_order_release);
    return r;
}

// Claim a channel; returns the token presented to anim_owns on every write and
// to anim_release. A claim over a live owner is a TAKEOVER — the old token goes
// stale. Pure table op, no SLS.
static uint64_t anim_claim(uint32_t wid, enum anim_channel ch, enum anim_owner_tag owner)
{
    pthread_mutex_lock(&g_anim_owner_lock);
    struct anim_claim_row *r = anim_row_find_or_create(wid);
    uint64_t gen = atomic_load_explicit(&r->gen[ch], memory_order_relaxed) + 1;
    atomic_store_explicit(&r->gen[ch], gen, memory_order_release);
    r->owner[ch] = (uint8_t) owner;
    pthread_mutex_unlock(&g_anim_owner_lock);
    return gen;
}

// Per-frame write gate, lock-free. Races resolve to false (skip the write) —
// never to a stale write landing.
static bool anim_owns(uint32_t wid, enum anim_channel ch, uint64_t gen)
{
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_acquire);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_acquire) != wid) continue;
        return atomic_load_explicit(&g_anim_owner[i].gen[ch], memory_order_acquire) == gen;
    }
    return false;
}

// Cede a channel: bump the gen so in-flight async holders of this token fail
// anim_owns. A stale release (newer claim took the channel) is a no-op.
static void anim_release(uint32_t wid, enum anim_channel ch, uint64_t gen)
{
    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        struct anim_claim_row *r = &g_anim_owner[i];
        if (atomic_load_explicit(&r->wid, memory_order_relaxed) != wid) continue;
        if (atomic_load_explicit(&r->gen[ch], memory_order_relaxed) == gen) {
            atomic_store_explicit(&r->gen[ch], gen + 1, memory_order_release);
            r->owner[ch] = ANIM_OWNER_NONE;
        }
        break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);
}

// GEO terminal intent — settles/deathwatch read intent, not matrix shape.
static void anim_set_terminal(uint32_t wid, enum anim_terminal terminal)
{
    pthread_mutex_lock(&g_anim_owner_lock);
    struct anim_claim_row *r = anim_row_find_or_create(wid);
    r->terminal = (uint8_t) terminal;
    pthread_mutex_unlock(&g_anim_owner_lock);
}

static enum anim_terminal anim_terminal_intent(uint32_t wid)
{
    enum anim_terminal terminal = ANIM_TERMINAL_IDENTITY;
    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_relaxed) != wid) continue;
        terminal = (enum anim_terminal) g_anim_owner[i].terminal;
        break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);
    return terminal;
}

// NOTE: smallest alpha trusted as a steady state. Near-0 is stranded animation
// residue, not config (--opacity 0.0 means "reset"); recording it bakes "stuck
// invisible" into the restore target. Distrust it and fall back to 1.0 (heals).
#define ANIM_BASELINE_MIN_ALPHA 0.01f

// Capture steady-state alpha. NOTE: call BEFORE claiming ALPHA — an owned
// channel returns the stored baseline (live alpha is a mid-fade transient); an
// unowned row re-reads so --opacity changes refresh. SLS read runs off the
// leaf lock: seed/begin paths only, never the pump or under an animator lock.
static float anim_baseline_capture(uint32_t wid)
{
    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_relaxed) != wid) continue;
        if (g_anim_owner[i].owner[ANIM_CH_ALPHA] != ANIM_OWNER_NONE && g_anim_owner[i].baseline_known
            && g_anim_owner[i].baseline_alpha >= ANIM_BASELINE_MIN_ALPHA) {
            float alpha = g_anim_owner[i].baseline_alpha;
            pthread_mutex_unlock(&g_anim_owner_lock);
            return alpha;
        }
        break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);

    float cur = 1.0f;
    bool have = (SLSGetWindowAlpha(SLSMainConnectionID(), wid, &cur) == kCGErrorSuccess);
    if (have && cur < ANIM_BASELINE_MIN_ALPHA) have = false;

    pthread_mutex_lock(&g_anim_owner_lock);
    struct anim_claim_row *r = anim_row_find_or_create(wid);
    if (have && (r->owner[ANIM_CH_ALPHA] == ANIM_OWNER_NONE || !r->baseline_known)) {
        r->baseline_alpha = cur;
        r->baseline_known = true;
    }
    cur = (r->baseline_known && r->baseline_alpha >= ANIM_BASELINE_MIN_ALPHA) ? r->baseline_alpha : 1.0f;
    pthread_mutex_unlock(&g_anim_owner_lock);
    return cur;
}

static float anim_baseline_alpha(uint32_t wid)
{
    float alpha = 1.0f;
    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_relaxed) != wid) continue;
        if (g_anim_owner[i].baseline_known && g_anim_owner[i].baseline_alpha >= ANIM_BASELINE_MIN_ALPHA)
            alpha = g_anim_owner[i].baseline_alpha;
        break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);
    return alpha;
}

static void anim_owner_dump(char *buf, size_t len)
{
    size_t off = 0;
    #define ANIM_DUMP(...) do {                                                     \
        if (off < len) {                                                            \
            int _n = snprintf(buf + off, len - off, __VA_ARGS__);                   \
            if (_n > 0) off += (size_t) _n;                                         \
        }                                                                           \
    } while (0)

    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    ANIM_DUMP("anim_owner: %d/%d rows keyed\n", hwm, ANIM_OWNER_MAX);
    for (int i = 0; i < hwm; ++i) {
        struct anim_claim_row *r = &g_anim_owner[i];
        uint32_t wid = atomic_load_explicit(&r->wid, memory_order_relaxed);
        char baseline[16] = "-";
        if (r->baseline_known) snprintf(baseline, sizeof(baseline), "%.2f", r->baseline_alpha);
        ANIM_DUMP("  wid=%-10u geo[g=%llu o=%s] alpha[g=%llu o=%s] terminal=%s baseline=%s\n",
                  wid,
                  (unsigned long long) atomic_load_explicit(&r->gen[ANIM_CH_GEO], memory_order_relaxed),
                  anim_owner_tag_name(r->owner[ANIM_CH_GEO]),
                  (unsigned long long) atomic_load_explicit(&r->gen[ANIM_CH_ALPHA], memory_order_relaxed),
                  anim_owner_tag_name(r->owner[ANIM_CH_ALPHA]),
                  r->terminal == ANIM_TERMINAL_PERSIST ? "persist" : "identity",
                  baseline);
        if (off >= len) break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);

    if (off >= len && len > 16) snprintf(buf + len - 13, 13, "\n[truncated]");
    #undef ANIM_DUMP
}
