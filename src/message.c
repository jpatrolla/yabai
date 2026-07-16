static struct {
    int sockfd;
    bool is_running;
    pthread_t thread;
} g_message_loop;

extern struct event_loop g_event_loop;
extern struct display_manager g_display_manager;
extern struct space_manager g_space_manager;
extern struct window_manager g_window_manager;
extern struct mouse_state g_mouse_state;
extern bool g_verbose;

#define DOMAIN_CONFIG  "config"
#define DOMAIN_DISPLAY "display"
#define DOMAIN_SPACE   "space"
#define DOMAIN_WINDOW  "window"
#define DOMAIN_QUERY   "query"
#define DOMAIN_RULE    "rule"
#define DOMAIN_SIGNAL  "signal"
#define DOMAIN_CAPTURE "capture"

#define COMMAND_CAPTURE_START  "start"
#define COMMAND_CAPTURE_STOP   "stop"
#define COMMAND_CAPTURE_STATUS "status"
#define COMMAND_CAPTURE_STITCH "stitch"
#define COMMAND_CAPTURE_HELP   "help"

/* --------------------------------DOMAIN CONFIG-------------------------------- */
#define COMMAND_CONFIG_DEBUG_OUTPUT          "debug_output"
#define COMMAND_CONFIG_MFF                   "mouse_follows_focus"
#define COMMAND_CONFIG_FFM                   "focus_follows_mouse"
#define COMMAND_CONFIG_DISPLAY_ORDER         "display_arrangement_order"
#define COMMAND_CONFIG_WINDOW_ORIGIN         "window_origin_display"
#define COMMAND_CONFIG_WINDOW_PLACEMENT      "window_placement"
#define COMMAND_CONFIG_WINDOW_INSERT_POINT   "window_insertion_point"
#define COMMAND_CONFIG_WINDOW_ZOOM_PERSIST   "window_zoom_persist"
#define COMMAND_CONFIG_OPACITY               "window_opacity"
#define COMMAND_CONFIG_OPACITY_DURATION      "window_opacity_duration"
#define COMMAND_CONFIG_ANIMATION_DURATION    "window_animation_duration"
#define COMMAND_CONFIG_COVER_FADE            "window_animation_cover_fade"
#define COMMAND_CONFIG_WARP_COVER            "window_animation_warp_cover"
#define COMMAND_CONFIG_ANIM_POLICY           "window_animation_policy"
#define COMMAND_CONFIG_ANIMATION_EASING      "window_animation_easing"
#define COMMAND_CONFIG_ANIMATION_MIN_OPACITY "window_animation_min_opacity"
#define COMMAND_CONFIG_ANIMATION_AX_WAKE      "window_animation_ax_wake"
#define COMMAND_CONFIG_SPACE_ANIMATION_DURATION "space_animation_duration"
#define COMMAND_CONFIG_SPACE_ANIMATION_BACKGROUND "space_animation_background"
#define COMMAND_CONFIG_EXPOSE_ANIMATION_DURATION "expose_animation_duration"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE       "space_animation_fade"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE_ENTER "space_animation_fade_enter"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE_EXIT  "space_animation_fade_exit"
#define COMMAND_CONFIG_WARP_MIN_MS           "window_animation_warp_min_ms"
#define COMMAND_CONFIG_SPACE_ANIMATION_ENTER_DELAY "space_animation_enter_delay"
#define COMMAND_CONFIG_SPACE_ANIMATION_EXIT_DELAY  "space_animation_exit_delay"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE_ENTER_DELAY "space_animation_fade_enter_delay"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE_EXIT_DELAY  "space_animation_fade_exit_delay"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE_ENTER_DUR   "space_animation_fade_enter_dur"
#define COMMAND_CONFIG_SPACE_ANIMATION_FADE_EXIT_DUR    "space_animation_fade_exit_dur"
#define COMMAND_CONFIG_CONTAIN_SPACE_FOCUS_PER_DISPLAY "contain_space_focus_per_display"
#define COMMAND_CONFIG_WINDOW_FOCUS_FOR_FLOATING "window_focus_for_floating_enabled"
#define COMMAND_CONFIG_WINDOW_FOCUS_INTER_DISPLAY "window_focus_inter_display"
#define COMMAND_CONFIG_WINDOW_FOCUS_WRAP     "window_focus_wrap"
#define COMMAND_CONFIG_SPACE_FOCUS_TARGET_DISPLAY "space_focus_target_display"
#define COMMAND_CONFIG_SHADOW                "window_shadow"
#define COMMAND_CONFIG_MENUBAR_OPACITY       "menubar_opacity"
#define COMMAND_CONFIG_ACTIVE_WINDOW_OPACITY "active_window_opacity"
#define COMMAND_CONFIG_NORMAL_WINDOW_OPACITY "normal_window_opacity"
#define COMMAND_CONFIG_INSERT_FEEDBACK_COLOR "insert_feedback_color"
#define COMMAND_CONFIG_TOP_PADDING           "top_padding"
#define COMMAND_CONFIG_BOTTOM_PADDING        "bottom_padding"
#define COMMAND_CONFIG_LEFT_PADDING          "left_padding"
#define COMMAND_CONFIG_RIGHT_PADDING         "right_padding"
#define COMMAND_CONFIG_LAYOUT                "layout"
#define COMMAND_CONFIG_WINDOW_GAP            "window_gap"
#define COMMAND_CONFIG_SPLIT_RATIO           "split_ratio"
#define COMMAND_CONFIG_SPLIT_TYPE            "split_type"
#define COMMAND_CONFIG_AUTO_BALANCE          "auto_balance"
#define COMMAND_CONFIG_MOUSE_MOD             "mouse_modifier"
#define COMMAND_CONFIG_MOUSE_ACTION1         "mouse_action1"
#define COMMAND_CONFIG_MOUSE_ACTION2         "mouse_action2"
#define COMMAND_CONFIG_MOUSE_DROP_ACTION     "mouse_drop_action"
#define COMMAND_CONFIG_EXTERNAL_BAR          "external_bar"
#define COMMAND_CONFIG_FRAME_VERIFY_RETRY    "window_frame_verify_retry"
#define COMMAND_CONFIG_SKIP_SPACE_ANIMATION  "skip_window_focus_animation"
#define COMMAND_CONFIG_MC_ALWAYS_SHOW_SPACES_STRIP "mission_control_always_show_spaces_strip_enabled"
#define COMMAND_CONFIG_FOCUS_RING_ENABLED    "focus_ring_enabled"
#define COMMAND_CONFIG_FOCUS_RING_WIDTH      "focus_ring_width"
#define COMMAND_CONFIG_FOCUS_RING_COLOR_OPACITY    "focus_ring_color_opacity"
#define COMMAND_CONFIG_FOCUS_RING_ALPHA      "focus_ring_alpha"
#define COMMAND_CONFIG_FOCUS_RING_COLOR      "focus_ring_color"
#define COMMAND_CONFIG_FOCUS_RING_BLUR_RADIUS          "focus_ring_blur_radius"
#define COMMAND_CONFIG_FOCUS_RING_BLEED           "focus_ring_bleed"
#define COMMAND_CONFIG_FOCUS_RING_FEATHER         "focus_ring_feather"
#define COMMAND_CONFIG_FOCUS_RING_SATURATION      "focus_ring_saturation"
#define COMMAND_CONFIG_FOCUS_RING_BRIGHTNESS      "focus_ring_brightness"
#define COMMAND_CONFIG_FOCUS_RING_CONTRAST        "focus_ring_contrast"
#define COMMAND_CONFIG_FOCUS_RING_HUE             "focus_ring_hue"
#define COMMAND_CONFIG_FOCUS_RING_BLEND_MODE           "focus_ring_blend_mode"
#define COMMAND_CONFIG_FOCUS_RING_INNER_STROKE          "focus_ring_inner_stroke"
#define COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_POSITION "focus_ring_inner_stroke_position"
#define COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_WIDTH    "focus_ring_inner_stroke_width"
#define COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_OPACITY  "focus_ring_inner_stroke_opacity"
#define COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_COLOR    "focus_ring_inner_stroke_color"

#define SELECTOR_CONFIG_SPACE                "--space"

#define ARGUMENT_CONFIG_FFM_AUTOFOCUS         "autofocus"
#define ARGUMENT_CONFIG_FFM_AUTORAISE         "autoraise"
#define ARGUMENT_CONFIG_DISPLAY_ORDER_DEFAULT "default"
#define ARGUMENT_CONFIG_DISPLAY_ORDER_X       "horizontal"
#define ARGUMENT_CONFIG_DISPLAY_ORDER_Y       "vertical"
#define ARGUMENT_CONFIG_WINDOW_ORIGIN_DEFAULT "default"
#define ARGUMENT_CONFIG_WINDOW_ORIGIN_FOCUSED "focused"
#define ARGUMENT_CONFIG_WINDOW_ORIGIN_CURSOR  "cursor"
#define ARGUMENT_CONFIG_SFTD_DEFAULT          "default"
#define ARGUMENT_CONFIG_SFTD_MOUSE            "mouse"
#define ARGUMENT_CONFIG_SFTD_SMART            "smart"
#define ARGUMENT_CONFIG_WINDOW_PLACEMENT_FST  "first_child"
#define ARGUMENT_CONFIG_WINDOW_PLACEMENT_SND  "second_child"
#define ARGUMENT_CONFIG_WINDOW_INSERT_FOCUSED "focused"
#define ARGUMENT_CONFIG_WINDOW_INSERT_FIRST   "first"
#define ARGUMENT_CONFIG_WINDOW_INSERT_LAST    "last"
#define ARGUMENT_CONFIG_SHADOW_FLT            "float"
#define ARGUMENT_CONFIG_LAYOUT_BSP            "bsp"
#define ARGUMENT_CONFIG_LAYOUT_STACK          "stack"
#define ARGUMENT_CONFIG_LAYOUT_FLOAT          "float"
#define ARGUMENT_CONFIG_SPLIT_TYPE_Y          "vertical"
#define ARGUMENT_CONFIG_SPLIT_TYPE_X          "horizontal"
#define ARGUMENT_CONFIG_SPLIT_TYPE_AUTO       "auto"
#define ARGUMENT_CONFIG_MOUSE_MOD_ALT         "alt"
#define ARGUMENT_CONFIG_MOUSE_MOD_SHIFT       "shift"
#define ARGUMENT_CONFIG_MOUSE_MOD_CMD         "cmd"
#define ARGUMENT_CONFIG_MOUSE_MOD_CTRL        "ctrl"
#define ARGUMENT_CONFIG_MOUSE_MOD_FN          "fn"
#define ARGUMENT_CONFIG_MOUSE_ACTION_MOVE     "move"
#define ARGUMENT_CONFIG_MOUSE_ACTION_RESIZE   "resize"
#define ARGUMENT_CONFIG_MOUSE_ACTION_SWAP     "swap"
#define ARGUMENT_CONFIG_MOUSE_ACTION_STACK    "stack"
#define ARGUMENT_CONFIG_EXTERNAL_BAR_MAIN     "main"
#define ARGUMENT_CONFIG_EXTERNAL_BAR_ALL      "all"
#define ARGUMENT_CONFIG_EXTERNAL_BAR          "%5[^:]:%d:%d"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN DISPLAY------------------------------- */
#define COMMAND_DISPLAY_FOCUS "--focus"
#define COMMAND_DISPLAY_SPACE "--space"
#define COMMAND_DISPLAY_LABEL "--label"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN SPACE--------------------------------- */
#define COMMAND_SPACE_FOCUS    "--focus"
#define COMMAND_SPACE_SWITCH   "--switch"
#define COMMAND_SPACE_CREATE   "--create"
#define COMMAND_SPACE_DESTROY  "--destroy"
#define COMMAND_SPACE_MOVE     "--move"
#define COMMAND_SPACE_SWAP     "--swap"
#define COMMAND_SPACE_DISPLAY  "--display"
#define COMMAND_SPACE_EQUALIZE "--equalize"
#define COMMAND_SPACE_BALANCE  "--balance"
#define COMMAND_SPACE_MIRROR   "--mirror"
#define COMMAND_SPACE_ROTATE   "--rotate"
#define COMMAND_SPACE_PADDING  "--padding"
#define COMMAND_SPACE_GAP      "--gap"
#define COMMAND_SPACE_TOGGLE   "--toggle"
#define COMMAND_SPACE_LAYOUT   "--layout"
#define COMMAND_SPACE_LABEL    "--label"

#define ARGUMENT_SPACE_ROTATE_90    "90"
#define ARGUMENT_SPACE_ROTATE_180   "180"
#define ARGUMENT_SPACE_ROTATE_270   "270"
#define ARGUMENT_SPACE_PADDING      "%255[^:]:%d:%d:%d:%d"
#define ARGUMENT_SPACE_GAP          "%255[^:]:%d"
#define ARGUMENT_SPACE_TGL_PADDING  "padding"
#define ARGUMENT_SPACE_TGL_GAP      "gap"
#define ARGUMENT_SPACE_TGL_MC       "mission-control"
#define ARGUMENT_SPACE_TGL_MC_SHOW_STRIP "mission-control-show-strip"
#define ARGUMENT_SPACE_TGL_SD       "show-desktop"
#define ARGUMENT_SPACE_LAYOUT_BSP   "bsp"
#define ARGUMENT_SPACE_LAYOUT_STACK "stack"
#define ARGUMENT_SPACE_LAYOUT_FLT   "float"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN WINDOW-------------------------------- */
#define COMMAND_WINDOW_FOCUS      "--focus"
#define COMMAND_WINDOW_CLOSE      "--close"
#define COMMAND_WINDOW_MINIMIZE   "--minimize"
#define COMMAND_WINDOW_DEMINIMIZE "--deminimize"
#define COMMAND_WINDOW_DISPLAY    "--display"
#define COMMAND_WINDOW_SPACE      "--space"
#define COMMAND_WINDOW_SWAP       "--swap"
#define COMMAND_WINDOW_WARP       "--warp"
#define COMMAND_WINDOW_STACK      "--stack"
#define COMMAND_WINDOW_INSERT     "--insert"
#define COMMAND_WINDOW_GRID       "--grid"
#define COMMAND_WINDOW_MOVE       "--move"
#define COMMAND_WINDOW_RESIZE     "--resize"
#define COMMAND_WINDOW_RATIO      "--ratio"
#define COMMAND_WINDOW_SUB_LAYER  "--sub-layer"
#define COMMAND_WINDOW_OPACITY    "--opacity"
#define COMMAND_WINDOW_RAISE      "--raise"
#define COMMAND_WINDOW_LOWER      "--lower"
#define COMMAND_WINDOW_TOGGLE     "--toggle"
#define COMMAND_WINDOW_SCRATCHPAD "--scratchpad"

#define ARGUMENT_WINDOW_SEL_LARGEST     "largest"
#define ARGUMENT_WINDOW_SEL_SMALLEST    "smallest"
#define ARGUMENT_WINDOW_SEL_SIBLING     "sibling"
#define ARGUMENT_WINDOW_SEL_FNEPHEW     "first_nephew"
#define ARGUMENT_WINDOW_SEL_SNEPHEW     "second_nephew"
#define ARGUMENT_WINDOW_SEL_UNCLE       "uncle"
#define ARGUMENT_WINDOW_SEL_FCOUSIN     "first_cousin"
#define ARGUMENT_WINDOW_SEL_SCOUSIN     "second_cousin"
#define ARGUMENT_WINDOW_GRID            "%d:%d:%d:%d:%d:%d"
#define ARGUMENT_WINDOW_MOVE            "%255[^:]:%255[^:]:%255[^:]"
#define ARGUMENT_WINDOW_RESIZE          "%255[^:]:%f:%f"
#define ARGUMENT_WINDOW_RATIO           "%255[^:]:%f"
#define ARGUMENT_WINDOW_LAYER_BELOW     "below"
#define ARGUMENT_WINDOW_LAYER_NORMAL    "normal"
#define ARGUMENT_WINDOW_LAYER_ABOVE     "above"
#define ARGUMENT_WINDOW_LAYER_AUTO      "auto"
#define ARGUMENT_WINDOW_TOGGLE_FLOAT    "float"
#define ARGUMENT_WINDOW_TOGGLE_STICKY   "sticky"
#define ARGUMENT_WINDOW_TOGGLE_SHADOW   "shadow"
#define ARGUMENT_WINDOW_TOGGLE_SPLIT    "split"
#define ARGUMENT_WINDOW_TOGGLE_PARENT   "zoom-parent"
#define ARGUMENT_WINDOW_TOGGLE_FULLSC   "zoom-fullscreen"
#define ARGUMENT_WINDOW_TOGGLE_WINDOWED "windowed-fullscreen"
#define ARGUMENT_WINDOW_TOGGLE_NATIVE   "native-fullscreen"
#define ARGUMENT_WINDOW_TOGGLE_EXPOSE   "expose"
#define ARGUMENT_WINDOW_TOGGLE_PIP      "pip"

#define ARGUMENT_WINDOW_SCRATCHPAD_RECOVER "recover"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN QUERY--------------------------------- */
#define COMMAND_QUERY_DISPLAYS "--displays"
#define COMMAND_QUERY_SPACES   "--spaces"
#define COMMAND_QUERY_WINDOWS  "--windows"

