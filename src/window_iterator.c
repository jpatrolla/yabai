#include "window_iterator.h"
#include "misc/extern.h"
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

extern CFArrayRef cfarray_of_cfnumbers(void *values, size_t size, int count, CFNumberType type);

// SLSWindowQueryWindows(cid, wid_array, flags). The 3rd arg is a FLAGS bitmask,
// NOT a window count — the wid array (2nd arg) carries its own length, and the
// 3rd arg is passed straight to _run_query independent of array length (Dock's
// own wrapper only ever passes 0x0/0x1/0x2). Flag bits (empirical + Dock disasm):
//   bit 0 (0x1) = decode window titles. Clear → SLSWindowIteratorCopyTitle
//                 returns NULL for EVERY window even with GetWindowCount>0;
//                 set → all titles decode.
//   bit 1 (0x2) = include attached windows. We want top-level enumeration
//                 only, so leave it clear.
//   bit 2 (0x4) = include the per-window space list. Clear → the server-side
//                 encode_space_list writes count=0, so SLSWindowIteratorGet
//                 SpaceCount / CopySpaces / IsInSpace read empty. Left clear
//                 for the same top-level-only reason as bit 1.
// Everything else (id/level/tags/bounds AND constraints) decodes regardless of
// flags, so flags=0x1 yields titles AND constraints in one query; they are NOT
// mutually exclusive.
//
// Separately, SLSWindowQueryWindows can return a "valid-but-empty" result for
// some ARRAY shapes (payload length 0 → GetWindowCount == 0); _run_query's
// reply validation (strict size match + end-of-payload cookie) is deterministic
// against the input, so retrying the same input never recovers. Fix: append
// zero-WIDs to the ARRAY until the reply validates.
//
// So: pad the array for valid-but-empty; pass a fixed flags=0x1 for titles.
static CFTypeRef query_windows_with_window_pad(int cid, CFArrayRef wids, uint32_t flags) {
    if (!wids) return NULL;
    int base = (int)CFArrayGetCount(wids);
    if (base == 0) return NULL;

    const int max_pad = 8;
    for (int pad = 0; pad <= max_pad; pad++) {
        CFArrayRef padded = wids;
        CFMutableArrayRef tmp = NULL;
        if (pad > 0) {
            tmp = CFArrayCreateMutableCopy(NULL, base + pad, wids);
            if (!tmp) return NULL;
            uint32_t zero = 0;
            CFNumberRef zero_ref = CFNumberCreate(NULL, kCFNumberSInt32Type, &zero);
            if (!zero_ref) { CFRelease(tmp); return NULL; }
            for (int i = 0; i < pad; i++) CFArrayAppendValue(tmp, zero_ref);
            CFRelease(zero_ref);
            padded = tmp;
        }
        CFTypeRef q = SLSWindowQueryWindows(cid, padded, flags);
        if (tmp) CFRelease(tmp);
        if (q && SLSWindowQueryResultGetWindowCount(q) > 0) return q;
        if (q) CFRelease(q);
    }
    return NULL;
}

static bool window_iterator_from_wids(int cid, CFArrayRef wids, uint32_t flags, CFTypeRef *out_iterator) {
    CFTypeRef query = query_windows_with_window_pad(cid, wids, flags);
    if (!query) return false;

    CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
    CFRelease(query);
    if (!iterator) return false;

    // SLS-side alignment hint — a GetCount immediately after CopyWindows
    // settles the iterator before the first Advance.
    (void)SLSWindowIteratorGetCount(iterator);

    *out_iterator = iterator;
    return true;
}

bool window_iterator_de_window(int cid, uint32_t wid, CFTypeRef *out_iterator) {
    if (!out_iterator) return false;

    CFArrayRef wids = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    if (!wids) return false;

    bool ok = window_iterator_from_wids(cid, wids, 0x1, out_iterator);
    CFRelease(wids);
    return ok;
}

bool window_iterator_get_constraints(int cid, uint32_t wid, CGSize *out_min,
                                     CGSize *out_max, CGSize *out_cur) {
    CFTypeRef iterator = NULL;
    if (!window_iterator_de_window(cid, wid, &iterator)) return false;

    bool found = false;
    if (SLSWindowIteratorAdvance(iterator)) {
        CGSize mn = {0}, mx = {0}, cur = {0}, junk = {0};
        SLSWindowIteratorGetConstraints(iterator, &mn, &mx, &cur, &junk);
        if (out_min) *out_min = mn;
        if (out_max) *out_max = mx;
        if (out_cur) *out_cur = cur;
        found = true;
    }
    CFRelease(iterator);
    return found;
}

