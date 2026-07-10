// window_query.c — rich _SLSWindowQuery builder, the by-FILTER arm of the SLS
// window-query subsystem. Sibling of window_iterator.c's by-ID arm
// (SLSWindowQueryWindows): instead of shipping an explicit wid list to the
// server, the filter (owner / spaces / include+exclude tags) is evaluated
// server-side and the matches come back as a z-ordered window iterator in one
// round-trip.

#include <dlfcn.h>

// dlsym a SkyLight exported CFString* key slot (name without leading '_').
// The query-key symbols are const CFStringRef DATA globals, so dlsym returns
// the address of the variable — deref once to get the CFStringRef itself.
static CFStringRef wq_resolve_key(const char *name)
{
    void *slot = dlsym(RTLD_DEFAULT, name);
    return slot ? *(CFStringRef *)slot : NULL;
}

CFTypeRef window_query_run(int cid, const struct window_query_filter *filter)
{
    if (!filter) return NULL;

    static CFStringRef kOwner, kSpaces, kSpaceOpts, kWinOpts, kInc, kExc;
    static bool resolved = false;
    if (!resolved) {
        resolved = true;
        kOwner     = wq_resolve_key("SLSWindowQueryKeyOwner");
        kSpaces    = wq_resolve_key("SLSWindowQueryKeySpaces");
        kSpaceOpts = wq_resolve_key("SLSWindowQueryKeySpaceListOptions");
        kWinOpts   = wq_resolve_key("SLSWindowQueryKeyWorkspaceWindowListOptions");
        kInc       = wq_resolve_key("SLSWindowQueryKeyIncludeTags");
        kExc       = wq_resolve_key("SLSWindowQueryKeyExcludeTags");
    }
    if (!kOwner || !kInc || !kExc) return NULL;

    bool use_explicit_spaces = filter->spaces && filter->space_count > 0;
    if (use_explicit_spaces ? !kSpaces : !kSpaceOpts) return NULL;

    CFTypeRef q = SLSWindowQueryCreate(NULL);
    if (!q) return NULL;

    int32_t owner_i = filter->owner;
    CFNumberRef nOwner = CFNumberCreate(NULL, kCFNumberSInt32Type, &owner_i);
    CFNumberRef nInc   = CFNumberCreate(NULL, kCFNumberSInt64Type, &filter->include_tags);
    CFNumberRef nExc   = CFNumberCreate(NULL, kCFNumberSInt64Type, &filter->exclude_tags);

    SLSWindowQuerySetValue(q, kOwner, nOwner);
    SLSWindowQuerySetValue(q, kInc, nInc);
    SLSWindowQuerySetValue(q, kExc, nExc);

    // Window-list options (the `options` arg of SLSCopyWindowsWithOptionsAndTags
    // — 0x2 visible/standard, 0x7 incl. minimized/extended). Best-effort: only
    // set when the key resolves, so a missing symbol degrades to the prior path.
    CFNumberRef nWinOpts = NULL;
    if (kWinOpts) {
        int32_t wopts = filter->window_list_options;
        nWinOpts = CFNumberCreate(NULL, kCFNumberSInt32Type, &wopts);
        SLSWindowQuerySetValue(q, kWinOpts, nWinOpts);
    }

    // Scope by explicit space list, or by SpaceListOptions (all spaces) when no
    // list is given.
    CFArrayRef aSpaces = NULL;
    CFNumberRef nSpaceOpts = NULL;
    if (use_explicit_spaces) {
        aSpaces = cfarray_of_cfnumbers((void *)filter->spaces, sizeof(uint64_t),
                                       filter->space_count, kCFNumberSInt64Type);
        SLSWindowQuerySetValue(q, kSpaces, aSpaces);
    } else {
        int32_t opts = filter->space_list_options;
        nSpaceOpts = CFNumberCreate(NULL, kCFNumberSInt32Type, &opts);
        SLSWindowQuerySetValue(q, kSpaceOpts, nSpaceOpts);
    }

    CFTypeRef result = SLSWindowQueryRun(cid, q, filter->query_flags);
    // The CopyWindows iterator retains its backing result (same lifetime rule as
    // the SLSWindowQueryWindows path), so releasing `result` here is safe — only
    // the iterator must outlive the getters.
    CFTypeRef iterator = result ? SLSWindowQueryResultCopyWindows(result) : NULL;

    if (result)    CFRelease(result);
    if (nOwner)    CFRelease(nOwner);
    if (nInc)      CFRelease(nInc);
    if (nExc)      CFRelease(nExc);
    if (aSpaces)   CFRelease(aSpaces);
    if (nSpaceOpts) CFRelease(nSpaceOpts);
    if (nWinOpts)  CFRelease(nWinOpts);
    if (q)        CFRelease(q);
    return iterator;
}

uint32_t window_query_topmost_wid(int cid, const struct window_query_filter *filter)
{
    CFTypeRef it = window_query_run(cid, filter);
    if (!it) return 0;
    uint32_t wid = SLSWindowIteratorAdvance(it) ? SLSWindowIteratorGetWindowID(it) : 0;
    CFRelease(it);
    return wid;
}
