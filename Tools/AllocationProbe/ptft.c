// ptft.c — file-syscall tracer used to find the cause of the bounded-storage allocation runaway (e2e B1),
// for DEBUG builds only, injected with DYLD_INSERT_LIBRARIES (the app is not changed; see run_probe.sh).
// Traces every syscall on files whose path contains $PTFT_MATCH (default ".mkv") and ends in ".mkv":
// open/close/pwrite(v)/write(v)/pread(v)/read/ftruncate/fcntl/lseek/mmap/fsync, with the file's st_size and
// allocated bytes (st_blocks) before and after, the duration and the thread. A sampler thread stats the file every
// $PTFT_SAMPLE_MS (default 10) ms and logs every allocation change >= 4 MiB together with the syscalls in flight.
// Extending writes (offset > st_size) and size-changing calls log a backtrace.
//   PTFT_LOG=<file>         trace output (required, otherwise the tracer is off)
//   PTFT_SKIP_PRESIZE=1     swallow ftruncate() that grows the traced file (turns the fork's presize mitigation off)
//   PTFT_READS=1            also log every read (default: only slow reads / reads that change the file)
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } _interpose_##_replacee \
    __attribute__((section("__DATA,__interpose"))) = {(const void *)(unsigned long)&_replacement, (const void *)(unsigned long)&_replacee};

#define MAXFD 4096
static _Atomic(char *) g_paths[MAXFD];      // traced fds -> path (strdup), NULL = not traced
static int g_log = -1;
static int g_skipPresize = 0, g_reads = 0, g_sampleMs = 10;
static const char *g_match = ".mkv";
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(char *) g_lastPath = NULL;   // most recently opened traced path (for the sampler)

// syscalls in flight
#define SLOTS 64
typedef struct { _Atomic int used; uint64_t tid; char op[16]; int fd; long long off, len; double t0; } Slot;
static Slot g_slots[SLOTS];

static double now(void) { struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); return ts.tv_sec + ts.tv_nsec / 1e9; }
static uint64_t tid(void) { uint64_t t; pthread_threadid_np(NULL, &t); return t; }

static void emit(const char *fmt, ...) {
    if (g_log < 0) return;
    char line[2048];
    double t = now(); time_t s = (time_t)t; struct tm tm; localtime_r(&s, &tm);
    int n = snprintf(line, sizeof line, "%02d:%02d:%02d.%03d ", tm.tm_hour, tm.tm_min, tm.tm_sec, (int)((t - s) * 1000));
    va_list ap; va_start(ap, fmt); n += vsnprintf(line + n, sizeof line - n, fmt, ap); va_end(ap);
    if (n > (int)sizeof line - 2) n = sizeof line - 2;
    line[n++] = '\n';
    pthread_mutex_lock(&g_logLock); write(g_log, line, n); pthread_mutex_unlock(&g_logLock);
}

static void emitBacktrace(void) {
    if (g_log < 0) return;
    void *frames[24]; int n = backtrace(frames, 24);
    char **syms = backtrace_symbols(frames, n);
    pthread_mutex_lock(&g_logLock);
    for (int i = 1; i < n && syms; i++) { write(g_log, "    bt ", 7); write(g_log, syms[i], strlen(syms[i])); write(g_log, "\n", 1); }
    pthread_mutex_unlock(&g_logLock);
    free(syms);
}

