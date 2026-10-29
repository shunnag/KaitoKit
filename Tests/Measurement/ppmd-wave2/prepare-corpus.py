#!/usr/bin/env python3
"""Add PPMd H/I archives omitted by the current decode-ab generator."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
manifest_path = root / 'manifest.json'
manifest = json.loads(manifest_path.read_text())
for extension, method in [('7z', '-m0=PPMd'), ('zip', '-mm=PPMd')]:
    path = root / 'archives' / ('text-ppmd.' + extension)
    command = ['7zz', 'a', '-t' + extension, method, '-mmt=1', '-bso0', '-bsp0', str(path), 'text.txt']
    result = subprocess.run(command, cwd=root / 'inputs', check=True)
    print(' '.join(command), 'exit', result.returncode)
    manifest['archives'].append(dict(path=path.relative_to(root).as_posix(), size=path.stat().st_size,
                                     sha256=hashlib.sha256(path.read_bytes()).hexdigest()))
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
