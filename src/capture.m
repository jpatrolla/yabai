#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <AVFoundation/AVFoundation.h>

#include <os/lock.h>
#include <sys/stat.h>
#include <pwd.h>

#define CAPTURE_MAX_FILE_BYTES (1LL * 1024 * 1024 * 1024)   // 1 GB hard cap
#define CAPTURE_SIZE_CHECK_EVERY_FRAMES 60                  // ~0.5s @ 120fps

#include "capture.h"

// SCK / AVFoundation are weak-linked; capture_start has a runtime @available(macOS 12.3) gate
// so references at file scope are safe. Silence the noisy unguarded-availability warnings.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

extern int g_connection;
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *bounds);
extern uint32_t window_display_id(uint32_t wid);
extern uint32_t display_manager_active_display_id(void);

API_AVAILABLE(macos(12.3))
@interface YBCapture : NSObject <SCStreamDelegate, SCStreamOutput>
@property (nonatomic, retain) SCStream                *stream;
@property (nonatomic, retain) AVAssetWriter           *writer;
@property (nonatomic, retain) AVAssetWriterInput      *videoInput;
@property (nonatomic, retain) dispatch_queue_t         sampleQueue;
@property (nonatomic, retain) NSString                *path;
@property (nonatomic, assign) CMTime                   firstPTS;
@property (nonatomic, assign) BOOL                     sessionStarted;
@property (nonatomic, assign) uint64_t                 framesWritten;
@property (nonatomic, assign) uint64_t                 framesDropped;
@property (nonatomic, assign) CFAbsoluteTime           startWallTime;
@property (nonatomic, assign) int                      width;
@property (nonatomic, assign) int                      height;
@property (nonatomic, assign) int                      fps;
@property (nonatomic, assign) dispatch_source_t        durationTimer;
@property (nonatomic, assign) NSString                *lastError;
@property (nonatomic, assign) uint32_t                 did;            // display id this stream captures
@property (nonatomic, retain) NSString                *group;         // shared group token (multi-display)
@property (nonatomic, assign) CGRect                   displayGlobalRect; // display bounds in global points
@property (nonatomic, assign) double                   backingScale;   // px/pt for this display
@end

// All active capture sessions. A single capture is just an array of one; a
// `display:all` capture holds one YBCapture per display. Guarded by g_capture_lock.
static NSMutableArray<YBCapture *> *g_captures = nil;
static os_unfair_lock g_capture_lock = OS_UNFAIR_LOCK_INIT;

// ─── helpers ─────────────────────────────────────────────────────────────────

static void
capture_err(char *err, size_t err_len, const char *fmt, ...)
{
    if (!err || err_len == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, err_len, fmt, ap);
    va_end(ap);
}

static NSString *
default_output_dir(void)
{
    const char *home = getenv("HOME");
    if (!home) {
        struct passwd *pw = getpwuid(getuid());
        home = pw ? pw->pw_dir : "/tmp";
    }
    NSString *dir = [NSString stringWithFormat:@"%s/Movies", home];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

static NSString *
build_timestamp(void)
{
    NSDateFormatter *df = [[[NSDateFormatter alloc] init] autorelease];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    return [df stringFromDate:[NSDate date]];
}

// Container (enum capture_container) -> file extension / AVFoundation file type.
// Both wrap the same HEVC bitstream; mp4 is the portable default.
static NSString *
container_ext(int container)
{
    return (container == CAPTURE_CONTAINER_MOV) ? @"mov" : @"mp4";
}

static AVFileType
container_filetype(int container)
{
    return (container == CAPTURE_CONTAINER_MOV) ? AVFileTypeQuickTimeMovie : AVFileTypeMPEG4;
}

static NSString *
build_output_path(const char *name_opt, NSString *ext)
{
    NSString *ts = build_timestamp();
    NSString *base;
    if (name_opt && *name_opt) {
        base = [NSString stringWithFormat:@"yabai-capture-%@_%s.%@", ts, name_opt, ext];
    } else {
        base = [NSString stringWithFormat:@"yabai-capture-%@.%@", ts, ext];
    }
    return [default_output_dir() stringByAppendingPathComponent:base];
}

// ~/Movies/<group>/ — the per-capture directory for a display:all run. Created if
// missing; reused as-is if it already exists (files inside follow the usual
// overwrite-at-target-path rule).
static NSString *
group_output_dir(NSString *group)
{
    NSString *dir = [default_output_dir() stringByAppendingPathComponent:group];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

// Multi-display file: <group-dir>/yabai-capture-<ts>_<group>_did<DID>.<ext>. `group`
// and `ts` are shared across one display:all capture so a stitch can re-pair the
// files; `dir` is the group directory.
static NSString *
build_output_path_multi(NSString *dir, NSString *ts, NSString *group, uint32_t did, NSString *ext)
{
    NSString *base = [NSString stringWithFormat:@"yabai-capture-%@_%@_did%u.%@", ts, group, did, ext];
    return [dir stringByAppendingPathComponent:base];
}

// Apply the if-exists policy to an output path. Returns the path to actually write
// (possibly renamed to a free <stem>-N.<ext>), or nil + err for FAIL on collision.
// OVERWRITE deletes the existing file in place. No collision -> returns path as-is.
static NSString *
resolve_output_path(NSString *path, int if_exists, char *err, size_t err_len)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return path;

    if (if_exists == CAPTURE_IF_EXISTS_OVERWRITE) {
        [fm removeItemAtPath:path error:nil];
        return path;
    }
    if (if_exists == CAPTURE_IF_EXISTS_FAIL) {
        capture_err(err, err_len, "capture: '%s' already exists (pass if-exists:overwrite|rename)",
                    path.UTF8String);
        return nil;
    }

    // CAPTURE_IF_EXISTS_RENAME (default): first free <stem>-N.<ext>.
    NSString *dir  = [path stringByDeletingLastPathComponent];
    NSString *ext  = [path pathExtension];
    NSString *stem = [[path lastPathComponent] stringByDeletingPathExtension];
    for (int i = 1; i < 10000; i++) {
        NSString *cand = [dir stringByAppendingPathComponent:
            (ext.length ? [NSString stringWithFormat:@"%@-%d.%@", stem, i, ext]
                        : [NSString stringWithFormat:@"%@-%d", stem, i])];
        if (![fm fileExistsAtPath:cand]) return cand;
    }
    capture_err(err, err_len, "capture: could not find a free name for '%s'", path.UTF8String);
    return nil;
}

// Write <file>.json next to a finished multi-display capture so a later stitch can
// sync (first-frame PTS on the host clock) and lay out (global rect / pixel dims).
static void
write_sidecar(YBCapture *cap)
{
    if (!cap.group || !cap.path) return;
    CGRect r = cap.displayGlobalRect;
    NSDictionary *meta = @{
        @"did":                 @(cap.did),
        @"group":               cap.group,
        @"first_pts_value":     @(cap.firstPTS.value),
        @"first_pts_timescale": @(cap.firstPTS.timescale),
        @"global_rect":         @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)],
        @"pix_w":               @(cap.width),
        @"pix_h":               @(cap.height),
        @"fps":                 @(cap.fps),
        @"backing_scale":       @(cap.backingScale),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:meta
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (json) {
        NSString *sidecar = [cap.path stringByAppendingPathExtension:@"json"];
        [json writeToFile:sidecar atomically:YES];
    }
}