static int traced(int fd) { return fd >= 0 && fd < MAXFD && atomic_load(&g_paths[fd]) != NULL; }
static int matches(const char *path) {
    if (!path || g_log < 0) return 0;
    size_t l = strlen(path);
    return l > 4 && strcmp(path + l - 4, ".mkv") == 0 && strstr(path, g_match) != NULL;
}
static void st(int fd, long long *size, long long *alloc) {
    struct stat s; if (fstat(fd, &s) == 0) { *size = s.st_size; *alloc = (long long)s.st_blocks * 512; } else { *size = -1; *alloc = -1; }
}
static int slotBegin(const char *op, int fd, long long off, long long len) {
    for (int i = 0; i < SLOTS; i++) {
        int z = 0;
        if (atomic_compare_exchange_strong(&g_slots[i].used, &z, 2)) {
            g_slots[i].tid = tid(); strncpy(g_slots[i].op, op, 15); g_slots[i].fd = fd; g_slots[i].off = off; g_slots[i].len = len; g_slots[i].t0 = now();
            atomic_store(&g_slots[i].used, 1);
            return i;
        }
    }
    return -1;
}
static void slotEnd(int i) { if (i >= 0) atomic_store(&g_slots[i].used, 0); }

#define MiB (1024.0 * 1024.0)
static void report(const char *op, int fd, long long off, long long len, long long ret, int err, double t0,
                   long long s0, long long a0, long long s1, long long a1, int always) {
    double dt = now() - t0;
    int changed = s1 != s0 || (a1 - a0) > 4 * 1024 * 1024 || (a0 - a1) > 4 * 1024 * 1024;
    if (!always && !changed && dt < 0.02) return;
    emit("%-9s tid=%llu fd=%d off=%lld len=%lld ret=%lld errno=%d dt=%.4f size %lld->%lld alloc %.1f->%.1f MiB%s",
         op, (unsigned long long)tid(), fd, off, len, ret, ret < 0 ? err : 0, dt, s0, s1, a0 / MiB, a1 / MiB,
         changed && (a1 - a0) > 64 * 1024 * 1024 ? "  <<< ALLOC JUMP" : "");
}

// ---- interposed calls ----
static int my_open(const char *path, int flags, ...) {
    int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    int fd = open(path, flags, mode);
    int err = errno;
    if (fd >= 0 && fd < MAXFD && matches(path)) {
        char *old = atomic_exchange(&g_paths[fd], strdup(path)); free(old);
        char *prev = atomic_exchange(&g_lastPath, strdup(path)); (void)prev; // leaked on purpose (sampler may read it)
        long long s, a; st(fd, &s, &a);
        emit("open      tid=%llu fd=%d flags=0x%x path=%s size=%lld alloc=%.1f MiB", (unsigned long long)tid(), fd, flags, path, s, a / MiB);
        emitBacktrace();
    }
    errno = err;
    return fd;
}
DYLD_INTERPOSE(my_open, open)

static int my_close(int fd) {
    if (traced(fd)) {
        long long s, a; st(fd, &s, &a);
        emit("close     tid=%llu fd=%d size=%lld alloc=%.1f MiB", (unsigned long long)tid(), fd, s, a / MiB);
        char *old = atomic_exchange(&g_paths[fd], NULL); free(old);
    }
    return close(fd);
}
DYLD_INTERPOSE(my_close, close)

#define WRAP_IO(name, isWrite, call, offExpr, lenExpr) \
    if (!traced(fd)) return call; \
    long long s0, a0, s1, a1; st(fd, &s0, &a0); \
    long long off_ = (offExpr), len_ = (lenExpr); \
    int extending = (isWrite) && off_ > s0 + 64LL * 1024 * 1024; \
    if (extending) { emit("%s BEGIN extending write tid=%llu fd=%d off=%lld len=%lld size=%lld alloc=%.1f MiB", name, (unsigned long long)tid(), fd, off_, len_, s0, a0 / MiB); emitBacktrace(); } \
    int slot_ = slotBegin(name, fd, off_, len_); double t0 = now(); \
    long long ret = call; int err = errno; \
    slotEnd(slot_); st(fd, &s1, &a1); \
    report(name, fd, off_, len_, ret, err, t0, s0, a0, s1, a1, (isWrite) || g_reads); \
    errno = err; return ret;

static long long iovlen(const struct iovec *v, int n) { long long t = 0; for (int i = 0; i < n; i++) t += v[i].iov_len; return t; }

