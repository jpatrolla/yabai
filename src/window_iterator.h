#ifndef WINDOW_ITERATOR_H
#define WINDOW_ITERATOR_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
#include <stdbool.h>

/**
 * Create an iterator for a single window
 *
 * @param cid Connection ID
 * @param wid Window ID to query
 * @param out_iterator Output iterator (caller must CFRelease when done)
 * @return true if successful, false otherwise
 *
 * NOTE: Applies the SLSWindowQueryWindows pad-sweep workaround for
 * valid-but-empty query replies (see window_iterator.c for rationale).
 */
bool window_iterator_de_window(int cid, uint32_t wid, CFTypeRef *out_iterator);

/**
 * Robust single-window size-constraint read (pad-swept iterator +
 * SLSWindowIteratorGetConstraints). Defeats the valid-but-empty
 * SLSWindowQueryWindows reply an un-padded query can trip on. Used by the
 * animator to fetch min/max at animation time.
 *
 * @param cid Connection ID (typically g_connection)
 * @param wid Window ID
 * @param out_min/out_max/out_cur Output sizes (any may be NULL). An
 *        unconstrained or not-yet-published window decodes as all-zeros, so
 *        test for > 0 to distinguish a real constraint.
 * @return true if a window decoded, false on query failure.
 */
bool window_iterator_get_constraints(int cid, uint32_t wid, CGSize *out_min, CGSize *out_max, CGSize *out_cur);

#endif
