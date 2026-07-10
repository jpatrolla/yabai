#ifndef SPACE_H
#define SPACE_H

uint32_t space_display_id(uint64_t sid);
uint32_t *space_window_list_for_connection(uint64_t *space_list, int space_count, int cid, int *count, bool include_minimized);
uint32_t *space_window_list(uint64_t sid, int *count, bool include_minimized);
bool space_is_user(uint64_t sid);
bool space_is_system(uint64_t sid);
bool space_is_fullscreen(uint64_t sid);
bool space_is_visible(uint64_t sid);
// Rich _SLSWindowQuery topmost (z-order row[0]) on `sid`, tag-filtered, optionally
// owner-scoped (0 = any owner). include_tags=1 = normal windows; the result is the
// focused-window candidate when owner-scoped to the front app's connection.
// Returns 0 if nothing matches.
uint32_t space_query_focused_wid(uint64_t sid, int owner, uint64_t include_tags, uint64_t exclude_tags);

#endif
