// payload.m — Dock-injected scripting addition for yabai.
//
// THIS FILE IS INTENTIONALLY UPSTREAM-SHAPED against `origin/master`.
// Don't add new opcode handlers, refactor "while you're in there", or
// modernize the upstream code. All experimental work (new opcodes, SLS
// observation, focus_ring, tests, scrap) lives in payload_inc/*.inc.m
// and is included as part of this single translation unit.
//
// See payload_inc/README.md for the upstream-vs-experimental rule and the
// four-touchpoint checklist for adding a new SA opcode.

#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFCGTypes.h>
#include <CoreGraphics/CGAffineTransform.h>
#include <CoreGraphics/CGDirectDisplay.h>
#include <Foundation/Foundation.h>

#include <Foundation/NSObjCRuntime.h>
#include <os/log.h>
#include <MacTypes.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <mach/vm_map.h>
#include <mach/vm_page_size.h>
#include <servers/bootstrap.h>
#include <objc/message.h>
#include <objc/runtime.h>

#include <CoreGraphics/CoreGraphics.h>
#include <IOSurface/IOSurface.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <arpa/inet.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdatomic.h>
#include <netdb.h>
#include <dlfcn.h>
#include <signal.h>

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
#include <fcntl.h>
#include <time.h>

#include "common.h"

#ifdef __x86_64__
#include "x64_payload.m"
#elif __arm64__
#include "arm64_payload.m"
#include <ptrauth.h>
#endif

#define HASHTABLE_IMPLEMENTATION
#include "../misc/hashtable.h"
#undef HASHTABLE_IMPLEMENTATION

#define page_align(addr) (vm_address_t)((uintptr_t)(addr) & (~(vm_page_size - 1)))
// do/while(0) so a conditional `if (cond) unpack(x);` guards BOTH the copy AND
// the cursor advance — the bare two-statement form advanced the cursor
// unconditionally, drifting every subsequent field. Mirrors the daemon's pack macro.
//
// AC-9 cursor-end guard: handle_message stashes one-past-end (the message length
// prefix) in g_unpack_end before dispatch. unpack refuses to read past it — on
// overflow it zeroes the destination, leaves the cursor put, and sets
// g_unpack_overflow so handle_message logs the daemon/payload field-list desync
// once instead of silently corrupting fields. Thread-local: only the single
// daemon dispatch thread unpacks.
static __thread const char *g_unpack_end;
static __thread bool        g_unpack_overflow;
#define unpack(v) do { \
        if ((const char *)(message) + sizeof(v) > g_unpack_end) { \
            g_unpack_overflow = true; memset(&(v), 0, sizeof(v)); \
        } else { \
            memcpy(&(v), message, sizeof(v)); message += sizeof(v); \
        } \
    } while (0)
#define lerp(a, t, b) (((1.0-t)*a) + (t*b))

// Wobbly-windows mesh method: 0 = display-coordinate, 1 = local/global-coordinate.
#define WOBBLY_USE_LOCAL_GLOBAL_COORDS 1

typedef struct {
  CGPoint local;
  CGPoint global;
} CGPointWarp;

typedef void *CGSRegionRef;
extern CGError SLSTransactionSetWindowTransform(CFTypeRef transaction, uint32_t wid, int unknown, int unknown2, CGAffineTransform t);
extern CGError SLSTransactionMoveWindowWithGroup(CFTypeRef transaction, uint32_t wid, CGPoint origin);
extern CGError SLSTransactionSetWindowShape(CFTypeRef transaction, uint32_t wid, float x, float y, CGSRegionRef shape);
extern CGError SLSTransactionSetWindowDragRegion(CFTypeRef transaction, uint32_t wid, CGSRegionRef region);
extern int      SLSAddDragRegion(int cid, uint32_t wid, CGSRegionRef region);
extern int      SLSAddDragRegionInWindow(int cid, uint32_t wid, CGSRegionRef region);
extern int      SLSClearDragRegion(int cid, uint32_t wid);
// Drag-region readers. _SLSGetDragRegionLegacy / _SLSGetSpecialCommandRegionLegacy
// are PROCESS-LOCAL: they only read the caller's own CGSWindow mapping dict,
// which is empty for foreign wids (the owning app wrote to ITS dict, not ours).
// For cross-process reads, use _SLSCopyWindowProperty — server-side path: tries
// local cache first, falls back to mach_msg(0x1513) to WindowServer for the
// authoritative value. Returns 0 on success, 0x3e8 on failure.
extern CGError SLSCopyWindowProperty(int cid, uint32_t wid, CFStringRef key, CFTypeRef *out);
extern bool    CGRegionContainsPoint(CGSRegionRef region, CGPoint point);
extern CGRect  CGRegionGetBoundingBox(CGSRegionRef region);
extern bool    CGRegionIsEmpty(CGSRegionRef region);
// Routing-records: the system-wide "what's at this point" primitive. Underlying
// AXUIElementCopyElementAtPosition + HI's drag-target resolution. Server-bound;
// returns a CFDictionary { kCGSRoutingRecordsKey: CFArray<{cid,wid,...}> }.
// Schema beyond cid+wid TBD — probed live by routing_records test.
extern CFDictionaryRef SLSCopyWindowRoutingRecordsForScreenLocation(int cid, double x, double y);
extern CGError CGSNewRegionWithRect(const CGRect *rect, CGSRegionRef *outRegion);
extern CGError CGSNewEmptyRegion(CGSRegionRef *outRegion);
extern CGError SLSSetWindowShape(int cid, uint32_t wid, float x, float y, CGSRegionRef shape);
extern CGError SLSSetWindowEventShape(int cid, uint32_t wid, CGSRegionRef shape);
extern void SLSDisableUpdate(int cid);
extern void SLSReenableUpdate(int cid);
extern CGError SLSTransactionOrderWindow(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGRect SLSWindowIteratorGetScreenRect(CFTypeRef iterator);
extern int SLSMainConnectionID(void);
 extern CGError SLSTransactionSetWindowOriginRelativeToWindow(CFTypeRef transaction, uint32_t wid, uint32_t relative_wid, float offset_x, float offset_y, uint32_t flags);
extern CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSGetWindowResolution(int cid, uint32_t wid, double *resolution);
extern OSStatus SLSMoveWindowWithGroup(int cid, uint32_t wid, CGPoint *point);
extern CGError SLSReassociateWindowsSpacesByGeometry(int cid, CFArrayRef window_list);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *window_cid);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSSetWindowLevel(int cid, uint32_t wid, int level);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int sub_level);
extern CGError SLSGetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSGetScreenRectForWindow(int cid, uint32_t wid, CGRect *frame);
extern int SLSWindowListSetLockedBounds(int cid, uint32_t *wid_list, CGRect *bounds_list, int count);
extern CGError SLSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *t);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSSetWindowTransforms(int cid, uint32_t wid, CGAffineTransform *transform, int flags);
extern int SLSSpaceSetTransform(int cid, uint64_t sid, CGAffineTransform *transform, int options);
extern CGError SLSTransactionSetSpaceTransform(CFTypeRef transaction, uint64_t sid, uint64_t options, CGAffineTransform *transform);
extern CGError SLSTransactionShowSpace(CFTypeRef transaction, uint64_t sid);
extern CGError SLSTransactionHideSpace(CFTypeRef transaction, uint64_t sid);
extern CGError SLSTransactionSetManagedDisplayIsAnimating(CFTypeRef transaction, CFStringRef display_uuid, bool is_animating);
extern CGError SLSTransactionSetManagedDisplayCurrentSpace(CFTypeRef transaction, CFStringRef display_uuid, uint64_t sid);
extern int SLSWillSwitchSpaces(int cid, CFArrayRef spaces);
extern CFArrayRef SLSCopyAssociatedWindows(int cid, uint32_t wid);
extern CGError SLSRegisterNotifyProc(void *handler, uint32_t event, void *context);
extern CGError SLSRequestNotificationsForWindows(int cid, uint32_t *window_list, int count);
extern int SLSDragWindowRelativeToMouse(int cid, uint32_t wid, double dx, double dy);

// Connection callback for window-specific events
#define CONNECTION_CALLBACK(name) void name(uint32_t type, void *data, size_t data_length, void *context, int cid)
typedef CONNECTION_CALLBACK(connection_callback);
extern CGError SLSRegisterConnectionNotifyProc(int cid, connection_callback *handler, uint32_t event, void *context);

// Remove a registered notify proc. SLSRemoveNotifyProc arg order is (event,
// handler, context) — event FIRST, opposite of SLSRegisterNotifyProc.
extern CGError SLSRemoveNotifyProc(int event, void *handler, void *context);
extern CGError SLSRemoveConnectionNotifyProc(int cid, int event, connection_callback *handler, void *context);

extern CGError SLSTransactionSetWindowAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
// SLSTransactionSetWindowAlphaAnimated is deliberately NOT declared — it SIGSEGVs
// WindowServer in CGXWindow::fade_finish; fades run per-frame via the instant
// SLSTransactionSetWindowAlpha above.
// System alpha is a second, independent alpha slot (op 0x0e; composited = normal x
// system). Privileged: only a universal-owner cid passes the server gate (fine — our
// transactions are on Dock's main cid). No instant singular form on Tahoe (only
// _SLSSetWindowListSystemAlpha); use a one-shot transaction.
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSTransactionSetWindowLockedBounds(CFTypeRef transaction, uint32_t wid, CGRect bounds);
// 'place' is an int, NOT CGRect (disasm-verified). Non-AtPlace wrappers call
// AtPlace with place=0x7ffffeff.
extern CGError SLSTransactionSetWindowLockedBoundsAtPlace(CFTypeRef transaction, uint32_t wid, int place, CGRect bounds);
extern CGError SLSTransactionClearWindowLockedBoundsAtPlace(CFTypeRef transaction, uint32_t wid, int place);
// disasm-verified: d0,d1 = target CGPoint; d2,d3 = mouse-location CGPoint;
// x2 = uint64 ts.
extern CGError SLSTransactionMoveWindowForServerSideDrag(CFTypeRef transaction, uint32_t wid, uint64_t timestamp, CGPoint point, CGPoint mouse_location);
extern CGError SLSTransactionSetWindowGlobalClipShape(CFTypeRef transaction, uint32_t wid, CGSRegionRef region);
extern CGError SLSTransactionSetWindowSystemCornerRadius(CFTypeRef transaction, uint32_t wid, double radius);
extern CGError SLSTransactionSetWindowCornerRadiusMaskedCorners(CFTypeRef transaction, uint32_t wid, uint32_t corners);
extern CGError SLSTransactionClearWindowCornerRadius(CFTypeRef transaction, uint32_t wid);
// NULL region => __XRemoveWindowListGlobalClipShape (true detach; sets the
// window's global clip pointer to NULL). Non-NULL => set. arg order is
// (cid, region, wids, count) per disasm.
extern CGError SLSSetWindowListGlobalClipShape(int cid, CGSRegionRef region, const uint32_t *wids, int count);
extern CGError SLSTransactionSetWindowBoundsPath(CFTypeRef transaction, uint32_t wid, CGPathRef path);
extern CGError SLSTransactionClearWindowLockedBounds(CFTypeRef transaction, uint32_t wid);
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
// op-0x80: reorder/move a managed Space server-side (same display UUID = reorder, different = cross-display).
extern CGError SLSTransactionMoveManagedSpaceToDisplayAfterSpace(CFTypeRef transaction, uint64_t sid, CFStringRef display_uuid, uint64_t after_sid);
// Modern fenced-commit path. method ∈ {1=sync, 2=async, 3=CA-commit+bind,
// 4=CA-commit-no-bind}. Method 3 is what WindowManager uses; it pairs the
// commit with the connection's last CA transaction so server-side and
// client-side animation commits hit the same display refresh. Disasm-verified.
extern void SLSTransactionCommitUsingMethod(CFTypeRef transaction, int method);