#define ARGUMENT_QUERY_DISPLAY "--display"
#define ARGUMENT_QUERY_SPACE   "--space"
#define ARGUMENT_QUERY_WINDOW  "--window"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN RULE---------------------------------- */
#define COMMAND_RULE_ADD     "--add"
#define COMMAND_RULE_REM     "--remove"
#define COMMAND_RULE_APPLY   "--apply"
#define COMMAND_RULE_LS      "--list"

#define ARGUMENT_RULE_ONE_SHOT       "--one-shot"
#define ARGUMENT_RULE_KEY_APP        "app"
#define ARGUMENT_RULE_KEY_TITLE      "title"
#define ARGUMENT_RULE_KEY_ROLE       "role"
#define ARGUMENT_RULE_KEY_SUBROLE    "subrole"
#define ARGUMENT_RULE_KEY_DISPLAY    "display"
#define ARGUMENT_RULE_KEY_SPACE      "space"
#define ARGUMENT_RULE_KEY_OPACITY    "opacity"
#define ARGUMENT_RULE_KEY_MANAGE     "manage"
#define ARGUMENT_RULE_KEY_STICKY     "sticky"
#define ARGUMENT_RULE_KEY_MFF        "mouse_follows_focus"
#define ARGUMENT_RULE_KEY_SUB_LAYER  "sub-layer"
#define ARGUMENT_RULE_KEY_FULLSCR    "native-fullscreen"
#define ARGUMENT_RULE_KEY_GRID       "grid"
#define ARGUMENT_RULE_KEY_LABEL      "label"
#define ARGUMENT_RULE_KEY_SCRATCHPAD "scratchpad"

#define ARGUMENT_RULE_VALUE_SPACE '^'
#define ARGUMENT_RULE_VALUE_GRID  "%d:%d:%d:%d:%d:%d"
/* ----------------------------------------------------------------------------- */

/* --------------------------------DOMAIN SIGNAL-------------------------------- */
#define COMMAND_SIGNAL_ADD "--add"
#define COMMAND_SIGNAL_REM "--remove"
#define COMMAND_SIGNAL_LS  "--list"

#define ARGUMENT_SIGNAL_KEY_APP      "app"
#define ARGUMENT_SIGNAL_KEY_TITLE    "title"
#define ARGUMENT_SIGNAL_KEY_ACTIVE   "active"
#define ARGUMENT_SIGNAL_KEY_EVENT    "event"
#define ARGUMENT_SIGNAL_KEY_ACTION   "action"
#define ARGUMENT_SIGNAL_KEY_LABEL    "label"

#define ARGUMENT_SIGNAL_VALUE_YES    "yes"
#define ARGUMENT_SIGNAL_VALUE_NO     "no"
/* ----------------------------------------------------------------------------- */

/* --------------------------------COMMON ARGUMENTS----------------------------- */
#define ARGUMENT_COMMON_VAL_ON           "on"
#define ARGUMENT_COMMON_VAL_OFF          "off"
#define ARGUMENT_COMMON_SEL_PREV         "prev"
#define ARGUMENT_COMMON_SEL_NEXT         "next"
#define ARGUMENT_COMMON_SEL_FIRST        "first"
#define ARGUMENT_COMMON_SEL_LAST         "last"
#define ARGUMENT_COMMON_SEL_RECENT       "recent"
#define ARGUMENT_COMMON_SEL_NORTH        "north"
#define ARGUMENT_COMMON_SEL_EAST         "east"
#define ARGUMENT_COMMON_SEL_SOUTH        "south"
#define ARGUMENT_COMMON_SEL_WEST         "west"
#define ARGUMENT_COMMON_SEL_MOUSE        "mouse"
#define ARGUMENT_COMMON_SEL_STACK        "stack"
#define ARGUMENT_COMMON_SEL_STACK_PREFIX "stack."
#define ARGUMENT_COMMON_VAL_AXIS_X       "x-axis"
#define ARGUMENT_COMMON_VAL_AXIS_Y       "y-axis"
/* ----------------------------------------------------------------------------- */

struct token
{
    char *text;
    int length;
};

enum token_type
{
    TOKEN_TYPE_INVALID,
    TOKEN_TYPE_UNKNOWN,
    TOKEN_TYPE_INT,
    TOKEN_TYPE_FLOAT,
    TOKEN_TYPE_U32,
    TOKEN_TYPE_STRING
};

struct token_value
{
    struct token token;
    enum token_type type;

    union {
        int int_value;
        float float_value;
        uint32_t u32_value;
        char *string_value;
    };
};

static const int token_char_int_table[] =
{
    ['0'] = 0x0, ['1'] = 0x1,
    ['2'] = 0x2, ['3'] = 0x3,
    ['4'] = 0x4, ['5'] = 0x5,
    ['6'] = 0x6, ['7'] = 0x7,
    ['8'] = 0x8, ['9'] = 0x9,
    ['a'] = 0xA, ['A'] = 0xA,
    ['b'] = 0xB, ['B'] = 0xB,
    ['c'] = 0xC, ['C'] = 0xC,
    ['d'] = 0xD, ['D'] = 0xD,
    ['e'] = 0xE, ['E'] = 0xE,
    ['f'] = 0xF, ['F'] = 0xF,
};

static struct token get_token(char **message)
{
    struct token token;

    token.text = *message;
    while (**message) {
        ++(*message);
    }
    token.length = *message - token.text;

    if ((*message)[0] == '\0' && (*message)[1] != '\0') {
        ++(*message);
    } else {
        // NOTE(asmvik): don't go past the null-terminator
    }

    return token;
}

static bool token_prefix(struct token token, char *match)
{
    char *at = match;
    for (int i = 0; i < token.length; ++i, ++at) {
        if (*at == 0)             return true;
        if (token.text[i] != *at) return false;
    }
    return *at == 0;
}

static bool token_equals(struct token token, char *match)
{
    char *at = match;
    for (int i = 0; i < token.length; ++i, ++at) {
        if ((*at == 0) || (token.text[i] != *at)) {
            return false;
        }
    }
    return *at == 0;
}

static inline bool token_is_valid(struct token token)
{
    return token.text && token.length > 0;
}

static bool token_is_positive_integer(struct token token, int *value)
{
    *value = 0;

    for (int i = 0; i < token.length; ++i) {
        char c = token.text[i];
        if (!(c >= '0' && c <= '9')) {
            return false;
        }
        *value = *value * 10 + token_char_int_table[(int)c];
    }

    return true;
}

static bool token_is_hexadecimal(struct token token, uint32_t *value)
{
    *value = 0;

    if (token.length <= 2) return false;

    if (!(token.text[0] == '0' &&
         (token.text[1] == 'x' ||
          token.text[1] == 'X'))) {
        return false;
    }

    for (int i = 2; i < token.length; ++i) {
        char c = token.text[i];
        if (!((c >= '0' && c <= '9') ||
              (c >= 'a' && c <= 'f') ||
              (c >= 'A' && c <= 'F'))) {
            return false;
        }
        *value = *value * 16 + (uint32_t)token_char_int_table[(int)c];
    }

    return true;
}

static bool token_is_float(struct token token, float *value)
{
    char *end = NULL;
    float v = strtof(token.text, &end);

    if (!end || *end) {
        *value = 0.0f;
        return false;
    } else {
        *value = v;
        return true;
    }
}

static struct token_value token_to_value(struct token token)
{
    struct token_value value = { .token = token, .type = TOKEN_TYPE_INVALID };

    if (token_is_valid(token)) {
        if (token_is_positive_integer(token, &value.int_value)) {
            value.type = TOKEN_TYPE_INT;
        } else if (token_is_hexadecimal(token, &value.u32_value)) {
            value.type = TOKEN_TYPE_U32;
        } else if (token_is_float(token, &value.float_value)) {
            value.type = TOKEN_TYPE_FLOAT;
        } else if ((value.string_value = token.text)) {
            value.type = TOKEN_TYPE_STRING;
        } else {
            value.type = TOKEN_TYPE_UNKNOWN;
        }
    }

    return value;
}

static inline void daemon_fail(FILE *rsp, char *fmt, ...)
{
    if (!rsp) return;

    va_list ap;
    va_start(ap, fmt);
    fprintf(rsp, FAILURE_MESSAGE);
    vfprintf(rsp, fmt, ap);
    va_end(ap);
}

__unused static inline void daemon_deprecated(FILE *rsp, char *fmt, ...)
{
    if (!rsp) return;

    va_list ap;
    va_start(ap, fmt);
    fprintf(rsp, "deprecation warning: ");
    vfprintf(rsp, fmt, ap);
    va_end(ap);
}

static void parse_key_value_pair(char *token, char **key, char **value, bool *exclusion)
{
    *key = token;

    while (*token) {
        char fst = token[0];
        char snd = token[1];

        if (fst == '!' && snd == '=') {
            break;
        } else if (fst == '=') {
            break;
        }

        ++token;
    }

    int index = (token[0] == '!' && token[1] == '=') ? 2 : 1;
    char check = (index == 2) ? '!' : '=';

    if (*token != check) {
        *key = NULL;
        *value = NULL;
    } else if (token[index]) {
        *token = '\0';
        *value = token+index;
        *exclusion = index == 2;
    } else {
        *value = NULL;
    }
}

static uint8_t parse_value_type(char *type)
{
    if (string_equals(type, "abs")) {
        return TYPE_ABS;
    } else if (string_equals(type, "rel")) {
        return TYPE_REL;
    } else {
        return 0;
    }
}

// Resolve one --move coordinate field: a number, or the literal "center", which
// centers the window on its display's usable area along that axis (same bounds
// --grid uses, so it clears the menu bar / Dock). "center" is absolute-only — it
// has no meaning against a rel delta. Returns false for a non-numeric field,
// "center" with a non-abs type, or a window/display that can't be resolved; the
// caller then reports the usual "unknown value" failure.
static bool parse_move_coord(struct window *window, uint8_t type, char *field, bool is_x, float *value)
{
    if (string_equals(field, "center")) {
        if (type != TYPE_ABS || !window) return false;

        uint32_t did = window_display_id(window->id);
        if (!did) return false;

        CGRect bounds = display_bounds_constrained(did, false);
        *value = is_x
            ? bounds.origin.x + (bounds.size.width  - window->frame.size.width)  / 2.0f
            : bounds.origin.y + (bounds.size.height - window->frame.size.height) / 2.0f;
        return true;
    }

    char *end = NULL;
    float v = strtof(field, &end);
    if (!end || *end) return false;

    *value = v;
    return true;
}

static uint8_t parse_resize_handle(char *handle)
{
    if (string_equals(handle, "top")) {
        return HANDLE_TOP;
    } else if (string_equals(handle, "bottom")) {
        return HANDLE_BOTTOM;
    } else if (string_equals(handle, "left")) {
        return HANDLE_LEFT;
    } else if (string_equals(handle, "right")) {
        return HANDLE_RIGHT;
    } else if (string_equals(handle, "top_left")) {
        return HANDLE_TOP | HANDLE_LEFT;
    } else if (string_equals(handle, "top_right")) {
        return HANDLE_TOP | HANDLE_RIGHT;
    } else if (string_equals(handle, "bottom_left")) {
        return HANDLE_BOTTOM | HANDLE_LEFT;
    } else if (string_equals(handle, "bottom_right")) {
        return HANDLE_BOTTOM | HANDLE_RIGHT;
    } else if (string_equals(handle, "abs")) {
        return HANDLE_ABS;
    } else {
        return 0;
    }
}

enum label_type
{
    LABEL_DISPLAY,
    LABEL_SPACE,
    LABEL_WINDOW
};

static char *reserved_display_identifiers[] =
{
    ARGUMENT_COMMON_SEL_NORTH,
    ARGUMENT_COMMON_SEL_EAST,
    ARGUMENT_COMMON_SEL_SOUTH,
    ARGUMENT_COMMON_SEL_WEST,
    ARGUMENT_COMMON_SEL_PREV,
    ARGUMENT_COMMON_SEL_NEXT,
    ARGUMENT_COMMON_SEL_FIRST,
    ARGUMENT_COMMON_SEL_LAST,
    ARGUMENT_COMMON_SEL_RECENT,
    ARGUMENT_COMMON_SEL_MOUSE
};

static char *reserved_space_identifiers[] =
{
    ARGUMENT_COMMON_SEL_PREV,
    ARGUMENT_COMMON_SEL_NEXT,
    ARGUMENT_COMMON_SEL_FIRST,
    ARGUMENT_COMMON_SEL_LAST,
    ARGUMENT_COMMON_SEL_RECENT,
    ARGUMENT_COMMON_SEL_MOUSE
};

static char *reserved_window_identifiers[] =
{
    ARGUMENT_WINDOW_TOGGLE_FLOAT,
    ARGUMENT_WINDOW_TOGGLE_STICKY,
    ARGUMENT_WINDOW_TOGGLE_SHADOW,
    ARGUMENT_WINDOW_TOGGLE_SPLIT,
    ARGUMENT_WINDOW_TOGGLE_PARENT,
    ARGUMENT_WINDOW_TOGGLE_FULLSC,
    ARGUMENT_WINDOW_TOGGLE_WINDOWED,
    ARGUMENT_WINDOW_TOGGLE_NATIVE,
    ARGUMENT_WINDOW_TOGGLE_EXPOSE,
    ARGUMENT_WINDOW_TOGGLE_PIP,
    ARGUMENT_WINDOW_SCRATCHPAD_RECOVER
};

static bool parse_label(FILE *rsp, struct token token, enum label_type type, char **label)
{
    struct token_value value = token_to_value(token);

    if (value.type == TOKEN_TYPE_INVALID) {
        *label = NULL;
        return true;
    }

    if (value.type != TOKEN_TYPE_STRING) {
        daemon_fail(rsp, "'%.*s' cannot be used as a label.\n", token.length, token.text);
        return false;
    }

    switch (type) {
    default: break;
    case LABEL_DISPLAY: {
        for (int i = 0; i < array_count(reserved_display_identifiers); ++i) {
            if (token_equals(token, reserved_display_identifiers[i])) {
                daemon_fail(rsp, "'%.*s' is a reserved keyword and cannot be used as a label.\n", token.length, token.text);
                return false;
            }
        }
    } break;
    case LABEL_SPACE: {
        for (int i = 0; i < array_count(reserved_space_identifiers); ++i) {
            if (token_equals(token, reserved_space_identifiers[i])) {
                daemon_fail(rsp, "'%.*s' is a reserved keyword and cannot be used as a label.\n", token.length, token.text);
                return false;
            }
        }
    } break;
    case LABEL_WINDOW: {
        for (int i = 0; i < array_count(reserved_window_identifiers); ++i) {
            if (token_equals(token, reserved_window_identifiers[i])) {
                daemon_fail(rsp, "'%.*s' is a reserved keyword and cannot be used as a scratchpad.\n", token.length, token.text);
                return false;
            }
        }
    } break;
    }

    *label = malloc(token.length + 1);
    if (!(*label)) return false;

    memcpy(*label, token.text, token.length);
    (*label)[token.length] = '\0';

    return true;
}

struct properties
{
    struct token token;
    bool did_parse;
    bool did_error;
    uint64_t flags;
};

static inline bool parse_property(struct properties *properties, char *property, uint64_t *property_val, char **property_str, int property_count)
{
    for (int i = 0; i < property_count; ++i) {
        if (string_equals(property, property_str[i])) {
            properties->flags |= property_val[i];
            return true;
        }
    }

    return false;
}

static struct properties parse_properties(FILE *rsp, struct token token, uint64_t *property_val, char **property_str, int property_count)
{
    struct properties result = { .token = token, .did_error = false };

    if ((result.did_parse = token_is_valid(token) && !token_prefix(token, "--"))) {
        for (int i = 0, cursor = 0; i < token.length; ++i) {
            if (i+1 == token.length) {
                if (!parse_property(&result, token.text+cursor, property_val, property_str, property_count)) {
                    daemon_fail(rsp, "'%.*s' is not a valid property.\n", i-cursor+1, token.text+cursor);
                    result.did_error = true;
                }
            } else if (token.text[i] == ',') {
                token.text[i] = '\0';

                if (!parse_property(&result, token.text+cursor, property_val, property_str, property_count)) {
                    daemon_fail(rsp, "'%.*s' is not a valid property.\n", i-cursor+1, token.text+cursor);
                    result.did_error = true;
                }

                cursor = i+1;
            }
        }
    }

    return result;
}

struct selector
{
    struct token token;
    bool did_parse;

    union {
        int dir;
        uint32_t did;
        uint64_t sid;
        struct window *window;
    };
};

static struct selector parse_display_selector(FILE *rsp, char **message, uint32_t acting_did, bool optional)
{
    TIME_FUNCTION;

    struct selector result = { .token = get_token(message), .did_parse = true };

