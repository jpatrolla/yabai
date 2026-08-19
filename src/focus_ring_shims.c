// Carve-local inert shims for daemon services not carried in this tree.
//   space_nav_observer_get_enabled() → false: the ring just follows focus.
//   focus_ring_settle_arm_public()  → no-op: no deferred settle re-show; a
//   focus landing mid native-space-animation recovers on the next focus change.

#include <stdbool.h>
#include <stdint.h>

bool     space_nav_observer_get_enabled(void)                            { return false; }
uint32_t focus_ring_settle_arm_public(uint32_t did, uint32_t resume_wid) { (void)did; (void)resume_wid; return 0; }
