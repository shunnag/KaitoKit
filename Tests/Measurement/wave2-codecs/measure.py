#!/usr/bin/env python3
"""Project-owned deterministic corpus; external codecs are black-box tools only."""
import argparse
import hashlib
import json
from pathlib import Path
import random
import subprocess
import tarfile

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=['generate', 'measure'])
parser.add_argument('--root', type=Path, default=Path('.build/wave2'))
args = parser.parse_args()
root = args.root.resolve()
root.mkdir(parents=True, exist_ok=True)
corpus = root / 'corpus'
corpus.mkdir(exist_ok=True)
log = root / (args.action + '.jsonl')

def run(command, cwd=None):
    result = subprocess.run([str(x) for x in command], cwd=cwd, capture_output=True, text=True)
    with log.open('a') as out:
        out.write(json.dumps(dict(command=[str(x) for x in command], cwd=str(cwd or Path.cwd()),
                                  exit=result.returncode, stdout=result.stdout, stderr=result.stderr)) + '\n')
    result.check_returncode()
    return result.stdout

if args.action == 'generate':
    rng = random.Random(20261029)
    words = b'archive reader entry stream buffer checksum decode window block table symbol length distance offset byte count format header compression measurement sample round baseline branch deterministic input output small large quick brown fox'.split()
    chunk = b' '.join(rng.choice(words) for _ in range(180000))[:1024 * 1024]
    (corpus / 'text.txt').write_bytes((chunk * (64 * 1024 * 1024 // len(chunk) + 1))[:64 * 1024 * 1024])
    # Synthetic RGB scanlines, repeated tiles plus deterministic sensor-like noise.
    tile = bytes((x // 3 + x // 768) & 255 for x in range(768 * 256))
    image = bytearray()
    for i in range(171):
        row = bytearray(tile)
        for _ in range(1024):
            row[rng.randrange(len(row))] = rng.randrange(256)
        image.extend(row)
    (corpus / 'image.rgb').write_bytes(image[:32 * 1024 * 1024])
    small = corpus / 'small'
    small.mkdir(exist_ok=True)
    for i in range(5000):
        (small / f'{i:05d}.txt').write_bytes(b' '.join(rng.choice(words) for _ in range(320)))
    run(['7zz', 'a', '-tzip', '-mm=Deflate64', '-bso0', '-bsp0', 'text-deflate64.zip', 'text.txt'], corpus)
    run(['7zz', 'a', '-tzip', '-mm=Deflate64', '-bso0', '-bsp0', 'small-deflate64.zip', 'small'], corpus)
    run(['7zz', 'a', '-tzip', '-mm=Deflate', '-mx6', '-bso0', '-bsp0', 'text-zip6.zip', 'text.txt'], corpus)
    for stem, name in [('text', 'text.txt'), ('image', 'image.rgb')]:
        tar = corpus / (stem + '.tar')
        with tarfile.open(tar, 'w', format=tarfile.USTAR_FORMAT) as archive:
            archive.add(corpus / name, arcname=name)
        for source, target in [(name, stem + '.lz4'), (tar.name, stem + '.tar.lz4')]:
            run(['lz4', '-q', '-f', '-BI', source, target], corpus)
        run(['lz4', '-q', '-f', '-l', name, stem + '-legacy.lz4'], corpus)
    manifest = {p.name: dict(bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                for p in corpus.iterdir() if p.suffix in ['.zip', '.lz4']}
    (root / 'corpus.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))
else:
    paths = sorted(p for p in corpus.iterdir() if p.suffix in ['.zip', '.lz4'])
    for path in paths:
        identity = [run([root / ('kaito-' + version), 'sha', path]) for version in ['before', 'after']]
        assert identity[0] == identity[1], path
        for round in range(3):
            for version in (['before', 'after'] if round % 2 == 0 else ['after', 'before']):
                output = run([root / ('kaito-' + version), 'bench', path, '3'])
                print(path.name, round, version, output.strip().replace('\n', '; '), flush=True)
