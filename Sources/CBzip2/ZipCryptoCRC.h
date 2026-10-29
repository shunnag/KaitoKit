#ifndef KAITO_ZIPCRYPTO_CRC_H
#define KAITO_ZIPCRYPTO_CRC_H

// KaitoKit's existing ZipCrypto key recurrence (PKWARE APPNOTE.TXT) with
// Arm ACLE __crc32b instruction semantics: IEEE reflected CRC-32, no initial
// or final complement. SSE4.2 CRC32 is CRC-32C and cannot replace this step.
// Follows CRC16Folding.h's header-only bridge and per-function feature guard.
#include <stdint.h>
#include <stddef.h>
#include <sys/sysctl.h>

static inline int kk_zipcrypto_has_crc32(void) {
#if defined(__aarch64__)
    int supported = 0;
    size_t size = sizeof(supported);
    return sysctlbyname("hw.optional.armv8_crc32", &supported, &size, NULL, 0) == 0
        && size == sizeof(supported) && supported == 1;
#else
    return 0;
#endif
}

#if defined(__aarch64__)
#include <arm_acle.h>
// Dispatch once per buffer, rather than crossing a feature-target boundary
// twice per byte. Password initialization still uses the original Swift table.
static __inline__ __attribute__((target("crc"), noinline))
void kk_zipcrypto_decrypt(uint8_t *bytes, size_t count,
                          uint32_t *key0, uint32_t *key1, uint32_t *key2) {
    uint32_t a = *key0, b = *key1, c = *key2;
    for (size_t i = 0; i < count; ++i) {
        uint32_t t = c | 2;
        uint8_t decoded = bytes[i] ^ (uint8_t)((t * (t ^ 1)) >> 8);
        bytes[i] = decoded;
        a = __crc32b(a, decoded);
        b = (b + (a & 255)) * 134775813u + 1;
        c = __crc32b(c, (uint8_t)(b >> 24));
    }
    *key0 = a;
    *key1 = b;
    *key2 = c;
}
#else
static inline void kk_zipcrypto_decrypt(uint8_t *bytes, size_t count,
                                        uint32_t *key0, uint32_t *key1, uint32_t *key2) {
    // Unreachable: non-Arm callers use Swift's original IEEE CRC-32 table.
}
#endif
#endif
