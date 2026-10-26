#!/usr/bin/env python3
"""計測用の自作 SITX。StuffItXContainerTests.Writer と同じ p2 / element / frames。"""
import argparse
from pathlib import Path

class Writer:
    def __init__(self):
        self.data = bytearray(b'StuffIt!')
        self.pending = self.count = 0
    def bits(self, value, width):
        for i in range(width):
            self.pending |= ((value >> i) & 1) << self.count
            self.count += 1
            if self.count == 8:
                self.align()
    def align(self):
        if self.count:
            self.data.append(self.pending)
        self.pending = self.count = 0
    def p2(self, value):
        x = value + 1
        for _ in range(1, x.bit_count()):
            self.bits(1, 1)
        self.bits(0, 1)
        self.bits(x, x.bit_length())
    def element(self, kind, attrs=(), algorithms=(), extra=None):
        self.align()
        self.bits(0, 1)
        self.p2(kind)
        for k,v in attrs:
            self.p2(k); self.p2(v)
        self.p2(0)
        for k,v,length in algorithms:
            self.p2(k); self.p2(v); self.p2(length)
        self.p2(0)
        if extra is not None:
            self.p2(extra)
        self.align()
    def frames(self):
        self.p2(0); self.align()

def archive(length):
    w=Writer()
    w.element(7, extra=5)
    records=[(4,3,min(1024,length-i)) for i in range(0,length,1024)]
    w.element(5, [(5,0)], records)
    w.frames(); w.frames(); w.element(0)
    return w.data

if __name__ == '__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--length', type=int, default=65536)
    p.add_argument('--output', type=Path, required=True)
    a=p.parse_args()
    a.output.write_bytes(archive(a.length))
