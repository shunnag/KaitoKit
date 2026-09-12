#!/usr/bin/env python3
# 圧縮された包みの SHA と展開後の fork SHA を分け、指定データだけで全件照合する。
import argparse
from collections import Counter
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
EMPTY = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'


def rows(text, literal_names=False):
    result = []
    for line in text.split('\n'):
        fields = line.split('\t')
        if len(fields) >= 4 and fields[0].isdigit():
            name = fields[3]
            if literal_names:
                name = name.replace('\\', '\\\\').replace('\t', '\\t').replace('\r', '\\r').replace('\n', '\\n')
            result.append((int(fields[1]), fields[2], name))
    return result


def nonempty(items):
    return Counter(x for x in items if x[0] or x[1] != EMPTY)


def expected_forks(archive):
    objects = {o['id']: o for o in archive['objects']}

    def name(owner):
        obj = objects[owner]
        parent = obj['parent']
        return (name(parent) + '/' if parent else '') + obj['metadata']['1']

    return [(f['length'], f['sha256'], name(f['owner']) + ('/..namedfork/rsrc' if f['kind'] == 1 else ''))
            for f in archive['forks'] if f['kind'] <= 1 and 'sha256' in f]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('kaito', type=Path)
    parser.add_argument('--corpus', type=Path, default=ROOT / 'inbox/stuffit-corpus')
    parser.add_argument('--inventory', type=Path, default=ROOT / '.build/slice4-inventory.json')
    args = parser.parse_args()
    archives = json.loads((ROOT / 'inbox/stuffit/research/archive-verification.json').read_text())['archives']
    research = {a['file']: a for a in archives if a['family'] == 'stuffitx'}
    inventory = {a['file']: a for a in json.loads(args.inventory.read_text())}
    log = ROOT / '.build'
    summary = dict(match=0, partial_jpeg=0, encrypted=0, recovery=0, mismatch=0, sha_forks=0, wrapper_sha=0)

    def run(path, forks=False):
        start = time.perf_counter()
        command = [str(args.kaito), 'sha', str(path)] + (['--forks'] if forks else [])
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        tag = 'slice4-' + path.name + ('-forks' if forks else '-sha')
        (log / (tag + '.log')).write_text(result.stdout)
        (log / (tag + '.err')).write_text(result.stderr)
        return result, rows(result.stdout), time.perf_counter() - start

    for path in sorted((args.corpus / 'cc0').iterdir()):
        if 'sitx' not in path.name or not path.is_file():
            continue
        if 'password' in path.name:
            rejected, _, _ = run(path, forks=True)
            assert rejected.returncode and 'encryption' in rejected.stderr, path
            summary['encrypted'] += 1
            continue
        if 'recoverability' in path.name or 'redundancy' in path.name:
            rejected, _, _ = run(path, forks=True)
            assert rejected.returncode and 'Root algorithms 5:0' in rejected.stderr, path
            summary['recovery'] += 1
            continue
        result, actual, _ = run(path, forks=True)
        base = path.name[:path.name.index('.sitx') + 5]
        if 'stuffit7_dlx.mac' in base:
            # 同じ CC0 ファイル集合の Mac 7 版を、支給 Mac 9 レコードの名前付き全 fork と照合する。
            reference = base.replace('macx1', 'mac9')
            expected = expected_forks(research[reference])
        elif base in research:
            expected = expected_forks(research[base])
        else:
            oracle = args.corpus / 'oracle/cc0' / (base + '.sha')
            expected = rows(oracle.read_bytes().decode('utf-8'), literal_names=True)
        assert nonempty(actual) == nonempty(expected), (path.name, nonempty(actual) - nonempty(expected), nonempty(expected) - nonempty(actual))
        if result.returncode:
            assert base in research and 'StuffIt X compression 7' in result.stderr, (path, result.stderr)
            assert result.stderr.count('failed entry') == 1, result.stderr
            summary['partial_jpeg'] += 1
        else:
            summary['match'] += 1
        summary['sha_forks'] += sum(nonempty(actual).values())
        unwrapped = args.corpus / 'oracle/unwrapped' / (path.name + '.data.sha')
        if not unwrapped.exists() and base != path.name:
            unwrapped = args.corpus / 'oracle/cc0' / (path.name + '.sha')
        if unwrapped.exists():
            compressed = rows(unwrapped.read_text())
            item = inventory['cc0/' + path.name]
            assert [(s, h) for s, h, _ in compressed] == [(item['unwrappedLength'], item['unwrappedSHA256'])], path
            summary['wrapper_sha'] += 1
    assert (summary['match'], summary['partial_jpeg'], summary['encrypted'], summary['recovery']) == (20, 2, 16, 10), summary
    print('CC0:', ', '.join(f'{k}={v}' for k, v in summary.items()))

    perf = []
    for name in ['SMSSenderPro3osx.sitx', 'BirdFluWAVE.sitx', 'warriors_screen.sitx', 'theconceptosx.sitx', 'Tickershock.sitx']:
        path = args.corpus / 'perf' / name
        result, actual, elapsed = run(path)
        assert result.returncode == 0, (name, result.stderr)
        oracle = rows((args.corpus / 'oracle/perf' / (name + '.sha')).read_bytes().decode('utf-8'), literal_names=True)
        item = inventory['perf/' + name]
        decoded = item['forkResults']
        assert all('error' not in f for f in decoded), (name, [f for f in decoded if 'error' in f])
        final_sha = name not in ['theconceptosx.sitx', 'Tickershock.sitx']
        if final_sha:
            assert Counter(actual) == Counter(oracle), (name, Counter(actual) - Counter(oracle))
        else:
            assert [(s, h) for s, h, _ in oracle] == [(item['unwrappedLength'], item['unwrappedSHA256'])], name
        result_forks, forks, _ = run(path, forks=True)
        assert result_forks.returncode == 0, result_forks.stderr
        # 通常 Reader と coordinator の全 fork の内容も照合する。独立 SHA 不在分は別集計にする。
        assert Counter((s, h) for s, h, _ in forks if s) == Counter((f['length'], f['sha256']) for f in decoded if f['kind'] <= 1 and f['length']), name
        record = dict(file=name, entries=len(actual), final_sha_entries=len(actual) if final_sha else 0,
                      crc_forks=len(decoded), missing_final_sha=sum(f['kind'] == 1 for f in decoded) if final_sha else len(decoded),
                      wrapper_sha=not final_sha, seconds=round(elapsed, 3))
        if name == 'SMSSenderPro3osx.sitx':
            assert len(actual) == 95
            english = [e for e in item['elements'] if e['type'] == 1 and [3, 0] in e['algorithms']]
            assert len(english) == 4
            record['english_streams'] = len(english)
        perf.append(record)
        print(name + ': ' + ', '.join(f'{k}={v}' for k, v in record.items() if k != 'file'))
    (log / 'slice4-corpus-summary.json').write_text(json.dumps(dict(cc0=summary, perf=perf), ensure_ascii=False, indent=2) + '\n')
    print('展開後 SHA 不在分は CRC 検証まで。包みの SHA を展開結果の一致に数えない。')


if __name__ == '__main__':
    main()