API_AVAILABLE(macos(12.3))
static SCDisplay *
find_sc_display(NSArray<SCDisplay *> *displays, uint32_t did)
{
    for (SCDisplay *d in displays) {
        if (d.displayID == did) return d;
    }
    return nil;
}

// finalize_region: common tail — given the resolved global region and its display
// bounds, fill the display-relative source rect (points) and the final encoded
// pixel size (after backing scale + user scale, forced even for HEVC).
static bool
finalize_region(uint32_t did, CGRect region_global, CGRect display_global,
                struct capture_options *o, CGRect *out_display_pts,
                int *out_pix_w, int *out_pix_h, double *out_backing_scale,
                char *err, size_t err_len)
{
    out_display_pts->origin.x = region_global.origin.x - display_global.origin.x;
    out_display_pts->origin.y = region_global.origin.y - display_global.origin.y;
    out_display_pts->size     = region_global.size;

    // Backing scale via CG (SCDisplay.frame is points; CGDisplayPixelsWide is pixels).
    double pix_w = (double)CGDisplayPixelsWide(did);
    double pt_w  = CGDisplayBounds(did).size.width;
    double bs    = (pt_w > 0.0) ? (pix_w / pt_w) : 2.0;
    *out_backing_scale = bs;

    double sx = (o->scale > 0.0f) ? (double)o->scale : 1.0;
    int    w  = (int)llround(region_global.size.width  * bs * sx);
    int    h  = (int)llround(region_global.size.height * bs * sx);

    // SCK/HEVC encoders require even dimensions.
    if (w & 1) w -= 1;
    if (h & 1) h -= 1;
    if (w < 16 || h < 16) {
        capture_err(err, err_len, "capture: region too small after scale (%dx%d)", w, h);
        return false;
    }
    *out_pix_w = w;
    *out_pix_h = h;
    return true;
}

// resolve_display_region: full-bounds capture for an explicit display id.
static bool
resolve_display_region(uint32_t did, struct capture_options *o, CGRect *out_display_pts,
                       int *out_pix_w, int *out_pix_h, CGRect *out_display_global,
                       double *out_backing_scale, char *err, size_t err_len)
{
    if (!did) { capture_err(err, err_len, "capture: invalid display id"); return false; }
    CGRect disp = CGDisplayBounds(did);
    *out_display_global = disp;
    return finalize_region(did, disp, disp, o, out_display_pts,
                           out_pix_w, out_pix_h, out_backing_scale, err, err_len);
}

