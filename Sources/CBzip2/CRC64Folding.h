#ifndef KAITO_CRC64_FOLDING_H
#define KAITO_CRC64_FOLDING_H

// Original derivation from CRC-64/XZ's reflected ECMA-182 polynomial
// 0xC96C5795D7870F42 and generic GF(2) carry-less-multiply folding.
// Follows KaitoKit's CRC16Folding.h bridge, instruction and provenance pattern;
// no xz/liblzma or other archive/CRC implementation source was consulted.
#include "CRC16Folding.h"

static inline int kk_crc64_has_folding(void) {
#if defined(__aarch64__)
    return kk_crc16_has_folding(); // Apple FEAT_PMULL runtime query.
#else
    return 0; // Including x86_64: retain Swift's slice-by-eight implementation.
#endif
}

#if defined(__aarch64__)
// Precondition: PMULL checked, count >= 64 and divisible by 16; bytes spans
// count readable bytes and table spans the existing 8 * 256 UInt64 entries.
// memcpy-based vector loads accept unaligned input and never read a tail.
static __inline__ __attribute__((target("aes"), noinline))
uint64_t kk_crc64_fold_blocks(const uint8_t *bytes, size_t count,
                              uint64_t crc, const uint64_t *table) {
    // Q = (0xC96C5795D7870F42 << 1) ^ 1. In GF(2)[x]/Q,
    // x^-1 = 0xC96C5795D7870F42. At distance d, multiply the low/high
    // halves by x^-d / x^(64-d). Constants and all 128 basis-vector
    // identities are independently derived in wave2/CRC64Constants.py.
    const kk_crc_vec k512 = kk_crc_pair(0x6ae3efbb9dd441f3, 0x081f6054a7842df4);
    const kk_crc_vec k128 = kk_crc_pair(0xe05dd497ca393ae4, 0xdabe95afc7875f40);
    kk_crc_vec a = kk_crc_xor(kk_crc_load(bytes), kk_crc_pair(crc, 0));
    kk_crc_vec b = kk_crc_load(bytes + 16);
    kk_crc_vec c = kk_crc_load(bytes + 32);
    kk_crc_vec d = kk_crc_load(bytes + 48);
    bytes += 64;
    count -= 64;
    while (count >= 64) {
        a = kk_crc_xor(kk_crc_fold(a, k512), kk_crc_load(bytes));
        b = kk_crc_xor(kk_crc_fold(b, k512), kk_crc_load(bytes + 16));
        c = kk_crc_xor(kk_crc_fold(c, k512), kk_crc_load(bytes + 32));
        d = kk_crc_xor(kk_crc_fold(d, k512), kk_crc_load(bytes + 48));
        bytes += 64;
        count -= 64;
    }
    a = kk_crc_xor(kk_crc_fold(a, k128), b);
    a = kk_crc_xor(kk_crc_fold(a, k128), c);
    a = kk_crc_xor(kk_crc_fold(a, k128), d);
    while (count >= 16) {
        a = kk_crc_xor(kk_crc_fold(a, k128), kk_crc_load(bytes));
        bytes += 16;
        count -= 16;
    }
    // Reduce the final 128-bit representative with the existing tables. This
    // is exactly two eight-byte steps, with no extra input reads or allocation.
    uint64_t words[2];
    memcpy(words, &a, 16);
    crc = 0;
    for (unsigned i = 0; i < 2; ++i) {
        uint64_t w = words[i] ^ crc;
        crc = table[7*256 + (w & 255)] ^ table[6*256 + ((w >> 8) & 255)]
            ^ table[5*256 + ((w >> 16) & 255)] ^ table[4*256 + ((w >> 24) & 255)]
            ^ table[3*256 + ((w >> 32) & 255)] ^ table[2*256 + ((w >> 40) & 255)]
            ^ table[256 + ((w >> 48) & 255)] ^ table[w >> 56];
    }
    return crc;
}
#else
static inline uint64_t kk_crc64_fold_blocks(const uint8_t *bytes, size_t count,
                                           uint64_t crc, const uint64_t *table) {
    return crc; // Unreachable: feature detection is false.
}
#endif
#endif
