#ifndef LOG_H
#define LOG_H

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <mach/mach_time.h>
#include <stdbool.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>

extern bool g_verbose;

// NOTE: "HH:MM:SS.mmm  TAG: message", teed to stdout and YB_LOG_PATH. The
// token before the first '_' in TAG is the family — it keys the YABAI_LOG
// filter. YB_LOG_TREE is injected by the makefile (-DYB_LOG_TREE).
#ifndef YB_LOG_TREE
#define YB_LOG_TREE "unknown"
#endif
#define YB_LOG_DIR         "/tmp/logs/yabai/" YB_LOG_TREE
#define YB_LOG_PATH        YB_LOG_DIR "/yabai.log"
#define YB_TAG_WIDTH 30

static int  g_yb_log_fd = -1;
static char g_yb_log_filter[256] = "";

static inline void yb_log_lower(char *s) {
    for (; *s; ++s) if (*s >= 'A' && *s <= 'Z') *s += 32;
}

static inline void yb_log_init(void) {
    if (g_yb_log_fd != -1) return;
    mkdir("/tmp/logs", 0755);
    mkdir("/tmp/logs/yabai", 0755);
    mkdir(YB_LOG_DIR, 0755);
    g_yb_log_fd = open(YB_LOG_PATH, O_WRONLY | O_APPEND | O_CREAT, 0644);
    const char *f = getenv("YABAI_LOG");
    if (f && f[0]) {
        snprintf(g_yb_log_filter, sizeof g_yb_log_filter, ",%s,", f);
        yb_log_lower(g_yb_log_filter);
    }
}

static inline bool yb_tag_has_prefix(const char *tag, const char *pfx) {
    for (size_t i = 0; pfx[i]; ++i) {
        char a = tag[i]; if (a >= 'a' && a <= 'z') a -= 32;
        if (a != pfx[i]) return false;
    }
    return true;
}

static inline const char *yb_family_color(const char *tag, size_t fam_len) {
    if (yb_tag_has_prefix(tag, "SLS_WIN_")) return "\x1b[92m";
    if (yb_tag_has_prefix(tag, "SLS_PL_"))  return "\x1b[95m";

    static const struct { const char *name; const char *ansi; } T[] = {
        {"EVENT","\x1b[36m"}, {"RUN","\x1b[90m"},     {"STAGES","\x1b[35m"},
        {"WINDOW","\x1b[34m"},{"PROCESS","\x1b[33m"}, {"FOCUS","\x1b[32m"},
        {"SLS","\x1b[35m"},   {"SA","\x1b[31m"},      {"PAYLOAD","\x1b[31m"},
        {"GBO","\x1b[31m"},   {"MOUSE","\x1b[90m"},   {"DISPLAY","\x1b[34m"},
        {"LAYOUT","\x1b[34m"},{"DAEMON","\x1b[90m"},
        {"MARKER","\x1b[93m"},
    };
    for (size_t i = 0; i < sizeof(T)/sizeof(T[0]); ++i) {
        if (strlen(T[i].name) != fam_len) continue;
        bool eq = true;
        for (size_t k = 0; k < fam_len; ++k) {
            char a = tag[k]; if (a >= 'a' && a <= 'z') a -= 32;
            if (a != T[i].name[k]) { eq = false; break; }
        }
        if (eq) return T[i].ansi;
    }
    return "";
}

static inline bool yb_family_enabled(const char *tag, size_t fam_len) {
    if (!g_yb_log_filter[0]) return true;
    char needle[80];
    if (fam_len > sizeof(needle) - 3) fam_len = sizeof(needle) - 3;
    needle[0] = ',';
    memcpy(needle + 1, tag, fam_len);
    needle[1 + fam_len] = ',';
    needle[2 + fam_len] = '\0';
    yb_log_lower(needle);
    return strstr(g_yb_log_filter, needle) != NULL;
}

static inline int yb_indent_copy(char *dst, int cap, const char *msg, int indent) {
    int o = 0;
    for (const char *s = msg; *s && o < cap - 1; ++s) {
        dst[o++] = *s;
        if (*s == '\n') {
            for (int i = 0; i < indent && o < cap - 1; ++i) dst[o++] = ' ';
        }
    }
    if (o < cap) dst[o] = '\0';
    return o;
}

