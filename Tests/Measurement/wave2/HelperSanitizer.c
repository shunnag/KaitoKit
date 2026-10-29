// Independent bit-step oracles from the CRC-64/XZ polynomial and KaitoKit's
// ZipCrypto recurrence. Exercise the header helpers with ASan and UBSan.
#include "CRC64Folding.h"
#include "ZipCryptoCRC.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t table[8 * 256];
static uint64_t crc64(uint64_t crc, const uint8_t *bytes, size_t count) {
    for (size_t i = 0; i < count; ++i) {
        crc ^= bytes[i];
        for (unsigned j = 0; j < 8; ++j)
            crc = (crc >> 1) ^ ((crc & 1) ? UINT64_C(0xC96C5795D7870F42) : 0);
    }
    return crc;
}
static uint32_t crc32(uint32_t crc, uint8_t byte) {
    crc ^= byte;
    for (unsigned j = 0; j < 8; ++j)
        crc = (crc >> 1) ^ ((crc & 1) ? 0xEDB88320u : 0);
    return crc;
}
int main(void) {
    for (unsigned i = 0; i < 256; ++i) {
        uint8_t byte = (uint8_t)i;
        table[i] = crc64(0, &byte, 1);
    }
    for (unsigned slice = 1; slice < 8; ++slice)
        for (unsigned i = 0; i < 256; ++i) {
            uint64_t previous = table[(slice - 1) * 256 + i];
            table[slice * 256 + i] = (previous >> 8) ^ table[previous & 255];
        }
    unsigned cases = 0;
    uint64_t random = 0xCA170002;
    for (size_t count = 0; count <= 4096; ++count) {
        size_t offset = count % 64;
        // The allocation ends exactly at the last byte, so ASan catches any
        // vector read beyond a complete block, including the zero-length case.
        uint8_t *allocation = malloc(count + offset + 1);
        assert(allocation);
        uint8_t *bytes = allocation + offset + 1;
        for (size_t i = 0; i < count; ++i) {
            random = random * UINT64_C(6364136223846793005) + 1;
            bytes[i] = (uint8_t)(random >> 32);
        }
        if (kk_crc64_has_folding() && count >= 64) {
            size_t blocks = count & ~(size_t)15;
            uint64_t actual = kk_crc64_fold_blocks(bytes, blocks, random, table);
            actual = crc64(actual, bytes + blocks, count - blocks);
            assert(actual == crc64(random, bytes, count));
        }
        if (kk_zipcrypto_has_crc32()) {
            uint32_t a = (uint32_t)random, b = (uint32_t)(random >> 32), c = ~a;
            uint32_t aa = a, bb = b, cc = c;
            uint8_t *expected = malloc(count + 1);
            assert(expected);
            for (size_t i = 0; i < count; ++i) {
                uint32_t t = cc | 2;
                uint8_t byte = bytes[i] ^ (uint8_t)((t * (t ^ 1)) >> 8);
                expected[i] = byte;
                aa = crc32(aa, byte);
                bb = (bb + (aa & 255)) * 134775813u + 1;
                cc = crc32(cc, (uint8_t)(bb >> 24));
            }
            kk_zipcrypto_decrypt(bytes, count, &a, &b, &c);
            assert(memcmp(bytes, expected, count) == 0);
            assert(a == aa && b == bb && c == cc);
            free(expected);
        }
        free(allocation);
        ++cases;
    }
#if !defined(__aarch64__)
    assert(!kk_crc64_has_folding() && !kk_zipcrypto_has_crc32());
#endif
    printf("%u cases; PMULL=%d CRC32=%d; no mismatches\n", cases,
           kk_crc64_has_folding(), kk_zipcrypto_has_crc32());
}
