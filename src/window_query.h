#ifndef WINDOW_QUERY_H
#define WINDOW_QUERY_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

// NOTE: subset of the SLS window tag bits. Minimized windows stay bound to their space
// server-side — without the exclude mask "topmost on space" returns a Dock resident.
#define WQ_TAG_NORMAL     (1ULL << 0)    // standard app window
#define WQ_TAG_STICKY     (1ULL << 11)   // on-all-spaces
#define WQ_TAG_HIDDEN     (1ULL << 39)   // owning app is hidden
#define WQ_TAG_MINIMIZED  (1ULL << 60)   // miniaturized to the Dock

struct window_query_filter {
    int owner;                 // cid; 0 = any owner
    const uint64_t *spaces;    // explicit space ids; NULL/0 => scope by space_list_options
    int space_count;
    int space_list_options;    // 0x7 = all space types, 0 = every wid SLS tracks
    int window_list_options;   // 0x2 = visible/standard, 0x7 = incl. minimized/extended
    int query_flags;           // bit0 titles, bit1 attached, bit2 per-window space list
    uint64_t include_tags;     // 1 = normal windows; 0 = all
    uint64_t exclude_tags;     // 0 = none
};

// NOTE: returns the z-ordered window iterator (caller CFReleases), or NULL when the key
// slots fail to resolve / the query fails.
CFTypeRef window_query_run(int cid, const struct window_query_filter *filter);

// z-order row[0] wid of the filter; 0 if nothing matches.
uint32_t window_query_topmost_wid(int cid, const struct window_query_filter *filter);

#endif
