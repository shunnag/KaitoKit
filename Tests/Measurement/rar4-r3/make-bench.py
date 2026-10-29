#!/usr/bin/env python3
"""Reproducible synthetic RAR4 R3 workloads; only KaitoKit generators and black-box tools."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('r0', ROOT / 'Scripts/fixtures/make-rar4.py')
r0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r0)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
w = args.destination.resolve()
if w.exists() and any(w.iterdir()):
    parser.error('destination must be new or empty')
d = w / 'inputs'
a = w / 'archives'
d.mkdir(parents=True)
a.mkdir()
rar, version = r0.rar4_tool()
if not rar:
    parser.error('RAR4_TOOL must name RAR 6.x')
log = []
env = dict(os.environ, TZ='UTC', LC_ALL='C', COPYFILE_DISABLE='1')
def run(cmd):
    p = subprocess.run(cmd, cwd=d, env=env, text=True, capture_output=True)
    log.append(dict(cmd=cmd, cwd=str(d), exit=p.returncode, stdout=p.stdout, stderr=p.stderr))
    (w / 'commands.json').write_text(json.dumps(log, indent=2) + '\n')
    p.check_returncode()

for i in range(3):
    bmp = d / f'page-{i}.bmp'
    bmp.write_bytes(r0.image_bmp(1024, 1024, i))
    for fmt, suffix in [('tiff', 'tiff'), ('png', 'png'), ('jpeg', 'jpg')]:
        run(['sips', '-s', 'format', fmt, str(bmp), '--out', str(d / f'page-{i}.{suffix}')])
rng = random.Random(2026102903)
words = (b'archive reader entry stream buffer checksum decode file directory metadata '
         b'window block table symbol length distance offset byte count format header '
         b'compression measurement sample round baseline branch identity timestamp').split()
text = bytearray()
while len(text) < 16 * 1024 * 1024:
    text.extend(rng.choice(words) + b' ')
(d / 'text.txt').write_bytes(text[:16 * 1024 * 1024])
(d / 'stereo.wav').write_bytes(r0.pcm_wave(2 * 1024 * 1024))
(d / 'x86-code.bin').write_bytes(r0.x86_code(12 * 1024 * 1024))
for path in d.iterdir():
    os.utime(path, (1700000000, 1700000000))
workloads = [
    ('tiff-rgb', ['-s-', '-mc-', '-mcC+'], [f'page-{i}.tiff' for i in range(3)]),
    ('jpeg', ['-s-', '-mc-'], [f'page-{i}.jpg' for i in range(3)]),
    ('text-lz', ['-s-', '-mc-'], ['text.txt']),
    ('text-ppmd', ['-s-', '-mc-', '-mct+'], ['text.txt']),
    ('solid-png', ['-s', '-mc-'], [f'page-{i}.png' for i in range(3)]),
    ('x86-e8', ['-s-', '-mc-', '-mcE+'], ['x86-code.bin']),
    ('wav-audio', ['-s-', '-mc-', '-mc4A+'], ['stereo.wav']),
]
manifest = dict(rar_version=version, dimensions=[1024, 1024], text_seed=2026102903,
                generator='KaitoKit R0 image/PCM/x86; MT19937 word text; sips image conversion', archives=[])
def digest(path):
    data = path.read_bytes()
    return dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
for name, flags, files in workloads:
    archive = a / f'{name}.rar'
    switches = ['-ma4', '-m3', '-cfg-', '-idq', '-mt1', '-tsc-', '-tsa-'] + flags
    run([rar, 'a'] + switches + [str(archive)] + files)
    manifest['archives'].append(dict(path=str(archive.relative_to(w)), switches=switches,
        **digest(archive), entries=[dict(path=f, **digest(d / f)) for f in files]))
(w / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'generated {len(workloads)} RAR4 workloads with RAR {version}')
