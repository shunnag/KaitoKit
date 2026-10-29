// KaitoKit/CommonCrypto comparison only; build commands in the verification note.
#include "PBKDF2SHA1.h"
#include <stdio.h>
#include <time.h>
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }

// Alternative measured and rejected on ARM: copies of CommonCrypto's public
// contexts, with no per-round pad absorption. Fixed benchmark inputs only.
static void contexts(uint8_t output[66]) {
    uint8_t pad[64] = {0}, u[20], sum[20], salt[16] = {0};
    memcpy(pad, "KaitoFuzz", 9);
    CC_SHA1_CTX inner, outer, salted;
    CC_SHA1_Init(&inner); CC_SHA1_Init(&outer);
    for (unsigned i=0; i<64; ++i) pad[i] ^= 0x36;
    CC_SHA1_Update(&inner, pad, 64);
    for (unsigned i=0; i<64; ++i) pad[i] ^= 0x36 ^ 0x5c;
    CC_SHA1_Update(&outer, pad, 64);
    salted=inner; CC_SHA1_Update(&salted, salt, 16);
    for (unsigned block=1; block<=4; ++block) {
        uint8_t counter[4] = {0,0,0,(uint8_t)block};
        CC_SHA1_CTX i=salted, o=outer;
        CC_SHA1_Update(&i, counter, 4); CC_SHA1_Final(u, &i);
        CC_SHA1_Update(&o, u, 20); CC_SHA1_Final(u, &o);
        memcpy(sum,u,20);
        for (unsigned round=1; round<1000; ++round) {
            i=inner; o=outer;
            CC_SHA1_Update(&i,u,20); CC_SHA1_Final(u,&i);
            CC_SHA1_Update(&o,u,20); CC_SHA1_Final(u,&o);
            for (unsigned j=0; j<20; ++j) sum[j] ^= u[j];
        }
        memcpy(output+(block-1)*20, sum, block==4 ? 6 : 20);
    }
}

#if defined(__aarch64__) && !defined(KK_PBKDF2_SHA1_FORCE_PORTABLE)
static volatile uint32_t compression_sink;
// Compression-only reference: one dependent chain of 8,000 final blocks,
// no HMAC setup, context copies, serialization, PBKDF2 XOR, or output handling.
static __attribute__((target("sha2"), noinline)) void compression_floor(void) {
    kk_sha1_state initial = {{0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476}, 0xc3d2e1f0};
    kk_sha1_state u=initial;
    for (unsigned i=0; i<8000; ++i) u=kk_sha1_digest_block(initial,u);
    compression_sink=u.e;
}
#endif

int main(void) {
    uint8_t salt[16] = {0}, a[66], b[66], c[66];
    const uint8_t password[] = "KaitoFuzz";
    double samples[4][5];
    unsigned methods=3;
#if defined(__aarch64__) && !defined(KK_PBKDF2_SHA1_FORCE_PORTABLE)
    methods=4;
#endif
    for (unsigned sample=0; sample<5; ++sample) {
        for (unsigned method=0; method<methods; ++method) {
            double start=now();
            for (unsigned n=0; n<500; ++n) {
                if (method==0) CCKeyDerivationPBKDF(kCCPBKDF2,(const char *)password,9,salt,16,kCCPRFHmacAlgSHA1,1000,a,66);
                else if (method==1) contexts(c);
                else if (method==2) kk_pbkdf2_sha1(password,9,salt,16,1000,b,66);
#if defined(__aarch64__) && !defined(KK_PBKDF2_SHA1_FORCE_PORTABLE)
                else compression_floor();
#endif
            }
            samples[method][sample]=(now()-start)*2000;
        }
        if (memcmp(a,b,66) || memcmp(a,c,66)) return 1;
    }
    const char *names[]={"CommonCrypto", "copied-contexts", "selected", "compression-only"};
    for (unsigned method=0; method<methods; ++method) {
        for (unsigned i=0; i<5; ++i) for (unsigned j=i+1; j<5; ++j)
            if (samples[method][j] < samples[method][i]) {
                double t=samples[method][j]; samples[method][j]=samples[method][i]; samples[method][i]=t;
            }
        printf("%s median %.3f us/derivation\n",names[method],samples[method][2]);
    }
    return 0;
}