// resolve_region: returns true on success; fills out_did, out_display_pts (display-relative,
// in points), out_pix_w/h (final encoded pixel size after scale). For a wid it crops to the
// window bounds; otherwise it captures the full bounds of o->display (or the active display).
static bool
resolve_region(struct capture_options *o, uint32_t *out_did, CGRect *out_display_pts,
               int *out_pix_w, int *out_pix_h, CGRect *out_display_global,
               double *out_backing_scale, char *err, size_t err_len)
{
    if (o->wid) {
        CGRect b;
        if (SLSGetWindowBounds(g_connection, o->wid, &b) != kCGErrorSuccess) {
            capture_err(err, err_len, "capture: SLSGetWindowBounds failed for wid %u", o->wid);
            return false;
        }
        uint32_t did = window_display_id(o->wid);
        if (!did) {
            capture_err(err, err_len, "capture: window_display_id failed for wid %u", o->wid);
            return false;
        }
        CGRect disp = CGDisplayBounds(did);

        // Straddle check: bare wid bounds must lie within its display.
        if (!CGRectContainsRect(disp, b)) {
            capture_err(err, err_len,
                "capture: window %u straddles display boundary "
                "(wid=[%.0f,%.0f %.0fx%.0f] disp=[%.0f,%.0f %.0fx%.0f])",
                o->wid,
                b.origin.x, b.origin.y, b.size.width, b.size.height,
                disp.origin.x, disp.origin.y, disp.size.width, disp.size.height);
            return false;
        }

        CGRect region_global = CGRectInset(b, -(CGFloat)o->padding, -(CGFloat)o->padding);
        region_global = CGRectIntersection(region_global, disp);
        *out_display_global = disp;
        *out_did = did;
        return finalize_region(did, region_global, disp, o, out_display_pts,
                               out_pix_w, out_pix_h, out_backing_scale, err, err_len);
    }

    uint32_t did = o->display ? o->display : display_manager_active_display_id();
    if (!did) {
        capture_err(err, err_len, "capture: no active display");
        return false;
    }
    *out_did = did;
    return resolve_display_region(did, o, out_display_pts, out_pix_w, out_pix_h,
                                  out_display_global, out_backing_scale, err, err_len);
}

static int
bitrate_for(int w, int h, int fps, double bpp)
{
    if (bpp <= 0.0) bpp = 0.6;
    long long br = (long long)((double)w * (double)h * (double)fps * bpp);
    if (br < 4LL * 1000 * 1000)    br = 4LL * 1000 * 1000;
    if (br > 1000LL * 1000 * 1000) br = 1000LL * 1000 * 1000;   // 1 Gbps sanity cap
    return (int)br;
}

// ─── YBCapture ───────────────────────────────────────────────────────────────

@implementation YBCapture

- (void)dealloc
{
    [_stream release];
    [_writer release];
    [_videoInput release];
    [_sampleQueue release];
    [_path release];
    [_lastError release];
    [_group release];
    if (_durationTimer) {
        dispatch_source_cancel(_durationTimer);
        dispatch_release(_durationTimer);
    }
    [super dealloc];
}

// SCStreamDelegate: stream stopped (error path).
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error
{
    if (error) {
        NSLog(@"[yabai-capture] stream stopped: %@", error);
    }
}

// SCStreamOutput: hot path.
- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sb
                   ofType:(SCStreamOutputType)type
{
    if (type != SCStreamOutputTypeScreen) return;
    if (!sb || !CMSampleBufferIsValid(sb) || !CMSampleBufferDataIsReady(sb)) return;

    // Drop idle/blank frames so we only record real updates.
    CFArrayRef att = CMSampleBufferGetSampleAttachmentsArray(sb, false);
    if (att && CFArrayGetCount(att) > 0) {
        CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(att, 0);
        CFNumberRef st = (CFNumberRef)CFDictionaryGetValue(d, (CFStringRef)SCStreamFrameInfoStatus);
        int status = 0;
        if (st) CFNumberGetValue(st, kCFNumberIntType, &status);
        if (status != SCFrameStatusComplete) return;
    }

    if (!_sessionStarted) {
        if (_writer.status == AVAssetWriterStatusUnknown) {
            if (![_writer startWriting]) {
                NSLog(@"[yabai-capture] startWriting failed: %@", _writer.error);
                return;
            }
        }
        _firstPTS = CMSampleBufferGetPresentationTimeStamp(sb);
        [_writer startSessionAtSourceTime:_firstPTS];
        _sessionStarted = YES;
    }

    if (_videoInput.isReadyForMoreMediaData) {
        if ([_videoInput appendSampleBuffer:sb]) {
            _framesWritten++;
            if ((_framesWritten % CAPTURE_SIZE_CHECK_EVERY_FRAMES) == 0 && _path) {
                struct stat st;
                if (stat(_path.UTF8String, &st) == 0 && st.st_size >= CAPTURE_MAX_FILE_BYTES) {
                    NSLog(@"[yabai-capture] hit %lld-byte cap at frame %llu — stopping",
                          (long long)CAPTURE_MAX_FILE_BYTES, _framesWritten);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        char e[256] = {0};
                        capture_stop(e, sizeof e);
                    });
                }
            }
        } else {
            _framesDropped++;
        }
    } else {
        _framesDropped++;
    }
}

@end

// ─── session lifecycle helpers ─────────────────────────────────────────────────

