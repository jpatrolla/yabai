#ifndef EASING_H
#define EASING_H

#include <math.h>

// NOTE: shared by daemon + SA payload — keep free of helpers.h's SLS/socket surface.

#define ANIMATION_EASING_TYPE_LIST \
    ANIMATION_EASING_TYPE_ENTRY(linear) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_sine) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_sine) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_sine) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_quad) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_quad) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_quad) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_cubic) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_cubic) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_cubic) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_quart) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_quart) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_quart) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_quint) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_quint) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_quint) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_expo) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_expo) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_expo) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_circ) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_circ) \
    ANIMATION_EASING_TYPE_ENTRY(ease_in_out_circ) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_back) \
    ANIMATION_EASING_TYPE_ENTRY(ease_out_elastic)

enum animation_easing_type
{
#define ANIMATION_EASING_TYPE_ENTRY(value) value##_type,
    ANIMATION_EASING_TYPE_LIST
#undef ANIMATION_EASING_TYPE_ENTRY
    EASING_TYPE_COUNT
};

static char *animation_easing_type_str[] =
{
#define ANIMATION_EASING_TYPE_ENTRY(value) [value##_type] = #value,
    ANIMATION_EASING_TYPE_LIST
#undef ANIMATION_EASING_TYPE_ENTRY
};

static inline float linear(float t)
{
    return t;
}

static inline float ease_in_sine(float t)
{
    return 1.0f - cosf((t * M_PI) / 2.0f);
}

static inline float ease_out_sine(float t)
{
    return sinf((t * M_PI) / 2.0f);
}

static inline float ease_in_out_sine(float t)
{
    return -(cosf(M_PI * t) - 1.0f) / 2.0f;
}

static inline float ease_in_quad(float t)
{
    return t * t;
}

static inline float ease_out_quad(float t)
{
    return 1.0f - (1.0f - t) * (1.0f - t);
}

static inline float ease_in_out_quad(float t)
{
    return t < 0.5f ? 2.0f * t * t : 1.0f - powf(-2.0f * t + 2.0f, 2.0f) / 2.0f;
}

static inline float ease_in_cubic(float t)
{
    return t * t * t;
}

static inline float ease_out_cubic(float t)
{
    return 1.0f - powf(1.0f - t, 3);
}

static inline float ease_in_out_cubic(float t)
{
    return t < 0.5f ? 4.0f * t * t * t : 1.0f - powf(-2.0f * t + 2.0f, 3.0f) / 2.0f;
}

static inline float ease_in_quart(float t)
{
    return t * t * t * t;
}

static inline float ease_out_quart(float t)
{
    return 1.0f - powf(1.0f - t, 4);
}

static inline float ease_in_out_quart(float t)
{
    return t < 0.5f ? 8.0f * t * t * t * t : 1.0f - powf(-2.0f * t + 2.0f, 4.0f) / 2.0f;
}

static inline float ease_in_quint(float t)
{
    return t * t * t * t * t;
}

static inline float ease_out_quint(float t)
{
    return 1.0f - powf(1.0f - t, 5);
}

static inline float ease_in_out_quint(float t)
{
    return t < 0.5f ? 16.0f * t * t * t * t * t : 1.0f - powf(-2.0f * t + 2.0f, 5.0f) / 2.0f;
}

static inline float ease_in_expo(float t)
{
    return t == 0.0f ? 0.0f : powf(2.0f, 10.0f * t - 10.0f);
}

static inline float ease_out_expo(float t)
{
    return t == 1.0f ? 1.0f : 1.0f - powf(2.0f, -10.0f * t);
}

static inline float ease_in_out_expo(float t)
{
    return t == 0.0f ? 0.0f : t == 1.0f ? 1.0f : t < 0.5f ? powf(2.0f, 20.0f * t - 10.0f) / 2.0f : (2.0f - powf(2.0f, -20.0f * t + 10.0f)) / 2.0f;
}

static inline float ease_in_circ(float t)
{
    return 1.0f - sqrtf(1.0f - powf(t, 2.0f));
}

static inline float ease_out_circ(float t)
{
    return sqrtf(1.0f - powf(t - 1.0f, 2.0f));
}

static inline float ease_in_out_circ(float t)
{
    return t < 0.5f ? (1.0f - sqrtf(1.0f - powf(2.0f * t, 2.0f))) / 2.0f : (sqrtf(1.0f - powf(-2.0f * t + 2.0f, 2.0f)) + 1.0f) / 2.0f;
}

static inline float ease_out_back(float t)
{
    const float c1 = 1.70158f;
    const float c3 = c1 + 1.0f;

    return 1.0f + c3 * powf(t - 1.0f, 3.0f) + c1 * powf(t - 1.0f, 2.0f);
}

static inline float ease_out_elastic(float t)
{
    const float c4 = (2.0f * M_PI) / 3.0f;

    return t == 0.0f
      ? 0.0f
      : t == 1.0f
      ? 1.0f
      : powf(2.0f, -10.0f * t) * sinf((t * 10.0f - 0.75f) * c4) + 1.0f;
}

static inline float apply_easing(float t, int easing_type)
{
    switch (easing_type) {
        case ease_in_sine_type:        return ease_in_sine(t);
        case ease_out_sine_type:       return ease_out_sine(t);
        case ease_in_out_sine_type:    return ease_in_out_sine(t);
        case ease_in_quad_type:        return ease_in_quad(t);
        case ease_out_quad_type:       return ease_out_quad(t);
        case ease_in_out_quad_type:    return ease_in_out_quad(t);
        case ease_in_cubic_type:       return ease_in_cubic(t);
        case ease_out_cubic_type:      return ease_out_cubic(t);
        case ease_in_out_cubic_type:   return ease_in_out_cubic(t);
        case ease_in_quart_type:       return ease_in_quart(t);
        case ease_out_quart_type:      return ease_out_quart(t);
        case ease_in_out_quart_type:   return ease_in_out_quart(t);
        case ease_in_quint_type:       return ease_in_quint(t);
        case ease_out_quint_type:      return ease_out_quint(t);
        case ease_in_out_quint_type:   return ease_in_out_quint(t);
        case ease_in_expo_type:        return ease_in_expo(t);
        case ease_out_expo_type:       return ease_out_expo(t);
        case ease_in_out_expo_type:    return ease_in_out_expo(t);
        case ease_in_circ_type:        return ease_in_circ(t);
        case ease_out_circ_type:       return ease_out_circ(t);
        case ease_in_out_circ_type:    return ease_in_out_circ(t);
        case ease_out_back_type:       return ease_out_back(t);
        case ease_out_elastic_type:    return ease_out_elastic(t);
        default:                       return t; // Linear fallback
    }
}

#endif // EASING_H
