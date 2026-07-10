#ifndef CAPTURE_H
#define CAPTURE_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

// Policy when an output file already exists. Zero default = rename (never clobber,
// never block); the directory itself is always reused, this governs files only.
enum capture_if_exists {
    CAPTURE_IF_EXISTS_RENAME    = 0, // write <stem>-N.<ext> (first free N)
    CAPTURE_IF_EXISTS_OVERWRITE = 1, // delete the existing file and reuse the name
    CAPTURE_IF_EXISTS_FAIL      = 2, // error out, write nothing
};

// Output container. Zero default = mp4 (the portable, near-universal target);
// mov is QuickTime, useful only for Apple-only track types. HEVC is written into
// either container with no quality difference (same encoder, just the wrapper).
enum capture_container {
    CAPTURE_CONTAINER_MP4 = 0, // .mp4 (AVFileTypeMPEG4)
    CAPTURE_CONTAINER_MOV = 1, // .mov (AVFileTypeQuickTimeMovie)
};

struct capture_options {
    uint32_t wid;        // 0 -> active display, full bounds
    int      padding;    // points, expand around wid bounds on all sides
    int      duration;   // seconds; 0 -> until capture_stop
    int      fps;        // default 120
    float    scale;      // default 0.25 (multiplier on captured pixel dims)
    float    bpp;        // default 0.6 (HEVC bits-per-pixel-per-frame target)
    bool     cursor;     // include cursor in the capture (default false)
    char    *name;       // optional filename suffix; appended after _<timestamp>
    uint32_t display;    // 0 -> active display, else a specific display id
    bool     all_displays; // capture every display, one file each (display:all)
    int      if_exists;  // enum capture_if_exists (default rename)
    int      container;  // enum capture_container (default mp4)
};

enum capture_stitch_layout {
    CAPTURE_STITCH_SIDEBYSIDE = 0, // equal-height columns left-to-right
    CAPTURE_STITCH_FAITHFUL   = 1, // reproduce real monitor arrangement
};

struct capture_stitch_options {
    char   *group;        // group name -> glob the per-display files; NULL when files given
    char  **files;        // explicit input .mov paths (alternative to group)
    int     file_count;   // number of entries in files
    int     layout;       // enum capture_stitch_layout (default sidebyside)
    int     border;       // black matte inset on every side, pixels (default 0)
    int     gap;          // black gap between panels, pixels (default = border)
    bool    match_height; // scale higher-res panels down to a common height (default true)
    char   *out;          // output .mov path; NULL -> ~/Movies/<group>/<group>_stitched.mov
    bool    cleanup;      // delete source files + sidecars after a successful export
    int     if_exists;    // enum capture_if_exists (default rename)
    int     container;    // enum capture_container (default mp4)
};

bool capture_start(struct capture_options *opts, char *err, size_t err_len);
bool capture_stop(char *err, size_t err_len);
void capture_status(char *out, size_t out_len);
bool capture_is_active(void);
bool capture_stitch(struct capture_stitch_options *opts, char *err, size_t err_len);

#endif