// Build, configure and start one SCStream -> AVAssetWriter session for a single
// display/region. Returns a +1 YBCapture on success (caller owns it), nil on error.
API_AVAILABLE(macos(12.3))
static YBCapture *
start_one_display(SCDisplay *sc_disp, uint32_t did, NSString *out_path,
                  CGRect source_rect_pts, int pix_w, int pix_h,
                  CGRect display_global, double backing_scale,
                  struct capture_options *o, NSString *group,
                  char *err, size_t err_len)
{
    out_path = resolve_output_path(out_path, o->if_exists, err, err_len);
    if (!out_path) return nil;

    YBCapture *cap = [[YBCapture alloc] init];
    cap.path        = out_path;
    cap.sampleQueue = dispatch_queue_create("com.koekeishiya.yabai.capture.samples",
                                            DISPATCH_QUEUE_SERIAL);
    cap.width             = pix_w;
    cap.height            = pix_h;
    cap.fps               = o->fps;
    cap.did               = did;
    cap.group             = group;
    cap.displayGlobalRect = display_global;
    cap.backingScale      = backing_scale;

    NSError *werr = nil;
    NSURL *url = [NSURL fileURLWithPath:cap.path];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url
                                                     fileType:container_filetype(o->container)
                                                        error:&werr];
    if (!writer) {
        capture_err(err, err_len, "capture: AVAssetWriter init failed: %s",
                    werr.localizedDescription.UTF8String);
        [cap release];
        return nil;
    }

    NSDictionary *compression = @{
        AVVideoExpectedSourceFrameRateKey: @(o->fps),
        AVVideoAverageBitRateKey:          @(bitrate_for(pix_w, pix_h, o->fps, o->bpp)),
        AVVideoMaxKeyFrameIntervalKey:     @(o->fps * 2),
    };
    NSDictionary *vs = @{
        AVVideoCodecKey:                   AVVideoCodecTypeHEVC,
        AVVideoWidthKey:                   @(pix_w),
        AVVideoHeightKey:                  @(pix_h),
        AVVideoCompressionPropertiesKey:   compression,
    };
    AVAssetWriterInput *vin = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                 outputSettings:vs];
    vin.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:vin]) {
        capture_err(err, err_len, "capture: writer cannot accept HEVC input");
        [cap release];
        return nil;
    }
    [writer addInput:vin];
    cap.writer     = writer;
    cap.videoInput = vin;

    SCContentFilter *filter = [[[SCContentFilter alloc] initWithDisplay:sc_disp
                                                       excludingWindows:@[]] autorelease];
    SCStreamConfiguration *cfg = [[[SCStreamConfiguration alloc] init] autorelease];
    cfg.sourceRect            = source_rect_pts;
    cfg.width                 = pix_w;
    cfg.height                = pix_h;
    cfg.minimumFrameInterval  = CMTimeMake(1, o->fps);
    cfg.pixelFormat           = kCVPixelFormatType_32BGRA;
    cfg.queueDepth            = 8;
    cfg.showsCursor           = o->cursor ? YES : NO;
    cfg.scalesToFit           = YES;

    SCStream *stream = [[SCStream alloc] initWithFilter:filter
                                          configuration:cfg
                                               delegate:cap];
    NSError *aerr = nil;
    if (![stream addStreamOutput:cap
                            type:SCStreamOutputTypeScreen
              sampleHandlerQueue:cap.sampleQueue
                           error:&aerr]) {
        capture_err(err, err_len, "capture: addStreamOutput failed: %s",
                    aerr.localizedDescription.UTF8String);
        [stream release];
        [cap release];
        return nil;
    }
    cap.stream = stream;
    [stream release];

    dispatch_semaphore_t start_sem = dispatch_semaphore_create(0);
    __block NSError *start_err = nil;
    [cap.stream startCaptureWithCompletionHandler:^(NSError *e) {
        start_err = [e retain];
        dispatch_semaphore_signal(start_sem);
    }];
    dispatch_semaphore_wait(start_sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    if (start_err) {
        capture_err(err, err_len, "capture: startCapture failed: %s",
                    start_err.localizedDescription.UTF8String);
        [start_err release];
        [cap release];
        return nil;
    }

    cap.startWallTime = CFAbsoluteTimeGetCurrent();
    NSLog(@"[yabai-capture] started: %@ (%dx%d @ %dfps, src=[%.0f,%.0f %.0fx%.0f] did=%u)",
          cap.path, pix_w, pix_h, o->fps,
          source_rect_pts.origin.x, source_rect_pts.origin.y,
          source_rect_pts.size.width, source_rect_pts.size.height, did);
    return cap;
}

