#ifndef SPACE_INDICATOR_H
#define SPACE_INDICATOR_H

struct space_indicator_config {
    bool enabled;
    float indicator_height;
    int position; // 0 = top, 1 = bottom
    uint32_t indicator_color;
};

struct space_indicator {
    uint32_t id;
    CGRect frame;
    CGRect target_frame;
    bool is_active;
    bool is_animating;
    float animation_progress;
    uint64_t animation_start_time;
    struct space_indicator_config config;
};

void space_indicator_create(struct space_indicator *indicator);
void space_indicator_destroy(struct space_indicator *indicator);
void space_indicator_update(struct space_indicator *indicator, uint64_t sid);
void space_indicator_update_optimistic(struct space_indicator *indicator, uint64_t sid);
void space_indicator_refresh(struct space_indicator *indicator);
void space_indicator_animate_step(struct space_indicator *indicator);

#endif