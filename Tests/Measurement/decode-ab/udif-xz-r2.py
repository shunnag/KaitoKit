#!/usr/bin/env python3
"""Reproduce the R2 UDIF / small-block XZ measurements using CLI black boxes."""
import argparse
import hashlib
import json
import os
import plistlib
import random
import shutil
import struct
import sys
import subprocess
from pathlib import Path

ROOT = Path('/private/tmp/kk-r2udif')
MIB = 1 << 20
sys.dont_write_bytecode = True


def space():
    subprocess.run(['df', '-g', '/System/Volumes/Data'], check=True)
    subprocess.run(['df', '-h', '/System/Volumes/Data'], check=True)
    if shutil.disk_usage('/System/Volumes/Data').free < 25 * (1 << 30):
        raise SystemExit('Less than 25 GiB free')
    if ROOT.exists():
        size = sum(p.stat().st_size for p in ROOT.rglob('*') if p.is_file() and not p.is_symlink())
        if size >= 3_000_000_000:
            raise SystemExit('Scratch reached 3 GB')


def run(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), check=True, **kwargs)


def make(dmg_dir):
    space()
    corpus = ROOT / 'corpus'
    corpus.mkdir()
    mixed, pages = corpus / 'mixed', corpus / 'pages'
    mixed.mkdir(); pages.mkdir()
    words = (b'archive reader entry stream buffer checksum decode file directory metadata '
             b'window block table symbol length distance offset byte count format header '
             b'compression measurement sample round baseline branch identity timestamp '
             b'deterministic input output random text small large quick brown fox jumps '
             b'over the lazy dog alpha beta gamma delta one two three four five six seven '
             b'eight nine zero repeat release performance memory process warm cache').split()
    rng = random.Random(20260924)
    text = bytearray()
    while len(text) < 16 * MIB:
        text.extend(rng.choice(words) + b' ')
    (mixed / 'text.txt').write_bytes(text[:16 * MIB])
    rng = random.Random(20260925)
    (mixed / 'random.bin').write_bytes(rng.getrandbits(16 * MIB * 8).to_bytes(16 * MIB, 'little'))
    small = mixed / 'small'
    small.mkdir()
    rng = random.Random(20260926)
    for index in range(3125):
        body = b' '.join(rng.choice(words) for _ in range(600))
        (small / f'{index:05d}.txt').write_bytes(body[:rng.randint(1024, 4096)])
    archives = corpus / 'archives'
    archives.mkdir()
    if dmg_dir:
        # User-provided hdiutil images remain read-only and outside cleanup ownership.
        for path in sorted(Path(dmg_dir).resolve().glob('*.dmg')):
            (archives / path.name).symlink_to(path)
    else:
        # Deterministic RGB noise, encoded by Apple's sips black box.
        rng = random.Random(20261029)
        ppm = corpus / 'page.ppm'
        for index in range(72):
            ppm.write_bytes(b'P6\n1024 768\n255\n' + rng.getrandbits(1024 * 768 * 24).to_bytes(1024 * 768 * 3, 'little'))
            run(['sips', '-s', 'format', 'jpeg', '-s', 'formatOptions', '85', ppm,
                 '--out', pages / f'{index:03d}.jpg'], stdout=subprocess.DEVNULL)
        ppm.unlink()
        for source in [mixed, pages]:
            for fmt in ['UDZO', 'UDBZ', 'ULFO', 'ULMO']:
                space()
                run(['hdiutil', 'create', '-quiet', '-ov', '-fs', 'HFS+', '-volname', 'kk-r2',
                     '-srcfolder', source, '-format', fmt, archives / f'{source.name}-{fmt}.dmg'])
    for label, member in [('text', 'text.txt'), ('small', 'small')]:
        space()
        tar = corpus / f'{label}.tar'
        run(['/usr/bin/tar', '--format=ustar', '-cf', tar, '-C', mixed, member],
            env={**os.environ, 'COPYFILE_DISABLE': '1'})
        with (archives / f'{label}.multi.tar.xz').open('wb') as out:
            run(['xz', '-6', '-T0', '--block-size=1MiB', '-c', tar], stdout=out)
        tar.unlink()
    with (archives / 'text.txt.xz').open('wb') as out:
        run(['xz', '-6', '-T0', '--block-size=1MiB', '-c', mixed / 'text.txt'], stdout=out)
    space()
    big = corpus / 'text128.txt'
    with big.open('wb') as out:
        for _ in range(8):
            out.write(text[:16 * MIB])
    with (archives / 'text128.T0.xz').open('wb') as out:
        run(['xz', '-6', '-T0', '--block-size=1MiB', '-c', big], stdout=out)
    big.unlink()
    manifest = [{'path': str(p.relative_to(corpus)), 'bytes': p.stat().st_size,
                 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
                for p in sorted(archives.iterdir())]
    (corpus / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


def bench(binary, label, patterns, rounds, against, requested_threads):
    import ab
    backend, _ = ab.timing_backend()
    records = []
    paths = sorted({p for pattern in patterns for p in (ROOT / 'corpus/archives').glob(pattern)})
    for path in paths:
        thread_counts = ([0 if t == 'auto' else int(t) for t in requested_threads]
                         if requested_threads else ([1, 0] if path.suffix == '.dmg' else [1, 0, 3, 16]))
        for threads in thread_counts:
            sides = {'branch': binary}
            if against: sides['base'] = against
            samples = {side: [] for side in sides}
            for round in range(rounds):
                order = list(sides) if round % 2 == 0 else list(reversed(sides))
                for side in order:
                    path.read_bytes()  # Warm input, new process for every sample.
                    sample = ab.measure(sides[side], ['sha', '--sink', '--threads',
                                        str(threads) if threads else 'auto', str(path)], backend)
                    if sample['exit_code']: raise SystemExit(sample)
                    samples[side].append(sample)
            for side in sides:
                record = {'label': label, 'side': side, 'archive': path.name,
                          'threads': threads, 'samples': samples[side]}
                records.append(record)
                best = min(samples[side], key=lambda s: s['wall'])
                print(json.dumps({**{k: v for k, v in record.items() if k != 'samples'}, 'best': best}), flush=True)
    (ROOT / f'{label}.json').write_text(json.dumps(records, indent=2) + '\n')


def oracles(rounds):
    import ab
    backend, _ = ab.timing_backend()
    records = []
    for path in sorted((ROOT / 'corpus/archives').iterdir()):
        tool, arguments = (('7zz', ['t', str(path)]) if path.suffix == '.dmg'
                           else ('xz', ['-dc', '-T0', str(path)]))
        samples = [ab.measure(shutil.which(tool), arguments, backend) for _ in range(rounds)]
        if any(sample['exit_code'] for sample in samples): raise SystemExit(samples)
        record = {'archive': path.name, 'tool': tool, 'samples': samples}
        records.append(record)
        print(json.dumps({'archive': path.name, 'tool': tool,
                          'best': min(samples, key=lambda sample: sample['wall'])}), flush=True)
    (ROOT / 'oracles.json').write_text(json.dumps(records, indent=2) + '\n')


def mutations():
    space()
    destination = ROOT / 'mutations'
    destination.mkdir()
    specs = []
    # Corrupt packed chunks in place; retain the original table and declared sizes.
    for path in sorted((ROOT / 'corpus/archives').glob('*.dmg')):
        data = path.read_bytes()
        xml_offset, xml_length = struct.unpack_from('>QQ', data, len(data) - 512 + 216)
        data_fork_offset = struct.unpack_from('>Q', data, len(data) - 512 + 24)[0]
        plist = plistlib.loads(data[xml_offset:xml_offset + xml_length])
        chunks = []
        for table in plist['resource-fork']['blkx']:
            b = table['Data']
            for i in range(struct.unpack_from('>I', b, 200)[0]):
                kind, _, _, _, offset, length = struct.unpack_from('>IIQQQQ', b, 204 + i * 40)
                if kind in [0x80000005, 0x80000006, 0x80000007, 0x80000008] and length > 100:
                    chunks.append((data_fork_offset + offset, length))
        # First / middle / last chunk, header / payload / check / truncated packed body.
        for index in sorted({0, len(chunks) // 2, len(chunks) - 1}):
            offset, length = chunks[index]
            for mode in ['header', 'body', 'check', 'zero-tail']:
                at = offset + {'header': 0, 'body': length // 2, 'check': length - 8, 'zero-tail': length // 2}[mode]
                specs.append({'source': str(path.relative_to(ROOT)), 'name': f'{path.stem}-{index}-{mode}.dmg',
                              'at': at, 'zero_to': offset + length if mode == 'zero-tail' else None})
    for path in sorted((ROOT / 'corpus/archives').glob('*.xz')):
        data = path.read_bytes()
        for at in [0, 6, 12, 24, len(data) // 2, len(data) - 20, len(data) - 8]:
            specs.append({'source': str(path.relative_to(ROOT)), 'name': f'{path.stem}-flip-{at}.xz', 'at': at})
        for cut in [1, 12, len(data) // 2]:
            specs.append({'source': str(path.relative_to(ROOT)), 'name': f'{path.stem}-cut-{cut}.xz', 'cut': cut})
    (destination / 'specs.json').write_text(json.dumps(specs, indent=2) + '\n')


def outcomes(binary, label):
    space()
    records = []
    def capture(path, threads):
        result = subprocess.run([binary, 'sha', '--threads', str(threads) if threads else 'auto', path], capture_output=True)
        records.append({'path': str(path.relative_to(ROOT)), 'threads': threads,
                        'exit': result.returncode, 'stdout': result.stdout.decode(), 'stderr': result.stderr.decode()})
    for path in sorted((ROOT / 'corpus/archives').iterdir()):
        for threads in [1, 0, 3, 16]: capture(path, threads)
    for spec in json.loads((ROOT / 'mutations/specs.json').read_text()):
        changed = bytearray((ROOT / spec['source']).read_bytes())
        if 'cut' in spec: del changed[-spec['cut']:]
        elif spec.get('zero_to'):
            changed[spec['at']:spec['zero_to']] = bytes(spec['zero_to'] - spec['at'])
        else: changed[spec['at']] ^= 0x80
        path = ROOT / 'mutations' / spec['name']
        path.write_bytes(changed)
        try:
            for threads in [1, 0]: capture(path, threads)
        finally: path.unlink()
    (ROOT / f'{label}-outcomes.json').write_text(json.dumps(records, indent=2) + '\n')
    print(f'{len(records)} outcomes: {sum(r["exit"] != 0 for r in records)} failures')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['make', 'bench', 'mutations', 'outcomes', 'oracles'])
    parser.add_argument('--binary')
    parser.add_argument('--dmg-dir', help='Read-only hdiutil images to use instead of generating DMGs')
    parser.add_argument('--label', default='head')
    parser.add_argument('--against', help='Alternate base / branch order on each timing round')
    parser.add_argument('--pattern', action='append')
    parser.add_argument('--rounds', type=int, default=5)
    parser.add_argument('--threads', nargs='+', help='Timing thread counts (e.g. 1 auto 3 16)')
    args = parser.parse_args()
    if args.mode == 'make': make(args.dmg_dir)
    elif args.mode == 'mutations': mutations()
    elif args.mode == 'oracles': oracles(args.rounds)
    elif args.mode == 'bench': bench(args.binary, args.label, args.pattern or ['*'], args.rounds, args.against, args.threads)
    else: outcomes(args.binary, args.label)
