// payload_inc/anim_owner.inc.m
//
// Per-wid animation ownership registry (AC-14) — cross-animator arbitration.
//
// Every continuous animator in this payload (anim, g_xfade, drag_warp,
// g_focus_fade, the upstream window_fade threads) hand-rolls its own
// interrupt mechanism, and none of them can see each other: any two that
// touch the same wid fight — last writer into the shared per-VBL transaction
// wins per frame, and whoever settles last stomps the other's terminal state.
// This registry centralizes the one idiom they all already use ("generation
// check at write time") so the checks work ACROSS animators, not just within
// one.
//
// Model: two channels per wid —
//   GEO   = T3D + LockedBounds + AX as ONE channel; the composed resize
//           recipe is non-substitutable, so its parts are never owned
//           separately.
//   ALPHA = window alpha.
// Each channel has a monotonic generation (never reset → no ABA) and an
// owner tag. The row additionally records GEO terminal intent (deathwatch
// reads this in AC-17 instead of inferring from matrix shape) and the
// steady-state alpha captured at the FIRST alpha claim (what settles restore
// to instead of a hardcoded 1.0 — SPA-9).
//
// Threading / lock discipline:
//   - g_anim_owner_lock is a strict LEAF: never call SLS and never take an
//     animator lock while holding it.
//   - anim_claim / anim_set_terminal run on the SA handler thread (animator
//     begin paths), where every begin already serializes. NEVER call them on
//     the ca_clock pump. anim_claim is a pure table op (no SLS), so calling
//     it while holding an animator lock (anim begin holds g_anim_lock)
//     is fine under the leaf discipline.
//   - anim_release may run from any context EXCEPT the pump hot path: the SA
//     handler thread inline, dispatched-off-pump blocks, or the main queue
//     (xfade's settle block). A stale release (a newer claim took the
//     channel) is a no-op, so racing a concurrent claim is safe.
//   - anim_owns is the per-frame write gate: lock-free (atomic wid + gen
//     loads), safe on the pump hot path at xfade scale (~512 wids/frame).
//     Every transient race resolves to `false` = "you don't own it" = the
//     caller skips its write — always the conservative outcome.
//   - anim_baseline_alpha / anim_terminal_intent take the leaf lock; they
//     are one-shot settle/sweep reads, not per-frame.
//
// Tag map: AC-14 = this table; AC-15 gates xfade <-> anim on it; SPA-9 =
// baseline-alpha capture (anim_baseline_capture below — claims themselves
// never call SLS); AC-16 folds anim's `superseded` + g_lb_wid_gen into it;
// AC-17 wires terminal intent.

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

// Caller holds g_anim_owner_lock. Find the wid's row; if absent, key a new
// slot at the high-water mark, or — table full — re-key a fully released row
// (both owners NONE: its begins are long done, so no live token can refer to
// it through this wid). Re-keying keeps the row's gens (monotonic per ROW,
// not per wid) so a token from the slot's previous life can never match.
// Falls back to row 0 only past 1024 distinct wids with live owners, which
// realistic concurrent-animation counts never approach.
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

// Claim a channel of a wid. SA handler thread only — never on the pump.
// Returns the generation token the caller must present to anim_owns on every
// per-frame write and to anim_release when it cedes. A claim over a live
// owner is a TAKEOVER: the old owner's token goes stale and its gated writes
// stop landing; eviction courtesies (e.g. xfade seed calling
// anim_skip_all_to_end) stay explicit and per-owner.
// Pure table op — no SLS — so it's safe while holding an animator lock and
// cheap at xfade seed scale (2 claims x 512 wids). Baseline-alpha capture is
// SPA-9's job, at a call site where an SLS read per wid is affordable.
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

// The per-frame write gate: does `gen` still own the channel? Lock-free —
// safe on the pump hot path. Any race with a concurrent claim/re-key
// resolves to false (skip the write), never to a stale write landing.
static bool anim_owns(uint32_t wid, enum anim_channel ch, uint64_t gen)
{
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_acquire);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_acquire) != wid) continue;
        return atomic_load_explicit(&g_anim_owner[i].gen[ch], memory_order_acquire) == gen;
    }
    return false;
}