    struct token_value value = token_to_value(result.token);
    if (value.type == TOKEN_TYPE_INT) {
        uint32_t did = display_manager_arrangement_display_id(value.int_value);
        if (did) {
            result.did = did;
        } else {
            daemon_fail(rsp, "could not locate display with arrangement index '%d'.\n", value.int_value);
        }
    } else if (value.type == TOKEN_TYPE_STRING) {
        if (token_equals(result.token, ARGUMENT_COMMON_SEL_NORTH)) {
            if (acting_did) {
                uint32_t did = display_manager_find_closest_display_in_direction(acting_did, DIR_NORTH);
                if (did) {
                    result.did = did;
                } else {
                    daemon_fail(rsp, "could not locate a northward display.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_EAST)) {
            if (acting_did) {
                uint32_t did = display_manager_find_closest_display_in_direction(acting_did, DIR_EAST);
                if (did) {
                    result.did = did;
                } else {
                    daemon_fail(rsp, "could not locate a eastward display.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_SOUTH)) {
            if (acting_did) {
                uint32_t did = display_manager_find_closest_display_in_direction(acting_did, DIR_SOUTH);
                if (did) {
                    result.did = did;
                } else {
                    daemon_fail(rsp, "could not locate a southward display.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_WEST)) {
            if (acting_did) {
                uint32_t did = display_manager_find_closest_display_in_direction(acting_did, DIR_WEST);
                if (did) {
                    result.did = did;
                } else {
                    daemon_fail(rsp, "could not locate a westward display.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_PREV)) {
            if (acting_did) {
                uint32_t did = display_manager_prev_display_id(acting_did);
                if (did) {
                    result.did = did;
                } else {
                    daemon_fail(rsp, "could not locate the previous display.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_NEXT)) {
            if (acting_did) {
                uint32_t did = display_manager_next_display_id(acting_did);
                if (did) {
                    result.did = did;
                } else {
                    daemon_fail(rsp, "could not locate the next display.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_FIRST)) {
            uint32_t did = display_manager_first_display_id();
            if (did) {
                result.did = did;
            } else {
                daemon_fail(rsp, "could not locate the first display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_LAST)) {
            uint32_t did = display_manager_last_display_id();
            if (did) {
                result.did = did;
            } else {
                daemon_fail(rsp, "could not locate the last display.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_RECENT)) {
            result.did = g_display_manager.last_display_id;
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_MOUSE)) {
            uint32_t did = display_manager_cursor_display_id();
            if (did) {
                result.did = did;
            } else {
                daemon_fail(rsp, "could not locate display containing cursor.\n");
            }
        } else {
            struct display_label *display_label = display_manager_get_display_for_label(&g_display_manager, value.string_value);
            if (display_label) {
                result.did_parse = true;
                result.did = display_label->did;
            } else {
                result.did_parse = false;
                daemon_fail(rsp, "value '%.*s' is not a valid option for DISPLAY_SEL\n", result.token.length, result.token.text);
            }
        }
    } else if (value.type == TOKEN_TYPE_INVALID) {
        result.did_parse = false;
        if (!optional) daemon_fail(rsp, "value '%.*s' is not a valid option for DISPLAY_SEL\n", result.token.length, result.token.text);
    } else {
        result.did_parse = false;
        daemon_fail(rsp, "value '%.*s' is not a valid option for DISPLAY_SEL\n", result.token.length, result.token.text);
    }

    return result;
}

static struct selector parse_space_selector(FILE *rsp, char **message, uint64_t acting_sid, bool optional)
{
    TIME_FUNCTION;

    struct selector result = { .token = get_token(message), .did_parse = true };

    struct token_value value = token_to_value(result.token);
    if (value.type == TOKEN_TYPE_INT) {
        uint64_t sid = space_manager_mission_control_space(value.int_value);
        if (sid) {
            result.sid = sid;
        } else {
            daemon_fail(rsp, "could not locate space with mission-control index '%d'.\n", value.int_value);
        }
    } else if (value.type == TOKEN_TYPE_STRING) {
        if (token_equals(result.token, ARGUMENT_COMMON_SEL_PREV)) {
            if (acting_sid) {
                uint64_t sid = space_manager_prev_space(acting_sid);
                if (sid) {
                    result.sid = sid;
                } else {
                    daemon_fail(rsp, "could not locate the previous space.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected space.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_NEXT)) {
            if (acting_sid) {
                uint64_t sid = space_manager_next_space(acting_sid);
                if (sid) {
                    result.sid = sid;
                } else {
                    daemon_fail(rsp, "could not locate the next space.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected space.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_FIRST)) {
            uint64_t sid = space_manager_first_space();
            if (sid) {
                result.sid = sid;
            } else {
                daemon_fail(rsp, "could not locate the first space.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_LAST)) {
            uint64_t sid = space_manager_last_space();
            if (sid) {
                result.sid = sid;
            } else {
                daemon_fail(rsp, "could not locate the last space.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_RECENT)) {
            result.sid = g_space_manager.last_space_id;
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_MOUSE)) {
            uint64_t sid = space_manager_cursor_space();
            if (sid) {
                result.sid = sid;
            } else {
                daemon_fail(rsp, "could not locate space containing cursor.\n");
            }
        } else {
            struct space_label *space_label = space_manager_get_space_for_label(&g_space_manager, value.string_value);
            if (space_label) {
                result.did_parse = true;
                result.sid = space_label->sid;
            } else {
                result.did_parse = false;
                daemon_fail(rsp, "value '%.*s' is not a valid option for SPACE_SEL\n", result.token.length, result.token.text);
            }
        }
    } else if (value.type == TOKEN_TYPE_INVALID) {
        result.did_parse = false;
        if (!optional) daemon_fail(rsp, "value '%.*s' is not a valid option for SPACE_SEL\n", result.token.length, result.token.text);
    } else {
        result.did_parse = false;
        daemon_fail(rsp, "value '%.*s' is not a valid option for SPACE_SEL\n", result.token.length, result.token.text);
    }

    return result;
}

static struct selector parse_window_selector(FILE *rsp, char **message, struct window *acting_window, bool optional)
{
    TIME_FUNCTION;

    struct selector result = { .token = get_token(message), .did_parse = true };

    struct token_value value = token_to_value(result.token);
    if (value.type == TOKEN_TYPE_INT) {
        struct window *window = window_manager_find_window(&g_window_manager, value.int_value);
        if (window) {
            result.window = window;
        } else {
            daemon_fail(rsp, "could not locate window with the specified id '%d'.\n", value.int_value);
        }
    } else if (value.type == TOKEN_TYPE_STRING) {
        if (token_equals(result.token, ARGUMENT_COMMON_SEL_NORTH)) {
            if (acting_window) {
                struct window *closest_window = window_manager_find_closest_window_in_direction(&g_window_manager, acting_window, DIR_NORTH);
                if (closest_window) {
                    result.window = closest_window;
                } else {
                    daemon_fail(rsp, "could not locate a northward window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_EAST)) {
            if (acting_window) {
                struct window *closest_window = window_manager_find_closest_window_in_direction(&g_window_manager, acting_window, DIR_EAST);
                if (closest_window) {
                    result.window = closest_window;
                } else {
                    daemon_fail(rsp, "could not locate a eastward window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_SOUTH)) {
            if (acting_window) {
                struct window *closest_window = window_manager_find_closest_window_in_direction(&g_window_manager, acting_window, DIR_SOUTH);
                if (closest_window) {
                    result.window = closest_window;
                } else {
                    daemon_fail(rsp, "could not locate a southward window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_WEST)) {
            if (acting_window) {
                struct window *closest_window = window_manager_find_closest_window_in_direction(&g_window_manager, acting_window, DIR_WEST);
                if (closest_window) {
                    result.window = closest_window;
                } else {
                    daemon_fail(rsp, "could not locate a westward window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_MOUSE)) {
            struct window *mouse_window = window_manager_find_window_below_cursor(&g_window_manager);
            if (mouse_window) {
                result.window = mouse_window;
            } else {
                daemon_fail(rsp, "could not locate a window below the cursor.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_LARGEST)) {
            struct window *area_window = window_manager_find_largest_managed_window(&g_space_manager, &g_window_manager);
            if (area_window) {
                result.window = area_window;
            } else {
                daemon_fail(rsp, "could not locate window with the largest area.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_SMALLEST)) {
            struct window *area_window = window_manager_find_smallest_managed_window(&g_space_manager, &g_window_manager);
            if (area_window) {
                result.window = area_window;
            } else {
                daemon_fail(rsp, "could not locate window with the smallest area.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_SIBLING)) {
            if (acting_window) {
                struct window *sibling_window = window_manager_find_sibling_for_managed_window(&g_window_manager, acting_window);
                if (sibling_window) {
                    result.window = sibling_window;
                } else {
                    daemon_fail(rsp, "could not locate sibling of window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_FNEPHEW)) {
            if (acting_window) {
                struct window *nephew_window = window_manager_find_first_nephew_for_managed_window(&g_window_manager, acting_window);
                if (nephew_window) {
                    result.window = nephew_window;
                } else {
                    daemon_fail(rsp, "could not locate first nephew of window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_SNEPHEW)) {
            if (acting_window) {
                struct window *nephew_window = window_manager_find_second_nephew_for_managed_window(&g_window_manager, acting_window);
                if (nephew_window) {
                    result.window = nephew_window;
                } else {
                    daemon_fail(rsp, "could not locate second nephew of window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_UNCLE)) {
            if (acting_window) {
                struct window *uncle_window = window_manager_find_uncle_for_managed_window(&g_window_manager, acting_window);
                if (uncle_window) {
                    result.window = uncle_window;
                } else {
                    daemon_fail(rsp, "could not locate uncle of window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_FCOUSIN)) {
            if (acting_window) {
                struct window *cousin_window = window_manager_find_first_cousin_for_managed_window(&g_window_manager, acting_window);
                if (cousin_window) {
                    result.window = cousin_window;
                } else {
                    daemon_fail(rsp, "could not locate first cousin of window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_WINDOW_SEL_SCOUSIN)) {
            if (acting_window) {
                struct window *cousin_window = window_manager_find_second_cousin_for_managed_window(&g_window_manager, acting_window);
                if (cousin_window) {
                    result.window = cousin_window;
                } else {
                    daemon_fail(rsp, "could not locate second cousin of window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_PREV)) {
            if (acting_window) {
                struct window *prev_window = window_manager_find_prev_managed_window(&g_space_manager, &g_window_manager, acting_window);
                if (prev_window) {
                    result.window = prev_window;
                } else {
                    daemon_fail(rsp, "could not locate the prev managed window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_NEXT)) {
            if (acting_window) {
                struct window *next_window = window_manager_find_next_managed_window(&g_space_manager, &g_window_manager, acting_window);
                if (next_window) {
                    result.window = next_window;
                } else {
                    daemon_fail(rsp, "could not locate the next managed window.\n");
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_FIRST)) {
            struct window *first_window = window_manager_find_first_managed_window(&g_space_manager, &g_window_manager);
            if (first_window) {
                result.window = first_window;
            } else {
                daemon_fail(rsp, "could not locate the first managed window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_LAST)) {
            struct window *last_window = window_manager_find_last_managed_window(&g_space_manager, &g_window_manager);
            if (last_window) {
                result.window = last_window;
            } else {
                daemon_fail(rsp, "could not locate the last managed window.\n");
            }
        } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_RECENT)) {
            struct window *recent_window = window_manager_find_recent_managed_window(&g_window_manager);
            if (recent_window) {
                result.window = recent_window;
            } else {
                daemon_fail(rsp, "could not locate the most recently focused window.\n");
            }
        } else if (token_prefix(result.token, ARGUMENT_COMMON_SEL_STACK_PREFIX)) {
            if (acting_window) {
                int index;
                result.token.text   += strlen(ARGUMENT_COMMON_SEL_STACK_PREFIX);
                result.token.length -= strlen(ARGUMENT_COMMON_SEL_STACK_PREFIX);

                if (token_equals(result.token, ARGUMENT_COMMON_SEL_PREV)) {
                    struct window *prev_window = window_manager_find_prev_window_in_stack(&g_space_manager, &g_window_manager, acting_window);
                    if (prev_window) {
                        result.window = prev_window;
                    } else {
                        daemon_fail(rsp, "could not locate the prev stacked window.\n");
                    }
                } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_NEXT)) {
                    struct window *next_window = window_manager_find_next_window_in_stack(&g_space_manager, &g_window_manager, acting_window);
                    if (next_window) {
                        result.window = next_window;
                    } else {
                        daemon_fail(rsp, "could not locate the next stacked window.\n");
                    }
                } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_FIRST)) {
                    struct window *first_window = window_manager_find_first_window_in_stack(&g_space_manager, &g_window_manager, acting_window);
                    if (first_window) {
                        result.window = first_window;
                    } else {
                        daemon_fail(rsp, "could not locate the first stacked window.\n");
                    }
                } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_LAST)) {
                    struct window *last_window = window_manager_find_last_window_in_stack(&g_space_manager, &g_window_manager, acting_window);
                    if (last_window) {
                        result.window = last_window;
                    } else {
                        daemon_fail(rsp, "could not locate the last stacked window.\n");
                    }
                } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_RECENT)) {
                    struct window *recent_window = window_manager_find_recent_window_in_stack(&g_space_manager, &g_window_manager, acting_window);
                    if (recent_window) {
                        result.window = recent_window;
                    } else {
                        daemon_fail(rsp, "could not locate the recent stacked window.\n");
                    }
                } else if (token_is_valid(result.token) && token_is_positive_integer(result.token, &index) && index > 0) {
                    struct window *index_window = window_manager_find_window_in_stack(&g_space_manager, &g_window_manager, acting_window, index);
                    if (index_window) {
                        result.window = index_window;
                    } else {
                        daemon_fail(rsp, "could not locate the stacked window in position %d.\n", index);
                    }
                } else {
                    result.did_parse = false;
                    daemon_fail(rsp, "value '%s%.*s' is not a valid option for WINDOW_SEL\n", ARGUMENT_COMMON_SEL_STACK_PREFIX, result.token.length, result.token.text);
                }
            } else {
                daemon_fail(rsp, "could not locate the selected window.\n");
            }
        } else {
            result.did_parse = false;
            daemon_fail(rsp, "value '%.*s' is not a valid option for WINDOW_SEL\n", result.token.length, result.token.text);
        }
    } else if (value.type == TOKEN_TYPE_INVALID) {
        result.did_parse = false;
        if (!optional) daemon_fail(rsp, "value '%.*s' is not a valid option for WINDOW_SEL\n", result.token.length, result.token.text);
    } else {
        result.did_parse = false;
        daemon_fail(rsp, "value '%.*s' is not a valid option for WINDOW_SEL\n", result.token.length, result.token.text);
    }

    return result;
}

static struct selector parse_insert_selector(FILE *rsp, char **message)
{
    struct selector result = { .token = get_token(message), .did_parse = true };

    if (token_equals(result.token, ARGUMENT_COMMON_SEL_NORTH)) {
        result.dir = DIR_NORTH;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_EAST)) {
        result.dir = DIR_EAST;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_SOUTH)) {
        result.dir = DIR_SOUTH;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_WEST)) {
        result.dir = DIR_WEST;
    } else if (token_equals(result.token, ARGUMENT_COMMON_SEL_STACK)) {
        result.dir = STACK;
    } else {
        result.did_parse = false;
        daemon_fail(rsp, "value '%.*s' is not a valid option for DIR_SEL\n", result.token.length, result.token.text);
    }

    return result;
}

// focus_ring config string tables. Index MUST match the matching enum in
// focus_ring.h (the ordinal is the payload wire contract — append at the end,
// never reorder).
static char *focus_ring_blend_mode_str[] = {
    "normal", "multiply", "screen", "overlay", "darken", "lighten",
    "color-dodge", "color-burn", "soft-light", "hard-light", "difference",
    "exclusion", "hue", "saturation", "color", "luminosity",
};
static char *focus_ring_inner_stroke_position_str[] = { "above", "below" };

// focus_ring config helpers. The ring exposes ~20 knobs sharing a handful of
// parse shapes; each helper takes the matching getter/setter instead of
// repeating the read-token / print-current / dispatch-or-fail sequence per key.
// All focus_ring setters clamp and self-repaint internally (see focus_ring.m),
// so message.c only has to parse the value.
static void fr_config_bool(FILE *rsp, char **message, struct token command, struct token domain, bool (*get)(void), void (*set)(bool))
{
    struct token value = get_token(message);
    if (!token_is_valid(value)) {
        fprintf(rsp, "%s\n", bool_str[get()]);
    } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
        set(false);
    } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
        set(true);
    } else {
        daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
    }
}

static void fr_config_float(FILE *rsp, char **message, struct token command, struct token domain, float (*get)(void), void (*set)(float))
{
    struct token_value value = token_to_value(get_token(message));
    if (value.type == TOKEN_TYPE_INVALID) {
        fprintf(rsp, "%f\n", get());
    } else if (value.type == TOKEN_TYPE_FLOAT) {
        set(value.float_value);
    } else if (value.type == TOKEN_TYPE_INT) {
        set((float) value.int_value);
    } else {
        daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
    }
}

static void fr_config_int(FILE *rsp, char **message, struct token command, struct token domain, int (*get)(void), void (*set)(int))
{
    struct token_value value = token_to_value(get_token(message));
    if (value.type == TOKEN_TYPE_INVALID) {
        fprintf(rsp, "%d\n", get());
    } else if (value.type == TOKEN_TYPE_INT) {
        set(value.int_value);
    } else if (value.type == TOKEN_TYPE_FLOAT) {
        set((int) value.float_value);
    } else {
        daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
    }
}

static void fr_config_enum(FILE *rsp, char **message, struct token command, struct token domain, char **names, int count, int (*get)(void), void (*set)(int))
{
    struct token value = get_token(message);
    if (!token_is_valid(value)) {
        int cur = get();
        if (cur >= 0 && cur < count) fprintf(rsp, "%s\n", names[cur]);
    } else {
        for (int i = 0; i < count; ++i) {
            if (token_equals(value, names[i])) { set(i); return; }
        }
        daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
    }
}

// Band color: 0xAARRGGBB | a named accent preset | auto|system (live accent).
static void fr_config_color_base(FILE *rsp, char **message, struct token command, struct token domain, uint32_t (*get)(void), bool (*is_auto)(void), void (*set)(uint32_t), void (*set_auto)(void))
{
    struct token value = get_token(message);
    uint32_t argb;
    if (!token_is_valid(value)) {
        if (is_auto()) fprintf(rsp, "auto\n");
        else           fprintf(rsp, "0x%08x\n", get());
    } else if (token_equals(value, "auto") || token_equals(value, "system")) {
        set_auto();
    } else if (focus_ring_color_preset(value.text, &argb)) {
        set(argb);
    } else if (token_is_hexadecimal(value, &argb)) {
        set(argb);
    } else {
        daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
    }
}

// Inner-stroke color: 0xRRGGBB | a named accent preset | inherit (follow the band).
static void fr_config_color_inherit(FILE *rsp, char **message, struct token command, struct token domain, uint32_t (*get)(void), bool (*is_set)(void), void (*set)(uint32_t), void (*set_inherit)(void))
{
    struct token value = get_token(message);
    uint32_t argb;
    if (!token_is_valid(value)) {
        if (!is_set()) fprintf(rsp, "inherit\n");
        else           fprintf(rsp, "0x%06x\n", get());
    } else if (token_equals(value, "inherit")) {
        set_inherit();
    } else if (focus_ring_color_preset(value.text, &argb)) {
        set(argb);
    } else if (token_is_hexadecimal(value, &argb)) {
        set(argb);
    } else {
        daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
    }
}

// Inner-stroke opacity: 0.0..1.0 | inherit (sentinel FOCUS_RING_OPACITY_INHERIT).
static void fr_config_opacity_inherit(FILE *rsp, char **message, struct token command, struct token domain, float (*get)(void), void (*set)(float))
{
    struct token value = get_token(message);
    if (!token_is_valid(value)) {
        float cur = get();
        if (cur == FOCUS_RING_OPACITY_INHERIT) fprintf(rsp, "inherit\n");
        else                                        fprintf(rsp, "%f\n", cur);
    } else if (token_equals(value, "inherit")) {
        set(FOCUS_RING_OPACITY_INHERIT);
    } else {
        struct token_value tv = token_to_value(value);
        if (tv.type == TOKEN_TYPE_FLOAT)    set(tv.float_value);
        else if (tv.type == TOKEN_TYPE_INT) set((float) tv.int_value);
        else daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
    }
}

static void handle_domain_config(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    uint64_t sel_sid = 0;
    struct token selector = get_token(&message);
    struct token command  = selector;

    bool found_selector = token_equals(selector, SELECTOR_CONFIG_SPACE);
    if (found_selector) {
        struct selector space_selector = parse_space_selector(rsp, &message, 0, false);
        if (!space_selector.did_parse || !space_selector.sid) return;

        sel_sid = space_selector.sid;
        command = get_token(&message);
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (token_equals(command, COMMAND_CONFIG_DEBUG_OUTPUT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_verbose]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_verbose = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_verbose = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MFF)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.enable_mff]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.enable_mff = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.enable_mff = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_FFM)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", ffm_mode_str[g_window_manager.ffm_mode]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_DISABLED);
            } else if (token_equals(value, ARGUMENT_CONFIG_FFM_AUTOFOCUS)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_AUTOFOCUS);
            } else if (token_equals(value, ARGUMENT_CONFIG_FFM_AUTORAISE)) {
                window_manager_set_focus_follows_mouse(&g_window_manager, FFM_AUTORAISE);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_DISPLAY_ORDER)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", display_arrangement_order_str[g_display_manager.order]);
            } else if (token_equals(value, ARGUMENT_CONFIG_DISPLAY_ORDER_DEFAULT)) {
                g_display_manager.order = DISPLAY_ARRANGEMENT_ORDER_DEFAULT;
            } else if (token_equals(value, ARGUMENT_CONFIG_DISPLAY_ORDER_X)) {
                g_display_manager.order = DISPLAY_ARRANGEMENT_ORDER_X;
            } else if (token_equals(value, ARGUMENT_CONFIG_DISPLAY_ORDER_Y)) {
                g_display_manager.order = DISPLAY_ARRANGEMENT_ORDER_Y;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_ORIGIN)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", window_origin_mode_str[g_window_manager.window_origin_mode]);
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_ORIGIN_DEFAULT)) {
                g_window_manager.window_origin_mode = WINDOW_ORIGIN_DEFAULT;
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_ORIGIN_FOCUSED)) {
                g_window_manager.window_origin_mode = WINDOW_ORIGIN_FOCUSED;
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_ORIGIN_CURSOR)) {
                g_window_manager.window_origin_mode = WINDOW_ORIGIN_CURSOR;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_PLACEMENT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", window_node_child_str[g_space_manager.window_placement]);
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_PLACEMENT_FST)) {
                g_space_manager.window_placement = CHILD_FIRST;
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_PLACEMENT_SND)) {
                g_space_manager.window_placement = CHILD_SECOND;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_INSERT_POINT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", window_insertion_point_str[g_space_manager.window_insertion_point]);
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_INSERT_FOCUSED)) {
                g_space_manager.window_insertion_point = INSERT_FOCUSED;
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_INSERT_FIRST)) {
                g_space_manager.window_insertion_point = INSERT_FIRST;
            } else if (token_equals(value, ARGUMENT_CONFIG_WINDOW_INSERT_LAST)) {
                g_space_manager.window_insertion_point = INSERT_LAST;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_ZOOM_PERSIST)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_space_manager.window_zoom_persist]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_space_manager.window_zoom_persist = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_space_manager.window_zoom_persist = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_FRAME_VERIFY_RETRY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.window_frame_verify_retry]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.window_frame_verify_retry = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.window_frame_verify_retry = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SKIP_SPACE_ANIMATION)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_space_manager.skip_window_focus_animation]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_space_manager.skip_window_focus_animation = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_space_manager.skip_window_focus_animation = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MC_ALWAYS_SHOW_SPACES_STRIP)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_space_manager.mission_control_always_show_spaces_strip_enabled]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_space_manager.mission_control_always_show_spaces_strip_enabled = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_space_manager.mission_control_always_show_spaces_strip_enabled = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_ENABLED)) {
            fr_config_bool(rsp, &message, command, domain, focus_ring_get_enabled, focus_ring_set_enabled);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_WIDTH)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_width, focus_ring_set_width);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_COLOR_OPACITY)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_color_opacity, focus_ring_set_color_opacity);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_ALPHA)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_alpha, focus_ring_set_alpha);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_COLOR)) {
            fr_config_color_base(rsp, &message, command, domain, focus_ring_get_color, focus_ring_get_color_is_auto, focus_ring_set_color, focus_ring_set_color_auto);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_BLUR_RADIUS)) {
            fr_config_int(rsp, &message, command, domain, focus_ring_get_blur_radius, focus_ring_set_blur_radius);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_BLEED)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_bleed, focus_ring_set_bleed);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_FEATHER)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_feather, focus_ring_set_feather);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_SATURATION)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_saturation, focus_ring_set_saturation);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_BRIGHTNESS)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_brightness, focus_ring_set_brightness);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_CONTRAST)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_contrast, focus_ring_set_contrast);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_HUE)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_hue, focus_ring_set_hue);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_BLEND_MODE)) {
            fr_config_enum(rsp, &message, command, domain, focus_ring_blend_mode_str, FOCUS_RING_BLEND_COUNT, focus_ring_get_blend_mode, focus_ring_set_blend_mode);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_INNER_STROKE)) {
            fr_config_bool(rsp, &message, command, domain, focus_ring_get_inner_stroke, focus_ring_set_inner_stroke);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_POSITION)) {
            fr_config_enum(rsp, &message, command, domain, focus_ring_inner_stroke_position_str, 2, focus_ring_get_inner_stroke_position, focus_ring_set_inner_stroke_position);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_WIDTH)) {
            fr_config_float(rsp, &message, command, domain, focus_ring_get_inner_stroke_width, focus_ring_set_inner_stroke_width);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_OPACITY)) {
            fr_config_opacity_inherit(rsp, &message, command, domain, focus_ring_get_inner_stroke_opacity, focus_ring_set_inner_stroke_opacity);
        } else if (token_equals(command, COMMAND_CONFIG_FOCUS_RING_INNER_STROKE_COLOR)) {
            fr_config_color_inherit(rsp, &message, command, domain, focus_ring_get_inner_stroke_color, focus_ring_get_inner_stroke_color_is_set, focus_ring_set_inner_stroke_color, focus_ring_set_inner_stroke_color_inherit);
        } else if (token_equals(command, COMMAND_CONFIG_OPACITY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.enable_window_opacity]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                window_manager_set_window_opacity_enabled(&g_window_manager, false);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                window_manager_set_window_opacity_enabled(&g_window_manager, true);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_OPACITY_DURATION)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_opacity_duration);
            } else if (value.type == TOKEN_TYPE_FLOAT) {
                g_window_manager.window_opacity_duration = value.float_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_COVER_FADE)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_animation_cover_fade);
            } else if (value.type == TOKEN_TYPE_FLOAT) {
                g_window_manager.window_animation_cover_fade = value.float_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WARP_COVER)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", warp_cover_mode_str[g_window_manager.window_animation_warp_cover]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON) || token_equals(value, "proxy")) {
                g_window_manager.window_animation_warp_cover = WM_WARP_COVER_PROXY;
            } else if (token_equals(value, "lb_warp")) {
                g_window_manager.window_animation_warp_cover = WM_WARP_COVER_LB_WARP;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.window_animation_warp_cover = WM_WARP_COVER_OFF;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WARP_MIN_MS)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_animation_warp_min_ms);
            } else if (value.type == TOKEN_TYPE_FLOAT) {
                g_window_manager.window_animation_warp_min_ms = value.float_value;
            } else if (value.type == TOKEN_TYPE_INT) {
                g_window_manager.window_animation_warp_min_ms = (float)value.int_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIM_POLICY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", anim_policy_str[g_window_manager.window_animation_policy]);
            } else if (token_equals(value, "true_resize")) {
                g_window_manager.window_animation_policy = WM_ANIM_POLICY_TRUE_RESIZE;
            } else if (token_equals(value, "lb_only")) {
                g_window_manager.window_animation_policy = WM_ANIM_POLICY_LB_ONLY;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_DURATION)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_animation_duration);
            } else if (value.type == TOKEN_TYPE_FLOAT) {
                if (value.float_value == 0.0f) {
                    g_window_manager.window_animation_duration = value.float_value;
                } else if (!scripting_addition_is_sip_friendly()) {
                    daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires System Integrity Protection to be partially disabled! ignoring request..\n", command.length, command.text, domain.length, domain.text);
                } else {
                    g_window_manager.window_animation_duration = value.float_value;
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_DURATION)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.space_animation_duration);
            } else if (value.type == TOKEN_TYPE_FLOAT) {
                if (value.float_value == 0.0f) {
                    g_window_manager.space_animation_duration = value.float_value;
                } else if (!scripting_addition_is_sip_friendly()) {
                    daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires System Integrity Protection to be partially disabled! ignoring request..\n", command.length, command.text, domain.length, domain.text);
                } else {
                    g_window_manager.space_animation_duration = value.float_value;
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_BACKGROUND)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.space_animation_background]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.space_animation_background = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.space_animation_background = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_EXPOSE_ANIMATION_DURATION)) {
            // MC-5b: push -[WVExpose animationDuration] to the Dock-side SA swizzle
            // (opcode 0x58). 0 zeroes MC's enter/exit tween; < 0 = passthrough to
            // the native ~0.25s.
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.expose_animation_duration);
            } else if (value.type == TOKEN_TYPE_FLOAT) {
                if (!scripting_addition_is_sip_friendly()) {
                    daemon_fail(rsp, "command '%.*s' for domain '%.*s' requires System Integrity Protection to be partially disabled! ignoring request..\n", command.length, command.text, domain.length, domain.text);
                } else {
                    g_window_manager.expose_animation_duration = value.float_value;
                    scripting_addition_set_expose_animation_duration((double)value.float_value);
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.space_animation_fade]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.space_animation_fade = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.space_animation_fade = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE_ENTER)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.space_animation_fade_enter]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.space_animation_fade_enter = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.space_animation_fade_enter = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE_EXIT)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.space_animation_fade_exit]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.space_animation_fade_exit = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.space_animation_fade_exit = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_ENTER_DELAY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.space_animation_enter_delay);
            } else if (value.type == TOKEN_TYPE_FLOAT && value.float_value >= 0.0f) {
                g_window_manager.space_animation_enter_delay = value.float_value;
            } else if (value.type == TOKEN_TYPE_INT && value.int_value >= 0) {
                g_window_manager.space_animation_enter_delay = (float)value.int_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_EXIT_DELAY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.space_animation_exit_delay);
            } else if (value.type == TOKEN_TYPE_FLOAT && value.float_value >= 0.0f) {
                g_window_manager.space_animation_exit_delay = value.float_value;
            } else if (value.type == TOKEN_TYPE_INT && value.int_value >= 0) {
                g_window_manager.space_animation_exit_delay = (float)value.int_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE_ENTER_DELAY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                if (g_window_manager.space_animation_fade_enter_delay < 0.0f) fprintf(rsp, "auto\n");
                else fprintf(rsp, "%f\n", g_window_manager.space_animation_fade_enter_delay);
            } else if (token_equals(value, "auto")) {
                g_window_manager.space_animation_fade_enter_delay = -1.0f;
            } else {
                struct token_value tv = token_to_value(value);
                if (tv.type == TOKEN_TYPE_FLOAT)    g_window_manager.space_animation_fade_enter_delay = tv.float_value;
                else if (tv.type == TOKEN_TYPE_INT) g_window_manager.space_animation_fade_enter_delay = (float)tv.int_value;
                else daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE_EXIT_DELAY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                if (g_window_manager.space_animation_fade_exit_delay < 0.0f) fprintf(rsp, "auto\n");
                else fprintf(rsp, "%f\n", g_window_manager.space_animation_fade_exit_delay);
            } else if (token_equals(value, "auto")) {
                g_window_manager.space_animation_fade_exit_delay = -1.0f;
            } else {
                struct token_value tv = token_to_value(value);
                if (tv.type == TOKEN_TYPE_FLOAT)    g_window_manager.space_animation_fade_exit_delay = tv.float_value;
                else if (tv.type == TOKEN_TYPE_INT) g_window_manager.space_animation_fade_exit_delay = (float)tv.int_value;
                else daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE_ENTER_DUR)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                if (g_window_manager.space_animation_fade_enter_dur <= 0.0f) fprintf(rsp, "auto\n");
                else fprintf(rsp, "%f\n", g_window_manager.space_animation_fade_enter_dur);
            } else if (token_equals(value, "auto")) {
                g_window_manager.space_animation_fade_enter_dur = -1.0f;
            } else {
                struct token_value tv = token_to_value(value);
                if (tv.type == TOKEN_TYPE_FLOAT)    g_window_manager.space_animation_fade_enter_dur = tv.float_value;
                else if (tv.type == TOKEN_TYPE_INT) g_window_manager.space_animation_fade_enter_dur = (float)tv.int_value;
                else daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_ANIMATION_FADE_EXIT_DUR)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                if (g_window_manager.space_animation_fade_exit_dur <= 0.0f) fprintf(rsp, "auto\n");
                else fprintf(rsp, "%f\n", g_window_manager.space_animation_fade_exit_dur);
            } else if (token_equals(value, "auto")) {
                g_window_manager.space_animation_fade_exit_dur = -1.0f;
            } else {
                struct token_value tv = token_to_value(value);
                if (tv.type == TOKEN_TYPE_FLOAT)    g_window_manager.space_animation_fade_exit_dur = tv.float_value;
                else if (tv.type == TOKEN_TYPE_INT) g_window_manager.space_animation_fade_exit_dur = (float)tv.int_value;
                else daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_CONTAIN_SPACE_FOCUS_PER_DISPLAY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.contain_space_focus_per_display]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.contain_space_focus_per_display = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.contain_space_focus_per_display = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_FOCUS_FOR_FLOATING)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.window_focus_for_floating_enabled]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.window_focus_for_floating_enabled = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.window_focus_for_floating_enabled = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_FOCUS_INTER_DISPLAY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.window_focus_inter_display]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.window_focus_inter_display = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.window_focus_inter_display = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_FOCUS_WRAP)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", bool_str[g_window_manager.window_focus_wrap]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.window_focus_wrap = false;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.window_focus_wrap = true;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPACE_FOCUS_TARGET_DISPLAY)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", space_focus_target_display_mode_str[g_window_manager.space_focus_target_display]);
            } else if (token_equals(value, ARGUMENT_CONFIG_SFTD_DEFAULT)) {
                g_window_manager.space_focus_target_display = SPACE_FOCUS_TARGET_DISPLAY_DEFAULT;
            } else if (token_equals(value, ARGUMENT_CONFIG_SFTD_MOUSE)) {
                g_window_manager.space_focus_target_display = SPACE_FOCUS_TARGET_DISPLAY_MOUSE;
            } else if (token_equals(value, ARGUMENT_CONFIG_SFTD_SMART)) {
                g_window_manager.space_focus_target_display = SPACE_FOCUS_TARGET_DISPLAY_SMART;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_EASING)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", animation_easing_type_str[g_window_manager.window_animation_easing]);
            } else {
                bool match = false;
                for (int i = 0; i < EASING_TYPE_COUNT; ++i) {
                    if (token_equals(value, animation_easing_type_str[i])) {
                        g_window_manager.window_animation_easing = i;
                        match = true;
                        break;
                    }
                }
                if (!match) daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_MIN_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%f\n", g_window_manager.window_animation_min_opacity);
            } else if (value.type == TOKEN_TYPE_FLOAT && in_range_ii(value.float_value, 0.0f, 1.0f)) {
                g_window_manager.window_animation_min_opacity = value.float_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ANIMATION_AX_WAKE)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", g_window_manager.window_animation_ax_wake ? "on" : "off");
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                g_window_manager.window_animation_ax_wake = true;
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                g_window_manager.window_animation_ax_wake = false;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SHADOW)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", purify_mode_str[g_window_manager.purify_mode]);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                window_manager_set_purify_mode(&g_window_manager, PURIFY_ALWAYS);
            } else if (token_equals(value, ARGUMENT_CONFIG_SHADOW_FLT)) {
                window_manager_set_purify_mode(&g_window_manager, PURIFY_MANAGED);
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                window_manager_set_purify_mode(&g_window_manager, PURIFY_DISABLED);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MENUBAR_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.menubar_opacity);
            } else if (value.type == TOKEN_TYPE_FLOAT && in_range_ii(value.float_value, 0.0f, 1.0f)) {
                window_manager_set_menubar_opacity(&g_window_manager, value.float_value);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_ACTIVE_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.active_window_opacity);
            } else if (value.type == TOKEN_TYPE_FLOAT && in_range_ei(value.float_value, 0.0f, 1.0f)) {
                window_manager_set_active_window_opacity(&g_window_manager, value.float_value);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_NORMAL_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_window_manager.normal_window_opacity);
            } else if (value.type == TOKEN_TYPE_FLOAT && in_range_ei(value.float_value, 0.0f, 1.0f)) {
                window_manager_set_normal_window_opacity(&g_window_manager, value.float_value);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_INSERT_FEEDBACK_COLOR)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "0x%x\n", g_window_manager.insert_feedback_color.p);
            } else if (value.type == TOKEN_TYPE_U32 && value.u32_value) {
                g_window_manager.insert_feedback_color = rgba_color_from_hex(value.u32_value);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_TOP_PADDING)) {
            struct token_value value = token_to_value(get_token(&message));
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", view->top_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    view_set_flag(view, VIEW_TOP_PADDING);
                    view->top_padding = value.int_value;
                    view_update(view);
                    view_flush(view);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", g_space_manager.top_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    space_manager_set_top_padding_for_all_spaces(&g_space_manager, value.int_value);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_BOTTOM_PADDING)) {
            struct token_value value = token_to_value(get_token(&message));
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", view->bottom_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    view_set_flag(view, VIEW_BOTTOM_PADDING);
                    view->bottom_padding = value.int_value;
                    view_update(view);
                    view_flush(view);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", g_space_manager.bottom_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    space_manager_set_bottom_padding_for_all_spaces(&g_space_manager, value.int_value);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_LEFT_PADDING)) {
            struct token_value value = token_to_value(get_token(&message));
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", view->left_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    view_set_flag(view, VIEW_LEFT_PADDING);
                    view->left_padding = value.int_value;
                    view_update(view);
                    view_flush(view);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", g_space_manager.left_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    space_manager_set_left_padding_for_all_spaces(&g_space_manager, value.int_value);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_RIGHT_PADDING)) {
            struct token_value value = token_to_value(get_token(&message));
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", view->right_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    view_set_flag(view, VIEW_RIGHT_PADDING);
                    view->right_padding = value.int_value;
                    view_update(view);
                    view_flush(view);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", g_space_manager.right_padding);
                } else if (value.type == TOKEN_TYPE_INT) {
                    space_manager_set_right_padding_for_all_spaces(&g_space_manager, value.int_value);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_WINDOW_GAP)) {
            struct token_value value = token_to_value(get_token(&message));
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", view->window_gap);
                } else if (value.type == TOKEN_TYPE_INT) {
                    view_set_flag(view, VIEW_WINDOW_GAP);
                    view->window_gap = value.int_value;
                    view_update(view);
                    view_flush(view);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (value.type == TOKEN_TYPE_INVALID) {
                    fprintf(rsp, "%d\n", g_space_manager.window_gap);
                } else if (value.type == TOKEN_TYPE_INT) {
                    space_manager_set_window_gap_for_all_spaces(&g_space_manager, value.int_value);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_LAYOUT)) {
            struct token value = get_token(&message);
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (!token_is_valid(value)) {
                    fprintf(rsp, "%s\n", view_type_str[view->layout]);
                } else if (token_equals(value, ARGUMENT_CONFIG_LAYOUT_BSP)) {
                    if (space_is_user(sel_sid)) {
                        view_set_flag(view, VIEW_LAYOUT);
                        view->layout = VIEW_BSP;
                        view_clear(view);
                        window_manager_validate_and_check_for_windows_on_space(&g_space_manager, &g_window_manager, sel_sid);
                    } else {
                        daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                    }
                } else if (token_equals(value, ARGUMENT_CONFIG_LAYOUT_STACK)) {
                    if (space_is_user(sel_sid)) {
                        view_set_flag(view, VIEW_LAYOUT);
                        view->layout = VIEW_STACK;
                        view_clear(view);
                        window_manager_validate_and_check_for_windows_on_space(&g_space_manager, &g_window_manager, sel_sid);
                    } else {
                        daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                    }
                } else if (token_equals(value, ARGUMENT_CONFIG_LAYOUT_FLOAT)) {
                    if (space_is_user(sel_sid)) {
                        view_set_flag(view, VIEW_LAYOUT);
                        view->layout = VIEW_FLOAT;
                        view_clear(view);
                    } else {
                        daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                    }
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (!token_is_valid(value)) {
                    fprintf(rsp, "%s\n", view_type_str[g_space_manager.layout]);
                } else if (token_equals(value, ARGUMENT_CONFIG_LAYOUT_BSP)) {
                    space_manager_set_layout_for_all_spaces(&g_space_manager, VIEW_BSP);
                } else if (token_equals(value, ARGUMENT_CONFIG_LAYOUT_STACK)) {
                    space_manager_set_layout_for_all_spaces(&g_space_manager, VIEW_STACK);
                } else if (token_equals(value, ARGUMENT_CONFIG_LAYOUT_FLOAT)) {
                    space_manager_set_layout_for_all_spaces(&g_space_manager, VIEW_FLOAT);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPLIT_RATIO)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_INVALID) {
                fprintf(rsp, "%.4f\n", g_space_manager.split_ratio);
            } else if (value.type == TOKEN_TYPE_FLOAT && in_range_ii(value.float_value, 0.1f, 0.9f)) {
                g_space_manager.split_ratio = value.float_value;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_SPLIT_TYPE)) {
            struct token value = get_token(&message);
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (!token_is_valid(value)) {
                    fprintf(rsp, "%s\n", window_node_split_str[view->split_type]);
                } else if (token_equals(value, ARGUMENT_CONFIG_SPLIT_TYPE_Y)) {
                    view_set_flag(view, VIEW_SPLIT_TYPE);
                    view->split_type = SPLIT_Y;
                } else if (token_equals(value, ARGUMENT_CONFIG_SPLIT_TYPE_X)) {
                    view_set_flag(view, VIEW_SPLIT_TYPE);
                    view->split_type = SPLIT_X;
                } else if (token_equals(value, ARGUMENT_CONFIG_SPLIT_TYPE_AUTO)) {
                    view_set_flag(view, VIEW_SPLIT_TYPE);
                    view->split_type = SPLIT_AUTO;
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (!token_is_valid(value)) {
                    fprintf(rsp, "%s\n", window_node_split_str[g_space_manager.split_type]);
                } else if (token_equals(value, ARGUMENT_CONFIG_SPLIT_TYPE_Y)) {
                    space_manager_set_split_type_for_all_spaces(&g_space_manager, SPLIT_Y);
                } else if (token_equals(value, ARGUMENT_CONFIG_SPLIT_TYPE_X)) {
                    space_manager_set_split_type_for_all_spaces(&g_space_manager, SPLIT_X);
                } else if (token_equals(value, ARGUMENT_CONFIG_SPLIT_TYPE_AUTO)) {
                    space_manager_set_split_type_for_all_spaces(&g_space_manager, SPLIT_AUTO);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_AUTO_BALANCE)) {
            struct token value = get_token(&message);
            if (sel_sid) {
                struct view *view = space_manager_find_view(&g_space_manager, sel_sid);
                if (!token_is_valid(value)) {
                    fprintf(rsp, "%s\n", auto_balance_str[view->auto_balance]);
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                    view_set_flag(view, VIEW_AUTO_BALANCE);
                    view->auto_balance = SPLIT_NONE;
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                    view_set_flag(view, VIEW_AUTO_BALANCE);
                    view->auto_balance = SPLIT_X | SPLIT_Y;
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X)) {
                    view_set_flag(view, VIEW_AUTO_BALANCE);
                    view->auto_balance = SPLIT_X;
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                    view_set_flag(view, VIEW_AUTO_BALANCE);
                    view->auto_balance = SPLIT_Y;
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                if (!token_is_valid(value)) {
                    fprintf(rsp, "%s\n", auto_balance_str[g_space_manager.auto_balance]);
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                    space_manager_set_auto_balance_for_all_spaces(&g_space_manager, SPLIT_NONE);
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                    space_manager_set_auto_balance_for_all_spaces(&g_space_manager, SPLIT_X | SPLIT_Y);
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X)) {
                    space_manager_set_auto_balance_for_all_spaces(&g_space_manager, SPLIT_X);
                } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                    space_manager_set_auto_balance_for_all_spaces(&g_space_manager, SPLIT_Y);
                } else {
                    daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            }
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_MOD)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", mouse_mod_str[g_mouse_state.modifier]);
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_MOD_ALT)) {
                g_mouse_state.modifier = MOUSE_MOD_ALT;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_MOD_SHIFT)) {
                g_mouse_state.modifier = MOUSE_MOD_SHIFT;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_MOD_CMD)) {
                g_mouse_state.modifier = MOUSE_MOD_CMD;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_MOD_CTRL)) {
                g_mouse_state.modifier = MOUSE_MOD_CTRL;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_MOD_FN)) {
                g_mouse_state.modifier = MOUSE_MOD_FN;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_ACTION1)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", mouse_mode_str[g_mouse_state.action1]);
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_ACTION_MOVE)) {
                g_mouse_state.action1 = MOUSE_MODE_MOVE;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_ACTION_RESIZE)) {
                g_mouse_state.action1 = MOUSE_MODE_RESIZE;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_ACTION2)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", mouse_mode_str[g_mouse_state.action2]);
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_ACTION_MOVE)) {
                g_mouse_state.action2 = MOUSE_MODE_MOVE;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_ACTION_RESIZE)) {
                g_mouse_state.action2 = MOUSE_MODE_RESIZE;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_MOUSE_DROP_ACTION)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                fprintf(rsp, "%s\n", mouse_mode_str[g_mouse_state.drop_action]);
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_ACTION_SWAP)) {
                g_mouse_state.drop_action = MOUSE_MODE_SWAP;
            } else if (token_equals(value, ARGUMENT_CONFIG_MOUSE_ACTION_STACK)) {
                g_mouse_state.drop_action = MOUSE_MODE_STACK;
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_CONFIG_EXTERNAL_BAR)) {
            int t, b;
            char mode[6];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_CONFIG_EXTERNAL_BAR, mode, &t, &b) == 3)) {
                if (string_equals(mode, ARGUMENT_CONFIG_EXTERNAL_BAR_MAIN)) {
                    g_display_manager.mode = EXTERNAL_BAR_MAIN;
                    g_display_manager.top_padding = t;
                    g_display_manager.bottom_padding = b;
                    space_manager_mark_spaces_invalid(&g_space_manager);
                } else if (string_equals(mode, ARGUMENT_CONFIG_EXTERNAL_BAR_ALL)) {
                    g_display_manager.mode = EXTERNAL_BAR_ALL;
                    g_display_manager.top_padding = t;
                    g_display_manager.bottom_padding = b;
                    space_manager_mark_spaces_invalid(&g_space_manager);
                } else if (string_equals(mode, ARGUMENT_COMMON_VAL_OFF)) {
                    g_display_manager.mode = EXTERNAL_BAR_OFF;
                    g_display_manager.top_padding = t;
                    g_display_manager.bottom_padding = b;
                    space_manager_mark_spaces_invalid(&g_space_manager);
                } else {
                    daemon_fail(rsp, "unknown mode '%s' specified in value '%.*s' given to command '%.*s' for domain '%.*s'\n", mode, value.length, value.text, command.length, command.text, domain.length, domain.text);
                }
            } else {
                fprintf(rsp, "%s:%d:%d\n", external_bar_mode_str[g_display_manager.mode], g_display_manager.top_padding, g_display_manager.bottom_padding);
            }
        } else {
            daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
        }
    }
}

