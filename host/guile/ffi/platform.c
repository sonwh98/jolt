#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#else
#define _POSIX_C_SOURCE 200809L
#endif

#include <errno.h>
#include <stdatomic.h>
#include <stdint.h>
#include <sys/stat.h>

void
jolt_guile_fence_release(void)
{
    atomic_thread_fence(memory_order_release);
}

void
jolt_guile_fence_acquire(void)
{
    atomic_thread_fence(memory_order_acquire);
}

int
jolt_guile_stat_mtime(const char *path, int64_t *out_sec, int64_t *out_nsec)
{
    struct stat st;

    if (path == NULL || out_sec == NULL || out_nsec == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (stat(path, &st) != 0) {
        return -1;
    }
#ifdef __APPLE__
    *out_sec = (int64_t)st.st_mtimespec.tv_sec;
    *out_nsec = (int64_t)st.st_mtimespec.tv_nsec;
#else
    *out_sec = (int64_t)st.st_mtim.tv_sec;
    *out_nsec = (int64_t)st.st_mtim.tv_nsec;
#endif
    return 0;
}
