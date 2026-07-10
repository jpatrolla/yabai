// =========================================================================
// payload_spring_physics.inc.m — reusable 1-D damped-spring integrator.
// =========================================================================
// Factored out so any animated payload feature (hover scale, focus ring,
// strip cards) can drive a scalar toward a moving target with natural motion.
//
// The model matches Stage Manager's SpringParameters {response, dampingRatio}
// (disasm-verified in WindowManagerAgent) — the same formulation Core
// Animation's CASpringAnimation and SwiftUI's .spring(response:dampingFraction:)
// use:
//
//   omega = 2*pi / response                 // undamped natural frequency
//   a     = -omega^2 * (x - target)         // Hooke restoring force
//           - 2 * zeta * omega * v          // viscous damping (zeta = ratio)
//   v    += a * dt;   x += v * dt           // semi-implicit Euler (stable)
//
//   response      ~ seconds for one oscillation. Smaller => snappier.
//   damping_ratio   < 1 underdamped (overshoots/bounces),
//                   = 1 critical (fastest settle, no overshoot),
//                   > 1 overdamped (sluggish, no overshoot).
//
// Pure math: no SLS, no window refs, no allocation — safe to step from any
// thread. The intended use is stepping with a target that may change every
// frame (that is exactly how hover-in / hover-out works): the spring chases
// whatever the current target is.
// =========================================================================
#ifndef PAYLOAD_SPRING_PHYSICS_INC_M
#define PAYLOAD_SPRING_PHYSICS_INC_M

#include <math.h>
#include <stdbool.h>

struct spring_params {
    double response;        // period-ish, in seconds (e.g. 0.35)
    double damping_ratio;   // zeta (e.g. 0.85 slight bounce, 1.0 no overshoot)
};

struct spring_state {
    double value;           // current animated value
    double velocity;        // current rate of change, in units/second
};

// Advance `s` toward `target` by `dt` real seconds. `dt` is measured elapsed
// time, so jitter in the frame clock changes only smoothness, not the shape
// of the motion.
static inline void spring_step(struct spring_state *s, double target,
                               struct spring_params p, double dt)
{
    if (p.response <= 0.0) {            // degenerate config => snap to target.
        s->value = target;
        s->velocity = 0.0;
        return;
    }
    double omega = (2.0 * M_PI) / p.response;
    double accel = -(omega * omega) * (s->value - target)
                   - (2.0 * p.damping_ratio * omega) * s->velocity;
    s->velocity += accel * dt;
    s->value    += s->velocity * dt;
}

// True once the spring has effectively reached `target` — within `eps` in
// both position and velocity. Lets a caller end an animation loop early.
static inline bool spring_settled(const struct spring_state *s, double target,
                                  double eps)
{
    return fabs(s->value - target) < eps && fabs(s->velocity) < eps;
}

#endif // PAYLOAD_SPRING_PHYSICS_INC_M
