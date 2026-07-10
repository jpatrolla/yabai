// payload_anim_metrics.inc.m — per-animation tick-interval stats (frame-clock
// jitter: mean/sd/min/max interval + long-tick count per animation).
#include <math.h>

struct anim_metrics {
    uint64_t count;
    double   sum, sumsq, min, max;
    int      long_ticks;       // ticks > 20ms (dropped-frame proxy)
    double   mach_to_s;
    uint64_t last_mach;
};

static inline void anim_metrics_reset(struct anim_metrics *m, double mach_to_s)
{
    m->count = 0; m->sum = 0.0; m->sumsq = 0.0; m->min = 1e9; m->max = 0.0;
    m->long_ticks = 0; m->mach_to_s = mach_to_s; m->last_mach = mach_absolute_time();
}

// Call once per VBL; returns dt (clamped). Skips frame 0 from the stats.
static inline double anim_metrics_tick(struct anim_metrics *m)
{
    uint64_t now = mach_absolute_time();
    double dt = (double)(now - m->last_mach) * m->mach_to_s;
    m->last_mach = now;
    if (dt > 0.05) dt = 0.05;
    if (dt < 0.0)  dt = 0.0;
    if (m->count > 0) {
        m->sum += dt; m->sumsq += dt * dt;
        if (dt < m->min) m->min = dt;
        if (dt > m->max) m->max = dt;
        if (dt > 0.020)  m->long_ticks++;
    }
    m->count++;
    return dt;
}

static inline void anim_metrics_report(struct anim_metrics *m, const char *tag, const char *clock)
{
    if (m->count <= 1) return;   // starved/superseded context — no meaningful jitter to report
    double n = (double)(m->count > 1 ? m->count - 1 : 1);
    double mean = m->sum / n;
    double var = m->sumsq / n - mean * mean;
    double sd = var > 0.0 ? sqrt(var) : 0.0;
    logpf("PAYLOAD", "%s clock=%s ticks=%llu mean=%.2fms sd=%.2fms min=%.2f max=%.2f drops=%d (~%.0fHz)",
          tag, clock, (unsigned long long)m->count, mean * 1e3, sd * 1e3,
          m->min * 1e3, m->max * 1e3, m->long_ticks, mean > 0.0 ? 1.0 / mean : 0.0);
}
