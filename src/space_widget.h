#ifndef SPACE_WIDGET_H
#define SPACE_WIDGET_H

enum space_widget_color {
    SPACE_WIDGET_COLOR_WHITE = 0,
    SPACE_WIDGET_COLOR_RED = 1,
    SPACE_WIDGET_COLOR_BLUE = 2,
    SPACE_WIDGET_COLOR_COUNT = 3
};

struct space_widget {
    uint32_t id;
    CGRect frame;
    bool is_active;
    enum space_widget_color current_color;  // Kept for API compatibility
};

void space_widget_create(struct space_widget *widget);
void space_widget_destroy(struct space_widget *widget);

// Placeholder functions for API compatibility
void space_widget_cycle_color(struct space_widget *widget);
void space_widget_update_color(struct space_widget *widget);
void space_widget_test_cycle(struct space_widget *widget);
void space_widget_set_color_for_space(struct space_widget *widget, uint64_t space_id, enum space_widget_color color);
void space_widget_load_color_for_space(struct space_widget *widget, uint64_t space_id);

#endif
