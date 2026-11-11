// zerofill_probe.c — reproduces, without libtorrent, the APFS behaviour behind the bounded-storage
// "allocation runaway" (BOUNDED_STORAGE.md, Disk full): a write that starts far beyond the end of a file
// whose last appends are still dirty in the buffer cache makes the kernel write zeros over the whole gap.
//
//   clang -O1 -o zerofill_probe zerofill_probe.c
//   zsh run_probe.sh            (fresh 3 GiB APFS sparse image, every mode, then detached and deleted)
//   zerofill_probe <dir> <mode> <trials> [far offset, default 4844421120]
//
// Each trial: a new file in <dir>; 3 threads append 256 KiB pwritev chunks (libtorrent's write-cache
// lines, ~37 MB/s) from a random piece (16-52 MiB) up to 80 MiB; then one 256 KiB pwritev at the far
// offset (a tail pin). Prints the far write's duration and the file's allocation before and after.
// Modes: plain   nothing else (the bug: ~40 % of trials allocate the whole gap / the whole volume)
//        fsync   fsync before the far write
//        pause   1 s pause before the far write
//        presize ftruncate to the final size right after the first append (the fork's fix)
//        late    ftruncate right after the burst of appends, dirty data at the end of the file
// A trial is RUNAWAY when the far write allocated more than 256 MiB.
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

static const long long kPiece = 4LL << 20, kChunk = 256LL << 10;
static int fd = -1;
static char buffer[256 << 10];
static long long nextOffset, endOffset;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static long long allocated(void) { struct stat s; fstat(fd, &s); return (long long)s.st_blocks * 512; }
static long long size(void) { struct stat s; fstat(fd, &s); return s.st_size; }

static void *appender(void *unused) {
    struct iovec v = {buffer, (size_t)kChunk};
    for (;;) {
        pthread_mutex_lock(&lock);
        long long offset = nextOffset; nextOffset += kChunk;
        pthread_mutex_unlock(&lock);
        if (offset >= endOffset) break;
        pwritev(fd, &v, 1, offset);
        usleep(20000);
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: %s <dir> <plain|fsync|pause|presize|late> <trials> [far offset]\n", argv[0]); return 2; }
    const char *mode = argv[2];
    int trials = atoi(argv[3]);
    long long far = argc > 4 ? atoll(argv[4]) / kPiece * kPiece : 4844421120LL;
    long long finalSize = far + kPiece;
    memset(buffer, 0x5a, sizeof buffer);
    char path[1024]; snprintf(path, sizeof path, "%s/probe.mkv", argv[1]);
    int runaways = 0;
    for (int t = 0; t < trials; t++) {
        unlink(path);
        fd = open(path, O_RDWR | O_CREAT, 0644);
        if (fd < 0) { perror("open"); return 1; }
        long long start = (long long)(arc4random_uniform(10) + 4) * kPiece;
        nextOffset = start; endOffset = 80LL << 20;
        if (!strcmp(mode, "presize")) {
            struct iovec v = {buffer, (size_t)kChunk};
            pwritev(fd, &v, 1, start);
            ftruncate(fd, finalSize);
        }
        pthread_t threads[3];
        for (int i = 0; i < 3; i++) pthread_create(&threads[i], NULL, appender, NULL);
        for (int i = 0; i < 3; i++) pthread_join(threads[i], NULL);
        if (!strcmp(mode, "fsync")) fsync(fd);
        if (!strcmp(mode, "pause")) sleep(1);
        if (!strcmp(mode, "late")) ftruncate(fd, finalSize);
        long long size0 = size(), alloc0 = allocated();
        struct iovec v = {buffer, (size_t)kChunk};
        double t0 = now();
        ssize_t written = pwritev(fd, &v, 1, far);
        double dt = now() - t0;
        long long alloc1 = allocated();
        int runaway = alloc1 - alloc0 > (256LL << 20);
        runaways += runaway;
        printf("trial %2d %-7s appends from %2lld MiB: size %lld -> %lld, allocated %lld -> %lld MiB, far write %zd B in %.3f s%s\n",
               t, mode, start >> 20, size0, size(), alloc0 >> 20, alloc1 >> 20, written, dt, runaway ? "  RUNAWAY" : "");
        fflush(stdout);
        close(fd);
        unlink(path);
        usleep(300000);
    }
    printf("%s: %d runaway(s) in %d trials\n", mode, runaways, trials);
    return 0;
}
