#include <stdio.h>
#include <math.h>

// Test the new easing functions
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

int main() {
    printf("Testing ease_out_back:\n");
    for (int i = 0; i <= 10; i++) {
        float t = i / 10.0f;
        printf("t=%.1f -> %.3f\n", t, ease_out_back(t));
    }
    
    printf("\nTesting ease_out_elastic:\n");
    for (int i = 0; i <= 10; i++) {
        float t = i / 10.0f;
        printf("t=%.1f -> %.3f\n", t, ease_out_elastic(t));
    }
    
    return 0;
}