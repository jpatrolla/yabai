// focus_ring_shims.c — inert carve-local definitions of daemon services
// focus_ring.m depends on whose full implementations live outside the
// animations-core showcase.
//
//   • space_nav_observer_get_enabled() — reports whether the native
//     space-navigation *anticipation* observer is armed. Not carried here →
//     false (the ring just follows focus normally).
//
//   • focus_ring_settle_arm_public() — arms a self-reposting "settle poll"
//     that re-shows the ring once a display stops animating. Out of scope
//     here, so a no-op: the ring shows immediately when the display is idle
//     (the common case); a focus landing mid native-space-animation loses the
//     deferred auto-re-show and recovers on the next focus change. The return
//     value (a generation id) is unused by the caller.
//
// The focus-follow path (event_loop.c → focus_ring_show_for_wid) depends on
// neither, so the inert values are correct for this branch.

#include <stdbool.h>
#include <stdint.h>

bool     space_nav_observer_get_enabled(void)                            { return false; }
uint32_t focus_ring_settle_arm_public(uint32_t did, uint32_t resume_wid) { (void)did; (void)resume_wid; return 0; }