// Owner cedes a channel. Bumps the generation so any in-flight async work
// still holding this token (dispatched-off-pump AX completions, stale
// settle resets) fails its anim_owns check. A stale release (a newer claim
// already took the channel) is a no-op. Row keeps baseline + terminal.
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

// Record GEO terminal intent (stage-thumb apply marks PERSIST) so settle
// paths and the deathwatch sweep read intent instead of inferring it from
// matrix shape.
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

// AC-18: the smallest alpha trusted as a steady state. A real config never
// parks a window near 0 (yabai's --opacity 0.0 means "reset to default"), but
// a stranded animation residue is exactly near-0 (a slide's final frame leaves
// 1-ease ≈ 0.001). Recording one bakes invisibility into the restore target —
// every later slide then fades the window 0→0 ("stuck invisible"). Sub-epsilon
// reads and stored baselines are distrusted; capture falls back to 1.0, which
// actively HEALS an already-stranded window on its next slide.
#define ANIM_BASELINE_MIN_ALPHA 0.01f

// SPA-9: capture a wid's steady-state alpha into its row and return the
// baseline. Call BEFORE claiming the ALPHA channel: while the channel is
// owned, the live alpha is a mid-fade transient, so an owned row returns the
// stored baseline untouched; an unowned row re-reads — a --opacity change
// between animations refreshes the restore target instead of going stale.
// The SLS read happens OFF the leaf lock; it's a server round-trip, so call
// from seed/begin paths only (never the pump, never while holding an animator
// lock). Returns 1.0 when nothing was ever recorded and the read fails.
static float anim_baseline_capture(uint32_t wid)
{
    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_relaxed) != wid) continue;
        if (g_anim_owner[i].owner[ANIM_CH_ALPHA] != ANIM_OWNER_NONE && g_anim_owner[i].baseline_known
            && g_anim_owner[i].baseline_alpha >= ANIM_BASELINE_MIN_ALPHA) {
            float alpha = g_anim_owner[i].baseline_alpha;   // mid-animation: live alpha is transient
            pthread_mutex_unlock(&g_anim_owner_lock);
            return alpha;
        }
        break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);

    float cur = 1.0f;
    bool have = (SLSGetWindowAlpha(SLSMainConnectionID(), wid, &cur) == kCGErrorSuccess);
    if (have && cur < ANIM_BASELINE_MIN_ALPHA) have = false;   // AC-18: stranded residue, not a steady state

    pthread_mutex_lock(&g_anim_owner_lock);
    struct anim_claim_row *r = anim_row_find_or_create(wid);
    // Re-check under the lock: a claim landing in the read gap makes `cur`
    // suspect — only overwrite a known baseline if the channel is still free.
    if (have && (r->owner[ANIM_CH_ALPHA] == ANIM_OWNER_NONE || !r->baseline_known)) {
        r->baseline_alpha = cur;
        r->baseline_known = true;
    }
    // Sub-epsilon stored baselines are distrusted the same way — restore to
    // 1.0 heals them.
    cur = (r->baseline_known && r->baseline_alpha >= ANIM_BASELINE_MIN_ALPHA) ? r->baseline_alpha : 1.0f;
    pthread_mutex_unlock(&g_anim_owner_lock);
    return cur;
}

// Steady-state alpha to restore at settle/handoff; 1.0 when no alpha claim
// ever recorded one. One-shot settle read — takes the leaf lock, fine off
// the per-frame path.
static float anim_baseline_alpha(uint32_t wid)
{
    float alpha = 1.0f;
    pthread_mutex_lock(&g_anim_owner_lock);
    int hwm = atomic_load_explicit(&g_anim_owner_hwm, memory_order_relaxed);
    for (int i = 0; i < hwm; ++i) {
        if (atomic_load_explicit(&g_anim_owner[i].wid, memory_order_relaxed) != wid) continue;
        if (g_anim_owner[i].baseline_known && g_anim_owner[i].baseline_alpha >= ANIM_BASELINE_MIN_ALPHA)
            alpha = g_anim_owner[i].baseline_alpha;   // AC-18: sub-epsilon = poisoned, fall back to 1.0
        break;
    }
    pthread_mutex_unlock(&g_anim_owner_lock);
    return alpha;
}

// Format the registry for the anim_owner_dump SA probe. Snapshots under the
// leaf lock; truncates gracefully when the response buffer fills.
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
