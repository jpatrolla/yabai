#ifndef DISPLAYLINK_H
#define DISPLAYLINK_H

// =========================================================================
// displaylink.h — shared CVDisplayLink clock helper (daemon + SA payload).
// =========================================================================
// Collapses the repeated CVDisplayLink Create/SetOutputCallback/Start/self-stop
// boilerplate + per-anim mach timebase that ~half a dozen animators hand-roll.
// Pure C: usable in the daemon and inside Dock's SA payload (both link CoreVideo).
// The payload must define DISPLAYLINK_NO_COREVIDEO_HEADER and predeclare the CV
// symbols before including this header — see the CoreVideo include below.
//
// Two drivers over one CV callback:
//   dl_lerp(dl, did, dur, easing, apply, ctx)
//       apply(eased_t, ctx) each frame with eased_t = apply_easing(elapsed/dur);
//       a final apply(1.0, ctx) lands exactly on target; self-stops at dur.
//   dl_start(dl, did, tick, ctx)
//       tick(dl, dt, elapsed, ctx) each frame; return false to self-stop.
//
// Lifecycle — PER-ANIMATOR REUSE: each struct
// owns its link; lazy-created on first start, the callback self-Stops WITHOUT
// releasing (link kept), dl_start/dl_lerp re-arm + restart it, and dl_stop is the
// ONLY releaser. Race-safe against restart (no callback self-release).
//
// Concurrency is the CALLER's job — the helper adds no locking. A site that
// changes link state from another thread (cancel, restart) serialises that with
// its own mutex.
// =========================================================================

// The daemon includes <CoreVideo/CoreVideo.h> before this header (manifest.m).
// The SA payload CANNOT — CoreVideo.h conflicts with the CG headers there — so a
// payload includer defines DISPLAYLINK_NO_COREVIDEO_HEADER and supplies its own CV
// forward-declarations (CVDisplayLinkRef, CVTimeStamp, CVReturn, CVOptionFlags,
// and the CV funcs it uses incl. CreateWithCGDisplay / IsRunning / Release) BEFORE
// including this header.
#ifndef DISPLAYLINK_NO_COREVIDEO_HEADER
#include <CoreVideo/CoreVideo.h>
#endif
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include "easing.h"   // enum animation_easing_type + apply_easing

// Seconds per mach tick, computed once. Identical in daemon + payload.
static inline double dl_mach_to_s(void)
{
    static double s = 0.0;
    if (s == 0.0) {
        struct mach_timebase_info tb;
        mach_timebase_info(&tb);
        s = (double)tb.numer / ((double)tb.denom * 1e9);
    }
    return s;
}

struct display_link {
    CVDisplayLinkRef link;        // lazily created; reused; released only by dl_stop
    uint64_t start_mach;
    uint64_t last_mach;
    double   duration;            // lerp driver only (0 for raw)
    int      easing;              // enum animation_easing_type (lerp driver only)
    bool   (*tick)(struct display_link *, double dt, double elapsed, void *);
    void   (*apply)(double t, void *);   // lerp driver: t = eased progress in [0,1]
    void    *ctx;
};

// static inline (not plain static): the address is taken in _dl_arm, and inline
// keeps it from tripping -Wunused-function before any call site exists.
static inline CVReturn _dl_cb(CVDisplayLinkRef link, const CVTimeStamp *now,
                              const CVTimeStamp *out, CVOptionFlags in,
                              CVOptionFlags *outf, void *context)
{
    (void)link; (void)now; (void)out; (void)in; (void)outf;
    struct display_link *dl = (struct display_link *)context;

    uint64_t t = mach_absolute_time();
    double   m = dl_mach_to_s();
    double   elapsed = (double)(t - dl->start_mach) * m;
    double   dt      = (double)(t - dl->last_mach)  * m;
    dl->last_mach = t;

    bool keep;
    if (dl->apply) {                          // eased driver
        double p = dl->duration > 0.0 ? elapsed / dl->duration : 1.0;
        if (p >= 1.0) {
            dl->apply(1.0, dl->ctx);          // exact terminal frame
            keep = false;
        } else {
            dl->apply((double)apply_easing((float)p, dl->easing), dl->ctx);
            keep = true;
        }
    } else {                                  // raw driver
        keep = dl->tick ? dl->tick(dl, dt, elapsed, dl->ctx) : false;
    }

    if (!keep && dl->link) CVDisplayLinkStop(dl->link);   // self-stop; link KEPT for reuse
    return kCVReturnSuccess;
}

// Internal: (lazy) create the link, register _dl_cb, arm the clock, start.
static inline void _dl_arm(struct display_link *dl, CGDirectDisplayID did)
{
    if (dl->link && CVDisplayLinkIsRunning(dl->link)) CVDisplayLinkStop(dl->link);
    dl->start_mach = dl->last_mach = mach_absolute_time();
    if (!dl->link) {
        if (did) CVDisplayLinkCreateWithCGDisplay(did, &dl->link);
        else     CVDisplayLinkCreateWithActiveCGDisplays(&dl->link);
        CVDisplayLinkSetOutputCallback(dl->link, _dl_cb, dl);
    }
    CVDisplayLinkStart(dl->link);
}

// Raw driver. `did == 0` => all active displays (current default). The first tick
// is delivered with dt == 0 (start_mach == last_mach), so a tick that integrates
// by dt must tolerate a zero step. A tick MAY call dl_start/dl_lerp to retarget
// from inside itself (CoreVideo permits Stop+Start from within the callback).
static inline void dl_start(struct display_link *dl, CGDirectDisplayID did,
                            bool (*tick)(struct display_link *, double, double, void *),
                            void *ctx)
{
    dl->tick = tick;
    dl->apply = NULL;
    dl->ctx = ctx;
    dl->duration = 0.0;
    _dl_arm(dl, did);
}

// Eased driver. `did == 0` => all active displays.
static inline void dl_lerp(struct display_link *dl, CGDirectDisplayID did, double dur,
                           int easing, void (*apply)(double, void *), void *ctx)
{
    dl->tick = NULL;
    dl->apply = apply;
    dl->ctx = ctx;
    dl->duration = dur > 0.0 ? dur : 0.0001;
    dl->easing = easing;
    _dl_arm(dl, did);
}

// External cancel + release. Safe from another thread: CVDisplayLinkStop blocks
// until any in-flight callback returns before we release. Leaves dl idle.
static inline void dl_stop(struct display_link *dl)
{
    if (!dl->link) return;
    CVDisplayLinkStop(dl->link);
    CVDisplayLinkRelease(dl->link);
    dl->link = NULL;
}

#endif // DISPLAYLINK_H
