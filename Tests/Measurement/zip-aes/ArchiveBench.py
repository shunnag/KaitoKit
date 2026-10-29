#!/usr/bin/env python3
"""Warm-cache, alternating black-box KaitoKit/7zz archive measurements."""
import argparse
import json
from pathlib import Path
import random
import statistics
import subprocess
import time


def prepare_large(root, sevenzip):
    archive = root / 'aes256-large.zip'
    if archive.exists():
        return archive
    inputs = root / 'large-input'
    inputs.mkdir(parents=True, exist_ok=True)
    generator = random.Random(0x801821041804)
    for index in range(4):
        with (inputs / f'{index:02d}.bin').open('wb') as output:
            for _ in range(16):
                output.write(generator.randbytes(1 << 20))
    command = [sevenzip, 'a', '-tzip', '-mx=0', '-mem=AES256', '-pKaitoFuzz', str(archive), '.']
    result = subprocess.run(command, cwd=inputs, text=True, capture_output=True, check=True)
    (root / 'large-generation.txt').write_text(result.stdout + result.stderr)
    print('fixture:', command, 'PASS; archive bytes:', archive.stat().st_size, flush=True)
    return archive


def measure(method, before, after, sevenzip, archive, expected_bytes):
    if method == '7zz':
        command = [sevenzip, 't', '-pKaitoFuzz', str(archive)]
    else:
        executable = before if method == 'before' else after
        command = [str(executable), 'bench', str(archive), '1', '-p', 'KaitoFuzz']
        if method in ('after-1', 'after-4'):
            command += ['--threads', method[-1]]
    start = time.perf_counter_ns()
    result = subprocess.run(command, text=True, capture_output=True, check=True)
    wall = (time.perf_counter_ns() - start) / 1e6
    sample = {'command': command, 'wall_ms': wall}
    if method != '7zz':
        parsed = dict(line.split('\t') for line in result.stdout.splitlines())
        assert int(parsed['bytes']) == expected_bytes, parsed
        sample.update(open_ms=float(parsed['open-median-ms']),
                      extract_ms=float(parsed['extract-median-ms']))
    return sample


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.build/zip-aes-verification'))
    parser.add_argument('--before', type=Path, default=Path('.build/zip-aes-verification/kaito-before'))
    parser.add_argument('--after', type=Path, default=Path('.build/zip-aes-final/out/Products/Release/kaito'))
    parser.add_argument('--sevenzip', default='/opt/homebrew/bin/7zz')
    parser.add_argument('--rounds', type=int, default=7)
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    large = prepare_large(root, args.sevenzip)
    if args.prepare_only:
        return
    assert args.rounds >= 3
    methods = ['before', 'after-auto', '7zz', 'after-1', 'after-4']
    archives = [('small', root / 'aes256.zip', 2000 * 127), ('large', large, 4 * (16 << 20))]
    results = {name: {'path': str(path), 'archive_bytes': path.stat().st_size,
                      'bytes': expected, 'samples': {method: [] for method in methods}}
               for name, path, expected in archives}
    # One complete extraction per method and archive before retained samples.
    for name, archive, expected in archives:
        for method in methods:
            measure(method, args.before.resolve(), args.after.resolve(), args.sevenzip, archive, expected)
        print(name, 'warm-up: PASS', flush=True)
    orders = []
    for round_index in range(args.rounds):
        offset = round_index % len(methods)
        order = methods[offset:] + methods[:offset]
        if round_index % 2:
            order.reverse()
        archive_order = archives if round_index % 2 == 0 else list(reversed(archives))
        orders.append({'round': round_index + 1, 'archives': [a[0] for a in archive_order], 'methods': order})
        for name, archive, expected in archive_order:
            for method in order:
                sample = measure(method, args.before.resolve(), args.after.resolve(), args.sevenzip, archive, expected)
                results[name]['samples'][method].append(sample)
        print('round', round_index + 1, 'order', order, 'PASS', flush=True)
    for name, archive, _ in archives:
        medians = {}
        for method, samples in results[name]['samples'].items():
            medians[method] = {key: statistics.median(sample[key] for sample in samples)
                               for key in ('open_ms', 'extract_ms', 'wall_ms') if key in samples[0]}
        results[name]['medians'] = medians
        print(name, archive.name, json.dumps(medians, indent=2), flush=True)
    (root / 'alternating-timings.json').write_text(json.dumps({'orders': orders, 'archives': results}, indent=2) + '\n')


if __name__ == '__main__':
    main()