// Required precondition for method-3 commits. Returns autoreleased CAContext
// (we discard it — just want the side effect: txn[0x1c] |= 0x1, the
// "fence-aware" flag that sls_transaction_commit_ca checks before attaching
// the txn's payload to the CA context. Without this flag, method 3 commits
// an EMPTY CA payload and our LB/T3D writes silently vanish.
extern id SLSTransactionGetFencingContext(CFTypeRef transaction);
#define YABAI_SLS_PLACE 0x7ffffeff
extern CGPoint SLSCurrentInputPointerPosition(void);
extern CGError SLSSetWindowLayerContext(int cid, uint32_t wid, CGContextRef context);
// mesh is w*h*4 float32 (4 floats/node = {srcX,srcY,dstX,dstY}), disasm-verified.
// NULL mesh clears the warp.
extern CGError SLSSetWindowWarp(int cid, uint32_t wid, int w, int h, const float *mesh);
extern CGError SLSTransactionSetWindowWarp(CFTypeRef transaction, uint32_t wid, int w, int h, float *mesh);
// FR-26 surface probes (see payload_inc/tests/test_surfaces.inc.m). AddSurface
// adds a surface to the window's surface list; SetSurfaceBounds positions it in
// window-local coords. SLSBindSurface (backingStore arg unverified) intentionally
// NOT declared here yet — add it when the bind step is filled in.
extern CGError SLSAddSurface(int cid, uint32_t wid, uint32_t *surface_out);
extern CGError SLSSetSurfaceBounds(int cid, uint32_t wid, uint32_t surface, CGRect bounds);
extern CGContextRef SLSGetWindowLayerContext(int cid, uint32_t wid);
extern CGError SLSCreateLayerContext(int cid, uint32_t *context_id, uint32_t *layer_id);

// Window content capture APIs (used by genie effect)
extern void *_WSWindowCreate(int cid, int type, CGSRegionRef region, int flags);
extern void _WSSystemWindowRelease(void *window);
extern CGError _WSWindowSetCapturedContent(void *window, void *capture_surface);
extern CGError _WSWindowSetTitle(void *window, CFStringRef title);
extern CGError _WSWindowSetDepth(void *window, int depth);
extern CGError _WSWindowSetHasAlpha(void *window, bool hasAlpha);
extern CGError _WSWindowGetShape(void *window);
extern CGError SLSOrderWindow(int cid, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSWindowIsOrderedIn(int cid, uint32_t wid, uint8_t *out);
extern int SLSBlockWindowOrdering(int cid, int block);

extern CGError SLSSetWindowParent(int cid, uint32_t child_wid, uint32_t parent_wid);
// SLSGetSpaceBindings 3rd arg is a 64-bit out (bound space id), NOT an int* —
// a 4-byte int here stores 8 bytes past it (stack smash). disasm-verified.
extern CGError SLSGetSpaceBindings(uint32_t wid, int8_t *binding1, uint64_t *binding2);
extern uint64_t SLSWindowGetBestSpace(uint32_t wid, uint32_t index);
// Dock "Assign To" — process->space binding (affects the process's FUTURE
// windows). Fire-and-forget; rc != applied. From the payload we call with Dock's
// universal-owner cid (SLSMainConnectionID()), the privileged path.
extern CGError SLSProcessAssignToSpace(int cid, pid_t pid, uint64_t sid);
extern CGError SLSProcessAssignToAllSpaces(int cid, pid_t pid);
// Per-CONNECTION default space ("where this connection's new windows open").
// Both take a separate target_cid (x1) and return a real CGError;
// kCGSConnectionDefaultSpace = CFString "ConnectionDefaultSpace", value is a
// CFNumber(kCFNumberSInt64Type) sid. Reads work cross-connection unprivileged;
// the write is the privilege/no-move experiment. disasm-verified.
extern CFStringRef kCGSConnectionDefaultSpace;
extern CGError SLSSetConnectionProperty(int cid, int target_cid, CFStringRef key, CFTypeRef value);
extern CGError SLSCopyConnectionProperty(int cid, int target_cid, CFStringRef key, CFTypeRef *out);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref, uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
extern bool SLSManagedDisplayIsAnimating(int cid, CFStringRef display_ref);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);
// Managed-space lifecycle — the spid-minting path Stage Manager uses. Signatures
// disasm-verified (SkyLight _SLSSpaceCreate/_SLSSpaceDestroy/
// _SLSMoveManagedSpaceToDisplayIndex). Callable from this payload's Dock cid
// (universal owner); see extern.h for the `values` dict recipe.
extern uint64_t SLSSpaceCreate(int cid, int options, CFDictionaryRef values);
extern void SLSSpaceDestroy(int cid, uint64_t sid);
extern CGError SLSSpaceResetMenuBar(int cid, uint64_t sid);
extern void SLSMoveManagedSpaceToDisplayIndex(int cid, uint64_t sid, CFStringRef display_uuid, uint64_t index);
extern CFStringRef kCGSPackagesDisplayIdentifierKey;
extern int SLSSpaceGetType(int cid, uint64_t sid);
extern uint64_t SLSGetActiveSpace(int cid);
extern CFArrayRef SLSCopyManagedDisplaySpaces(int cid);
// Space-values get/set — the mutator counterpart to SLSSpaceCreate's `values`
// dict. `SLSSpaceSetValues` disasm-verified (3 args; values is type-checked as
// CFDictionary then plist-serialized over mach, same wire form as
// SLSSpaceCreateTile). rc is unreliable on the bridged path — verify via the
// CopyValues read-back. CopyValues signature inferred-symmetric (read sibling).
extern CGError SLSSpaceSetValues(int cid, uint64_t sid, CFDictionaryRef values);
extern CFDictionaryRef SLSSpaceCopyValues(int cid, uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern CFTypeRef SLSTransactionCreate(int cid);
extern CGError SLSTransactionCommit(CFTypeRef transaction, int synchronous);
extern CGError SLSTransactionOrderWindowGroup(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
// "Safe" variant: commit block re-checks CGSWindowGetMappedImpl(cid, wid, 0)
// and no-ops on wids absent from this connection's local window table; an
// ordered-out-but-still-backed window stays mapped, so it IS re-ordered.
// Return value is a commit-buffer artifact — do NOT read it as a CGError.
// (op 0x65; signature disasm-verified.)
extern CGError SLSTransactionSafeOrderWindowGroup(CFTypeRef transaction, uint32_t wid, int order, uint32_t rel_wid);
extern CGError SLSTransactionSetWindowSystemAlpha(CFTypeRef transaction, uint32_t wid, float alpha);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);
extern void SLSTransactionDragWindowRelativeToMouse(CFTypeRef transaction, uint32_t wid, double dx, double dy, uint64_t flags);
// Batch z-order: order every wid in the list with one shared op + rel_wid in
// a single mach round-trip. op 1=above / -1=below / 0=out (2 is an internal
// to-front sentinel the wrapper rewrites — don't pass it). Server reorder is
// unconditional (foreign windows included from a universal-owner cid); the
// internal CGSWindowGetMappedImpl gate only skips the client CA-mirror.
// Returns a real CGError. (op 0x65 family; signature disasm-verified.)
extern CGError SLSOrderWindowListWithOperation(int cid, const uint32_t *wids, int operation, uint32_t rel_wid, int count);
extern CGError SLSAddWindowToWindowOrderingGroup(int cid, uint32_t parent_wid, uint32_t child_wid, int order);
extern CGError SLSAddWindowToWindowMovementGroup(int cid, uint32_t parent_wid, uint32_t child_wid, int order);
// Asymmetric naming: ordering has a single-arg child remove (each wid lives in
// at most one ordering group), movement has a symmetric parent+child remove.
extern CGError SLSRemoveFromOrderingGroup(int cid, uint32_t child_wid);
extern CGError SLSRemoveWindowFromWindowMovementGroup(int cid, uint32_t parent_wid, uint32_t child_wid);
extern CFDictionaryRef SLSGetDebugInfo(int cid);
extern CGError SLSManagedDisplaySetIsAnimating(int cid, CFStringRef display_uuid, bool is_animating);
extern CFStringRef CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID display);

// CVDisplayLink forward declarations (avoiding CoreVideo.h which conflicts with CG headers)
typedef struct __CVDisplayLink *CVDisplayLinkRef;
typedef uint32_t CVOptionFlags;
typedef int32_t CVReturn;
enum { kCVReturnSuccess = 0 };
typedef struct {
    uint32_t version;
    int32_t  videoTimeScale;
    int64_t  videoTime;
    uint64_t hostTime;
    double   rateScalar;
    int64_t  videoRefreshPeriod;
    int64_t  reserved[5];
} CVTimeStamp;
typedef CVReturn (*CVDisplayLinkOutputCallback)(CVDisplayLinkRef, const CVTimeStamp *, const CVTimeStamp *, CVOptionFlags, CVOptionFlags *, void *);
extern CVReturn CVDisplayLinkCreateWithActiveCGDisplays(CVDisplayLinkRef *linkOut);
extern CVReturn CVDisplayLinkSetOutputCallback(CVDisplayLinkRef link, CVDisplayLinkOutputCallback cb, void *ctx);
extern CVReturn CVDisplayLinkStart(CVDisplayLinkRef link);
extern CVReturn CVDisplayLinkStop(CVDisplayLinkRef link);
extern CVReturn CVDisplayLinkCreateWithCGDisplay(CGDirectDisplayID did, CVDisplayLinkRef *linkOut);
extern Boolean  CVDisplayLinkIsRunning(CVDisplayLinkRef link);
extern void     CVDisplayLinkRelease(CVDisplayLinkRef link);

