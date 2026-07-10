#ifndef WINDOW_QUERY_H
#define WINDOW_QUERY_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreFoundation/CoreFoundation.h>

// SLS window tag bits used in query filters (subset). A window carrying any of
// the exclude bits is never a focused-window candidate: the server keeps
// minimized windows bound to their original space, so without the exclusion a
// query for "topmost window on this space" happily returns a window that is
// sitting in the Dock.
#define WQ_TAG_NORMAL     (1ULL << 0)    // standard app window
#define WQ_TAG_STICKY     (1ULL << 11)   // on-all-spaces
#define WQ_TAG_HIDDEN     (1ULL << 39)   // owning app is hidden
#define WQ_TAG_MINIMIZED  (1ULL << 60)   // miniaturized to the Dock

// Rich _SLSWindowQuery filter — the by-FILTER arm of the SLS window-query
// subsystem (_SLSWindowQuery{Create,SetValue,Run}). owner/spaces/include+exclude
// tags resolve to a z-ordered window iterator with full per-window data in ONE
// round-trip, vs the Copy+re-query two-RPC path. owner=0 → any owner (wildcard);
// include_tags=1 → normal windows. Key constants are exported CFString* data
// slots resolved via dlsym.
struct window_query_filter {
    int owner;                 // SLS connection id; 0 = any owner (wildcard)
    const uint64_t *spaces;    // explicit space ids; when NULL / space_count<=0,
    int space_count;           //   scope by space_list_options instead (all spaces)
    int space_list_options;    // KeySpaceListOptions, used only when space_count<=0:
                               //   0x7 = all space types, 0 = every wid SLS tracks
    int window_list_options;   // KeyWorkspaceWindowListOptions (the `options` arg of
                               //   SLSCopyWindowsWithOptionsAndTags): 0x2 = visible/
                               //   standard (focus path), 0x7 = incl. minimized/extended
    int query_flags;           // SLSWindowQueryRun flags: bit0=titles, bit1=attached,
                               //   bit2=per-window space list. 0x2 = cheapest (no
                               //   titles/spaces decoded); 0x7 decodes all.
    uint64_t include_tags;     // IncludeTags mask (1 = normal windows; 0 = all tags)
    uint64_t exclude_tags;     // ExcludeTags mask (0 = none)
};

// Build + run the filter on `cid`; returns the z-ordered window iterator
// (caller releases via CFRelease). Iterate with SLSWindowIteratorAdvance +
// getters. The iterator retains its backing result, so the result is released
// internally — only the returned iterator must be released. NULL if the key
// slots can't resolve or the query fails.
CFTypeRef window_query_run(int cid, const struct window_query_filter *filter);

// Convenience: z-order row[0] wid of the filter (the focused-window candidate
// when scoped to the focused space). 0 if nothing matches.
uint32_t window_query_topmost_wid(int cid, const struct window_query_filter *filter);

#endif
