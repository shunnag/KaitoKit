// Standalone C ASan/UBSan coverage of the imported instruction helper.
// clang -O1 -g -fsanitize=address,undefined Tests/Benchmarks/CRC16FoldingSanitizer.c -o CHECK
#include "../../Sources/CBzip2/CRC16Folding.h"
#include <stdio.h>
#include <stdlib.h>

static uint16_t tables[2048];
static uint16_t reference(const uint8_t *p, size_t n, uint16_t crc) {
    for (size_t i = 0; i < n; ++i) crc = (crc >> 8) ^ tables[(crc ^ p[i]) & 255];
    return crc;
}
int main(void) {
    for (unsigned i = 0; i < 256; ++i) {
        uint16_t c = i;
        for (int j = 0; j < 8; ++j) c = (c >> 1) ^ ((c & 1) ? 0xa001 : 0);
        tables[i] = c;
    }
    for (unsigned s = 1; s < 8; ++s)
        for (unsigned i = 0; i < 256; ++i) {
            uint16_t c = tables[(s-1)*256+i];
            tables[s*256+i] = (c >> 8) ^ tables[c & 255];
        }
    if (!kk_crc16_has_folding()) { puts("SKIP: carry-less multiply unavailable"); return 0; }
    uint64_t random = 0xc16a001;
    unsigned tested = 0;
    for (size_t n = 64; n <= 4096; n += 16) {
        for (size_t offset = 0; offset < 64; ++offset) {
            uint8_t *allocation = malloc(n + offset);
            if (!allocation) return 2;
            uint8_t *p = allocation + offset;
            for (size_t i = 0; i < n; ++i) {
                random = random * UINT64_C(6364136223846793005) + 1;
                p[i] = random >> 32;
            }
            uint16_t seed = random >> 16;
            if (kk_crc16_fold_blocks(p, n, seed, tables) != reference(p, n, seed)) return 1;
            free(allocation);
            ++tested;
        }
    }
    printf("C folding checks: %u, mismatches: 0\n", tested);
    return 0;
}