// displaylink.h skips its own <CoreVideo/CoreVideo.h> when this is defined; the
// CV symbols it needs are forward-declared just above. (CGDirectDisplayID comes
// from <CoreGraphics/CGDirectDisplay.h>, already included; Boolean from MacTypes.h.)
#define DISPLAYLINK_NO_COREVIDEO_HEADER
#include "../misc/displaylink.h"

// Payload-side unified log (logpf) — appends to the shared yabai log so
// Dock-side lines interleave with the daemon's. Included before the other
// payload_inc handlers so they can all use it.
#include "payload_inc/logp.inc.m"

// Per-wid animation ownership registry (AC-14) — claim/owns/release table
// every animator's write gates check. Depends on nothing; included before
// all animators. See payload_inc/anim_owner.inc.m.
#include "payload_inc/anim_owner.inc.m"

// Shared easing curves (payload_ease). Depends on nothing; included before all
// animators so focus_ring + space_animation route through one curve table.
#include "payload_inc/easing.inc.m"

// Forward declaration for the focus_ring deathwatch hook defined in
// payload_inc/focus_ring.inc.m. Hoisted so the deathwatch helper (included
// EARLIER in this TU than focus_ring.inc.m) can tear down the ring windows
// when yabai dies.
static void payload_focus_ring_destroy_all(void);

// Daemon deathwatch: kqueue NOTE_EXIT on the daemon pid — resets demoted
// window sub-levels when yabai dies so nothing is stranded below the desktop,
// and frees the focus_ring overlay windows so no ghost band haunts a space.
#include "payload_inc/deathwatch.inc.m"

// SkyLight private SPI externs used by code earlier in this TU than the
// experimental_opcodes / focus_ring / tests includes. Declared here so the
// extraction doesn't break forward-reference order.
extern CGError SLSWindowFreezeWithOptions(int cid, uint32_t wid, CFDictionaryRef options);
extern CGError SLSWindowThaw(int cid, uint32_t wid);
extern CGError SLSTransactionSetWindowTransform3D(CFTypeRef transaction, uint32_t wid, double *t);

// CFArray-of-CFNumbers helper used by SLS APIs that want array-wrapped
// integer args. Lives here (not in an include) because callers earlier in
// the TU than experimental_opcodes.inc.m reference it (the focus_ring
// overlay setup, plus test helpers).
static inline CFArrayRef cfarray_of_cfnumbers(void *values, size_t size, int count, CFNumberType type)
{
    CFNumberRef temp[count];

    for (int i = 0; i < count; ++i) {
        temp[i] = CFNumberCreate(NULL, type, ((char *)values) + (size * i));
    }

    CFArrayRef result = CFArrayCreate(NULL, (const void **)temp, count, &kCFTypeArrayCallBacks);

    for (int i = 0; i < count; ++i) {
        CFRelease(temp[i]);
    }

    return result;
}


extern CFDictionaryRef SLSCreateWindowDebugInfo(int cid, uint32_t wid);

// Broadcast notification API
extern int SLSPostBroadcastNotification(int cid, void *data, int length);
extern void SLSTransactionPostBroadcastNotification(CFTypeRef transaction, int event_code, void *data, int length);

// Accessibility report API
extern CGError SLSGetUserAccessibilityReport(int cid, pid_t pid, CFDictionaryRef *report_out);
extern CGError SLSGetUserAccessibilityReportForPid(pid_t pid, CFDictionaryRef *report_out);

// ---- SLS notify (private) --------------------------------------------------
typedef void (*SLSNotifyProc)(int, int, int, int, int, void *);

extern CGError SLSRequestNotificationsForWindows(int cid, uint32_t *window_list, int count);
extern CGError SLSSetConnectionProperty(int cid, int target_cid, CFStringRef key, CFTypeRef value);

// SLS Iterator APIs for window queries
extern CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef window_list, int count);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef query);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern void SLSWindowIteratorGetConstraints(CFTypeRef iterator, CGSize *outA, CGSize *outB, CGSize *outC, CGSize *junk);
extern void SLSFlushWindow(int cid, uint32_t wid, void *null);

// Non-deprecated sibling of SLSFlushWindow. Disasm-verified: it IGNORES the cid
// arg and uses the process's main connection, looks the
// window up via _CGSWindowGetMappedImpl (a GetWindowShmemReference mach_msg the
// WindowServer owner-gates), then calls _CGSWindowFlushRegion(window, region, 0).
// The passed region is taken VERBATIM in window-LOCAL coords (unlike SLSFlushWindow,
// which offsets a global region by -shapeBounds first). Always returns 0.
extern CGError SLSFlushWindowContentRegion(int cid, uint32_t wid, CGSRegionRef region);

// Force the WindowServer to recomposite a window's whole content region — the
// step that makes an already-committed transform / bounds / clip change actually
// become visible when the compositor hasn't refreshed the surface on its own.
//
// Owner gate: SLSFlushWindowContentRegion maps the wid through this process's
// main connection, so the server only honors the flush for windows THIS cid can
// map. From the SA payload that cid is Dock's (universal owner), which is why we
// run the flush here rather than from yabai's daemon g_connection.
//
// Region: built explicitly in window-local coords from the live bounds. A NULL
// region routes into _CGSWindowFlushRegion's CGRegion* path, which dereferences
// the null arg — so we never pass NULL.
//
// Returns false only if the bounds read or region build failed; the flush rc
// (effectively always 0) is written to *out_rc when non-NULL.
static bool payload_flush_content_region(int cid, uint32_t wid, CGError *out_rc)
{
    CGRect bounds = {0};
    if (SLSGetWindowBounds(cid, wid, &bounds) != kCGErrorSuccess ||
        bounds.size.width <= 0.0 || bounds.size.height <= 0.0) {
        return false;
    }

    CGRect local = { { 0, 0 }, bounds.size };
    CGSRegionRef region = NULL;
    if (CGSNewRegionWithRect(&local, &region) != kCGErrorSuccess || !region) {
        return false;
    }

    SLSFlushWindowContentRegion(cid, wid, region);
    if (out_rc) *out_rc = kCGErrorSuccess;
    CFRelease(region);
    return true;
}

// SLSNewConnection(0, &cid) — creates a new SLS connection, returns the cid via
// the out-param and a CGError as the result (Apple convention; matches
// src/misc/extern.h and JankyBorders). Used by the focus-ring blur overlay to own
// its window on a dedicated connection rather than Dock's main cid.
extern CGError SLSNewConnection(int zero, int *cid);

// ScreenWatcher types
typedef uint32_t CGSConnectionID;

struct window_fade_context
{
    pthread_t thread;
    uint32_t wid;
    volatile float alpha;
    volatile float duration;
    volatile bool skip;
};

pthread_mutex_t window_fade_lock;
struct table window_fade_table;

static id dock_spaces;
static id dp_desktop_picture_manager;
static uint64_t add_space_fp;
static uint64_t remove_space_fp;
static uint64_t move_space_fp;
static uint64_t set_front_window_fp;
static uint64_t animation_time_addr;
static bool macOSSequoia;

static pthread_t daemon_thread;
static int daemon_sockfd;

static uint64_t static_base_address(void)
{
    const struct segment_command_64 *command = getsegbyname("__TEXT");
    uint64_t addr = command->vmaddr;
    return addr;
}

static uint64_t image_slide(void)
{
    char path[1024];
    uint32_t size = sizeof(path);

    if (_NSGetExecutablePath(path, &size) != 0) {
        return -1;
    }

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }

    return 0;
}

static uint64_t hex_find_seq(uint64_t baddr, const char *c_pattern)
{
    if (!baddr || !c_pattern) return 0;

    uint64_t addr = baddr;
    uint64_t pattern_length = (strlen(c_pattern) + 1) / 3;
    char buffer_a[pattern_length];
    char buffer_b[pattern_length];
    memset(buffer_a, 0, sizeof(buffer_a));
    memset(buffer_b, 0, sizeof(buffer_b));

    char *pattern = (char *) c_pattern + 1;
    for (int i = 0; i < pattern_length; ++i) {
        char c = pattern[-1];
        if (c == '?') {
            buffer_b[i] = 1;
        } else {
            int temp = c <= '9' ? 0 : 9;
            temp = (temp + c) << 0x4;
            c = pattern[0];
            int temp2 = c <= '9' ? 0xd0 : 0xc9;
            buffer_a[i] = temp2 + c + temp;
        }
        pattern += 3;
    }

loop:
    for (int counter = 0; counter < pattern_length; ++counter) {
        if ((buffer_b[counter] == 0) && (((char *)addr)[counter] != buffer_a[counter])) {
            addr = (uint64_t)((char *)addr + 1);
            if (addr - baddr < 0x1286a0) {
                goto loop;
            } else {
                return 0;
            }
        }
    }

    return addr;
}

#if __arm64__
uint64_t decode_adrp_add(uint64_t addr, uint64_t offset)
{
    uint32_t adrp_instr = *(uint32_t *) addr;

    uint32_t immlo = (0x60000000 & adrp_instr) >> 29;
    uint32_t immhi = (0xffffe0 & adrp_instr) >> 3;

    int32_t value = (immhi | immlo) << 12;
    int64_t value_64 = value;

    uint32_t add_instr = *(uint32_t *) (addr + 4);
    uint64_t imm12 = (add_instr & 0x3ffc00) >> 10;

    if (add_instr & 0xc00000) {
        imm12 <<= 12;
    }

    return (offset & 0xfffffffffffff000) + value_64 + imm12;
}
#endif

