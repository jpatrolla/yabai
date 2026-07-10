// Shared normalized-progress easing curves for payload-side animators.
// Single source of truth for the curve math: focus_ring's fade tick
// (focus_ease) and the space cross-fade/slide (anim_eased_p) both route
// through payload_ease so a curve can't drift between features. The mode
// integers are the wire contract shipped by the daemon (enum focus_ring_easing
// in focus_ring.h — 0=linear, 1=smoothstep, 2=ease-in quad, 3=ease-out expo);
// keep this switch in sync with that enum. Included BEFORE every animator.
//
//   t is clamped normalized progress in [0,1]; returns the eased fraction.
static inline double payload_ease(int mode, double t)
{
    switch (mode) {
        case 0:  return t;                       // linear
        case 1:  return t * t * (3.0 - 2.0 * t); // smoothstep (ease-in-out)
        case 2:  return t * t;                   // ease-in quad
        default: return 1.0 - exp2(-10.0 * t);   // ease-out expo
    }
}
