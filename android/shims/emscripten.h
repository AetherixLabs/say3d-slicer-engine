// Native (Android) stand-ins for the few Emscripten calls bridge/slicer.cpp
// makes. Progress is delivered on the calling thread; there is no JS side.
#pragma once
#include <time.h>

#define EMSCRIPTEN_KEEPALIVE __attribute__((used, visibility("default")))
#define MAIN_THREAD_EM_ASM(...) ((void)0)
#define EM_ASM(...) ((void)0)

static inline double emscripten_get_now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}
