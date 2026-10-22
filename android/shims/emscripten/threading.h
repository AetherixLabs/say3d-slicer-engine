#pragma once
#include <pthread.h>
// Every thread may run the host's progress callback (the CLI's is thread-safe).
static inline int emscripten_is_main_runtime_thread(void) { return 1; }
static inline pthread_t emscripten_main_runtime_thread_id(void) { return pthread_self(); }