static void handle_domain_display(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    uint32_t acting_did = display_manager_active_display_id();
    struct selector selector = parse_display_selector(NULL, &message, acting_did, true);

    if (selector.did_parse) {
        acting_did = selector.did;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    if (!acting_did) {
        daemon_fail(rsp, "could not locate the display to act on!\n");
        return;
    }

    if (token_equals(command, COMMAND_DISPLAY_FOCUS)) {
        struct selector selector = parse_display_selector(rsp, &message, acting_did, false);
        if (selector.did_parse && selector.did) {
            if (acting_did != selector.did) {
                // Keyboard-driven display focus: `smart`
                // space_focus_target_display should follow this display on
                // the next defaulted space --focus.
                g_window_manager.last_focus_method = FOCUS_METHOD_KEYBOARD;
                display_manager_focus_display(selector.did, display_space_id(selector.did));
            } else {
                daemon_fail(rsp, "cannot focus an already focused display.\n");
            }
        }
    } else if (token_equals(command, COMMAND_DISPLAY_SPACE)) {
        struct selector selector = parse_space_selector(rsp, &message, display_space_id(acting_did), false);
        if (selector.did_parse && selector.sid) {
            enum space_op_error result = display_manager_focus_space(acting_did, selector.sid);
            if (result == SPACE_OP_ERROR_SAME_DISPLAY) {
                daemon_fail(rsp, "acting display does not contain the given space.\n");
            } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                daemon_fail(rsp, "cannot focus space because the display is in the middle of an animation.\n");
            } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                daemon_fail(rsp, "cannot focus space because mission-control is active.\n");
            } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                daemon_fail(rsp, "cannot focus space due to an error with the scripting-addition.\n");
            }
        }
    } else if (token_equals(command, COMMAND_DISPLAY_LABEL)) {
        char *label;
        if (parse_label(rsp, get_token(&message), LABEL_DISPLAY, &label)) {
            if (label) {
                display_manager_set_label_for_display(&g_display_manager, acting_did, label);
            } else {
                if (!display_manager_remove_label_for_display(&g_display_manager, acting_did)) {
                    daemon_fail(rsp, "the selected display was not associated with a label!\n");
                }
            }
        }
    } else {
        daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
    }
}

