// Standalone ASan/portable-path oracle. Only Apple's CommonCrypto is used.
#include "PBKDF2SHA1.h"
#include <stdio.h>
#include <stdlib.h>
static uint64_t seed = UINT64_C(0x801821041804);
static unsigned random_below(unsigned n) {
    seed = seed * UINT64_C(6364136223846793005) + UINT64_C(1442695040888963407);
    return (unsigned)((seed >> 16) % n);
}
static void verify(size_t pn, size_t sn, unsigned iterations, size_t on) {
    // Offset inputs/output by one byte to exercise unaligned vector accesses.
    uint8_t *p = malloc(pn + 1), *s = malloc(sn + 1), *o = malloc(on + 2), *ref = malloc(on);
    if (!p || !s || !o || !ref) abort();
    for (size_t n = 0; n < pn; ++n) p[n+1] = random_below(256);
    for (size_t n = 0; n < sn; ++n) s[n+1] = random_below(256);
    o[0] = 0x37; o[on+1] = 0x59;
    int a = kk_pbkdf2_sha1(pn ? p+1 : NULL, pn, sn ? s+1 : NULL, sn, iterations, o+1, on);
    int b = CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)(p+1), pn, s+1, sn,
                                kCCPRFHmacAlgSHA1, iterations, ref, on);
    if (a || b || memcmp(o+1, ref, on) || o[0] != 0x37 || o[on+1] != 0x59) {
        fprintf(stderr, "mismatch p=%zu s=%zu iterations=%u dk=%zu\n", pn, sn, iterations, on);
        abort();
    }
    free(p); free(s); free(o); free(ref);
}
int main(void) {
    size_t passwords[] = {0,1,63,64,65,200}, salts[] = {8,12,16}, lengths[] = {34,50,66};
    unsigned rounds[] = {1,2,1000};
    for (unsigned p=0; p<6; ++p) for (unsigned s=0; s<3; ++s)
        for (unsigned i=0; i<3; ++i) for (unsigned d=0; d<3; ++d)
            verify(passwords[p], salts[s], rounds[i], lengths[d]);
    for (unsigned n=0; n<10000; ++n) {
        size_t p=random_below(257), s=random_below(161), d=1+random_below(101);
        unsigned iterations[] = {1,2,3,17,1000};
        verify(p,s,iterations[random_below(5)],d);
    }
    verify(4097,1024,2,66);
    verify(3,0,2,5141);
    uint8_t o[1];
    if (kk_pbkdf2_sha1(NULL,0,NULL,0,0,o,1) != kCCParamError ||
        kk_pbkdf2_sha1(NULL,0,NULL,0,1,o,0) != kCCParamError ||
        kk_pbkdf2_sha1(NULL,0,NULL,0,1,o,(size_t)UINT32_MAX*20+1) != kCCParamError) abort();
    puts("162 matrix + 10000 random + 2 boundary cases; parameter checks: PASS");
}