static bool verify_os_version(NSOperatingSystemVersion os_version)
{
    NSLog(@"[yabai-sa] checking for macOS %ld.%ld.%ld compatibility!", os_version.majorVersion, os_version.minorVersion, os_version.patchVersion);

#ifdef __x86_64__
    if (os_version.majorVersion == 11) {
        return true; // Big Sur 11.0
    } else if (os_version.majorVersion == 12) {
        return true; // Monterey 12.0
    } else if (os_version.majorVersion == 13) {
        return true; // Ventura 13.0
    } else if (os_version.majorVersion == 14) {
        return true; // Sonoma 14.0
    } else if (os_version.majorVersion == 15) {
        macOSSequoia = true;
        return true; // Sequoia 15.0
    } else if (os_version.majorVersion == 26) {

        NSLog(@"[yabai-sa] Detected Tahoe Preview... flagging 'macOSSequoia=true.'");
        macOSSequoia = true;
        return true; // Tahoe preview
    }

    NSLog(@"[yabai-sa] spaces functionality is only supported on macOS Big Sur 11.0.0+, Monterey 12.0.0+, Ventura 13.0.0+, Sonoma 14.0.0+, and Sequoia 15.0");
#elif __arm64__
    if (os_version.majorVersion == 12) {
        return true; // Monterey 12.0
    } else if (os_version.majorVersion == 13) {
        return true; // Ventura 13.0
    } else if (os_version.majorVersion == 14) {
        return true; // Sonoma 14.0
    } else if (os_version.majorVersion == 15) {
        macOSSequoia = true;
        return true; // Sequoia 15.0
    } else if (os_version.majorVersion == 26) {

        NSLog(@"[yabai-sa] Detected Tahoe Preview... flagging 'macOSSequoia=true.'");
        macOSSequoia = true;
        return true; // Tahoe preview
    }

    NSLog(@"[yabai-sa] spaces functionality is only supported on macOS Monterey 12.0.0+, and Ventura 13.0.0+, Sonoma 14.0.0+, and Sequoia 15.0");
#endif

    return false;
}

// MC-5b: -[WVExpose animationDuration] swizzle statics. WVExpose is a DockCore
// class already injected; the daemon pushes a duration over SA opcode 0x58.
// >= 0 overrides (0 => no MC tween => SLSGetScreenRectForWindow is a ~1-frame
// layout oracle + native-animation off-switch); < 0 = passthrough to native.
static double expose_animation_duration = -1;
static double (*orig_WVExpose_animationDuration)(id, SEL);

static double hook_WVExpose_animationDuration(id self, SEL sel)
{
    if (expose_animation_duration >= 0) return expose_animation_duration;
    return orig_WVExpose_animationDuration ? orig_WVExpose_animationDuration(self, sel) : 0.25;
}

static void do_set_expose_animation_duration(char *message)
{
    double duration;
    unpack(duration);
    expose_animation_duration = duration;
    NSLog(@"[yabai-sa] expose_animation_duration set to %f", expose_animation_duration);
}

static void init_instances()
{
    NSOperatingSystemVersion os_version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (!verify_os_version(os_version)) return;

    uint64_t baseaddr = static_base_address() + image_slide();

    uint64_t dock_spaces_addr = hex_find_seq(baseaddr + get_dock_spaces_offset(os_version), get_dock_spaces_pattern(os_version));
    if (dock_spaces_addr == 0) {
        dock_spaces = nil;
        NSLog(@"[yabai-sa] could not locate pointer to dock.spaces! spaces functionality will not work!");
    } else {
#ifdef __x86_64__
        uint32_t dock_spaces_offset = *(int32_t *)dock_spaces_addr;
        NSLog(@"[yabai-sa] (0x%llx) dock.spaces found at address 0x%llX (0x%llx)", baseaddr, dock_spaces_addr, dock_spaces_addr - baseaddr);
        dock_spaces = [(*(id *)(dock_spaces_addr + dock_spaces_offset + 0x4)) retain];
#elif __arm64__
        uint64_t dock_spaces_offset = decode_adrp_add(dock_spaces_addr, dock_spaces_addr - baseaddr);
        NSLog(@"[yabai-sa] (0x%llx) dock.spaces found at address 0x%llX (0x%llx)", baseaddr, dock_spaces_offset, dock_spaces_offset - baseaddr);
        dock_spaces = [(*(id *)(baseaddr + dock_spaces_offset)) retain];
#endif
    }

    uint64_t dppm_addr = hex_find_seq(baseaddr + get_dppm_offset(os_version), get_dppm_pattern(os_version));
    if (dppm_addr == 0) {
        dp_desktop_picture_manager = nil;
        NSLog(@"[yabai-sa] could not locate pointer to dppm! moving spaces will not work!");
    } else {
#ifdef __x86_64__
        uint32_t dppm_offset = *(int32_t *)dppm_addr;
        NSLog(@"[yabai-sa] (0x%llx) dppm found at address 0x%llX (0x%llx)", baseaddr, dppm_addr, dppm_addr - baseaddr);
        dp_desktop_picture_manager = [(*(id *)(dppm_addr + dppm_offset + 0x4)) retain];
#elif __arm64__
        uint64_t dppm_offset = decode_adrp_add(dppm_addr, dppm_addr - baseaddr);
        NSLog(@"[yabai-sa] (0x%llx) dppm found at address 0x%llX (0x%llx)", baseaddr, dppm_offset, dppm_offset - baseaddr);
        dp_desktop_picture_manager = [(*(id *)(baseaddr + dppm_offset)) retain];
#endif

        //
        // @hack
        //
        // NOTE(asmvik): For whatever reason, in Sonoma, DPDesktopPictureManager is initialized and swapped
        // to an alternate storage location instead of where it used to be stored in previous macOS versions..
        //
        // This alternate storage location resides 8-bytes before the usual location, so we simply do
        // the subtract to arrive at the correct location in cases where the usual location is null.
        //

#ifdef __x86_64__
        if (dp_desktop_picture_manager == nil) {
            dp_desktop_picture_manager = [(*(id *)(dppm_addr + dppm_offset + 0x4 - 0x8)) retain];
        }
#elif __arm64__
        if (dp_desktop_picture_manager == nil) {
            dp_desktop_picture_manager = [(*(id *)(baseaddr + dppm_offset - 0x8)) retain];
        }
#endif
    }

    uint64_t add_space_addr = hex_find_seq(baseaddr + get_add_space_offset(os_version), get_add_space_pattern(os_version));
    if (add_space_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to addSpace function..");
        add_space_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) addSpace found at address 0x%llX (0x%llx)", baseaddr, add_space_addr, add_space_addr - baseaddr);
#ifdef __x86_64__
        add_space_fp = add_space_addr;
#elif __arm64__
        add_space_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) add_space_addr, ptrauth_key_asia, 0);
#endif
    }

    uint64_t remove_space_addr = hex_find_seq(baseaddr + get_remove_space_offset(os_version), get_remove_space_pattern(os_version));
    if (remove_space_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to removeSpace function..");
        remove_space_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) removeSpace found at address 0x%llX (0x%llx)", baseaddr, remove_space_addr, remove_space_addr - baseaddr);
#ifdef __x86_64__
        remove_space_fp = remove_space_addr;
#elif __arm64__
        remove_space_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) remove_space_addr, ptrauth_key_asia, 0);
#endif
    }

    uint64_t move_space_addr = hex_find_seq(baseaddr + get_move_space_offset(os_version), get_move_space_pattern(os_version));
    if (move_space_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to moveSpace function..");
        move_space_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) moveSpace found at address 0x%llX (0x%llx)", baseaddr, move_space_addr, move_space_addr - baseaddr);
#ifdef __x86_64__
        move_space_fp = move_space_addr;
#elif __arm64__
        move_space_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) move_space_addr, ptrauth_key_asia, 0);
#endif
    }

    uint64_t set_front_window_addr = hex_find_seq(baseaddr + get_set_front_window_offset(os_version), get_set_front_window_pattern(os_version));
    if (set_front_window_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to setFrontWindow function..");
        set_front_window_fp = 0;
    } else {
        NSLog(@"[yabai-sa] (0x%llx) setFrontWindow found at address 0x%llX (0x%llx)", baseaddr, set_front_window_addr, set_front_window_addr - baseaddr);
#ifdef __x86_64__
        set_front_window_fp = set_front_window_addr;
#elif __arm64__
        set_front_window_fp = (uint64_t) ptrauth_sign_unauthenticated((void *) set_front_window_addr, ptrauth_key_asia, 0);
#endif
    }

    animation_time_addr = hex_find_seq(baseaddr + get_fix_animation_offset(os_version), get_fix_animation_pattern(os_version));
    if (animation_time_addr == 0x0) {
        NSLog(@"[yabai-sa] failed to get pointer to animation-time..");
    } else {
        NSLog(@"[yabai-sa] (0x%llx) animation_time_addr found at address 0x%llX (0x%llx)", baseaddr, animation_time_addr, animation_time_addr - baseaddr);
        if (vm_protect(mach_task_self(), page_align(animation_time_addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
#ifdef __x86_64__
            *(uint64_t *) animation_time_addr = 0x660fefc0660fefc0;
#elif __arm64__
            *(uint32_t *) animation_time_addr = 0x2f00e400;
#endif
            vm_protect(mach_task_self(), page_align(animation_time_addr), vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
        } else {
            NSLog(@"[yabai-sa] animation_time_addr vm_protect failed; unable to patch instruction!");
        }
    }

    // MC-5b: swizzle -[WVExpose animationDuration] (DockCore) so we can zero MC's
    // enter/exit tween on demand (layout oracle + native-animation off-switch).
    Class WVExpose = objc_getClass("WVExpose");
    if (!WVExpose) WVExpose = objc_getClass("_TtC8DockCore8WVExpose");
    if (WVExpose) {
        Method m = class_getInstanceMethod(WVExpose, @selector(animationDuration));
        if (m) {
            orig_WVExpose_animationDuration = (double (*)(id, SEL))method_setImplementation(m, (IMP)hook_WVExpose_animationDuration);
            NSLog(@"[yabai-sa] hooked -[WVExpose animationDuration]");
        } else {
            NSLog(@"[yabai-sa] WVExpose has no -animationDuration; expose-duration override disabled");
        }
    } else {
        NSLog(@"[yabai-sa] WVExpose class not found; expose-duration override disabled");
    }
}

static inline id get_ivar_value(id instance, const char *name)
{
    id result = nil;
    object_getInstanceVariable(instance, name, (void **) &result);
    return result;
}

static inline void set_ivar_value(id instance, const char *name, id value)
{
    object_setInstanceVariable(instance, name, value);
}

static inline uint64_t get_space_id(id space)
{
    return ((uint64_t (*)(id, SEL)) objc_msgSend)(space, @selector(spid));
}

static inline id space_for_display_with_id(CFStringRef display_uuid, uint64_t space_id)
{
    NSArray *spaces_for_display = ((NSArray *(*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(spacesForDisplay:), display_uuid);
    for (id space in spaces_for_display) {
        if (space_id == get_space_id(space)) {
            return space;
        }
    }
    return nil;
}

static inline id display_space_for_display_uuid(CFStringRef display_uuid)
{
    id result = nil;

    NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
    if (display_spaces != nil) {
        for (id display_space in display_spaces) {
            id display_source_space = get_ivar_value(display_space, "_currentSpace");
            uint64_t sid = get_space_id(display_source_space);
            CFStringRef uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), sid);
            bool match = CFEqual(uuid, display_uuid);
            CFRelease(uuid);
            if (match) {
                result = display_space;
                break;
            }
        }
    }

    return result;
}

static inline id display_space_for_space_with_id(uint64_t space_id)
{
    NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
    if (display_spaces != nil) {
        for (id display_space in display_spaces) {
            id display_source_space = get_ivar_value(display_space, "_currentSpace");
            if (get_space_id(display_source_space) == space_id) {
                return display_space;
            }
        }
    }
    return nil;
}

// Mark Dock's in-process Spaces model stale by ivar NAME (robust; no byte-pattern).
// A server-side space op (SLSSpaceCreate / op-0x80 move / SLSSpaceDestroy) changes
// the WindowServer but not Dock's model. Called only for the wallpaper cases: the
// `wallpaper` flag sets _needToUpdateDesktopPicture, which handleDisplayReconfig's
// wallpaper branch is gated on, so a brand-new space (create) or a display-changed
// space (cross-display move) renders its desktop picture. The strip itself rebuilds
// unconditionally in handleDisplayReconfig and needs no poke. Runs on the main queue
// to match Dock's space-change path. See project_spaces_handle_display_reconfig_non_mc_resync.
static void payload_mark_spaces_dirty(bool wallpaper)
{
    if (dock_spaces == nil) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        Class cls = object_getClass(dock_spaces);
        Ivar iv = class_getInstanceVariable(cls, "_needToUpdateSpaces");
        if (iv) *((uint8_t *)dock_spaces + ivar_getOffset(iv)) = 1;
        if (wallpaper) {
            Ivar wv = class_getInstanceVariable(cls, "_needToUpdateDesktopPicture");
            if (wv) *((uint8_t *)dock_spaces + ivar_getOffset(wv)) = 1;
        }
    });
}

