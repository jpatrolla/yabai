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
};

void space_widget_create(struct space_widget *widget);
void space_widget_destroy(struct space_widget *widget);
void space_widget_refresh(struct space_widget *widget);

#endif
