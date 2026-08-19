#ifndef DISPLAYLINK_H
#define DISPLAYLINK_H

// NOTE: shared CVDisplayLink clock for daemon + SA payload (pure C; both link CoreVideo).
// Lifecycle: each struct owns its link — lazy-created; the callback self-Stops WITHOUT
// releasing (link kept for re-arm); dl_stop is the ONLY releaser. No internal locking —
// callers serialise cross-thread cancel/restart themselves.

// NOTE: the SA payload can't include CoreVideo.h (conflicts with its CG headers) — it
// defines DISPLAYLINK_NO_COREVIDEO_HEADER and forward-declares the CV symbols first.
#ifndef DISPLAYLINK_NO_COREVIDEO_HEADER
#include <CoreVideo/CoreVideo.h>
#endif
#include <mach/mach_time.h>
#include <stdbool.h>
#include <stdint.h>
#include "easing.h"

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
    CVDisplayLinkRef link;
    uint64_t start_mach;
    uint64_t last_mach;
    double   duration;            // lerp driver only (0 for raw)
    int      easing;              // enum animation_easing_type (lerp driver only)
    bool   (*tick)(struct display_link *, double dt, double elapsed, void *);
    void   (*apply)(double t, void *);   // lerp driver: t = eased progress in [0,1]
    void    *ctx;
};

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
    if (dl->apply) {
        double p = dl->duration > 0.0 ? elapsed / dl->duration : 1.0;
        if (p >= 1.0) {
            dl->apply(1.0, dl->ctx);          // exact terminal frame
            keep = false;
        } else {
            dl->apply((double)apply_easing((float)p, dl->easing), dl->ctx);
            keep = true;
        }
    } else {
        keep = dl->tick ? dl->tick(dl, dt, elapsed, dl->ctx) : false;
    }

    if (!keep && dl->link) CVDisplayLinkStop(dl->link);
    return kCVReturnSuccess;
}

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

// NOTE: did == 0 => all active displays. First tick arrives with dt == 0. A tick may call
// dl_start/dl_lerp from inside itself (CV permits Stop+Start within the callback).
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

// NOTE: cross-thread safe — CVDisplayLinkStop blocks until any in-flight callback returns.
static inline void dl_stop(struct display_link *dl)
{
    if (!dl->link) return;
    CVDisplayLinkStop(dl->link);
    CVDisplayLinkRelease(dl->link);
    dl->link = NULL;
}

#endif // DISPLAYLINK_H