// Rebuild Dock's Mission-Control strip after a byte-pattern-free server-side space op
// by invoking the named @objc -[Spaces handleDisplayReconfig]. This is a NON-Mission-
// Control rebuild path: it reaches Dock's per-display rebuild helper directly, without a
// WVExpose MC enter->exit cycle. Pure @objc, respondsToSelector-guarded so an OS rename
// degrades to a no-op instead of a crash, run on the main queue to match Dock's own
// space-change path. handleDisplayReconfig rebuilds the strip UNCONDITIONALLY (not gated
// on _needToUpdateSpaces); its only internal gate defers the rebuild while a space switch
// is mid-flight, which never trips here since every daemon caller rejects MC-active.
// See project_spaces_handle_display_reconfig_non_mc_resync.
static void payload_spaces_reconfig(void)
{
    if (dock_spaces == nil) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        SEL sel = sel_registerName("handleDisplayReconfig");
        if ([dock_spaces respondsToSelector:sel])
            ((void (*)(id, SEL))objc_msgSend)(dock_spaces, sel);
    });
}

// SA_OPCODE_SPACES_RECONFIG handler — no wire payload. Rebuilds the MC strip via
// handleDisplayReconfig; the daemon (space_manager_dock_rebuild_strip) fires this after a
// byte-pattern-free server-side create / move / destroy.
static void do_spaces_reconfig(char *message)
{
    (void)message;
    payload_spaces_reconfig();
}

// Async identity-Transform3D pin: re-commit identity SLSTransactionSetWindowTransform3D
// on `wids` from the Dock cid every ~1ms for dur_ms, so our identity is the last writer
// before each refresh and any residual MC scale-toward-grid nudge never lands. Copies
// wids — the async loop outlives the caller's buffer. Foreign-window T3D needs the
// universal-owner (Dock) cid; no autorelease pool on this path, so CF types only.
static void payload_pin_windows(uint32_t *wids, uint32_t count, uint32_t dur_ms)
{
    if (count == 0 || dur_ms == 0) return;
    if (count > 256) count = 256;
    uint32_t *copy = malloc(sizeof(uint32_t) * count);
    if (!copy) return;
    memcpy(copy, wids, sizeof(uint32_t) * count);
    int cid = SLSMainConnectionID();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        static const double IDENTITY3D[16] = { 1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1 };
        for (uint32_t k = 0; k < dur_ms; k++) {
            CFTypeRef txn = SLSTransactionCreate(cid);
            if (txn) {
                for (uint32_t i = 0; i < count; i++)
                    SLSTransactionSetWindowTransform3D(txn, copy[i], (double *)IDENTITY3D);
                SLSTransactionCommit(txn, 1);
                CFRelease(txn);
            }
            usleep(1000);
        }
        free(copy);
    });
}

// SA_OPCODE_PIN_WINDOWS handler. Wire: [u32 dur_ms][u32 count][u32 wids[count]].
static void do_pin_windows(char *message)
{
    uint32_t dur_ms, count;
    unpack(dur_ms);
    unpack(count);
    if (count > 256) count = 256;
    uint32_t *wids = malloc(sizeof(uint32_t) * (count ? count : 1));
    if (!wids) return;
    for (uint32_t i = 0; i < count; i++) { uint32_t w = 0; unpack(w); wids[i] = w; }
    payload_pin_windows(wids, count, dur_ms);
    free(wids);
}

static void do_space_move(char *message)
{
    if (dock_spaces == nil) return;

    uint64_t source_space_id, dest_space_id, source_prev_space_id;
    unpack(source_space_id);
    unpack(dest_space_id);
    unpack(source_prev_space_id);

    bool focus_dest_space;
    unpack(focus_dest_space);

    int cid = SLSMainConnectionID();

    CFStringRef source_display_uuid = SLSCopyManagedDisplayForSpace(cid, source_space_id);
    id source_space = space_for_display_with_id(source_display_uuid, source_space_id);
    id source_display_space = display_space_for_display_uuid(source_display_uuid);

    CFStringRef dest_display_uuid = SLSCopyManagedDisplayForSpace(cid, dest_space_id);
    id dest_space = space_for_display_with_id(dest_display_uuid, dest_space_id);
    unsigned dest_display_id = ((unsigned (*)(id, SEL, id)) objc_msgSend)(dock_spaces, @selector(displayIDForSpace:), dest_space);
    id dest_display_space = display_space_for_display_uuid(dest_display_uuid);

    bool cross_display = source_display_uuid && dest_display_uuid && !CFEqual(source_display_uuid, dest_display_uuid);

    if (source_prev_space_id) {
        NSArray *ns_source_space = @[ @(source_space_id) ];
        NSArray *ns_dest_space = @[ @(source_prev_space_id) ];
        id new_source_space = space_for_display_with_id(source_display_uuid, source_prev_space_id);
        SLSShowSpaces(cid, (__bridge CFArrayRef) ns_dest_space);
        SLSHideSpaces(cid, (__bridge CFArrayRef) ns_source_space);
        SLSManagedDisplaySetCurrentSpace(cid, source_display_uuid, source_prev_space_id);
        set_ivar_value(source_display_space, "_currentSpace", [new_source_space retain]);
        [ns_dest_space release];
        [ns_source_space release];
    }

    // Byte-pattern-free move (primary): op-0x80 places source after dest on dest's display
    // (same display UUID = reorder; different = cross-display). Replaces the asm moveSpace.
    bool moved = false;
    CFTypeRef txn = SLSTransactionCreate(cid);
    if (txn) {
        SLSTransactionMoveManagedSpaceToDisplayAfterSpace(txn, source_space_id, dest_display_uuid, dest_space_id);
        SLSTransactionCommit(txn, 1);
        CFRelease(txn);
        moved = true;
    } else if (move_space_fp) {
        asm__call_move_space(source_space, dest_space, dest_display_uuid, dock_spaces, move_space_fp);
        moved = true;
    }

    // Cross-display only: the wallpaper association must follow to the dest display. Prefer the
    // byte-pattern-free _needToUpdateDesktopPicture dirty (set below); also drive the Dock
    // desktop-picture-manager mover if its pattern resolved (belt-and-suspenders).
    if (moved && cross_display && dp_desktop_picture_manager != nil) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            ((void (*)(id, SEL, id, unsigned, CFStringRef)) objc_msgSend)(dp_desktop_picture_manager, @selector(moveSpace:toDisplay:displayUUID:), source_space, dest_display_id, dest_display_uuid);
        });
    }

    if (focus_dest_space) {
        uint64_t new_source_space_id = SLSManagedDisplayGetCurrentSpace(cid, source_display_uuid);
        id new_source_space = space_for_display_with_id(source_display_uuid, new_source_space_id);
        set_ivar_value(source_display_space, "_currentSpace", [new_source_space retain]);

        NSArray *ns_dest_monitor_space = @[ @(dest_space_id) ];
        SLSHideSpaces(cid, (__bridge CFArrayRef) ns_dest_monitor_space);
        SLSManagedDisplaySetCurrentSpace(cid, dest_display_uuid, source_space_id);
        set_ivar_value(dest_display_space, "_currentSpace", [source_space retain]);
        [ns_dest_monitor_space release];
    }

    // The daemon rebuilds the MC strip via handleDisplayReconfig after this returns; that path
    // needs no _needToUpdateSpaces poke, so no strip dirty here. BUT a cross-display move changes
    // the space's display and thus its wallpaper — keep the byte-pattern-free
    // _needToUpdateDesktopPicture dirty so reconfig's wallpaper branch runs (belt-and-suspenders
    // with the dp_desktop_picture_manager mover above). Same-display reorder changes no wallpaper.
    if (cross_display) payload_mark_spaces_dirty(true);

    CFRelease(source_display_uuid);
    CFRelease(dest_display_uuid);
}