static ssize_t my_pwrite(int fd, const void *b, size_t n, off_t o) { WRAP_IO("pwrite", 1, pwrite(fd, b, n, o), o, n) }
DYLD_INTERPOSE(my_pwrite, pwrite)
static ssize_t my_pwritev(int fd, const struct iovec *v, int c, off_t o) { WRAP_IO("pwritev", 1, pwritev(fd, v, c, o), o, iovlen(v, c)) }
DYLD_INTERPOSE(my_pwritev, pwritev)
static ssize_t my_write(int fd, const void *b, size_t n) { WRAP_IO("write", 1, write(fd, b, n), lseek(fd, 0, SEEK_CUR), n) }
DYLD_INTERPOSE(my_write, write)
static ssize_t my_writev(int fd, const struct iovec *v, int c) { WRAP_IO("writev", 1, writev(fd, v, c), lseek(fd, 0, SEEK_CUR), iovlen(v, c)) }
DYLD_INTERPOSE(my_writev, writev)
static ssize_t my_pread(int fd, void *b, size_t n, off_t o) { WRAP_IO("pread", 0, pread(fd, b, n, o), o, n) }
DYLD_INTERPOSE(my_pread, pread)
static ssize_t my_preadv(int fd, const struct iovec *v, int c, off_t o) { WRAP_IO("preadv", 0, preadv(fd, v, c, o), o, iovlen(v, c)) }
DYLD_INTERPOSE(my_preadv, preadv)
static ssize_t my_read(int fd, void *b, size_t n) { WRAP_IO("read", 0, read(fd, b, n), lseek(fd, 0, SEEK_CUR), n) }
DYLD_INTERPOSE(my_read, read)
static int my_fsync(int fd) { WRAP_IO("fsync", 0, fsync(fd), 0, 0) }
DYLD_INTERPOSE(my_fsync, fsync)

static int my_ftruncate(int fd, off_t len) {
    if (!traced(fd)) return ftruncate(fd, len);
    long long s0, a0, s1, a1; st(fd, &s0, &a0);
    if (g_skipPresize && len > s0) {
        emit("ftruncate SKIPPED (PTFT_SKIP_PRESIZE) tid=%llu fd=%d len=%lld size=%lld alloc=%.1f MiB", (unsigned long long)tid(), fd, (long long)len, s0, a0 / MiB);
        return 0;
    }
    int slot_ = slotBegin("ftruncate", fd, len, 0); double t0 = now();
    int ret = ftruncate(fd, len); int err = errno;
    slotEnd(slot_); st(fd, &s1, &a1);
    report("ftruncate", fd, len, 0, ret, err, t0, s0, a0, s1, a1, 1);
    emitBacktrace();
    errno = err; return ret;
}
DYLD_INTERPOSE(my_ftruncate, ftruncate)

static off_t my_lseek(int fd, off_t o, int whence) {
    if (!traced(fd) || whence == SEEK_CUR) return lseek(fd, o, whence);
    long long s0, a0, s1, a1; st(fd, &s0, &a0);
    int slot_ = slotBegin("lseek", fd, o, whence); double t0 = now();
    off_t ret = lseek(fd, o, whence); int err = errno;
    slotEnd(slot_); st(fd, &s1, &a1);
    report(whence == SEEK_HOLE ? "seek_hole" : whence == SEEK_DATA ? "seek_data" : "lseek", fd, o, whence, ret, err, t0, s0, a0, s1, a1, g_reads);
    errno = err; return ret;
}
DYLD_INTERPOSE(my_lseek, lseek)

