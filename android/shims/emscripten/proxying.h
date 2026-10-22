#pragma once
#include <pthread.h>
typedef struct em_proxying_queue em_proxying_queue;
static inline em_proxying_queue* emscripten_proxy_get_system_queue(void) { return 0; }
static inline int emscripten_proxy_sync(em_proxying_queue* q, pthread_t t, void (*fn)(void*), void* arg) {
    (void)q; (void)t; fn(arg); return 1;
}