static void do_space_destroy(char *message)
{
    if (dock_spaces == nil) return;

    uint64_t space_id, dest_space_id;
    unpack(space_id);
    unpack(dest_space_id);

    int cid = SLSMainConnectionID();

    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(cid, space_id);
    if (!display_uuid) return;

    id display_space = display_space_for_display_uuid(display_uuid);
    uint64_t active_space_id = SLSManagedDisplayGetCurrentSpace(cid, display_uuid);

    // If the doomed space is the display's visible space, switch the display to the
    // destination FIRST (mirror do_space_move's source pre-switch) so the display never
    // shows a destroyed space. The daemon already migrated the doomed space's windows to
    // dest_space_id before this call.
    if (active_space_id == space_id && dest_space_id) {
        NSArray *ns_doomed = @[ @(space_id) ];
        NSArray *ns_dest   = @[ @(dest_space_id) ];
        id new_current = space_for_display_with_id(display_uuid, dest_space_id);
        SLSShowSpaces(cid, (__bridge CFArrayRef) ns_dest);
        SLSHideSpaces(cid, (__bridge CFArrayRef) ns_doomed);
        SLSManagedDisplaySetCurrentSpace(cid, display_uuid, dest_space_id);
        set_ivar_value(display_space, "_currentSpace", [new_current retain]);
        [ns_dest release];
        [ns_doomed release];
    }

    // Byte-pattern-free destroy (primary): the named SLS export tears down the managed Space
    // server-side. SLSSpaceDestroy is void + async with no fallback signal, but it's the same
    // Dock-cid bridged family as SLSSpaceCreate / op-0x80 move, so it replaces the asm removeSpace
    // that breaks on Dock updates (#2799). It does NOT migrate windows — the daemon moved them off
    // space_id first so they aren't orphaned.
    SLSSpaceDestroy(cid, space_id);

    // No dirty poke: the daemon rebuilds the MC strip via handleDisplayReconfig after this
    // returns, and that path rebuilds unconditionally. The surviving spaces' wallpapers are
    // unchanged (windows were pre-migrated to dest_space_id, and the display was pre-switched
    // there above), so no _needToUpdateDesktopPicture poke either.

    CFRelease(display_uuid);
}

static void do_space_create(char *message)
{
    if (dock_spaces == nil) return;

    uint64_t space_id;
    unpack(space_id);

    int cid = SLSMainConnectionID();

    // Byte-pattern-free path (primary): mint a managed Space via the named SLS export,
    // bound to the reference space's display, reset its menubar, then dirty Dock's model.
    // The daemon rebuilds the MC strip via handleDisplayReconfig after this returns. The
    // _needToUpdateDesktopPicture dirty (via mark_spaces_dirty true) is what a BRAND-NEW space
    // needs so reconfig's wallpaper branch renders its desktop picture (the strip itself rebuilds
    // unconditionally). This survives Dock updates; the legacy asm addSpace below does not (#2799).
    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(cid, space_id);
    if (display_uuid) {
        CFMutableDictionaryRef values = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int32_t type = 0; // SLS_SPACE_USER
        CFNumberRef type_num = CFNumberCreate(NULL, kCFNumberSInt32Type, &type);
        CFDictionarySetValue(values, CFSTR("type"), type_num);
        CFDictionarySetValue(values, kCGSPackagesDisplayIdentifierKey, display_uuid);

        uint64_t new_sid = SLSSpaceCreate(cid, 0, values);

        CFRelease(type_num);
        CFRelease(values);

        if (new_sid) {
            SLSSpaceResetMenuBar(cid, new_sid);
            payload_mark_spaces_dirty(true);   // spaces + wallpaper
            CFRelease(display_uuid);
            return;
        }
        CFRelease(display_uuid);
    }

    // Legacy fallback: Dock-internal addSpace via byte-pattern (breaks on Dock updates, #2799).
    // Only reached if SLSSpaceCreate failed AND the pattern resolved.
    if (add_space_fp == 0) return;
    dispatch_sync(dispatch_get_main_queue(), ^{
        CFStringRef du = SLSCopyManagedDisplayForSpace(cid, space_id);
        id new_space = macOSSequoia
                     ? [[objc_getClass("ManagedSpace") alloc] init]
                     : [[objc_getClass("Dock.ManagedSpace") alloc] init];
        id display_space = display_space_for_display_uuid(du);
        asm__call_add_space(new_space, display_space, add_space_fp);
        if (du) CFRelease(du);
    });
}

static void do_space_focus(char *message)
{
    if (dock_spaces == nil) return;

    uint64_t dest_space_id;
    unpack(dest_space_id);

    if (dest_space_id) {
        CFStringRef dest_display = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
        id source_space = macOSSequoia
                        ? ((id (*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(currentSpaceForDisplayUUID:), dest_display)
                        : ((id (*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(currentSpaceforDisplayUUID:), dest_display);
        uint64_t source_space_id = get_space_id(source_space);

        if (source_space_id != dest_space_id) {
            id dest_space = space_for_display_with_id(dest_display, dest_space_id);
            if (dest_space != nil) {
                id display_space = display_space_for_space_with_id(source_space_id);
                if (display_space != nil) {
                    NSArray *ns_source_space = @[ @(source_space_id) ];
                    NSArray *ns_dest_space = @[ @(dest_space_id) ];
                    SLSShowSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_dest_space);
                    SLSHideSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_source_space);
                    SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), dest_display, dest_space_id);
                    set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
                    [ns_dest_space release];
                    [ns_source_space release];
                }
            }
        }

        CFRelease(dest_display);
    }
}

// SPA-17: the cross-fade seed parks the focus ring before its collect snapshot
// so the ring can ride the slide as a geo-only rider. The park helper lives in
// payload_inc/focus_ring.inc.m (included later in this TU), so forward-declare it
// here — same hoist pattern as the deathwatch helper above.
uint32_t payload_focus_ring_park_for_slide(int cid, uint32_t target_wid,
                                           CGRect rect, float radius, uint64_t sid);
// SPA-21: same hoist for the exit-ride adopt — the seed hands the OUTGOING
// space's live ring to the slide so it rides off with the exiting windows.
uint32_t payload_focus_ring_adopt_for_exit(uint64_t out_sid);

#include "payload_inc/space_animation.inc.m"

static void do_window_scale(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    CGRect frame = {};
    SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame);
    CGAffineTransform original_transform = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);

    CGAffineTransform current_transform;
    SLSGetWindowTransform(SLSMainConnectionID(), wid, &current_transform);

    if (CGAffineTransformEqualToTransform(current_transform, original_transform)) {
        float dx, dy, dw, dh;
        unpack(dx);
        unpack(dy);
        unpack(dw);
        unpack(dh);

        int target_width  = dw / 4;
        int target_height = target_width / (frame.size.width/frame.size.height);

        float x_scale = frame.size.width/target_width;
        float y_scale = frame.size.height/target_height;

        CGFloat transformed_x = -(dx+dw) + (frame.size.width * (1/x_scale));
        CGFloat transformed_y = -dy;

        CGAffineTransform scale = CGAffineTransformConcat(CGAffineTransformIdentity, CGAffineTransformMakeScale(x_scale, y_scale));
        CGAffineTransform transform = CGAffineTransformTranslate(scale, transformed_x, transformed_y);
        SLSSetWindowTransform(SLSMainConnectionID(), wid, transform);
    } else {
        SLSSetWindowTransform(SLSMainConnectionID(), wid, original_transform);
    }
}

static void do_window_move(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    int x, y;
    unpack(x);
    unpack(y);

    CGPoint point = CGPointMake(x, y);
    SLSMoveWindowWithGroup(SLSMainConnectionID(), wid, &point);

    NSArray *window_list = @[ @(wid) ];
    SLSReassociateWindowsSpacesByGeometry(SLSMainConnectionID(), (__bridge CFArrayRef) window_list);
    [window_list release];
}

static void do_window_opacity(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    float alpha;
    unpack(alpha);

    pthread_mutex_lock(&window_fade_lock);
    struct window_fade_context *context = table_find(&window_fade_table, &wid);

    if (context) {
        context->alpha = alpha;
        context->duration = 0.0f;
        __asm__ __volatile__ ("" ::: "memory");

        context->skip = true;
        pthread_mutex_unlock(&window_fade_lock);
    } else {
        SLSSetWindowAlpha(SLSMainConnectionID(), wid, alpha);
        pthread_mutex_unlock(&window_fade_lock);
    }
}

static void *window_fade_thread_proc(void *data)
{
entry:;
    struct window_fade_context *context = (struct window_fade_context *) data;
    context->skip  = false;

    float start_alpha;
    float end_alpha = context->alpha;
    SLSGetWindowAlpha(SLSMainConnectionID(), context->wid, &start_alpha);

    int frame_duration = 8;
    int total_duration = (int)(context->duration * 1000.0f);
    int frame_count = (int)(((float) total_duration / (float) frame_duration) + 1.0f);

    for (int frame_index = 1; frame_index <= frame_count; ++frame_index) {
        if (context->skip) goto entry;

        float t = (float) frame_index / (float) frame_count;
        if (t < 0.0f) t = 0.0f;
        if (t > 1.0f) t = 1.0f;

        float alpha = lerp(start_alpha, t, end_alpha);
        SLSSetWindowAlpha(SLSMainConnectionID(), context->wid, alpha);

        usleep(frame_duration*1000);
    }

    pthread_mutex_lock(&window_fade_lock);
    if (!context->skip) {
        table_remove(&window_fade_table, &context->wid);
        pthread_mutex_unlock(&window_fade_lock);
        free(context);
        return NULL;
    }
    pthread_mutex_unlock(&window_fade_lock);

    goto entry;
}

static void do_window_opacity_fade(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    float alpha, duration;
    unpack(alpha);
    unpack(duration);

    pthread_mutex_lock(&window_fade_lock);
    struct window_fade_context *context = table_find(&window_fade_table, &wid);

    if (context) {
        context->alpha = alpha;
        context->duration = duration;
        __asm__ __volatile__ ("" ::: "memory");

        context->skip = true;
        pthread_mutex_unlock(&window_fade_lock);
    } else {
        context = malloc(sizeof(struct window_fade_context));
        context->wid = wid;
        context->alpha = alpha;
        context->duration = duration;
        context->skip = false;
        __asm__ __volatile__ ("" ::: "memory");

        table_add(&window_fade_table, &wid, context);
        pthread_mutex_unlock(&window_fade_lock);
        pthread_create(&context->thread, NULL, &window_fade_thread_proc, context);
        pthread_detach(context->thread);
    }
}

static void do_window_layer(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    int layer;
    unpack(layer);

    int sub = CGWindowLevelForKey(layer);
    SLSSetWindowSubLevel(SLSMainConnectionID(), wid, sub);
    deathwatch_record(wid, sub);
}