static int my_fcntl(int fd, int cmd, ...) {
    va_list ap; va_start(ap, cmd); void *arg = va_arg(ap, void *); va_end(ap);
    if (!traced(fd) || cmd == F_GETFL || cmd == F_GETFD || cmd == F_SETFD) return fcntl(fd, cmd, arg);
    long long s0, a0, s1, a1; st(fd, &s0, &a0);
    long long off = 0, len = 0; const char *name = "fcntl";
    if (cmd == F_PUNCHHOLE) { fpunchhole_t *h = arg; off = h->fp_offset; len = h->fp_length; name = "punchhole"; }
    else if (cmd == F_PREALLOCATE) { fstore_t *f = arg; off = f->fst_offset; len = f->fst_length; name = "PREALLOC"; }
    else if (cmd == F_NOCACHE) name = "nocache";
    else if (cmd == F_RDADVISE) name = "rdadvise";
    else if (cmd == F_FULLFSYNC) name = "fullfsync";
    int slot_ = slotBegin(name, fd, off, len); double t0 = now();
    int ret = fcntl(fd, cmd, arg); int err = errno;
    slotEnd(slot_); st(fd, &s1, &a1);
    char op[24]; snprintf(op, sizeof op, "%s/%d", name, cmd);
    report(op, fd, off, len, ret, err, t0, s0, a0, s1, a1, 1);
    if (cmd == F_PREALLOCATE) emitBacktrace();
    errno = err; return ret;
}
DYLD_INTERPOSE(my_fcntl, fcntl)

static void *my_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    if (traced(fd)) { emit("mmap      tid=%llu fd=%d off=%lld len=%zu prot=%d flags=0x%x", (unsigned long long)tid(), fd, (long long)off, len, prot, flags); emitBacktrace(); }
    return mmap(addr, len, prot, flags, fd, off);
}
DYLD_INTERPOSE(my_mmap, mmap)

// ---- sampler ----
static void *sampler(void *unused) {
    long long lastAlloc = -1, lastSize = -1;
    char *lastPath = NULL;
    for (;;) {
        usleep(g_sampleMs * 1000);
        char *path = atomic_load(&g_lastPath);
        if (!path) continue;
        if (path != lastPath) { lastPath = path; lastAlloc = -1; lastSize = -1; }
        struct stat s; if (stat(path, &s) != 0) continue;
        long long a = (long long)s.st_blocks * 512, sz = s.st_size;
        if (lastAlloc < 0 || sz != lastSize || a - lastAlloc >= 4 * 1024 * 1024 || lastAlloc - a >= 4 * 1024 * 1024) {
            char inflight[1024]; int n = 0; inflight[0] = 0; double t = now();
            for (int i = 0; i < SLOTS && n < (int)sizeof inflight - 100; i++) {
                if (atomic_load(&g_slots[i].used) != 1) continue;
                n += snprintf(inflight + n, sizeof inflight - n, " [%s tid=%llu off=%lld len=%lld for %.3fs]", g_slots[i].op,
                              (unsigned long long)g_slots[i].tid, g_slots[i].off, g_slots[i].len, t - g_slots[i].t0);
            }
            emit("SAMPLE size=%lld alloc=%.1f MiB (%+.1f) inflight:%s", sz, a / MiB, lastAlloc < 0 ? 0.0 : (a - lastAlloc) / MiB, inflight);
            lastAlloc = a; lastSize = sz;
        }
    }
    return NULL;
}

__attribute__((constructor)) static void init(void) {
    const char *log = getenv("PTFT_LOG");
    if (!log) return;
    g_log = open(log, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (getenv("PTFT_MATCH")) g_match = getenv("PTFT_MATCH");
    g_skipPresize = getenv("PTFT_SKIP_PRESIZE") && atoi(getenv("PTFT_SKIP_PRESIZE"));
    g_reads = getenv("PTFT_READS") && atoi(getenv("PTFT_READS"));
    if (getenv("PTFT_SAMPLE_MS")) g_sampleMs = atoi(getenv("PTFT_SAMPLE_MS"));
    if (g_sampleMs < 1) g_sampleMs = 10;
    emit("ptft loaded pid=%d match=%s skipPresize=%d reads=%d sampleMs=%d", getpid(), g_match, g_skipPresize, g_reads, g_sampleMs);
    pthread_t t; pthread_create(&t, NULL, sampler, NULL); pthread_detach(t);
}
