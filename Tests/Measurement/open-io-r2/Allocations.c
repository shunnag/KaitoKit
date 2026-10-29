#include <stdint.h>
#include <stdatomic.h>
// Darwin malloc_logger ABI. Count successful allocation events during open only.
extern void (*malloc_logger)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
static _Atomic uint64_t events, bytes;
static void log_allocation(uint32_t type, uintptr_t a, uintptr_t b, uintptr_t c, uintptr_t result, uint32_t skip) {
    if ((type & 2) && result) {
        atomic_fetch_add_explicit(&events, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&bytes, (type & 4) ? c : b, memory_order_relaxed);
    }
}
void kk_alloc_start(void) { events = 0; bytes = 0; malloc_logger = log_allocation; }
void kk_alloc_stop(void) { malloc_logger = 0; }
uint64_t kk_alloc_count(void) { return events; }
uint64_t kk_alloc_bytes(void) { return bytes; }