static inline void yb_emit_bg(const char *s, const char *bg) {
    if (!bg[0]) { fputs(s, stdout); fputc('\n', stdout); return; }
    fputs(bg, stdout);
    for (const char *p = s; *p; ++p) {
        if (*p == '\n') { fputs("\x1b[K\x1b[0m\n", stdout); fputs(bg, stdout); }
        else fputc(*p, stdout);
    }
    fputs("\x1b[K\x1b[0m\n", stdout);
}

static inline __attribute__((format(printf, 2, 3)))
void yb_logf(const char *tag, const char *fmt, ...) {
    if (!g_verbose) return;
    yb_log_init();

    size_t fam = 0;
    while (tag[fam] && tag[fam] != '_') ++fam;
    if (!yb_family_enabled(tag, fam)) return;

    struct timeval tv; gettimeofday(&tv, NULL);
    struct tm tmv;     localtime_r(&tv.tv_sec, &tmv);

    char msg[960];
    va_list args; va_start(args, fmt);
    int mn = vsnprintf(msg, sizeof msg, fmt, args);
    va_end(args);
    if (mn < 0) return;
    size_t mlen = ((size_t)mn < sizeof msg) ? (size_t)mn : sizeof msg - 1;
    while (mlen && msg[mlen - 1] == '\n') msg[--mlen] = '\0';

    int taglen = (int)strlen(tag) + 1;
    int pad = taglen < YB_TAG_WIDTH ? YB_TAG_WIDTH - taglen : 0;
    int tagfield = (taglen < YB_TAG_WIDTH ? YB_TAG_WIDTH : taglen) + 1;

    char ts[16];
    int tslen = snprintf(ts, sizeof ts, "%02d:%02d:%02d.%03d",
                         tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000));

    char body[1536];

    // NOTE: single write() per entry — the O_APPEND log file is shared, so a
    // split write interleaves entries.
    int o = snprintf(body, sizeof body, "%s  %s:%*s ", ts, tag, pad, "");
    o += yb_indent_copy(body + o, (int)sizeof body - o, msg, tslen + 2 + tagfield);
    if (o < (int)sizeof body - 1) body[o++] = '\n';
    if (g_yb_log_fd != -1) write(g_yb_log_fd, body, o);

    static int tty = 0;
    if (tty == 0) tty = isatty(fileno(stdout)) ? 1 : 2;
    const char *c = (tty == 1) ? yb_family_color(tag, fam) : "";
    o = c[0] ? snprintf(body, sizeof body, "%s%s:\x1b[39m%*s ", c, tag, pad, "")
             : snprintf(body, sizeof body, "%s:%*s ", tag, pad, "");
    o += yb_indent_copy(body + o, (int)sizeof body - o, msg, tagfield);

    if (tty == 1) {
        static unsigned s_entry = 0;
        const char *bg = (s_entry++ & 1u) ? "\x1b[48;5;236m" : "";
        yb_emit_bg(body, bg);
    } else {
        fwrite(body, 1, o, stdout);
        fputc('\n', stdout);
    }
    fflush(stdout);
}

#define LOGFT(tag, ...) yb_logf((tag), __VA_ARGS__)
#define LOGF(...)       yb_logf(LOG_CAT, __VA_ARGS__)

static inline __attribute__((format(printf, 1, 2)))
void
debug(const char *format, ...)
{
    if (!g_verbose) return;

    va_list args;
    va_start(args, format);
    vfprintf(stdout, format, args);
    va_end(args);

    yb_log_init();
    if (g_yb_log_fd != -1) {
        char buf[1024];
        va_start(args, format);
        int n = vsnprintf(buf, sizeof buf, format, args);
        va_end(args);
        if (n > 0) write(g_yb_log_fd, buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
    }
}

static inline void
warn(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);
}

static inline void
error(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);

    exit(EXIT_FAILURE);
}

static inline void
require(const char *format, ...)
{
    va_list args;
    va_start(args, format);
    vfprintf(stderr, format, args);
    va_end(args);

    exit(EXIT_SUCCESS);
}

static inline void
debug_message(const char *prefix, char *message)
{
    if (!g_verbose) return;

    fprintf(stdout, "%s:", prefix);

    for (;*message;) {
        message += fprintf(stdout, " %s", message);
    }

    putc('\n', stdout);
    fflush(stdout);
}

#endif

