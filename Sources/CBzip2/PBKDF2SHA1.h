#ifndef KAITO_PBKDF2_SHA1_H
#define KAITO_PBKDF2_SHA1_H

// Clean-room derivation: RFC 8018 section 5.2, RFC 2104 sections 2/4,
// FIPS 180-4 sections 4.1.1, 4.2.1, 5 and 6.1; Apple CommonDigest.h.
// No third-party cryptographic or archive implementation was consulted.
#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <CommonCrypto/CommonCryptoError.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>

#if defined(__aarch64__) && !defined(KK_PBKDF2_SHA1_FORCE_PORTABLE)
// Supported arm64 macOS hardware provides SHA-1 instructions. Clang groups
// these intrinsics under the "sha2" target feature; Intel takes the fallback.
#include <arm_neon.h>
typedef struct { uint32x4_t abcd; uint32_t e; } kk_sha1_state;

// One final block after the 64-byte HMAC pad: 20 digest bytes, 0x80,
// zeros, and the big-endian bit length (64 + 20) * 8 = 672.
// Words remain in host order between the inner and outer compressions.
static __inline__ __attribute__((target("sha2"), always_inline))
kk_sha1_state kk_sha1_digest_block(kk_sha1_state initial, kk_sha1_state message) {
    uint32x4_t w[4] = {
        message.abcd, {message.e, 0x80000000, 0, 0},
        {0, 0, 0, 0}, {0, 0, 0, 672}
    };
    uint32x4_t abcd = initial.abcd;
    uint32_t e = initial.e;
#pragma clang loop unroll(full)
    for (unsigned group = 0; group < 20; ++group) {
        unsigned i = group & 3;
        if (group >= 4) {
            w[i] = vsha1su1q_u32(vsha1su0q_u32(w[i], w[(i+1)&3], w[(i+2)&3]), w[(i+3)&3]);
        }
        uint32_t next_e = vsha1h_u32(vgetq_lane_u32(abcd, 0));
        uint32_t k = group < 5 ? 0x5a827999 : group < 10 ? 0x6ed9eba1
                     : group < 15 ? 0x8f1bbcdc : 0xca62c1d6;
        uint32x4_t wk = vaddq_u32(w[i], vdupq_n_u32(k));
        if (group < 5) abcd = vsha1cq_u32(abcd, e, wk);
        else if (group < 10 || group >= 15) abcd = vsha1pq_u32(abcd, e, wk);
        else abcd = vsha1mq_u32(abcd, e, wk);
        e = next_e;
    }
    return (kk_sha1_state){vaddq_u32(abcd, initial.abcd), e + initial.e};
}

static __inline__ __attribute__((target("sha2"), noinline))
void kk_pbkdf2_sha1_rounds(const CC_SHA1_CTX *inner, const CC_SHA1_CTX *outer,
                          uint8_t digest[20], uint32_t iterations) {
    kk_sha1_state ipad = {{inner->h0, inner->h1, inner->h2, inner->h3}, inner->h4};
    kk_sha1_state opad = {{outer->h0, outer->h1, outer->h2, outer->h3}, outer->h4};
    uint32_t last;
    memcpy(&last, digest + 16, 4);
    kk_sha1_state u = {vreinterpretq_u32_u8(vrev32q_u8(vld1q_u8(digest))), __builtin_bswap32(last)};
    kk_sha1_state sum = u;
    for (uint32_t round = 1; round < iterations; ++round) {
        u = kk_sha1_digest_block(opad, kk_sha1_digest_block(ipad, u));
        sum.abcd = veorq_u32(sum.abcd, u.abcd);
        sum.e ^= u.e;
    }
    vst1q_u8(digest, vrev32q_u8(vreinterpretq_u8_u32(sum.abcd)));
    last = __builtin_bswap32(sum.e);
    memcpy(digest + 16, &last, 4);
}
#endif

static inline void kk_sha1_update(CC_SHA1_CTX *ctx, const uint8_t *bytes, size_t count) {
    while (count) {
        CC_LONG chunk = (CC_LONG)(count > UINT32_MAX ? UINT32_MAX : count);
        CC_SHA1_Update(ctx, bytes, chunk);
        bytes += chunk;
        count -= chunk;
    }
}

// Buffers span the supplied lengths, and may be unaligned. Empty password/salt
// may be NULL. The output must not alias either input. No pointers escape.
static inline int kk_pbkdf2_sha1(const uint8_t *password, size_t password_length,
                                const uint8_t *salt, size_t salt_length,
                                uint32_t iterations, uint8_t *output, size_t output_length) {
    if (!iterations || !output_length || (uint64_t)output_length > (uint64_t)UINT32_MAX * 20)
        return kCCParamError;
#if !defined(__aarch64__) || defined(KK_PBKDF2_SHA1_FORCE_PORTABLE)
    // Preserve CommonCrypto's platform-specific implementation on Intel.
    // Copies of CC_SHA1_CTX cost more than CCKeyDerivationPBKDF on Apple ARM.
    const uint8_t empty = 0;
    return CCKeyDerivationPBKDF(kCCPBKDF2,
        (const char *)(password_length ? password : &empty), password_length,
        salt_length ? salt : &empty, salt_length, kCCPRFHmacAlgSHA1,
        iterations, output, output_length);
#else
    uint8_t key[64] = {0};
    if (password_length > sizeof(key)) {
        CC_SHA1_CTX ctx;
        CC_SHA1_Init(&ctx);
        kk_sha1_update(&ctx, password, password_length);
        CC_SHA1_Final(key, &ctx);
    } else if (password_length) {
        memcpy(key, password, password_length);
    }
    CC_SHA1_CTX inner, outer;
    CC_SHA1_Init(&inner);
    CC_SHA1_Init(&outer);
    for (unsigned i = 0; i < sizeof(key); ++i) key[i] ^= 0x36;
    CC_SHA1_Update(&inner, key, sizeof(key));
    for (unsigned i = 0; i < sizeof(key); ++i) key[i] ^= 0x36 ^ 0x5c;
    CC_SHA1_Update(&outer, key, sizeof(key));
    CC_SHA1_CTX salted = inner;
    kk_sha1_update(&salted, salt, salt_length);
    uint32_t block = 1;
    while (output_length) {
        uint8_t counter[4] = {block >> 24, block >> 16, block >> 8, block};
        uint8_t digest[20];
        CC_SHA1_CTX i = salted, o = outer;
        CC_SHA1_Update(&i, counter, sizeof(counter));
        CC_SHA1_Final(digest, &i);
        CC_SHA1_Update(&o, digest, sizeof(digest));
        CC_SHA1_Final(digest, &o);
        kk_pbkdf2_sha1_rounds(&inner, &outer, digest, iterations);
        size_t count = output_length < sizeof(digest) ? output_length : sizeof(digest);
        memcpy(output, digest, count);
        output += count;
        output_length -= count;
        ++block;
    }
    return kCCSuccess;
#endif
}
#endif
