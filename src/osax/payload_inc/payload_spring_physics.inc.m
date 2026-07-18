// NOTE: 1-D damped spring, semi-implicit Euler — the {response, damping_ratio}
// model CASpringAnimation/SwiftUI .spring use. Pure math (no SLS, no
// allocation): safe from any thread, target may move every frame.
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

// dt is measured elapsed time — clock jitter changes smoothness, not shape.
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
