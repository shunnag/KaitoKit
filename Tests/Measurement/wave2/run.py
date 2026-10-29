#!/usr/bin/env python3
"""Benchmark actual Swift sources without adding a package target.
Usage: python3 Tests/Measurement/wave2/run.py SOURCE_DIRECTORY OUTPUT_DIRECTORY
SOURCE_DIRECTORY contains Blake2.swift, CRC64.swift, ZipCrypto.swift snapshots.
"""
import os
from pathlib import Path
import subprocess
import sys

source, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
root = Path(__file__).resolve().parents[3]
# Only the unrelated ByteSource wrapper's dependencies are stubbed; the measured
# ZipCryptoKeys implementation is copied verbatim from the supplied snapshot.
keys = (source / 'ZipCrypto.swift').read_text().split('// 圧縮済み plaintext')[0]
keys += '''
enum KaitoError: Error { case truncated, wrongPassword }
enum ZipCrypto { static let headerSize = 12 }
enum ConstantTime { static func equals(_ a: UInt8, _ b: UInt8) -> Bool { a == b } }
'''
(output / 'ZipCryptoKeys.swift').write_text(keys)
env = dict(os.environ, CLANG_MODULE_CACHE_PATH='/tmp/kaito-wave2-module-cache')
command = ['swiftc', '-O', '-module-cache-path', env['CLANG_MODULE_CACHE_PATH'],
           '-I', str(root / 'Sources/CBzip2'), str(source / 'Blake2.swift'),
           str(source / 'CRC64.swift'), str(output / 'ZipCryptoKeys.swift'),
           str(root / 'Tests/Measurement/wave2/HotLoopBench.swift'),
           '-o', str(output / 'bench')]
print(' '.join(command), flush=True)
subprocess.run(command, env=env, check=True)
subprocess.run([str(output / 'bench')], check=True)