static void handle_domain_space(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    uint64_t acting_sid = space_manager_active_space();
    struct selector selector = parse_space_selector(NULL, &message, acting_sid, true);
    // Whether the acting space was given as an explicit selector (e.g.
    // `space 3 --focus next`). When it wasn't, a defaulted prev/next routes
    // through the space_focus_target_display gate.
    bool acting_explicit = selector.did_parse;

    if (selector.did_parse) {
        acting_sid = selector.sid;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    if (!acting_sid) {
        daemon_fail(rsp, "could not locate the space to act on!\n");
        return;
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (token_equals(command, COMMAND_SPACE_FOCUS)) {
            // Relative prev/next routes through the edge-guard-aware path so a
            // hop that would leave this display nudges (contain_space_focus_per_display
            // on) instead of silently crossing to another display. Peek the
            // selector token BEFORE parsing: at an outer extreme (globally
            // first/last space) prev/next resolves to no space at all and the
            // parse would fail before the guard could fire — so route on the
            // token itself and suppress the parse's own "could not locate"
            // failure (NULL rsp); the relative path owns the edge semantics.
            char *peek = message;
            struct token selector_token = get_token(&peek);
            bool relative = token_equals(selector_token, ARGUMENT_COMMON_SEL_NEXT) ||
                            token_equals(selector_token, ARGUMENT_COMMON_SEL_PREV);
            struct selector selector = parse_space_selector(relative ? NULL : rsp, &message, acting_sid, false);
            if (relative) {
                int dir = token_equals(selector_token, ARGUMENT_COMMON_SEL_NEXT) ? +1 : -1;
                uint64_t base_sid = acting_explicit ? acting_sid : space_manager_focus_target_space();
                enum space_op_error result = space_manager_focus_relative_space(base_sid, dir);
                if (result == SPACE_OP_ERROR_MISSING_DST) {
                    daemon_fail(rsp, "could not locate the %s space.\n", dir > 0 ? "next" : "previous");
                } else if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot focus an already focused space.\n");
                } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                    daemon_fail(rsp, "cannot focus space because the display is in the middle of an animation.\n");
                } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                    daemon_fail(rsp, "cannot focus space because mission-control is active.\n");
                } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                    daemon_fail(rsp, "cannot focus space due to an error with the scripting-addition.\n");
                }
            } else if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_focus_space(selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot focus an already focused space.\n");
                } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                    daemon_fail(rsp, "cannot focus space because the display is in the middle of an animation.\n");
                } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                    daemon_fail(rsp, "cannot focus space because mission-control is active.\n");
                } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                    daemon_fail(rsp, "cannot focus space due to an error with the scripting-addition.\n");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_SWITCH)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_switch_space(selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot focus an already focused space.\n");
                } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                    daemon_fail(rsp, "cannot focus space because the display is in the middle of an animation.\n");
                } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                    daemon_fail(rsp, "cannot focus space because mission-control is active.\n");
                } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                    daemon_fail(rsp, "cannot focus space due to an error with the scripting-addition.\n");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_MOVE)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_move_space_to_space(acting_sid, selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot move space to itself.\n");
                } else if (result == SPACE_OP_ERROR_SAME_DISPLAY) {
                    daemon_fail(rsp, "cannot move space across display boundaries. use --display instead.\n");
                } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                    daemon_fail(rsp, "cannot move space because the display is in the middle of an animation.\n");
                } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                    daemon_fail(rsp, "cannot move space because mission-control is active.\n");
                } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                    daemon_fail(rsp, "cannot move space due to an error with the scripting-addition.\n");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_SWAP)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, false);
            if (selector.did_parse && selector.sid) {
                enum space_op_error result = space_manager_swap_space_with_space(acting_sid, selector.sid);
                if (result == SPACE_OP_ERROR_SAME_SPACE) {
                    daemon_fail(rsp, "cannot swap space with itself.\n");
                } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                    daemon_fail(rsp, "cannot swap space because the display is in the middle of an animation.\n");
                } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                    daemon_fail(rsp, "cannot swap space because mission-control is active.\n");
                } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                    daemon_fail(rsp, "cannot swap space due to an error with the scripting-addition.\n");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_DISPLAY)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                enum space_op_error result = space_manager_move_space_to_display(&g_space_manager, acting_sid, selector.did);
                if (result == SPACE_OP_ERROR_MISSING_SRC) {
                    daemon_fail(rsp, "could not locate the space to act on.\n");
                } else if (result == SPACE_OP_ERROR_MISSING_DST) {
                    daemon_fail(rsp, "could not locate the active space of the given display.\n");
                } else if (result == SPACE_OP_ERROR_INVALID_SRC) {
                    daemon_fail(rsp, "acting space is the last user-space on the source display and cannot be moved.\n");
                } else if (result == SPACE_OP_ERROR_INVALID_DST) {
                    daemon_fail(rsp, "acting space is already located on the given display.\n");
                } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                    daemon_fail(rsp, "cannot send space to display because it is in the middle of an animation.\n");
                } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                    daemon_fail(rsp, "cannot send space to display because mission-control is active.\n");
                } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                    daemon_fail(rsp, "cannot send space to display due to an error with the scripting-addition.\n");
                }
            }
        } else if (token_equals(command, COMMAND_SPACE_CREATE)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.did) {
                    acting_sid = display_space_id(selector.did);
                } else {
                    return;
                }
            }

            enum space_op_error result = space_manager_add_space(acting_sid);
            if (result == SPACE_OP_ERROR_MISSING_SRC) {
                daemon_fail(rsp, "could not locate the space to act on.\n");
            } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                daemon_fail(rsp, "cannot create space because the display is in the middle of an animation.\n");
            } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                daemon_fail(rsp, "cannot create space because mission-control is active.\n");
            } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                daemon_fail(rsp, "cannot create space due to an error with the scripting-addition.\n");
            }
        } else if (token_equals(command, COMMAND_SPACE_DESTROY)) {
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.sid) {
                    acting_sid = selector.sid;
                } else {
                    return;
                }
            }

            enum space_op_error result = space_manager_destroy_space(acting_sid);
            if (result == SPACE_OP_ERROR_MISSING_SRC) {
                daemon_fail(rsp, "could not locate the space to act on.\n");
            } else if (result == SPACE_OP_ERROR_INVALID_SRC) {
                daemon_fail(rsp, "acting space is the last user-space on the source display and cannot be destroyed.\n");
            } else if (result == SPACE_OP_ERROR_INVALID_TYPE) {
                daemon_fail(rsp, "cannot destroy a macOS fullscreen space.\n");
            } else if (result == SPACE_OP_ERROR_DISPLAY_IS_ANIMATING) {
                daemon_fail(rsp, "cannot destroy space because the display is in the middle of an animation.\n");
            } else if (result == SPACE_OP_ERROR_IN_MISSION_CONTROL) {
                daemon_fail(rsp, "cannot destroy space because mission-control is active.\n");
            } else if (result == SPACE_OP_ERROR_SCRIPTING_ADDITION) {
                daemon_fail(rsp, "cannot destroy space due to an error with the scripting-addition.\n");
            }
        } else if (token_equals(command, COMMAND_SPACE_EQUALIZE)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                if (!space_manager_equalize_space(&g_space_manager, acting_sid, SPLIT_X | SPLIT_Y)) {
                    daemon_fail(rsp, "cannot equalize a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X)) {
                if (!space_manager_equalize_space(&g_space_manager, acting_sid, SPLIT_X)) {
                    daemon_fail(rsp, "cannot equalize a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                if (!space_manager_equalize_space(&g_space_manager, acting_sid, SPLIT_Y)) {
                    daemon_fail(rsp, "cannot equalize a non-managed space.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_BALANCE)) {
            struct token value = get_token(&message);
            if (!token_is_valid(value)) {
                if (!space_manager_balance_space(&g_space_manager, acting_sid, SPLIT_X | SPLIT_Y)) {
                    daemon_fail(rsp, "cannot balance a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X)) {
                if (!space_manager_balance_space(&g_space_manager, acting_sid, SPLIT_X)) {
                    daemon_fail(rsp, "cannot balance a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                if (!space_manager_balance_space(&g_space_manager, acting_sid, SPLIT_Y)) {
                    daemon_fail(rsp, "cannot balance a non-managed space.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_MIRROR)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_X)) {
                if (!space_manager_mirror_space(&g_space_manager, acting_sid, SPLIT_X)) {
                    daemon_fail(rsp, "cannot mirror a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_COMMON_VAL_AXIS_Y)) {
                if (!space_manager_mirror_space(&g_space_manager, acting_sid, SPLIT_Y)) {
                    daemon_fail(rsp, "cannot mirror a non-managed space.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_ROTATE)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_SPACE_ROTATE_90)) {
                if (!space_manager_rotate_space(&g_space_manager, acting_sid, 90)) {
                    daemon_fail(rsp, "cannot rotate a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_ROTATE_180)) {
                if (!space_manager_rotate_space(&g_space_manager, acting_sid, 180)) {
                    daemon_fail(rsp, "cannot rotate a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_ROTATE_270)) {
                if (!space_manager_rotate_space(&g_space_manager, acting_sid, 270)) {
                    daemon_fail(rsp, "cannot rotate a non-managed space.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_PADDING)) {
            int t, b, l, r;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_SPACE_PADDING, type, &t, &b, &l, &r) == 5)) {
                if (!space_manager_set_padding_for_space(&g_space_manager, acting_sid, parse_value_type(type), t, b, l, r)) {
                    daemon_fail(rsp, "cannot set padding for a non-managed space.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_GAP)) {
            int gap;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_SPACE_GAP, type, &gap) == 2)) {
                if (!space_manager_set_gap_for_space(&g_space_manager, acting_sid, parse_value_type(type), gap)) {
                    daemon_fail(rsp, "cannot set gap for a non-managed space.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_TOGGLE)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_SPACE_TGL_PADDING)) {
                if (!space_manager_toggle_padding_for_space(&g_space_manager, acting_sid)) {
                    daemon_fail(rsp, "cannot toggle padding for a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_GAP)) {
                if (!space_manager_toggle_gap_for_space(&g_space_manager, acting_sid)) {
                    daemon_fail(rsp, "cannot toggle gap for a non-managed space.\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_MC)) {
                space_manager_toggle_mission_control(acting_sid, g_space_manager.mission_control_always_show_spaces_strip_enabled);
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_MC_SHOW_STRIP)) {
                space_manager_toggle_mission_control(acting_sid, true);
            } else if (token_equals(value, ARGUMENT_SPACE_TGL_SD)) {
                space_manager_toggle_show_desktop(acting_sid);
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_LAYOUT)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_SPACE_LAYOUT_BSP)) {
                if (space_is_user(acting_sid)) {
                    space_manager_set_layout_for_space(&g_space_manager, acting_sid, VIEW_BSP);
                } else {
                    daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_LAYOUT_STACK)) {
                if (space_is_user(acting_sid)) {
                    space_manager_set_layout_for_space(&g_space_manager, acting_sid, VIEW_STACK);
                } else {
                    daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                }
            } else if (token_equals(value, ARGUMENT_SPACE_LAYOUT_FLT)) {
                if (space_is_user(acting_sid)) {
                    space_manager_set_layout_for_space(&g_space_manager, acting_sid, VIEW_FLOAT);
                } else {
                    daemon_fail(rsp, "cannot set layout for a macOS fullscreen space!\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_SPACE_LABEL)) {
            char *label;
            if (parse_label(rsp, get_token(&message), LABEL_SPACE, &label)) {
                if (label) {
                    space_manager_set_label_for_space(&g_space_manager, acting_sid, label);
                } else {
                    if (!space_manager_remove_label_for_space(&g_space_manager, acting_sid)) {
                        daemon_fail(rsp, "the selected space was not associated with a label!\n");
                    }
                }
            }
        } else {
            daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
        }
    }
}

static void handle_domain_window(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command;
    struct window *acting_window = window_manager_focused_window(&g_window_manager);
    struct selector selector = parse_window_selector(NULL, &message, acting_window, true);

    if (selector.did_parse) {
        acting_window = selector.window;
        command = get_token(&message);
    } else {
        command = selector.token;
    }

    for (; token_is_valid(command); command = get_token(&message)) {
        if (!acting_window &&
            !token_equals(command, COMMAND_WINDOW_FOCUS) &&
            !token_equals(command, COMMAND_WINDOW_CLOSE) &&
            !token_equals(command, COMMAND_WINDOW_MINIMIZE) &&
            !token_equals(command, COMMAND_WINDOW_DEMINIMIZE) &&
            !token_equals(command, COMMAND_WINDOW_TOGGLE)) {
            daemon_fail(rsp, "could not locate the window to act on!\n");
            return;
        }

        if (token_equals(command, COMMAND_WINDOW_FOCUS)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    acting_window = selector.window;
                } else {
                    return;
                }
            }

            if (acting_window) {
                // Keyboard-driven focus: `smart` space_focus_target_display
                // should follow the active window's display on the next defaulted
                // space --focus.
                g_window_manager.last_focus_method = FOCUS_METHOD_KEYBOARD;
                window_manager_focus_window_with_raise(&acting_window->application->psn, acting_window->id, acting_window->ref);
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_CLOSE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    acting_window = selector.window;
                } else {
                    return;
                }
            }

            if (acting_window) {
                if (!window_manager_close_window(acting_window)) {
                    daemon_fail(rsp, "could not close window with id '%d'.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_MINIMIZE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    acting_window = selector.window;
                } else {
                    return;
                }
            }

            if (acting_window) {
                enum window_op_error result = window_manager_minimize_window(acting_window);
                if (result == WINDOW_OP_ERROR_CANT_MINIMIZE) {
                    daemon_fail(rsp, "window with id '%d' does not support the minimize operation.\n", acting_window->id);
                } else if (result == WINDOW_OP_ERROR_ALREADY_MINIMIZED) {
                    daemon_fail(rsp, "window with id '%d' is already minimized.\n", acting_window->id);
                } else if (result == WINDOW_OP_ERROR_MINIMIZE_FAILED) {
                    daemon_fail(rsp, "could not minimize window with id '%d'.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "could not locate the window to act on!\n");
            }
        } else if (token_equals(command, COMMAND_WINDOW_DEMINIMIZE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_deminimize_window(selector.window);
                if (result == WINDOW_OP_ERROR_NOT_MINIMIZED) {
                    daemon_fail(rsp, "window with id '%d' is not minimized.\n", selector.window->id);
                } else if (result == WINDOW_OP_ERROR_DEMINIMIZE_FAILED) {
                    daemon_fail(rsp, "could not deminimize window with id '%d'.\n", selector.window->id);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_DISPLAY)) {
            struct selector selector = parse_display_selector(rsp, &message, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                uint64_t sid = display_space_id(selector.did);
                if (space_is_fullscreen(sid)) {
                    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
                } else {
                    window_manager_send_window_to_display(&g_space_manager, &g_window_manager, acting_window, selector.did, sid);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_SPACE)) {
            struct selector selector = parse_space_selector(rsp, &message, space_manager_active_space(), false);
            if (selector.did_parse && selector.sid) {
                if (space_is_fullscreen(selector.sid)) {
                    daemon_fail(rsp, "can not move window to a macOS fullscreen space!\n");
                } else {
                    window_manager_send_window_to_space(&g_space_manager, &g_window_manager, acting_window, selector.sid, false);
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_SWAP)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_swap_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "the acting window is not within a bsp space.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_VIEW) {
                    daemon_fail(rsp, "the selected window is not within a bsp space.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "the acting window is not managed.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_NODE) {
                    daemon_fail(rsp, "the selected window is not managed.\n");
                } else if (result == WINDOW_OP_ERROR_SAME_STACK) {
                    daemon_fail(rsp, "cannot swap a window with a window in the same stack.\n");
                } else if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot swap a window with itself.\n");
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_WARP)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_warp_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "the acting window is not within a bsp space.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_VIEW) {
                    daemon_fail(rsp, "the selected window is not within a bsp space.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "the acting window is not managed.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_NODE) {
                    daemon_fail(rsp, "the selected window is not managed.\n");
                } else if (result == WINDOW_OP_ERROR_SAME_STACK) {
                    daemon_fail(rsp, "cannot warp a window with a window in the same stack.\n");
                } else if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot warp a window onto itself.\n");
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_STACK)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, false);
            if (selector.did_parse && selector.window) {
                enum window_op_error result = window_manager_stack_window(&g_space_manager, &g_window_manager, acting_window, selector.window);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "the acting window is not managed.\n");
                } else if (result == WINDOW_OP_ERROR_MAX_STACK) {
                    daemon_fail(rsp, "cannot stack window, max capacity of %d reached.\n", NODE_MAX_WINDOW_COUNT);
                } else if (result == WINDOW_OP_ERROR_SAME_WINDOW) {
                    daemon_fail(rsp, "cannot stack a window onto itself.\n");
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_INSERT)) {
            struct selector selector = parse_insert_selector(rsp, &message);
            if (selector.did_parse && selector.dir) {
                enum window_op_error result = window_manager_set_window_insertion(&g_space_manager, acting_window, selector.dir);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "the acting window is not within a bsp space.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "the acting window is not managed.\n");
                }
            }
        } else if (token_equals(command, COMMAND_WINDOW_GRID)) {
            unsigned r, c, x, y, w, h;
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_GRID, &r, &c, &x, &y, &w, &h) == 6)) {
                enum window_op_error result = window_manager_apply_grid(&g_space_manager, &g_window_manager, acting_window, r, c, x, y, w, h);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot apply grid layout to a managed window.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_MOVE)) {
            float x, y;
            char type[MAXLEN], sx[MAXLEN], sy[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_MOVE, type, sx, sy) == 3) &&
                parse_move_coord(acting_window, parse_value_type(type), sx, true,  &x) &&
                parse_move_coord(acting_window, parse_value_type(type), sy, false, &y)) {
                enum window_op_error result = window_manager_move_window_relative(&g_window_manager, acting_window, parse_value_type(type), x, y);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot move a managed window.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RESIZE)) {
            float w, h;
            char handle[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_RESIZE, handle, &w, &h) == 3)) {
                enum window_op_error result = window_manager_resize_window_relative(&g_window_manager, acting_window, parse_resize_handle(handle), w, h, true);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "cannot locate bsp node for the managed window.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_DST_NODE) {
                    daemon_fail(rsp, "cannot locate a bsp node fence.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_OPERATION) {
                    daemon_fail(rsp, "cannot use absolute resizing on a managed window.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RATIO)) {
            float r;
            char type[MAXLEN];
            struct token value = get_token(&message);
            if ((sscanf(value.text, ARGUMENT_WINDOW_RATIO, type, &r) == 2)) {
                enum window_op_error result = window_manager_adjust_window_ratio(&g_window_manager, acting_window, parse_value_type(type), r);
                if (result == WINDOW_OP_ERROR_INVALID_SRC_VIEW) {
                    daemon_fail(rsp, "cannot adjust ratio of a non-managed window.\n");
                } else if (result == WINDOW_OP_ERROR_INVALID_SRC_NODE) {
                    daemon_fail(rsp, "cannot adjust ratio of a root node.\n");
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_TOGGLE)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_FLOAT)) {
                if (acting_window) {
                    window_manager_make_window_floating(&g_space_manager, &g_window_manager, acting_window, !window_check_flag(acting_window, WINDOW_FLOAT), false);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_STICKY)) {
                if (acting_window) {
                    window_manager_make_window_sticky(&g_space_manager, &g_window_manager, acting_window, !window_check_flag(acting_window, WINDOW_STICKY));
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_SHADOW)) {
                if (acting_window) {
                    window_manager_toggle_window_shadow(acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_SPLIT)) {
                if (acting_window) {
                    space_manager_toggle_window_split(&g_space_manager, acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_PARENT)) {
                if (acting_window) {
                    window_manager_toggle_window_zoom_parent(&g_window_manager, acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_FULLSC)) {
                if (acting_window) {
                    window_manager_toggle_window_zoom_fullscreen(&g_window_manager, acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_WINDOWED)) {
                if (acting_window) {
                    window_manager_toggle_window_windowed_fullscreen(acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_NATIVE)) {
                if (acting_window) {
                    window_manager_toggle_window_native_fullscreen(acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_EXPOSE)) {
                if (acting_window) {
                    window_manager_toggle_window_expose(acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_TOGGLE_PIP)) {
                if (acting_window) {
                    window_manager_toggle_window_pip(&g_space_manager, acting_window);
                } else {
                    daemon_fail(rsp, "could not locate the window to act on!\n");
                }
            } else if (!window_manager_toggle_scratchpad_window_by_label(&g_window_manager, value.text)) {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_SUB_LAYER)) {
            struct token value = get_token(&message);
            if (token_equals(value, ARGUMENT_WINDOW_LAYER_BELOW)) {
                if (!window_manager_set_window_layer(acting_window, LAYER_BELOW)) {
                    daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYER_NORMAL)) {
                if (!window_manager_set_window_layer(acting_window, LAYER_NORMAL)) {
                    daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYER_ABOVE)) {
                if (!window_manager_set_window_layer(acting_window, LAYER_ABOVE)) {
                    daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else if (token_equals(value, ARGUMENT_WINDOW_LAYER_AUTO)) {
                if (!window_manager_set_window_layer(acting_window, LAYER_AUTO)) {
                    daemon_fail(rsp, "could not change sub-layer of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.length, value.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_OPACITY)) {
            struct token_value value = token_to_value(get_token(&message));
            if (value.type == TOKEN_TYPE_FLOAT && in_range_ii(value.float_value, 0.0f, 1.0f)) {
                if (window_manager_set_opacity(&g_window_manager, acting_window, value.float_value)) {
                    acting_window->opacity = value.float_value;
                } else {
                    daemon_fail(rsp, "could not change opacity of window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
                }
            } else {
                daemon_fail(rsp, "unknown value '%.*s' given to command '%.*s' for domain '%.*s'\n", value.token.length, value.token.text, command.length, command.text, domain.length, domain.text);
            }
        } else if (token_equals(command, COMMAND_WINDOW_RAISE)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);
            uint32_t selector_wid = 0;

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    selector_wid = selector.window->id;
                } else {
                    return;
                }
            }

            if (!scripting_addition_order_window(acting_window->id, 1, selector_wid)) {
                daemon_fail(rsp, "could not raise window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_LOWER)) {
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);
            uint32_t selector_wid = 0;

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    selector_wid = selector.window->id;
                } else {
                    return;
                }
            }

            if (!scripting_addition_order_window(acting_window->id, -1, selector_wid)) {
                daemon_fail(rsp, "could not lower window with id '%d' due to an error with the scripting-addition.\n", acting_window->id);
            }
        } else if (token_equals(command, COMMAND_WINDOW_SCRATCHPAD)) {
            char *label;
            struct token token = get_token(&message);
            if (token_is_valid(token) && token_equals(token, ARGUMENT_WINDOW_SCRATCHPAD_RECOVER)) {
                window_manager_scratchpad_recover_windows();
            } else if (parse_label(rsp, token, LABEL_WINDOW, &label)) {
                if (label) {
                    if (!window_manager_set_scratchpad_for_window(&g_window_manager, acting_window, label)) {
                        daemon_fail(rsp, "the given scratchpad is already assigned to a different window!\n");
                    }
                } else {
                    if (!window_manager_remove_scratchpad_for_window(&g_window_manager, acting_window, true)) {
                        daemon_fail(rsp, "the selected window was not assigned to a scratchpad!\n");
                    }
                }
            }
        } else {
            daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
        }
    }
}

static void handle_domain_query(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_QUERY_DISPLAYS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), display_property_val, display_property_str, array_count(display_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            struct selector selector = parse_display_selector(rsp, &message, acting_did, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.did) {
                    acting_did = selector.did;
                } else {
                    return;
                }
            }

            display_serialize(rsp, acting_did, properties.flags);
            fprintf(rsp, "\n");
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.sid) {
                    acting_sid = selector.sid;
                } else {
                    return;
                }
            }

            display_serialize(rsp, space_display_id(acting_sid), properties.flags);
            fprintf(rsp, "\n");
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_focused_window(&g_window_manager);
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    acting_window = selector.window;
                } else {
                    return;
                }
            }

            if (acting_window) {
                display_serialize(rsp, window_display_id(acting_window->id), properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not find window to retrieve display details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail(rsp, "unknown option '%.*s' given to command '%.*s' for domain '%.*s'\n", option.length, option.text, command.length, command.text, domain.length, domain.text);
        } else {
            display_manager_query_displays(rsp, properties.flags);
        }
    } else if (token_equals(command, COMMAND_QUERY_SPACES)) {
        struct properties properties = parse_properties(rsp, get_token(&message), space_property_val, space_property_str, array_count(space_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            struct selector selector = parse_display_selector(rsp, &message, acting_did, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.did) {
                    acting_did = selector.did;
                } else {
                    return;
                }
            }

            if (!space_manager_query_spaces_for_display(rsp, acting_did, properties.flags)) {
                daemon_fail(rsp, "could not retrieve spaces for display.\n");
            }
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.sid) {
                    acting_sid = selector.sid;
                } else {
                    return;
                }
            }

            if (!space_manager_query_space(rsp, acting_sid, properties.flags)) {
                daemon_fail(rsp, "could not retrieve space details.\n");
            }
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_focused_window(&g_window_manager);
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    acting_window = selector.window;
                } else {
                    return;
                }
            }

            if (acting_window) {
                space_manager_query_spaces_for_window(rsp, acting_window, properties.flags);
            } else {
                daemon_fail(rsp, "could not find window to retrieve space details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail(rsp, "unknown option '%.*s' given to command '%.*s' for domain '%.*s'\n", option.length, option.text, command.length, command.text, domain.length, domain.text);
        } else if (!space_manager_query_spaces_for_displays(rsp, properties.flags)) {
            daemon_fail(rsp, "could not retrieve spaces for displays.\n");
        }
    } else if (token_equals(command, COMMAND_QUERY_WINDOWS)) {
        struct properties properties = parse_properties(rsp, get_token(&message), window_property_val, window_property_str, array_count(window_property_str));
        if (properties.did_error) return;

        struct token option = properties.did_parse ? get_token(&message) : properties.token;
        if (token_equals(option, ARGUMENT_QUERY_DISPLAY)) {
            uint32_t acting_did = display_manager_active_display_id();
            struct selector selector = parse_display_selector(rsp, &message, acting_did, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.did) {
                    acting_did = selector.did;
                } else {
                    return;
                }
            }

            window_manager_query_windows_for_display(rsp, acting_did, properties.flags);
        } else if (token_equals(option, ARGUMENT_QUERY_SPACE)) {
            uint64_t acting_sid = space_manager_active_space();
            struct selector selector = parse_space_selector(rsp, &message, acting_sid, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.sid) {
                    acting_sid = selector.sid;
                } else {
                    return;
                }
            }

            window_manager_query_windows_for_spaces(rsp, &acting_sid, 1, properties.flags);
        } else if (token_equals(option, ARGUMENT_QUERY_WINDOW)) {
            struct window *acting_window = window_manager_focused_window(&g_window_manager);
            struct selector selector = parse_window_selector(rsp, &message, acting_window, true);

            if (token_is_valid(selector.token)) {
                if (selector.did_parse && selector.window) {
                    acting_window = selector.window;
                } else {
                    return;
                }
            }

            if (acting_window) {
                window_serialize(rsp, acting_window, properties.flags);
                fprintf(rsp, "\n");
            } else {
                daemon_fail(rsp, "could not retrieve window details.\n");
            }
        } else if (token_is_valid(option)) {
            daemon_fail(rsp, "unknown option '%.*s' given to command '%.*s' for domain '%.*s'\n", option.length, option.text, command.length, command.text, domain.length, domain.text);
        } else {
            window_manager_query_windows_for_displays(rsp, properties.flags);
        }
    } else {
        daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
    }
}

static bool parse_rule(FILE *rsp, char **message, struct rule *rule, struct token token)
{
    TIME_FUNCTION;

    char *unsupported_exclusion = NULL;
    bool did_parse = true;
    bool has_filter = false;

    for (; token_is_valid(token); token = get_token(message)) {
        char *key = NULL;
        char *value = NULL;
        bool exclusion = false;
        parse_key_value_pair(token.text, &key, &value, &exclusion);

        if (!key || !value) {
            daemon_fail(rsp, "invalid key-value pair '%s'\n", token.text);
            did_parse = false;
            continue;
        }

        if (string_equals(key, ARGUMENT_RULE_KEY_LABEL)) {
            if (exclusion) unsupported_exclusion = key;
            rule->label = string_copy(value);
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SCRATCHPAD)) {
            if (exclusion) unsupported_exclusion = key;

            bool valid = true;
            for (int i = 0; i < array_count(reserved_window_identifiers); ++i) {
                if (string_equals(value, reserved_window_identifiers[i])) {
                    valid = false;
                    break;
                }
            }

            if (valid) {
                rule->effects.scratchpad = string_copy(value);
                rule->effects.manage = RULE_PROP_OFF;
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_APP)) {
            has_filter = true;
            rule->app = string_copy(value);
            if (exclusion) rule_set_flag(rule, RULE_APP_EXCLUDE);
            if (regcomp(&rule->app_regex, value, REG_EXTENDED) == 0) {
                rule_set_flag(rule, RULE_APP_VALID);
            } else {
                daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_TITLE)) {
            has_filter = true;
            rule->title = string_copy(value);
            if (exclusion) rule_set_flag(rule, RULE_TITLE_EXCLUDE);
            if (regcomp(&rule->title_regex, value, REG_EXTENDED) == 0) {
                rule_set_flag(rule, RULE_TITLE_VALID);
            } else {
                daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_ROLE)) {
            has_filter = true;
            rule->role = string_copy(value);
            if (exclusion) rule_set_flag(rule, RULE_ROLE_EXCLUDE);
            if (regcomp(&rule->role_regex, value, REG_EXTENDED) == 0) {
                rule_set_flag(rule, RULE_ROLE_VALID);
            } else {
                daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SUBROLE)) {
            has_filter = true;
            rule->subrole = string_copy(value);
            if (exclusion) rule_set_flag(rule, RULE_SUBROLE_EXCLUDE);
            if (regcomp(&rule->subrole_regex, value, REG_EXTENDED) == 0) {
                rule_set_flag(rule, RULE_SUBROLE_VALID);
            } else {
                daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_DISPLAY)) {
            if (exclusion) unsupported_exclusion = key;

            if (value[0] == ARGUMENT_RULE_VALUE_SPACE) {
                ++value;
                rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
            }

            struct selector selector = parse_display_selector(rsp, &value, display_manager_active_display_id(), false);
            if (selector.did_parse && selector.did) {
                rule->effects.did = selector.did;
            } else {
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SPACE)) {
            if (exclusion) unsupported_exclusion = key;

            if (value[0] == ARGUMENT_RULE_VALUE_SPACE) {
                ++value;
                rule_effects_set_flag(&rule->effects, RULE_FOLLOW_SPACE);
            }

            struct selector selector = parse_space_selector(rsp, &value, space_manager_active_space(), false);
            if (selector.did_parse && selector.sid) {
                rule->effects.sid = selector.sid;
            } else {
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_GRID)) {
            if (exclusion) unsupported_exclusion = key;

            if ((sscanf(value, ARGUMENT_RULE_VALUE_GRID,
                        &rule->effects.grid[0], &rule->effects.grid[1],
                        &rule->effects.grid[2], &rule->effects.grid[3],
                        &rule->effects.grid[4], &rule->effects.grid[5]) != 6)) {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_OPACITY)) {
            if (exclusion) unsupported_exclusion = key;

            if ((sscanf(value, "%f", &rule->effects.opacity) == 1) && (in_range_ii(rule->effects.opacity, 0.0f, 1.0f))) {
                rule_effects_set_flag(&rule->effects, RULE_OPACITY);
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_MANAGE)) {
            if (exclusion) unsupported_exclusion = key;

            if (string_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                rule->effects.manage = RULE_PROP_ON;
            } else if (string_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                rule->effects.manage = RULE_PROP_OFF;
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_STICKY)) {
            if (exclusion) unsupported_exclusion = key;

            if (string_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                rule->effects.sticky = RULE_PROP_ON;
            } else if (string_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                rule->effects.sticky = RULE_PROP_OFF;
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_MFF)) {
            if (exclusion) unsupported_exclusion = key;

            if (string_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                rule->effects.mff = RULE_PROP_ON;
            } else if (string_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                rule->effects.mff = RULE_PROP_OFF;
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_SUB_LAYER)) {
            if (exclusion) unsupported_exclusion = key;

            if (string_equals(value, ARGUMENT_WINDOW_LAYER_BELOW)) {
                rule->effects.layer = LAYER_BELOW;
                rule_effects_set_flag(&rule->effects, RULE_LAYER);
            } else if (string_equals(value, ARGUMENT_WINDOW_LAYER_NORMAL)) {
                rule->effects.layer = LAYER_NORMAL;
                rule_effects_set_flag(&rule->effects, RULE_LAYER);
            } else if (string_equals(value, ARGUMENT_WINDOW_LAYER_ABOVE)) {
                rule->effects.layer = LAYER_ABOVE;
                rule_effects_set_flag(&rule->effects, RULE_LAYER);
            } else if (string_equals(value, ARGUMENT_WINDOW_LAYER_AUTO)) {
                rule->effects.layer = LAYER_AUTO;
                rule_effects_set_flag(&rule->effects, RULE_LAYER);
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else if (string_equals(key, ARGUMENT_RULE_KEY_FULLSCR)) {
            if (exclusion) unsupported_exclusion = key;

            if (string_equals(value, ARGUMENT_COMMON_VAL_ON)) {
                rule->effects.fullscreen = RULE_PROP_ON;
            } else if (string_equals(value, ARGUMENT_COMMON_VAL_OFF)) {
                rule->effects.fullscreen = RULE_PROP_OFF;
            } else {
                daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                did_parse = false;
            }
        } else {
            daemon_fail(rsp, "unknown key '%s'\n", key);
            did_parse = false;
        }
    }

    if (!has_filter) {
        daemon_fail(rsp, "missing required key-value pair 'app[!]=..' or 'title[!]=..'\n");
        did_parse = false;
    }

    if (unsupported_exclusion) {
        daemon_fail(rsp, "unsupported token '!' (exclusion) given for key '%s'\n", unsupported_exclusion);
        did_parse = false;
    }

    return did_parse;
}

static void handle_domain_rule(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_RULE_ADD)) {
        struct rule rule = {0};

        struct token token = get_token(&message);
        if (token_equals(token, ARGUMENT_RULE_ONE_SHOT)) {
            rule_set_flag(&rule, RULE_ONE_SHOT);
            token = get_token(&message);
        }

        if (parse_rule(rsp, &message, &rule, token)) {
            rule_add(&rule);
        } else {
            rule_destroy(&rule);
        }
    } else if (token_equals(command, COMMAND_RULE_APPLY)) {
        struct token_value value = token_to_value(get_token(&message));
        if (value.type == TOKEN_TYPE_INT) {
            if (!rule_reapply_by_index(value.int_value)) {
                daemon_fail(rsp, "rule with index '%d' not found.\n", value.int_value);
            }
        } else if (value.type == TOKEN_TYPE_STRING) {
            if (!rule_reapply_by_label(value.string_value)) {
                struct rule rule = {0};
                if (parse_rule(rsp, &message, &rule, value.token)) {
                    rule_apply(&rule);
                }
                rule_destroy(&rule);
            }
        } else if (value.type == TOKEN_TYPE_INVALID) {
            rule_reapply_all();
        } else {
            daemon_fail(rsp, "value '%.*s' is not a valid option for RULE_SEL\n", value.token.length, value.token.text);
        }
    } else if (token_equals(command, COMMAND_RULE_REM)) {
        struct token_value value = token_to_value(get_token(&message));
        if (value.type == TOKEN_TYPE_INT) {
            if (!rule_remove_by_index(value.int_value)) {
                daemon_fail(rsp, "rule with index '%d' not found.\n", value.int_value);
            }
        } else if (value.type == TOKEN_TYPE_STRING) {
            if (!rule_remove_by_label(value.string_value)) {
                daemon_fail(rsp, "rule with label '%s' not found.\n", value.string_value);
            }
        } else {
            daemon_fail(rsp, "value '%.*s' is not a valid option for RULE_SEL\n", value.token.length, value.token.text);
        }
    } else if (token_equals(command, COMMAND_RULE_LS)) {
        window_manager_query_window_rules(rsp);
    } else {
        daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
    }
}

static void handle_domain_signal(FILE *rsp, struct token domain, char *message)
{
    TIME_FUNCTION;

    struct token command = get_token(&message);
    if (token_equals(command, COMMAND_SIGNAL_ADD)) {
        char *unsupported_exclusion = NULL;
        bool did_parse = true;
        bool has_command = false;
        bool has_signal_type = false;
        enum signal_type signal_type = SIGNAL_TYPE_UNKNOWN;
        struct signal signal = {0};

        for (struct token token = get_token(&message); token_is_valid(token); token = get_token(&message)) {
            char *key = NULL;
            char *value = NULL;
            bool exclusion = false;
            parse_key_value_pair(token.text, &key, &value, &exclusion);

            if (!key || !value) {
                daemon_fail(rsp, "invalid key-value pair '%s'\n", token.text);
                did_parse = false;
                continue;
            }

            if (string_equals(key, ARGUMENT_SIGNAL_KEY_LABEL)) {
                if (exclusion) unsupported_exclusion = key;
                signal.label = string_copy(value);
            } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_APP)) {
                signal.app = string_copy(value);
                signal.app_regex_exclude = exclusion;
                signal.app_regex_valid = regcomp(&signal.app_regex, value, REG_EXTENDED) == 0;
                if (!signal.app_regex_valid) {
                    daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
                    did_parse = false;
                }
            } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_TITLE)) {
                signal.title = string_copy(value);
                signal.title_regex_exclude = exclusion;
                signal.title_regex_valid = regcomp(&signal.title_regex, value, REG_EXTENDED) == 0;
                if (!signal.title_regex_valid) {
                    daemon_fail(rsp, "invalid regex pattern '%s' for key '%s'\n", value, key);
                    did_parse = false;
                }
            } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_ACTIVE)) {
                if (exclusion) unsupported_exclusion = key;

                if (string_equals(value, ARGUMENT_SIGNAL_VALUE_YES)) {
                    signal.active = SIGNAL_PROP_YES;
                } else if (string_equals(value, ARGUMENT_SIGNAL_VALUE_NO)) {
                    signal.active = SIGNAL_PROP_NO;
                } else {
                    daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                    did_parse = false;
                }
            } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_ACTION)) {
                if (exclusion) unsupported_exclusion = key;

                has_command = true;
                signal.command = string_copy(value);
            } else if (string_equals(key, ARGUMENT_SIGNAL_KEY_EVENT)) {
                if (exclusion) unsupported_exclusion = key;

                has_signal_type = true;
                signal_type = signal_type_from_string(value);
                if (signal_type == SIGNAL_TYPE_UNKNOWN) {
                    daemon_fail(rsp, "invalid value '%s' for key '%s'\n", value, key);
                    did_parse = false;
                }
            } else {
                daemon_fail(rsp, "unknown key '%s'\n", key);
                did_parse = false;
            }
        }

        if (!has_signal_type) {
            daemon_fail(rsp, "missing required key-value pair 'event=..'\n");
            did_parse = false;
        }

        if (!has_command) {
            daemon_fail(rsp, "missing required key-value pair 'action=..'\n");
            did_parse = false;
        }

        if (unsupported_exclusion) {
            daemon_fail(rsp, "unsupported token '!' (exclusion) given for key '%s'\n", unsupported_exclusion);
            did_parse = false;
        }

        if (did_parse) {
            event_signal_add(signal_type, &signal);
        } else {
            event_signal_destroy(&signal);
        }
    } else if (token_equals(command, COMMAND_SIGNAL_REM)) {
        struct token_value value = token_to_value(get_token(&message));
        if (value.type == TOKEN_TYPE_INT) {
            if (!event_signal_remove_by_index(value.int_value)) {
                daemon_fail(rsp, "signal with index '%d' not found.\n", value.int_value);
            }
        } else if (value.type == TOKEN_TYPE_STRING) {
            if (!event_signal_remove(value.string_value)) {
                daemon_fail(rsp, "signal with label '%s' not found.\n", value.string_value);
            }
        } else {
            daemon_fail(rsp, "value '%.*s' is not a valid option for SIGNAL_SEL\n", value.token.length, value.token.text);
        }
    } else if (token_equals(command, COMMAND_SIGNAL_LS)) {
        event_signal_list(rsp);
    } else {
        daemon_fail(rsp, "unknown command '%.*s' for domain '%.*s'\n", command.length, command.text, domain.length, domain.text);
    }
}

static inline const char *capture_arg_value(struct token t, const char *key)
{
    size_t klen = strlen(key);
    if ((size_t)t.length <= klen)         return NULL;
    if (memcmp(t.text, key, klen) != 0)   return NULL;
    if (t.text[klen] != ':')              return NULL;
    return t.text + klen + 1;
}

static void handle_domain_capture(FILE *rsp, struct token domain, char *message)
{
    (void)domain;
    struct token cmd = get_token(&message);

    if (!token_is_valid(cmd) || token_equals(cmd, COMMAND_CAPTURE_HELP)) {
        fprintf(rsp,
            "usage: yabai -m capture <command> [<args>...]\n"
            "\n"
            "commands:\n"
            "  start [<args>...]   begin a screen recording (HEVC .mp4 in ~/Movies/yabai-capture)\n"
            "  stop                finalize the active capture session(s)\n"
            "  status              print JSON status of the active capture\n"
            "  stitch [<args>...]  combine per-display .mov files into one side-by-side video\n"
            "  help                print this message\n"
            "\n"
            "start args:\n"
            "  wid:<id>            window to record (0/omitted -> active display, full bounds)\n"
            "  display:<index|all> record a specific display by arrangement index, or every display to one file each\n"
            "  padding:<pts>       expand around the wid bounds on all sides, in points\n"
            "  duration:<secs>     auto-stop after N seconds (0/omitted -> until `capture stop`)\n"
            "  fps:<n>             frame rate (default 120)\n"
            "  scale:<f>           multiplier on captured pixel dimensions (default 0.25)\n"
            "  bpp:<f>             HEVC bits-per-pixel-per-frame target (default 0.6)\n"
            "  cursor:<on|off>     include the mouse cursor (default off)\n"
            "  name:<str>          filename suffix, appended after _<timestamp>\n"
            "  format:<mp4|mov>    output container (default mp4; HEVC either way)\n"
            "  if-exists:<overwrite|fail|rename>  output-file collision policy (default rename)\n"
            "\n"
            "stitch args:\n"
            "  group:<name>        glob the per-display files written under that capture group\n"
            "  <file.mov>...       explicit input paths (alternative to group:)\n"
            "  out:<path>          output path (default ~/Movies/<group>/<group>_stitched.mov)\n"
            "  layout:<sidebyside|faithful>  panel arrangement (default sidebyside)\n"
            "  border:<px>         black matte inset on every side (default 0)\n"
            "  gap:<px>            black gap between panels (default = border)\n"
            "  match:<height|none> scale panels to a common height (default height; none disables)\n"
            "  cleanup:<on|off>    delete source files after a successful export (default off)\n"
            "  format:<mp4|mov>    output container (default mp4; HEVC either way)\n"
            "  if-exists:<overwrite|fail|rename>  output-file collision policy (default rename)\n"
            "\n"
            "examples:\n"
            "  # record the active display until `capture stop`\n"
            "  yabai -m capture start\n"
            "\n"
            "  # record the focused window for 10s, full resolution, with the cursor\n"
            "  yabai -m capture start wid:$(yabai -m query --windows --window | jq .id) \\\n"
            "      duration:10 scale:1.0 cursor:on name:demo\n"
            "\n"
            "  # record every display to its own file, grouped for a later stitch\n"
            "  yabai -m capture start display:all name:multimon\n"
            "  yabai -m capture stop\n"
            "\n"
            "  # stitch that group into one faithful-layout video, then delete the parts\n"
            "  yabai -m capture stitch group:multimon layout:faithful gap:8 cleanup:on\n"
            "\n"
            "  # stitch explicit files, overwriting any existing output\n"
            "  yabai -m capture stitch left.mov right.mov out:~/Movies/combined.mov if-exists:overwrite\n");
        return;
    }

    if (token_equals(cmd, COMMAND_CAPTURE_START)) {
        struct capture_options o = {0};
        struct token t;
        while (token_is_valid(t = get_token(&message))) {
            const char *v;
            if      ((v = capture_arg_value(t, "wid")))      o.wid      = (uint32_t)strtoul(v, NULL, 10);
            else if ((v = capture_arg_value(t, "padding")))  o.padding  = (int)strtol(v, NULL, 10);
            else if ((v = capture_arg_value(t, "duration"))) o.duration = (int)strtol(v, NULL, 10);
            else if ((v = capture_arg_value(t, "fps")))      o.fps      = (int)strtol(v, NULL, 10);
            else if ((v = capture_arg_value(t, "scale")))    o.scale    = strtof(v, NULL);
            else if ((v = capture_arg_value(t, "bpp")))      o.bpp      = strtof(v, NULL);
            else if ((v = capture_arg_value(t, "name")))     o.name     = (char *)v;
            else if ((v = capture_arg_value(t, "display"))) {
                if (strcmp(v, "all") == 0) o.all_displays = true;
                else {
                    uint32_t did = display_manager_arrangement_display_id((int)strtol(v, NULL, 10));
                    if (!did) { daemon_fail(rsp, "capture start: no display at arrangement index '%s'\n", v); return; }
                    o.display = did;
                }
            }
            else if ((v = capture_arg_value(t, "if-exists"))) {
                if      (strcmp(v, "overwrite") == 0) o.if_exists = CAPTURE_IF_EXISTS_OVERWRITE;
                else if (strcmp(v, "fail")      == 0) o.if_exists = CAPTURE_IF_EXISTS_FAIL;
                else if (strcmp(v, "rename")    == 0) o.if_exists = CAPTURE_IF_EXISTS_RENAME;
                else { daemon_fail(rsp, "capture start: bad if-exists '%s' (overwrite|fail|rename)\n", v); return; }
            }
            else if ((v = capture_arg_value(t, "cursor")))
                o.cursor = (strcmp(v, "on") == 0 || strcmp(v, "true") == 0 || strcmp(v, "1") == 0);
            else if ((v = capture_arg_value(t, "format"))) {
                if      (strcmp(v, "mp4") == 0) o.container = CAPTURE_CONTAINER_MP4;
                else if (strcmp(v, "mov") == 0) o.container = CAPTURE_CONTAINER_MOV;
                else { daemon_fail(rsp, "capture start: bad format '%s' (mp4|mov)\n", v); return; }
            }
            else {
                daemon_fail(rsp, "capture start: unknown arg '%.*s'\n", t.length, t.text);
                return;
            }
        }
        char err[512] = {0};
        if (!capture_start(&o, err, sizeof err)) { daemon_fail(rsp, "%s\n", err); return; }
        fprintf(rsp, "ok\n");
    } else if (token_equals(cmd, COMMAND_CAPTURE_STOP)) {
        char err[256] = {0};
        if (!capture_stop(err, sizeof err)) { daemon_fail(rsp, "%s\n", err); return; }
        fprintf(rsp, "ok\n");
    } else if (token_equals(cmd, COMMAND_CAPTURE_STATUS)) {
        char out[4096];
        capture_status(out, sizeof out);
        fprintf(rsp, "%s\n", out);
    } else if (token_equals(cmd, COMMAND_CAPTURE_STITCH)) {
        struct capture_stitch_options o = { .match_height = true };
        char  *files[16];
        int    file_count = 0;
        struct token t;
        while (token_is_valid(t = get_token(&message))) {
            const char *v;
            if      ((v = capture_arg_value(t, "group")))  o.group  = (char *)v;
            else if ((v = capture_arg_value(t, "out")))    o.out    = (char *)v;
            else if ((v = capture_arg_value(t, "border"))) o.border = (int)strtol(v, NULL, 10);
            else if ((v = capture_arg_value(t, "gap")))    o.gap    = (int)strtol(v, NULL, 10);
            else if ((v = capture_arg_value(t, "layout")))
                o.layout = (strcmp(v, "faithful") == 0) ? CAPTURE_STITCH_FAITHFUL : CAPTURE_STITCH_SIDEBYSIDE;
            else if ((v = capture_arg_value(t, "match")))
                o.match_height = (strcmp(v, "none") != 0);
            else if ((v = capture_arg_value(t, "cleanup")))
                o.cleanup = (strcmp(v, "on") == 0 || strcmp(v, "true") == 0 || strcmp(v, "1") == 0);
            else if ((v = capture_arg_value(t, "if-exists"))) {
                if      (strcmp(v, "overwrite") == 0) o.if_exists = CAPTURE_IF_EXISTS_OVERWRITE;
                else if (strcmp(v, "fail")      == 0) o.if_exists = CAPTURE_IF_EXISTS_FAIL;
                else if (strcmp(v, "rename")    == 0) o.if_exists = CAPTURE_IF_EXISTS_RENAME;
                else { daemon_fail(rsp, "capture stitch: bad if-exists '%s' (overwrite|fail|rename)\n", v); return; }
            }
            else if ((v = capture_arg_value(t, "format"))) {
                if      (strcmp(v, "mp4") == 0) o.container = CAPTURE_CONTAINER_MP4;
                else if (strcmp(v, "mov") == 0) o.container = CAPTURE_CONTAINER_MOV;
                else { daemon_fail(rsp, "capture stitch: bad format '%s' (mp4|mov)\n", v); return; }
            }
            else if (file_count < 16) {
                // bare token -> an explicit input .mov path (token text is
                // null-terminated in place, so it is usable as a C string).
                files[file_count++] = t.text;
            } else {
                daemon_fail(rsp, "capture stitch: too many file arguments\n");
                return;
            }
        }
        if (file_count > 0) { o.files = files; o.file_count = file_count; }
        char err[512] = {0};
        if (!capture_stitch(&o, err, sizeof err)) { daemon_fail(rsp, "%s\n", err); return; }
        fprintf(rsp, "ok\n");
    } else {
        daemon_fail(rsp, "capture: unknown command '%.*s' (try `yabai -m capture help`)\n", cmd.length, cmd.text);
    }
}

void handle_message(FILE *rsp, char *message)
{
    struct token domain = get_token(&message);
    if (token_equals(domain, DOMAIN_CONFIG)) {
        handle_domain_config(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_DISPLAY)) {
        handle_domain_display(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_SPACE)) {
        handle_domain_space(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_WINDOW)) {
        handle_domain_window(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_QUERY)) {
        handle_domain_query(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_RULE)) {
        handle_domain_rule(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_SIGNAL)) {
        handle_domain_signal(rsp, domain, message);
    } else if (token_equals(domain, DOMAIN_CAPTURE)) {
        handle_domain_capture(rsp, domain, message);
    } else {
        daemon_fail(rsp, "unknown domain '%.*s'\n", domain.length, domain.text);
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"
static void *message_loop_run(void *context)
{
    while (g_message_loop.is_running) {
        int sockfd = accept(g_message_loop.sockfd, NULL, 0);
        if (sockfd == -1) continue;

        event_loop_post(&g_event_loop, DAEMON_MESSAGE, NULL, sockfd);
    }

    return NULL;
}
#pragma clang diagnostic pop

bool message_loop_begin(char *socket_path)
{
    struct sockaddr_un socket_address;
    socket_address.sun_family = AF_UNIX;
    snprintf(socket_address.sun_path, sizeof(socket_address.sun_path), "%s", socket_path);
    unlink(socket_path);

    if ((g_message_loop.sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        return false;
    }

    if (bind(g_message_loop.sockfd, (struct sockaddr *) &socket_address, sizeof(socket_address)) == -1) {
        return false;
    }

    if (chmod(socket_path, 0600) != 0) {
        return false;
    }

    if (listen(g_message_loop.sockfd, SOMAXCONN) == -1) {
        return false;
    }

    fcntl(g_message_loop.sockfd, F_SETFD, FD_CLOEXEC | fcntl(g_message_loop.sockfd, F_GETFD));

    g_message_loop.is_running = true;
    pthread_create(&g_message_loop.thread, NULL, &message_loop_run, NULL);

    return true;
}
