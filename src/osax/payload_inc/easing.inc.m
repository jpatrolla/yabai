// NOTE: mode integers are the wire contract (enum focus_ring_easing,
// focus_ring.h: 0=linear 1=smoothstep 2=ease-in quad 3=ease-out expo) —
// keep this switch in sync. t is clamped [0,1].
static inline double payload_ease(int mode, double t)
{
    switch (mode) {
        case 0:  return t;                       // linear
        case 1:  return t * t * (3.0 - 2.0 * t); // smoothstep (ease-in-out)
        case 2:  return t * t;                   // ease-in quad
        default: return 1.0 - exp2(-10.0 * t);   // ease-out expo
    }
}