// Stop one session's stream and writer. If keep, finalize the file (and write the
// sidecar for a multi-display capture); otherwise discard the partial file. Best
// effort — never throws.
API_AVAILABLE(macos(12.3))
static void
finalize_session(YBCapture *cap, bool keep)
{
    if (cap.durationTimer) {
        dispatch_source_cancel(cap.durationTimer);
        // ownership released in dealloc
    }
    if (cap.stream) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [cap.stream stopCaptureWithCompletionHandler:^(NSError *e) {
            (void)e;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }

    [cap.videoInput markAsFinished];

    if (keep && cap.writer && cap.writer.status == AVAssetWriterStatusWriting) {
        dispatch_semaphore_t finish_sem = dispatch_semaphore_create(0);
        [cap.writer finishWritingWithCompletionHandler:^{
            dispatch_semaphore_signal(finish_sem);
        }];
        dispatch_semaphore_wait(finish_sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        write_sidecar(cap);   // no-op when group == nil (single-display capture)
    } else {
        // No samples written, or aborting a partial start: drop the file + sidecar.
        if (cap.writer && cap.writer.status == AVAssetWriterStatusWriting) {
            [cap.writer cancelWriting];
        }
        [[NSFileManager defaultManager] removeItemAtPath:cap.path error:nil];
        NSString *sidecar = [cap.path stringByAppendingPathExtension:@"json"];
        [[NSFileManager defaultManager] removeItemAtPath:sidecar error:nil];
    }

    NSLog(@"[yabai-capture] %s: %@ (frames=%llu dropped=%llu)",
          keep ? "stopped" : "aborted", cap.path, cap.framesWritten, cap.framesDropped);
}

// ─── public C API ────────────────────────────────────────────────────────────

bool
capture_is_active(void)
{
    os_unfair_lock_lock(&g_capture_lock);
    bool active = (g_captures != nil && g_captures.count > 0);
    os_unfair_lock_unlock(&g_capture_lock);
    return active;
}

bool
capture_start(struct capture_options *o, char *err, size_t err_len)
{
    if (!o) { capture_err(err, err_len, "capture: null options"); return false; }

    if (@available(macOS 12.3, *)) {
        // continue
    } else {
        capture_err(err, err_len, "capture: requires macOS 12.3+ (ScreenCaptureKit)");
        return false;
    }

    os_unfair_lock_lock(&g_capture_lock);
    bool busy = (g_captures != nil && g_captures.count > 0);
    os_unfair_lock_unlock(&g_capture_lock);
    if (busy) {
        capture_err(err, err_len, "capture: already active");
        return false;
    }

    if (o->fps   <= 0)   o->fps   = 120;
    if (o->scale <= 0.0f) o->scale = 0.25f;
    if (o->bpp   <= 0.0f) o->bpp   = 0.6f;

    // Enumerate all shareable displays once (shared by single + all paths).
    __block SCShareableContent *content = nil;
    __block NSError            *content_err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                onScreenWindowsOnly:NO
                                                  completionHandler:^(SCShareableContent *c, NSError *e) {
        content     = [c retain];
        content_err = [e retain];
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (!content) {
        NSString *msg = content_err
            ? [NSString stringWithFormat:@"capture: SCShareableContent failed: %@ "
                                          "(grant Screen Recording in System Settings → Privacy & Security)",
                                          content_err.localizedDescription]
            : @"capture: SCShareableContent timeout (grant Screen Recording in System Settings → Privacy & Security)";
        capture_err(err, err_len, "%s", msg.UTF8String);
        [content_err release];
        return false;
    }

    NSMutableArray<YBCapture *> *started = [NSMutableArray array];

    if (o->all_displays) {
        NSString *ts    = build_timestamp();
        NSString *group = (o->name && *o->name)
            ? [NSString stringWithUTF8String:o->name] : ts;
        NSString *dir   = group_output_dir(group);   // ~/Movies/<group>/

        for (SCDisplay *sc_disp in content.displays) {
            uint32_t did = sc_disp.displayID;
            CGRect   src_rect, disp_global;
            int      pix_w = 0, pix_h = 0;
            double   backing_scale = 2.0;
            if (!resolve_display_region(did, o, &src_rect, &pix_w, &pix_h,
                                        &disp_global, &backing_scale, err, err_len)) {
                goto fail;
            }
            NSString *path = build_output_path_multi(dir, ts, group, did, container_ext(o->container));
            YBCapture *cap = start_one_display(sc_disp, did, path, src_rect, pix_w, pix_h,
                                               disp_global, backing_scale, o, group, err, err_len);
            if (!cap) goto fail;
            [started addObject:cap];
            [cap release];   // `started` retains
        }

        if (started.count == 0) {
            capture_err(err, err_len, "capture: no displays to capture");
            goto fail;
        }
    } else {
        uint32_t did = 0;
        CGRect   src_rect, disp_global;
        int      pix_w = 0, pix_h = 0;
        double   backing_scale = 2.0;
        if (!resolve_region(o, &did, &src_rect, &pix_w, &pix_h,
                            &disp_global, &backing_scale, err, err_len)) {
            goto fail;
        }
        SCDisplay *sc_disp = find_sc_display(content.displays, did);
        if (!sc_disp) {
            capture_err(err, err_len, "capture: SCDisplay not found for did %u", did);
            goto fail;
        }
        NSString *path = build_output_path(o->name, container_ext(o->container));
        YBCapture *cap = start_one_display(sc_disp, did, path, src_rect, pix_w, pix_h,
                                           disp_global, backing_scale, o, nil, err, err_len);
        if (!cap) goto fail;
        [started addObject:cap];
        [cap release];
    }

    // One duration timer drives capture_stop, which finalizes every session.
    if (o->duration > 0) {
        dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        dispatch_source_set_timer(t,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)o->duration * NSEC_PER_SEC),
            DISPATCH_TIME_FOREVER, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(t, ^{
            char e[256] = {0};
            capture_stop(e, sizeof e);
        });
        started[0].durationTimer = t;
        dispatch_resume(t);
    }

    os_unfair_lock_lock(&g_capture_lock);
    if (!g_captures) g_captures = [[NSMutableArray alloc] init];
    [g_captures addObjectsFromArray:started];   // retains each
    os_unfair_lock_unlock(&g_capture_lock);

    [content release]; [content_err release];
    return true;

fail:
    for (YBCapture *cap in started) finalize_session(cap, false);
    [content release]; [content_err release];
    return false;
}

bool
capture_stop(char *err, size_t err_len)
{
    // Detach the whole set atomically so a concurrent stop / duration-timer fire is
    // idempotent (the loser sees an empty set -> "not active").
    os_unfair_lock_lock(&g_capture_lock);
    NSArray<YBCapture *> *caps = g_captures ? [g_captures copy] : nil;
    [g_captures removeAllObjects];
    os_unfair_lock_unlock(&g_capture_lock);

    if (!caps || caps.count == 0) {
        [caps release];
        capture_err(err, err_len, "capture: not active");
        return false;
    }

    for (YBCapture *cap in caps) {
        if (@available(macOS 12.3, *)) finalize_session(cap, true);
    }
    [caps release];   // releases each session -> dealloc
    return true;
}

void
capture_status(char *out, size_t out_len)
{
    if (!out || out_len == 0) return;
    os_unfair_lock_lock(&g_capture_lock);
    NSArray<YBCapture *> *caps = g_captures ? [g_captures copy] : nil;
    os_unfair_lock_unlock(&g_capture_lock);

    if (!caps || caps.count == 0) {
        [caps release];
        snprintf(out, out_len, "{\"active\":false}");
        return;
    }

    NSMutableString *arr = [NSMutableString stringWithString:@"["];
    for (NSUInteger i = 0; i < caps.count; i++) {
        YBCapture *cap = caps[i];
        double elapsed = CFAbsoluteTimeGetCurrent() - cap.startWallTime;
        [arr appendFormat:@"%@{\"did\":%u,\"path\":\"%@\",\"frames\":%llu,\"dropped\":%llu,"
                          @"\"elapsed_s\":%.2f,\"size\":[%d,%d],\"fps\":%d}",
            (i ? @"," : @""), cap.did, cap.path,
            cap.framesWritten, cap.framesDropped,
            elapsed, cap.width, cap.height, cap.fps];
    }
    [arr appendString:@"]"];
    snprintf(out, out_len, "{\"active\":true,\"sessions\":%s}", arr.UTF8String);
    [caps release];
}

// ─── stitch ────────────────────────────────────────────────────────────────────

#define STITCH_MAX_PANELS 16
#define STITCH_TIMESCALE  600

struct stitch_panel {
    AVURLAsset   *asset;
    AVAssetTrack *track;
    CGRect        global_rect; // display bounds, points (zero for explicit files)
    double        first_pts;   // first-frame PTS, seconds on the host clock (0 if unknown)
    double        duration;    // asset duration, seconds
    double        tw, th;      // source track natural size, pixels
    int           fps;
};

static int
stitch_cmp_x(const void *a, const void *b)
{
    const struct stitch_panel *pa = a, *pb = b;
    if (pa->global_rect.origin.x < pb->global_rect.origin.x) return -1;
    if (pa->global_rect.origin.x > pb->global_rect.origin.x) return  1;
    if (pa->global_rect.origin.y < pb->global_rect.origin.y) return -1;
    if (pa->global_rect.origin.y > pb->global_rect.origin.y) return  1;
    return 0;
}

// Load a .mov into a panel: open the asset, grab its first video track + dims/fps.
// `pts`/`rect` come from the caller (sidecar for a group, defaults for explicit files).
static bool
stitch_load_panel(NSString *mov_path, double first_pts, CGRect global_rect,
                  struct stitch_panel *out, char *err, size_t err_len)
{
    NSString *path = [mov_path stringByExpandingTildeInPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        capture_err(err, err_len, "capture stitch: file not found: %s", path.UTF8String);
        return false;
    }
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:[NSURL fileURLWithPath:path] options:nil];
    AVAssetTrack *vt = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!vt) {
        capture_err(err, err_len, "capture stitch: no video track in %s", path.UTF8String);
        [asset release];
        return false;
    }
    out->asset       = asset;            // retained
    out->track       = [vt retain];
    out->global_rect = global_rect;
    out->first_pts   = first_pts;
    out->duration    = CMTimeGetSeconds(asset.duration);
    out->tw          = vt.naturalSize.width;
    out->th          = vt.naturalSize.height;
    out->fps         = (int)llround(vt.nominalFrameRate > 0 ? vt.nominalFrameRate : 60.0);
    return true;
}

