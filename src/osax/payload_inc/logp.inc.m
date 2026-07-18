// Payload-side dev log. Compiled out by default — an injected payload must not
// write to /tmp on user machines; re-enable for development with
//   make PAYLOAD_EXTRA_FLAGS='-DYB_PAYLOAD_LOG=1'
#include <stdarg.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>

#ifndef YB_PAYLOAD_LOG
#define YB_PAYLOAD_LOG 0
#endif

#ifndef YB_LOG_TREE
#define YB_LOG_TREE "unknown"
#endif
#define LOGP_DIR  "/tmp/logs/yabai/" YB_LOG_TREE
#define LOGP_PATH LOGP_DIR "/yabai.log"

#if !YB_PAYLOAD_LOG

// NOTE: real function, not a macro — call sites keep their format-string checking.
static inline __attribute__((format(printf, 2, 3)))
void logpf(const char *tag, const char *fmt, ...) {
    (void)tag;
    (void)fmt;
}

#else

static int g_logp_fd = -1;

static void logp_init(void) {
    if (g_logp_fd != -1) return;
    mkdir("/tmp/logs", 0755);
    mkdir("/tmp/logs/yabai", 0755);
    mkdir(LOGP_DIR, 0755);
    g_logp_fd = open(LOGP_PATH, O_WRONLY | O_APPEND | O_CREAT, 0644);
}

static __attribute__((format(printf, 2, 3)))
void logpf(const char *tag, const char *fmt, ...) {
    logp_init();
    if (g_logp_fd == -1) return;

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
    int pad = taglen < 30 ? 30 - taglen : 0;

    char line[1024];
    int ln = snprintf(line, sizeof line, "%02d:%02d:%02d.%03d  %s:%*s %s\n",
                      tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000),
                      tag, pad, "", msg);
    if (ln < 0) return;
    if ((size_t)ln >= sizeof line) ln = sizeof line - 1;
    write(g_logp_fd, line, ln);
}

#endif // YB_PAYLOAD_LOG
