#!/usr/bin/env python3
"""固定測定の8コマンドを共有OFFのCLIで再実行し、stdoutのbyte一致を検査する。性能測定には使わない。"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True, help='共有ONのreport.jsonがあるディレクトリ')
    parser.add_argument('--kaito', type=Path, required=True, help='共有OFFのCLI')
    parser.add_argument('--out-dir', type=Path, required=True)
    args = parser.parse_args()
    report = json.loads((args.reference / 'report.json').read_text())
    commands = report['commands']
    runs = args.out_dir / 'runs'
    runs.mkdir(parents=True, exist_ok=True)
    # udetのstdinも測定器と同じ順序・空行区切りで作る。
    inputs = {}
    for mode, column in [('names', 3), ('archives', 4)]:
        path = args.out_dir / f'{mode}-udet.stdin.txt'
        source = Path(commands[f'{mode}-kaito_ja'][-1])
        with source.open() as incoming, path.open('w') as outgoing:
            next(incoming)
            for line in incoming:
                fields = line.rstrip('\n').split('\t')
                value = fields[column]
                outgoing.write(value + '\n' if mode == 'names' else '\n'.join(value.split(',')) + '\n\n')
        inputs[mode] = path

    def replay(detector):
        records = []
        for mode in ['names', 'archives']:
            label = f'{mode}-{detector}'
            command = list(commands[label])
            if detector != 'udet':
                command[0] = str(args.kaito.resolve())
            stdout = runs / f'{label}.stdout.tsv'
            stderr = runs / f'{label}.stderr.txt'
            print(f'running {label}', flush=True)
            with stdout.open('wb') as output, stderr.open('wb') as errors:
                if detector == 'udet':
                    with inputs[mode].open('rb') as incoming:
                        subprocess.run(command, stdin=incoming, stdout=output, stderr=errors, check=True)
                else:
                    subprocess.run(command, stdout=output, stderr=errors, check=True)
            original = args.reference / 'runs' / stdout.name
            expected, actual = sha256(original), sha256(stdout)
            # ハッシュに加え、同じチャンク境界で内容自体を比較する。
            equal = original.stat().st_size == stdout.stat().st_size
            with original.open('rb') as left, stdout.open('rb') as right:
                while equal:
                    a, b = left.read(1024 * 1024), right.read(1024 * 1024)
                    equal = a == b
                    if not a:
                        break
            records.append({'file': stdout.name, 'bytes': stdout.stat().st_size,
                            'reference_sha256': expected, 'sha256': actual, 'equal': equal,
                            'command': command})
            print(f'{label}: equal={equal}', flush=True)
        return records

    # 精度とbyte一致の検査だけを並列化する。共有ONの時間とは比較しない。
    with ThreadPoolExecutor(max_workers=4) as executor:
        rows = [row for records in executor.map(replay, ['kaito_ja', 'kaito_none', 'kaito_zh', 'udet']) for row in records]
    result = {'reference': str(args.reference.resolve()), 'unshared_kaito_sha256': sha256(args.kaito),
              'parallel_replay_not_a_performance_measurement': True, 'outputs': rows}
    target = args.out_dir / 'tune-equivalence.json'
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if not all(row['equal'] for row in rows):
        raise SystemExit('共有ON/OFFの出力が一致しない')
    print(target, flush=True)


if __name__ == '__main__':
    main()
