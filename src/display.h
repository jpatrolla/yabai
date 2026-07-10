#ifndef DISPLAY_H
#define DISPLAY_H

#define DISPLAY_EVENT_HANDLER(name) void name(uint32_t did, CGDisplayChangeSummaryFlags flags, void *context)
typedef DISPLAY_EVENT_HANDLER(display_callback);

#define DISPLAY_PROPERTY_LIST \
    DISPLAY_PROPERTY_ENTRY("id",        DISPLAY_PROPERTY_ID,        0x01) \
    DISPLAY_PROPERTY_ENTRY("uuid",      DISPLAY_PROPERTY_UUID,      0x02) \
    DISPLAY_PROPERTY_ENTRY("index",     DISPLAY_PROPERTY_INDEX,     0x04) \
    DISPLAY_PROPERTY_ENTRY("label",     DISPLAY_PROPERTY_LABEL,     0x08) \
    DISPLAY_PROPERTY_ENTRY("frame",     DISPLAY_PROPERTY_FRAME,     0x10) \
    DISPLAY_PROPERTY_ENTRY("spaces",    DISPLAY_PROPERTY_SPACES,    0x20) \
    DISPLAY_PROPERTY_ENTRY("has-focus", DISPLAY_PROPERTY_HAS_FOCUS, 0x40)

enum display_property
{
#define DISPLAY_PROPERTY_ENTRY(n, p, v) p = v,
    DISPLAY_PROPERTY_LIST
#undef DISPLAY_PROPERTY_ENTRY
};

static uint64_t display_property_val[] =
{
#define DISPLAY_PROPERTY_ENTRY(n, p, v) p,
    DISPLAY_PROPERTY_LIST
#undef DISPLAY_PROPERTY_ENTRY
};

static char *display_property_str[] =
{
#define DISPLAY_PROPERTY_ENTRY(n, p, v) n,
    DISPLAY_PROPERTY_LIST
#undef DISPLAY_PROPERTY_ENTRY
};

void display_serialize(FILE *rsp, uint32_t did, uint64_t flags);
CFStringRef display_uuid(uint32_t did);
uint32_t display_id(CFStringRef uuid);
CGRect display_bounds_constrained(uint32_t did, bool ignore_external_bar);
CGPoint display_center(uint32_t did);
uint64_t display_space_id(uint32_t did);
int display_space_count(uint32_t did);
uint64_t *display_space_list(uint32_t did, int *count);

// Per-display refresh-timing cache (CG-based). The animation engine reads
// display_timing_get(did)->refresh_rate_hz to pace the payload CA pump; it
// falls back to 60Hz when the lookup returns NULL.
#define DISPLAY_TIMING_MAX 16
struct display_timing {
    uint32_t did;
    uint64_t refresh_interval_ns;
    double   refresh_rate_hz;
    bool     is_promotion;
    bool     is_vrr;
    bool     valid;
};
void                   display_timing_table_init(void);
void                   display_timing_table_refresh_if_needed(void);
void                   display_timing_table_refresh_force(void);
struct display_timing *display_timing_get(uint32_t did);
struct display_timing *display_timing_get_all(int *out_count);

// True while SkyLight reports `did` mid-animation (native space switch, Mission
// Control, etc.). The focus ring reads it to defer painting until settle.
bool display_is_animating(uint32_t did);

#endif