// Sticky stashes the window's original level in a custom property so un-sticky
// can restore it, instead of blindly resetting to level 0 (which silently
// demoted windows that legitimately lived above the normal layer, e.g. floating
// panels). The property is written and read from Dock's cid (this payload), so it
// persists and is readable here — same connection-scoped visibility as stage_id;
// see do_window_set_stage_id_property.
static void do_window_sticky(char *message)
{
    extern CGError SLSGetWindowLevel(int cid, uint32_t wid, int *level);
    extern CGError SLSSetWindowProperty(int cid, uint32_t wid, CFStringRef property, CFTypeRef value);

    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    bool value;
    unpack(value);

    int cid = SLSMainConnectionID();
    uint64_t sticky_tag = (1ULL << 11); // kCGSOnAllWorkspacesTagBit — identity bit
    // Companion bits set/cleared in lockstep with sticky so the window survives
    // app-deactivation hide and is left alone by Mission Control:
    //   bit 24 — kCGSDontHideTagBit
    //   bit 38 — kCGSIgnoreForExposeTagBit            (don't animate during MC; cf. 49)
    //   bit 49 — kCGSIgnoresWorkspaceHeuristicsTagBit
    uint64_t tag_mask = (1ULL << 11) | (1ULL << 24) | (1ULL << 38) | (1ULL << 49);
    CFStringRef level_key = CFSTR("com.koekeishiya.yabai.sticky_level.v1");

    // Server truth: is the sticky tag already set? Guards both edges against
    // double-apply — a redundant enable must not overwrite the saved level
    // with 21.
    uint64_t tags = 0;
    SLSGetWindowTags(cid, wid, &tags, 64);
    bool currently_sticky = (tags & sticky_tag) != 0;

    if (value == 1) {
        if (!currently_sticky) {
            int level = 0;
            SLSGetWindowLevel(cid, wid, &level);
            CFNumberRef num = CFNumberCreate(NULL, kCFNumberIntType, &level);
            if (num) {
                SLSSetWindowProperty(cid, wid, level_key, num);
                CFRelease(num);
            }
            SLSSetWindowTags(cid, wid, &tag_mask, 64);
        }
        SLSSetWindowLevel(cid, wid, 21);
    } else {
        // Restore the stashed level; fall back to 0 if it's missing (window
        // made sticky by an older build that didn't record it).
        int level = 0;
        CFTypeRef stored = NULL;
        if (SLSCopyWindowProperty(cid, wid, level_key, &stored) == kCGErrorSuccess &&
            stored && CFGetTypeID(stored) == CFNumberGetTypeID()) {
            CFNumberGetValue((CFNumberRef)stored, kCFNumberIntType, &level);
        }
        if (stored) CFRelease(stored);

        SLSClearWindowTags(cid, wid, &tag_mask, 64);
        SLSSetWindowLevel(cid, wid, level);
    }
}

typedef void (*focus_window_call)(ProcessSerialNumber psn, uint32_t wid);
static void do_window_focus(char *message)
{
    if (set_front_window_fp == 0) return;

    int window_connection;
    ProcessSerialNumber window_psn;

    uint32_t wid;
    unpack(wid);

    SLSGetWindowOwner(SLSMainConnectionID(), wid, &window_connection);
    SLSGetConnectionPSN(window_connection, &window_psn);

    ((focus_window_call) set_front_window_fp)(window_psn, wid);
}

static void do_window_shadow(char *message)
{
    uint32_t wid;
    unpack(wid);
    if (!wid) return;

    bool value;
    unpack(value);

    uint64_t tags = (1 << 3);
    if (value == 1) {
        SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    } else {
        SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    }
}

static void do_window_swap_proxy_in(char *message)
{
    int count = 0;
    unpack(count);
    if (!count) return;

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) return;
    for (int i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;

        uint32_t proxy_wid;
        unpack(proxy_wid);

        SLSTransactionOrderWindowGroup(transaction, proxy_wid, 1, wid);
        SLSTransactionSetWindowSystemAlpha(transaction, wid, 0);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_swap_proxy_out(char *message)
{
    int count = 0;
    unpack(count);
    if (!count) return;

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) return;
    for (int i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;

        uint32_t proxy_wid;
        unpack(proxy_wid);

        SLSTransactionSetWindowSystemAlpha(transaction, wid, 1.0f);
        SLSTransactionOrderWindowGroup(transaction, proxy_wid, 0, wid);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

static void do_window_order(char *message)
{
    uint32_t a_wid;
    unpack(a_wid);
    if (!a_wid) return;

    int order;
    unpack(order);

    uint32_t b_wid;
    unpack(b_wid);

    SLSOrderWindow(SLSMainConnectionID(), a_wid, order, b_wid);
}

static void do_window_order_in(char *message)
{
    int count = 0;
    unpack(count);
    if (!count) return;

    CFTypeRef transaction = SLSTransactionCreate(SLSMainConnectionID());
    if (!transaction) return;
    for (int i = 0; i < count; ++i) {
        uint32_t wid;
        unpack(wid);
        if (!wid) continue;

        SLSTransactionOrderWindowGroup(transaction, wid, 1, 0);
    }
    SLSTransactionCommit(transaction, 0);
    CFRelease(transaction);
}

// Move a list of windows to a managed space (from inside Dock).
static void do_window_list_move_to_space(char *message)
{
    uint64_t sid;
    unpack(sid);

    int count = 0;
    unpack(count);

    CFArrayRef window_list_ref = cfarray_of_cfnumbers((uint32_t*)message, sizeof(uint32_t), count, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list_ref, sid);
    CFRelease(window_list_ref);
}

static void do_window_move_to_space(char *message)
{
    uint64_t sid;
    unpack(sid);

    uint32_t wid;
    unpack(wid);

    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&wid, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), window_list_ref, sid);
    CFRelease(window_list_ref);
}


// Shared typedef + externs for SkyLight's hardware capture stream API.
// Hoisted to file scope so multiple test handlers can reference the same
// SLDisplayStreamRef type (function-local typedefs aliasing the same struct
// produce distinct types from the compiler's perspective and conflict on
// the extern signatures below).
typedef struct __CGDisplayStream *SLDisplayStreamRef;
typedef void (^SLFrameHandler)(int status, uint64_t displayTime,
                               IOSurfaceRef surface, CFTypeRef updateRef);
extern SLDisplayStreamRef SLSHWCaptureStreamCreateWithWindow(
    uint32_t wid, int opts, CFDictionaryRef props,
    dispatch_queue_t queue, SLFrameHandler handler);
extern CGError SLDisplayStreamStart(SLDisplayStreamRef stream);
extern CGError SLDisplayStreamStop(SLDisplayStreamRef stream);


// probe_sls_input_notify — SLSRegisterNotifyProc probe for a single event code,
// from Dock's cid. SPI behavior: _SLSRegisterNotifyProc accepts registration for
// any type < 0x5DE without further gating, but the dispatch side
// (ServerNotifier::invoke_callbacks) only delivers the types some caller actually
// posts via post_notification. The kCGSEventNotification<CGEventType> range
// (0x2C6..0x2EE) is declared but no observed emitter publishes it — input events
// flow through _CGXFilterEvent / the event-tap chain instead.
//
// Registers ONE notify proc per run (one clean experiment per invocation). The
// callback logs the `type` arg it receives, so dispatchers that ignore the
// registered type and broadcast to all listeners are visible.
//
// Wire format (must match the daemon-side packed struct in test_events.m):
//   uint32_t event_code     — required; type passed to SLSRegisterNotifyProc
//   uint32_t duration_ms    — optional; observation window, default 10000

static _Atomic(int) g_probe_notify_count;
static uint32_t     g_probe_notify_expected;
static int          g_probe_notify_expected_ctx;  // cid we passed as ctx


// Schedules `steps + 1` keyframes of SLSTransactionSetSpaceTransform along
// `envelope(t)` (t∈[0,1], expected to be 0 at the endpoints), then a final
// identity commit at `dur_ms + 50ms` with options=0x01000000 — SkyLight's own
// resetSpaceTransform flag — guaranteeing the space lands flat even if the
// envelope leaves a small residual.
//
// Callers own the response. This helper only kicks off the async work.
//
// `steps` is supplied by the daemon side, which sizes it from the destination
// display's refresh rate (~one keyframe per VBL).
static void payload_animate_space_transform(int cid,
                                            uint64_t sid,
                                            double dx,
                                            double dy,
                                            uint32_t dur_ms,
                                            int steps,
                                            double (^envelope)(double t))
{
    if (steps < 2) steps = 2;
    dispatch_queue_t main_q = dispatch_get_main_queue();
    for (int i = 0; i <= steps; i++) {
        double t = (double)i / (double)steps;
        double e = envelope(t);
        double cur_dx = dx * e;
        double cur_dy = dy * e;
        int64_t delay_ns = (int64_t)(t * (double)dur_ms * 1e6);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay_ns),
                       main_q, ^{
            CGAffineTransform xf = { 1.0, 0.0, 0.0, 1.0, cur_dx, cur_dy };
            CFTypeRef tx = SLSTransactionCreate(cid);
            if (tx) {   // NULL: skip this step
                SLSTransactionSetSpaceTransform(tx, sid, 0, &xf);
                SLSTransactionCommit(tx, 0);
                CFRelease(tx);
            }
        });
    }
    int64_t commit_ns = (int64_t)((double)dur_ms * 1e6) + 50 * 1000000;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, commit_ns), main_q, ^{
        CGAffineTransform identity = { 1.0, 0.0, 0.0, 1.0, 0.0, 0.0 };
        CFTypeRef tx = SLSTransactionCreate(cid);
        if (tx) {
            SLSTransactionSetSpaceTransform(tx, sid, SLS_SPACE_TRANSFORM_CLEAR_STATE, &identity);
            SLSTransactionCommit(tx, 0);
            CFRelease(tx);
        }
    });
}

// Reusable 1-D damped-spring integrator (pure math, no SLS). Included before
// the experimental handlers / tests so any of them can drive animated scalars.
// See payload_inc/payload_spring_physics.inc.m.
#include "payload_inc/payload_spring_physics.inc.m"

// LockedBounds + Transform3D geometry primitives — the per-frame write path
// behind smooth window move/resize (the core feature). Must precede focus_ring
// (forward-decl resolve) and tests (test arms call do_window_lockedbounds_batch).
// See payload_inc/window_transform.inc.m.
#include "payload_inc/window_transform.inc.m"

// displaylink_ca.inc.m (SPA-6 CADisplayLink clock) — generic clock primitive
// (takes a C tick callback) that drives the CA animation pump; included before
// the animators (anim / window_transform) that call ca_clock_*.
#include "payload_inc/displaylink_ca.inc.m"
// Payload-CA LB+T3D animator (Branch B) — needs ca_clock_* (displaylink_ca) and
// the shared jitter metrics; defines do_anim_ax_begin for dispatch below.
#include "payload_inc/payload_anim_metrics.inc.m"
#include "payload_inc/payload_ax.inc.m"
#include "payload_inc/warp_mesh.inc.m"   // shared 9-slice builder: jello-policy animator (anim) + warp cover
#include "payload_inc/anim.inc.m"
#include "payload_inc/warp_cover.inc.m"

