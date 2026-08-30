#if !defined(_WIN32) && defined(__linux__)
#include <features.h>
// Only need shims on musl (glibc already provides these). Musl does NOT define __GLIBC__.
#if !defined(__GLIBC__)
// Musl compatibility shims for Dawn prebuilt (glibc) on musl

// __libc_single_threaded – glibc internal, Dawn/Tint checks it for single-thread opt
int __libc_single_threaded = 0;

// __isoc23_* – C23 versioned symbols, musl provides unversioned strto* – alias them
#include <stdlib.h>
unsigned long __isoc23_strtoul(const char *nptr, char **endptr, int base) {
    return strtoul(nptr, endptr, base);
}
long __isoc23_strtol(const char *nptr, char **endptr, int base) {
    return strtol(nptr, endptr, base);
}
long long __isoc23_strtoll(const char *nptr, char **endptr, int base) {
    return strtoll(nptr, endptr, base);
}
unsigned long long __isoc23_strtoull(const char *nptr, char **endptr, int base) {
    return strtoull(nptr, endptr, base);
}

// pthread_cond_clockwait – glibc extension, shim via pthread_cond_timedwait
// Signature: int pthread_cond_clockwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
//                                       clockid_t clock, const struct timespec *abstime)
#define _GNU_SOURCE
#include <pthread.h>
#include <time.h>
#include <errno.h>
int pthread_cond_clockwait(pthread_cond_t *cond, pthread_mutex_t *mutex,
                           clockid_t clock, const struct timespec *abstime) {
    // musl's pthread_cond_timedwait ignores clock, uses CLOCK_REALTIME.
    // For Dawn's usage (CLOCK_MONOTONIC vs REALTIME), this is close enough;
    // Dawn falls back to timedwait + retry on spurious wakeups.
    (void)clock;
    return pthread_cond_timedwait(cond, mutex, abstime);
}
#endif
#endif