bool
capture_stitch(struct capture_stitch_options *o, char *err, size_t err_len)
{
    if (!o) { capture_err(err, err_len, "capture stitch: null options"); return false; }

    struct stitch_panel panels[STITCH_MAX_PANELS];
    int n = 0;
    bool ok = false;
    NSString *out_path = nil;

    // ── 1. resolve inputs ──────────────────────────────────────────────────────
    if (o->group && *o->group) {
        NSString *group = [NSString stringWithUTF8String:o->group];
        NSString *dir   = [default_output_dir() stringByAppendingPathComponent:group]; // ~/Movies/<group>/
        BOOL isdir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isdir] || !isdir) {
            capture_err(err, err_len, "capture stitch: no capture directory for group '%s' (%s)",
                        o->group, dir.UTF8String);
            return false;
        }
        NSArray<NSString *> *entries =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];

        // The directory may hold sidecars from several display:all runs (each shares
        // a <ts> prefix). Pick the most recent run so we never mix panels across runs.
        NSString *latest_ts = nil;
        for (NSString *e in entries) {
            // Sidecars are named <videofile>.<ext>.json, so the extension tracks the
            // recorded container (mp4 or mov); match on the .json tail, not the container.
            if (![e hasPrefix:@"yabai-capture-"] || ![e hasSuffix:@".json"]) continue;
            NSString *rest = [e substringFromIndex:[@"yabai-capture-" length]];
            NSRange us = [rest rangeOfString:@"_"];
            NSString *ts = (us.location != NSNotFound) ? [rest substringToIndex:us.location] : rest;
            if (!latest_ts || [ts compare:latest_ts] == NSOrderedDescending) latest_ts = ts;
        }
        NSMutableArray<NSString *> *sidecars = [NSMutableArray array];
        if (latest_ts) {
            NSString *prefix = [NSString stringWithFormat:@"yabai-capture-%@_", latest_ts];
            for (NSString *e in entries) {
                if ([e hasPrefix:prefix] && [e hasSuffix:@".json"]) {
                    [sidecars addObject:[dir stringByAppendingPathComponent:e]];
                }
            }
        }
        if (sidecars.count < 2) {
            capture_err(err, err_len, "capture stitch: need >= 2 files for group '%s' (found %lu)",
                        o->group, (unsigned long)sidecars.count);
            return false;
        }
        for (NSString *sc in sidecars) {
            if (n >= STITCH_MAX_PANELS) break;
            NSData *data = [NSData dataWithContentsOfFile:sc];
            NSDictionary *m = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            NSArray *gr = m[@"global_rect"];
            CGRect rect = CGRectZero;
            if ([gr isKindOfClass:[NSArray class]] && gr.count == 4) {
                rect = CGRectMake([gr[0] doubleValue], [gr[1] doubleValue],
                                  [gr[2] doubleValue], [gr[3] doubleValue]);
            }
            double pts_v  = [m[@"first_pts_value"] doubleValue];
            double pts_ts = [m[@"first_pts_timescale"] doubleValue];
            double first_pts = (pts_ts > 0) ? (pts_v / pts_ts) : 0.0;
            NSString *video = [sc stringByDeletingPathExtension]; // strip ".json" -> the .mp4/.mov
            if (stitch_load_panel(video, first_pts, rect, &panels[n], err, err_len)) n++;
        }
        out_path = o->out && *o->out
            ? [[NSString stringWithUTF8String:o->out] stringByExpandingTildeInPath]
            : [dir stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"%@_stitched.%@", group, container_ext(o->container)]];
    } else if (o->files && o->file_count >= 2) {
        for (int i = 0; i < o->file_count && n < STITCH_MAX_PANELS; i++) {
            // explicit files carry no sync/layout info: order = input order (x = index).
            CGRect rect = CGRectMake((double)i, 0, 0, 0);
            if (stitch_load_panel([NSString stringWithUTF8String:o->files[i]], 0.0, rect,
                                  &panels[n], err, err_len)) {
                n++;
            } else {
                goto cleanup;
            }
        }
        out_path = o->out && *o->out
            ? [[NSString stringWithUTF8String:o->out] stringByExpandingTildeInPath]
            : [default_output_dir() stringByAppendingPathComponent:
                  [NSString stringWithFormat:@"yabai-capture-%@_stitched.%@",
                                             build_timestamp(), container_ext(o->container)]];
    } else {
        capture_err(err, err_len, "capture stitch: provide group:<name> or >= 2 files");
        return false;
    }

    if (n < 2) {
        capture_err(err, err_len, "capture stitch: need >= 2 loadable panels (got %d)", n);
        goto cleanup;
    }

    // ── 2. order (left-to-right by global-x; explicit files keep input order) ──
    qsort(panels, n, sizeof(struct stitch_panel), stitch_cmp_x);

    // ── 3. sync window: align every panel to the LATEST first-frame instant, so
    // composition-time 0 is the same wall-clock moment on all displays. A panel
    // whose stream started earlier has extra head footage, so it is trimmed by
    // (t_latest - its first_pts); the latest-starting panel is trimmed by 0.
    double t_latest = panels[0].first_pts;
    for (int i = 1; i < n; i++) if (panels[i].first_pts > t_latest) t_latest = panels[i].first_pts;
    double overlap = INFINITY;
    int    target_fps = 0;
    for (int i = 0; i < n; i++) {
        double trim = t_latest - panels[i].first_pts;   // >= 0
        double avail = panels[i].duration - trim;
        if (avail < overlap) overlap = avail;
        if (panels[i].fps > target_fps) target_fps = panels[i].fps;
    }
    if (target_fps <= 0) target_fps = 60;
    if (!(overlap > 0)) {
        capture_err(err, err_len, "capture stitch: no overlapping footage after sync");
        goto cleanup;
    }

    // ── 4/5. compute per-panel scale + offset and the render canvas ────────────
    int    border = o->border > 0 ? o->border : 0;
    int    gap    = o->gap    > 0 ? o->gap    : border;
    bool   match  = o->match_height;
    double sx[STITCH_MAX_PANELS], sy[STITCH_MAX_PANELS];
    double tx[STITCH_MAX_PANELS], ty[STITCH_MAX_PANELS];
    double renderW = 0, renderH = 0;

    if (o->layout == CAPTURE_STITCH_FAITHFUL) {
        // Reproduce the real arrangement: union of global rects (points) -> pixels at
        // the lowest panel density k, each panel drawn at its rect, black fills gaps.
        double minx = panels[0].global_rect.origin.x, miny = panels[0].global_rect.origin.y;
        double maxx = minx, maxy = miny, k = INFINITY;
        for (int i = 0; i < n; i++) {
            CGRect r = panels[i].global_rect;
            minx = fmin(minx, r.origin.x); miny = fmin(miny, r.origin.y);
            maxx = fmax(maxx, r.origin.x + r.size.width);
            maxy = fmax(maxy, r.origin.y + r.size.height);
            if (r.size.height > 0) k = fmin(k, panels[i].th / r.size.height);
        }
        if (!(k > 0) || k == INFINITY) k = 1.0;
        renderW = (maxx - minx) * k + 2 * border;
        renderH = (maxy - miny) * k + 2 * border;
        for (int i = 0; i < n; i++) {
            CGRect r = panels[i].global_rect;
            double dw = r.size.width  * k, dh = r.size.height * k;
            sx[i] = panels[i].tw > 0 ? dw / panels[i].tw : 1.0;
            sy[i] = panels[i].th > 0 ? dh / panels[i].th : 1.0;
            tx[i] = border + (r.origin.x - minx) * k;
            ty[i] = border + (r.origin.y - miny) * k; // global coords are top-left, y-down
        }
    } else {
        // side-by-side: equal-height columns (scale higher-res down to the smallest).
        double H = panels[0].th;
        for (int i = 1; i < n; i++) H = match ? fmin(H, panels[i].th) : fmax(H, panels[i].th);
        double x = border;
        for (int i = 0; i < n; i++) {
            double s  = match ? (panels[i].th > 0 ? H / panels[i].th : 1.0) : 1.0;
            double sw = panels[i].tw * s;
            sx[i] = sy[i] = s;
            tx[i] = x;
            ty[i] = border;
            x += sw + gap;
        }
        renderW = x - gap + border;
        renderH = H + 2 * border;
    }

    // even dimensions for the HEVC encoder
    NSInteger rw = (NSInteger)llround(renderW); if (rw & 1) rw += 1;
    NSInteger rh = (NSInteger)llround(renderH); if (rh & 1) rh += 1;

    // ── 6. build composition + video composition ───────────────────────────────
    AVMutableComposition *comp = [AVMutableComposition composition];
    NSMutableArray<AVMutableVideoCompositionLayerInstruction *> *lis = [NSMutableArray array];
    CMTime overlap_t = CMTimeMakeWithSeconds(overlap, STITCH_TIMESCALE);

    for (int i = 0; i < n; i++) {
        AVMutableCompositionTrack *ct =
            [comp addMutableTrackWithMediaType:AVMediaTypeVideo
                              preferredTrackID:kCMPersistentTrackID_Invalid];
        double trim = t_latest - panels[i].first_pts;
        CMTimeRange src_range = CMTimeRangeMake(CMTimeMakeWithSeconds(trim, STITCH_TIMESCALE), overlap_t);
        NSError *ie = nil;
        if (![ct insertTimeRange:src_range ofTrack:panels[i].track atTime:kCMTimeZero error:&ie]) {
            capture_err(err, err_len, "capture stitch: insertTimeRange failed for panel %d: %s",
                        i, ie.localizedDescription.UTF8String);
            goto cleanup;
        }
        AVMutableVideoCompositionLayerInstruction *li =
            [AVMutableVideoCompositionLayerInstruction videoCompositionLayerInstructionWithAssetTrack:ct];
        CGAffineTransform tf = CGAffineTransformConcat(
            CGAffineTransformMakeScale(sx[i], sy[i]),
            CGAffineTransformMakeTranslation(tx[i], ty[i]));
        [li setTransform:tf atTime:kCMTimeZero];
        [lis addObject:li];
    }

    AVMutableVideoCompositionInstruction *vci = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    vci.timeRange         = CMTimeRangeMake(kCMTimeZero, overlap_t);
    vci.backgroundColor   = CGColorGetConstantColor(kCGColorBlack); // black matte for border/gap
    vci.layerInstructions = lis;

    AVMutableVideoComposition *vc = [AVMutableVideoComposition videoComposition];
    vc.renderSize    = CGSizeMake(rw, rh);
    vc.frameDuration = CMTimeMake(1, target_fps);
    vc.instructions  = @[vci];

    // ── 7. export ──────────────────────────────────────────────────────────────
    out_path = resolve_output_path(out_path, o->if_exists, err, err_len);
    if (!out_path) goto cleanup;
    NSString *preset = AVAssetExportPresetHEVCHighestQuality;
    if (![[AVAssetExportSession exportPresetsCompatibleWithAsset:comp] containsObject:preset]) {
        preset = AVAssetExportPresetHighestQuality;
    }
    AVAssetExportSession *ex = [[AVAssetExportSession alloc] initWithAsset:comp presetName:preset];
    ex.outputURL        = [NSURL fileURLWithPath:out_path];
    ex.outputFileType   = container_filetype(o->container);
    ex.videoComposition = vc;

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [ex exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (ex.status != AVAssetExportSessionStatusCompleted) {
        capture_err(err, err_len, "capture stitch: export failed: %s",
                    ex.error.localizedDescription.UTF8String);
        [ex release];
        goto cleanup;
    }
    [ex release];
    ok = true;

    NSLog(@"[yabai-capture] stitched %d panels -> %@ (%ldx%ld @ %dfps, %.2fs)",
          n, out_path, (long)rw, (long)rh, target_fps, overlap);

    // ── 8. optional cleanup of source files + sidecars ─────────────────────────
    if (o->cleanup && o->group && *o->group) {
        for (int i = 0; i < n; i++) {
            NSString *p = panels[i].asset.URL.path;
            [[NSFileManager defaultManager] removeItemAtPath:p error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:[p stringByAppendingPathExtension:@"json"] error:nil];
        }
    }

cleanup:
    for (int i = 0; i < n; i++) {
        [panels[i].track release];
        [panels[i].asset release];
    }
    return ok;
}

#pragma clang diagnostic pop
