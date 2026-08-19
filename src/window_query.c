#include <dlfcn.h>

// NOTE: the query-key symbols are CFStringRef DATA slots — dlsym returns the variable's
// address; deref once.
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

    CFNumberRef nWinOpts = NULL;
    if (kWinOpts) {
        int32_t wopts = filter->window_list_options;
        nWinOpts = CFNumberCreate(NULL, kCFNumberSInt32Type, &wopts);
        SLSWindowQuerySetValue(q, kWinOpts, nWinOpts);
    }

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
    // NOTE: the iterator CFRetains its backing result — releasing result here is safe.
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
