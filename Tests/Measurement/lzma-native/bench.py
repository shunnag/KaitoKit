#!/usr/bin/env python3
"""各組合せを別 process で 5 回計時し、全標本と best を残す。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

binary, corpus, output = map(Path, sys.argv[1:])
manifest = json.loads((corpus / 'manifest.json').read_text())
rows = []
with output.open('x') as log:
    for case in manifest['cases']:
        path = corpus / case['path']
        path.read_bytes()  # warm cache
        for backend in ['swift', 'native']:
            env = dict(os.environ, KAITOKIT_LZMA_BACKEND=backend)
            result = subprocess.run([str(binary), 'sha', '--threads', '1', str(path)], env=env,
                                    capture_output=True, text=True, check=True)
            assert case['sha256'] in result.stdout, result.stdout
        for round_ in range(5):
            order = ['swift', 'native', '7zz']
            order = order[round_ % 3:] + order[:round_ % 3]
            for backend in order:
                if shutil.disk_usage('/System/Volumes/Data').free < 25 * 1024**3:
                    raise SystemExit('less than 25 GiB free')
                env = dict(os.environ, KAITOKIT_LZMA_BACKEND=backend)
                command = ([str(binary), 'bench', '--threads', '1', str(path), '1'] if backend != '7zz'
                           else [shutil.which('7zz'), 'x', '-so', '-mmt=1', '-bd', '-bb0', str(path)])
                start = time.perf_counter_ns()
                result = subprocess.run(command, env=env, stdout=subprocess.DEVNULL if backend == '7zz' else subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True)
                elapsed = (time.perf_counter_ns() - start) / 1e6
                assert result.returncode == 0, result.stderr
                if backend != '7zz':
                    assert f"bytes\t{case['bytes']}\n" in result.stdout, result.stdout
                row = dict(case=case['path'], backend=backend, round=round_ + 1, wall_ms=elapsed,
                           stdout=result.stdout, stderr=result.stderr, command=command)
                rows.append(row); log.write(json.dumps(row) + '\n'); log.flush()
        best = {side: min(r['wall_ms'] for r in rows if r['case'] == case['path'] and r['backend'] == side)
                for side in ['swift', 'native', '7zz']}
        print(case['path'], json.dumps(best), 'gain', 100 * (1 - best['native'] / best['swift']), flush=True)