// MC-exit ring ride: string-xref resolver for the unexported _CGSGetWindowTransform3D
// (dlsym-null in-process). Must precede focus_ring.inc.m (its mirror calls the reader).
#include "payload_inc/cgs_transform3d.inc.m"

// Production focus_ring overlay (experimental) — payload-side state, slot
// table, three SA opcode handlers, and the SLS-visibility/event-driven
// redraw paths. See payload_inc/focus_ring.inc.m.
#include "payload_inc/focus_ring.inc.m"

// multi_display_edge_guard nudge animator (SA_OPCODE_SPACE_NUDGE).
// See payload_inc/edge_guard.inc.m.
#include "payload_inc/edge_guard.inc.m"


// SkyLight exports these as `_SLS…` at the linker level; the C declaration
// drops the leading underscore so the compiler re-adds it. The SA bundle
// doesn't ship misc/extern.h so we declare them here.
extern CGError SLSSetFrontProcessWithInfo(ProcessSerialNumber *psn, uint32_t wid, uint32_t options, CFDictionaryRef info);
extern CGError SLSSetFrontWindow(int cid, uint32_t wid);
extern CGError SLSSetWindowHasKeyAppearance(int cid, uint32_t wid, bool has_key);
extern CGError SLSOrderFrontConditionally(int cid, uint32_t wid, int flag);
extern CGError SLSSpaceSetFrontPSN(int cid, uint64_t sid, uint64_t psn_packed);
extern CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
// LaunchServices private — see src/misc/extern.h for the full annotation.
extern int _LSSetFrontApplicationLong(int sessionID, uint32_t asn_high, uint32_t asn_low, CFDictionaryRef options);
extern CFTypeRef _LSASNCreateWithPid(CFAllocatorRef alloc, pid_t pid);
extern Boolean _LSASNExtractHighAndLowParts(CFTypeRef asn, uint32_t *high_out, uint32_t *low_out);
// LS-fwd→SkyLight stub used by LSD's makeApplicationFrontmost. Same signature
// as _SLPSSetFrontProcessWithOptions; empirically untested whether alias or sibling.
extern CGError _CPSSetFrontProcessWithOptions(ProcessSerialNumber *psn, uint32_t wid, uint32_t opts);
// _LSOrderApplications — XPC msg 0x398. Different server handler than
// _LSSetFrontApplicationLong (msg 0x38e).
extern int _LSOrderApplications(int sessionID, CFArrayRef order, CFTypeRef after);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);


static void do_handshake(int sockfd)
{
    uint32_t attrib = 0;

    if (dock_spaces != nil)                attrib |= OSAX_ATTRIB_DOCK_SPACES;
    if (dp_desktop_picture_manager != nil) attrib |= OSAX_ATTRIB_DPPM;
    if (add_space_fp)                      attrib |= OSAX_ATTRIB_ADD_SPACE;
    if (remove_space_fp)                   attrib |= OSAX_ATTRIB_REM_SPACE;
    if (move_space_fp)                     attrib |= OSAX_ATTRIB_MOV_SPACE;
    if (set_front_window_fp)               attrib |= OSAX_ATTRIB_SET_WINDOW;
    if (animation_time_addr)               attrib |= OSAX_ATTRIB_ANIM_TIME;

    char bytes[BUFSIZ] = {};
    int version_length = strlen(OSAX_VERSION);
    int attrib_length = sizeof(uint32_t);
    int bytes_length = version_length + 1 + attrib_length;

    memcpy(bytes, OSAX_VERSION, version_length);
    memcpy(bytes + version_length + 1, &attrib, attrib_length);
    bytes[version_length] = '\0';
    bytes[bytes_length] = '\n';

    send(sockfd, bytes, bytes_length+1, 0);
}

static void handle_message(int sockfd, char *message, int length)
{
    // AC-9 cursor-end guard: `length` is the body byte count (opcode + fields)
    // from read_message. Stash one-past-end so unpack can reject reads that walk
    // off the message — the signature of a daemon/payload field-list desync.
    g_unpack_end      = message + length;
    g_unpack_overflow = false;

    // Wire format is a single opcode byte. Typed as uint8_t (not enum
    // sa_opcode) so the dispatch switch's experimental #define cases don't trip
    // -Wswitch — the enum is intentionally upstream-shaped (see common.h).
    uint8_t op = *message++;
    switch (op) {
    case SA_OPCODE_HANDSHAKE: {
        do_handshake(sockfd);
    } break;
    case SA_OPCODE_SPACE_FOCUS: {
        do_space_focus(message);
    } break;
    case SA_OPCODE_SPACE_CREATE: {
        do_space_create(message);
    } break;
    case SA_OPCODE_SPACE_DESTROY: {
        do_space_destroy(message);
    } break;
    case SA_OPCODE_SPACE_MOVE: {
        do_space_move(message);
    } break;
    case SA_OPCODE_WINDOW_MOVE: {
        do_window_move(message);
    } break;
    case SA_OPCODE_WINDOW_OPACITY: {
        do_window_opacity(message);
    } break;
    case SA_OPCODE_WINDOW_OPACITY_FADE: {
        do_window_opacity_fade(message);
    } break;
    case SA_OPCODE_WINDOW_LAYER: {
        do_window_layer(message);
    } break;
    case SA_OPCODE_WINDOW_STICKY: {
        do_window_sticky(message);
    } break;
    case SA_OPCODE_WINDOW_SHADOW: {
        do_window_shadow(message);
    } break;
    case SA_OPCODE_WINDOW_FOCUS: {
        do_window_focus(message);
    } break;
    case SA_OPCODE_WINDOW_SCALE: {
        do_window_scale(message);
    } break;
    case SA_OPCODE_WINDOW_SWAP_PROXY_IN: {
        do_window_swap_proxy_in(message);
    } break;
    case SA_OPCODE_WINDOW_SWAP_PROXY_OUT: {
        do_window_swap_proxy_out(message);
    } break;
    case SA_OPCODE_WINDOW_ORDER: {
        do_window_order(message);
    } break;
    case SA_OPCODE_WINDOW_ORDER_IN: {
        do_window_order_in(message);
    } break;
    case SA_OPCODE_WINDOW_LIST_TO_SPACE: {
        do_window_list_move_to_space(message);
    } break;
    case SA_OPCODE_WINDOW_TO_SPACE: {
        do_window_move_to_space(message);
    } break;
    // Experimental (non-upstream) opcode arms — extracted to keep this switch
    // upstream-shaped. See payload_inc/README.md for the upstream/experimental rule.
    #include "payload_inc/dispatch_experimental.inc.m"
    }

    if (g_unpack_overflow)
        logpf("SA", "WIRE DESYNC: opcode 0x%02x unpack walked past the %d-byte message — daemon pack/payload unpack field lists disagree", op, length);
}

static inline bool read_message(int sockfd, char *message, int *out_len)
{
    int bytes_read    = 0;
    int bytes_to_read = 0;

    if (read(sockfd, &bytes_to_read, sizeof(int16_t)) == sizeof(int16_t)) {
        if (bytes_to_read >= SA_SOCKET_BUFF_LEN) return false;
        if (bytes_to_read <= 0)                  return false;

        do {
            int cur_read = read(sockfd, message+bytes_read, bytes_to_read-bytes_read);
            if (cur_read <= 0) break;

            bytes_read += cur_read;
        } while (bytes_read < bytes_to_read);

        if (bytes_read == bytes_to_read) { *out_len = bytes_to_read; return true; }
    }

    return false;
}

static void *handle_connection(void *unused)
{
    for (;;) {
        int sockfd = accept(daemon_sockfd, NULL, 0);
        if (sockfd == -1) continue;

        char message[SA_SOCKET_BUFF_LEN];
        int  message_len = 0;
        if (read_message(sockfd, message, &message_len)) {
            // Arm the deathwatch only for real daemon operations. The load/reload
            // handshake (SA_OPCODE_HANDSHAKE) is sent by the transient
            // `yabai --load-sa` / `--reload-sa` process, NOT the long-running
            // daemon — arming on its pid fires a false "death" the instant that
            // command exits.
            if (message_len > 0 && (uint8_t)message[0] != SA_OPCODE_HANDSHAKE) {
                deathwatch_observe_peer(sockfd);
            }
            handle_message(sockfd, message, message_len);
        }

        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
    }

    return NULL;
}

static TABLE_HASH_FUNC(hash_wid)
{
    return *(uint32_t *) key;
}

static TABLE_COMPARE_FUNC(compare_wid)
{
    return *(uint32_t *) key_a == *(uint32_t *) key_b;
}

static bool start_daemon(char *socket_path)
{
    struct sockaddr_un socket_address;
    socket_address.sun_family = AF_UNIX;
    snprintf(socket_address.sun_path, sizeof(socket_address.sun_path), "%s", socket_path);
    unlink(socket_path);

    if ((daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) {
        return false;
    }

    if (bind(daemon_sockfd, (struct sockaddr *) &socket_address, sizeof(socket_address)) == -1) {
        return false;
    }

    if (chmod(socket_path, 0600) != 0) {
        return false;
    }

    if (listen(daemon_sockfd, SOMAXCONN) == -1) {
        return false;
    }

    init_instances();
    pthread_mutex_init(&window_fade_lock, NULL);
    table_init(&window_fade_table, 150, hash_wid, compare_wid);
    pthread_create(&daemon_thread, NULL, &handle_connection, NULL);

    return true;
}

__attribute__((constructor))
void load_payload(void)
{
    NSLog(@"[yabai-sa] loaded payload..");
    logpf("PAYLOAD_LOAD", "xxx payload constructor ran, shared log = %s", LOGP_PATH);
    logpf("PAYLOAD_ID", "branch=%s sha=%s (constructor / fresh inject) pid=%d", PAYLOAD_BRANCH, PAYLOAD_SHA, getpid());
    payload_focus_ring_log("payload_id", "branch=%s sha=%s (constructor) pid=%d", PAYLOAD_BRANCH, PAYLOAD_SHA, getpid());

    const char *user = getenv("USER");
    if (!user) {
        NSLog(@"[yabai-sa] could not get 'env USER'! abort..");
        return;
    }

    char socket_file[255];
    snprintf(socket_file, sizeof(socket_file), SA_SOCKET_PATH_FMT, user);

    deathwatch_init();

    if (start_daemon(socket_file)) {
        NSLog(@"[yabai-sa] now listening..");
    } else {
        NSLog(@"[yabai-sa] failed to spawn thread..");
    }

}
