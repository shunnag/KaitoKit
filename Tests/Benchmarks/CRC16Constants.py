#!/usr/bin/env python3
"""Derive the folding constants from KaitoKit's original reflected bit step.
No third-party CRC implementation or precomputed constant table is used.
"""
POLYNOMIAL = 0x14003  # x^16 + x^14 + x + 1 = (0xA001 << 1) ^ 1

def remainder(p):
    while p.bit_length() > 16:
        p ^= POLYNOMIAL << (p.bit_length() - 17)
    return p

def multiply(a, b):
    p = 0
    while b:
        if b & 1:
            p ^= a
        a <<= 1
        b >>= 1
    return p

def inverse_power(n):
    c = 1
    for _ in range(n):
        c = (c >> 1) ^ (0xA001 if c & 1 else 0)
    # Independent polynomial division establishes c * x^n == 1 (mod Q).
    assert remainder(c << n) == 1
    return c

for distance in [128, 512]:
    lo, hi = inverse_power(distance), inverse_power(distance - 64)
    print(f'd={distance}: low=0x{lo:04x}, high=0x{hi:04x}')
    # Check all 128 basis vectors. Linearity then proves the fold for every
    # possible 128-bit representative, including ones with previous folds.
    for bit in range(128):
        p = 1 << bit
        folded = multiply(p & ((1 << 64) - 1), lo) ^ multiply(p >> 64, hi)
        assert remainder(folded << distance) == remainder(p)
print('All inverse powers and 256 basis-vector identities verified.')
