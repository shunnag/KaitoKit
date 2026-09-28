#!/usr/bin/env python3
"""C-B の固定 report / runs から比較表を作る。判定と一致条件は測定器を共有する。"""
import argparse
from collections import Counter, defaultdict
import hashlib
from importlib import import_module
import json
from pathlib import Path

measure = import_module('measure-name-detection')
generator = import_module('make-name-corpus')
OLD = {(lang, iana) for lang, encodings in generator.TASK_B_ENCODINGS.items() for _, iana in encodings}
DETECTORS = list(measure.LABELS)
FINAL = "cb-correction3"
NEW = [lang for lang in generator.ENCODINGS if lang not in generator.TASK_B_ENCODINGS]
REPORT_ONLY_GROUPS = [
    ('中欧DOS/ISO/Windows', ['hr', 'sl', 'sk', 'ro', 'sr-Latn'], ['windows-1250', 'iso-8859-2', 'cp852']),
    ('MacRoman系', None, ['macintosh', 'x-mac-icelandic', 'x-mac-croatian', 'x-mac-romanian']),
    ('Baltic Windows/ISO', None, ['windows-1257', 'iso-8859-13']),
    ('Greek Windows/ISO', None, ['windows-1253', 'iso-8859-7']),
    ('Turkish Windows/ISO', None, ['windows-1254', 'iso-8859-9']),
    ('南スラブCyrillic', ['bg', 'sr', 'mk'], ['windows-1251', 'iso-8859-5', 'cp855']),
]


def select(report, kind, lang=None, old=False, encoding=None):
    key = 'archive_by_encoding_k' if kind == 'archive10' else 'single_by_length'
    rows = [r for r in report[key] if (lang is None or r['lang'] == lang)
            and (not old or (r['lang'], r['truth_iana']) in OLD)
            and (encoding is None or r['truth_iana'] == encoding)]
    rows = [r for r in rows if r['k'] >= 10] if kind == 'archive10' else [
        r for r in rows if r['non_ascii_scalars'] in (['1', '2–3'] if kind == 'short' else ['4–7', '8+'])]
    n = sum(r['eligible'] for r in rows)
    correct = {d: sum(r['detectors'][d]['correct'] for r in rows) for d in DETECTORS}
    return n, {d: 100 * correct[d] / n if n else None for d in DETECTORS}


def fmt(value):
    return '—' if value is None else f'{value:.2f}'


def table(headers, rows):
    return '\n'.join(['| ' + ' | '.join(headers) + ' |', '|' + '---|' * len(headers)] +
                     ['| ' + ' | '.join(map(str, row)) + ' |' for row in rows])


def report_only_family(lang, truth, detected):
    if measure.codec_for(truth) == measure.codec_for(detected):
        return None
    for label, languages, pair in REPORT_ONLY_GROUPS:
        if languages is not None and lang not in languages:
            continue
        codecs = {measure.codec_for(x) for x in pair}
        if measure.codec_for(truth) in codecs and measure.codec_for(detected) in codecs:
            return label
    return None


def report_only(lang, truth, detected):
    return report_only_family(lang, truth, detected) is not None


def wrong_predictions(corpus, runs):
    names = measure.tsv_rows(corpus / 'names.tsv', 'id\tlang\ttruth_iana\thex\ttext')
    archives = measure.tsv_rows(corpus / 'archives.tsv', 'group\tlang\ttruth_iana\tk\thex1,hex2,...')
    truth = {}
    eligible = {}
    by_encoding = defaultdict(list)
    for row in names:
        by_encoding[row[2]].append(row)
    for encoding, rows in by_encoding.items():
        checked = measure.keyed_output((runs / f'decode-{encoding}.stdout.tsv').read_text(), [r[0] for r in rows], 3)
        for identifier, lang, enc, hex_value, text in rows:
            status, escaped = checked[identifier]
            ok = enc != 'cp861' and status != 'FAIL' and measure.cf_comparison_text(measure.decoded_fields(escaped)[0], enc) == text
            key = (lang, enc, hex_value)
            truth[key] = text
            eligible[key] = eligible.get(key, True) and ok
    output = {'single': defaultdict(Counter), 'archive': defaultdict(Counter), 'examples': {'single': {}, 'archive': {}}}
    single = measure.keyed_output((runs / 'names-kaito_ja.stdout.tsv').read_text(), [r[0] for r in names], 4)
    for identifier, lang, enc, hex_value, text in names:
        if not eligible[(lang, enc, hex_value)] or sum(ord(c) > 127 for c in text) < 4:
            continue
        predicted, _, escaped = single[identifier]
        decoded = measure.cf_comparison_text(measure.decoded_fields(escaped)[0], predicted)
        if decoded != text:
            output['single'][(lang, enc)][predicted] += 1
            output['examples']['single'].setdefault((lang, enc, predicted), (identifier, text, decoded))
    archive = measure.keyed_output((runs / 'archives-kaito_ja.stdout.tsv').read_text(), [r[0] for r in archives], 4)
    for identifier, lang, enc, k, hex_list in archives:
        if int(k) < 10 or enc == 'cp861':
            continue
        members = hex_list.split(',')
        if any(not eligible.get((lang, enc, h), True) for h in members):
            continue
        expected = [truth.get((lang, enc, h), bytes.fromhex(h).decode('ascii', errors='replace')) for h in members]
        predicted, _, escaped = archive[identifier]
        decoded = [measure.cf_comparison_text(x, predicted) for x in measure.decoded_fields(escaped)]
        if decoded != expected:
            output['archive'][(lang, enc)][predicted] += 1
            a, b = next((a, b) for a, b in zip(expected, decoded) if a != b)
            output['examples']['archive'].setdefault((lang, enc, predicted), (identifier, a, b))
    return output


def foreign_name_rows(build):
    corpus = build / 'name-corpus-c-eval'
    names = measure.tsv_rows(corpus / 'names.tsv', 'id\tlang\ttruth_iana\thex\ttext')
    archives = measure.tsv_rows(corpus / 'archives.tsv', 'group\tlang\ttruth_iana\tk\thex1,hex2,...')
    watched = ['Liv og død', 'Kõ', 'Kõrgessaare', 'Breiðdalsá (Breiðadalur)']
    lookup = {(l,e,h):t for _,l,e,h,t in names}
    eligible = {}
    for enc in {e for _,e in OLD}:
        subset = [r for r in names if r[2] == enc]
        checked = measure.keyed_output((build / 'baseline-main/eval/runs' / f'decode-{enc}.stdout.tsv').read_text(), [r[0] for r in subset], 3)
        for identifier, lang, _, h, title in subset:
            status, escaped = checked[identifier]
            eligible[lang,enc,h] = status != 'FAIL' and measure.cf_comparison_text(measure.decoded_fields(escaped)[0], enc) == title
    singles = []
    groups = []
    for phase in ['baseline-main', FINAL]:
        runs = build / phase / 'eval/runs'
        singles.append(measure.keyed_output((runs / 'names-kaito_ja.stdout.tsv').read_text(), [r[0] for r in names], 4))
        groups.append(measure.keyed_output((runs / 'archives-kaito_ja.stdout.tsv').read_text(), [r[0] for r in archives], 4))
    name_rows = []
    for identifier, lang, enc, h, title in names:
        if title not in watched or (lang, enc) not in OLD or not eligible[lang,enc,h]:
            continue
        values = []
        for results in singles:
            predicted, _, escaped = results[identifier]
            values.append(f'{predicted}: {measure.cf_comparison_text(measure.decoded_fields(escaped)[0], predicted)}')
        name_rows.append([identifier, lang, enc, title, *values])
    group_rows = []
    for title in watched:
        n = 0
        correct = [0,0]
        for identifier, lang, enc, k, hex_list in archives:
            if int(k) < 10 or (lang, enc) not in OLD:
                continue
            if any(not eligible.get((lang,enc,h), True) for h in hex_list.split(',')):
                continue
            expected = [lookup.get((lang,enc,h), bytes.fromhex(h).decode('ascii', errors='replace')) for h in hex_list.split(',')]
            if title not in expected:
                continue
            n += 1
            for i, results in enumerate(groups):
                predicted, _, escaped = results[identifier]
                decoded = [measure.cf_comparison_text(t, predicted) for t in measure.decoded_fields(escaped)]
                correct[i] += decoded == expected
        group_rows.append([title, n, *correct])
    return name_rows, group_rows


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, default=Path('.build'))
    parser.add_argument('--output', type=Path, default=Path('Documentation/verification/2026-09-14-name-encoding-languages.md'))
    args = parser.parse_args()
    reports = {(phase, split): json.loads((args.build / phase / split / 'report.json').read_text())
               for phase in ['baseline-main', FINAL] for split in ['tune', 'eval']}
    ablations = [json.loads((args.build / phase / 'tune/report.json').read_text())
                 for phase in ['cb-ablation-languages', 'cb-ablation-candidates']]
    output = ['## 固定レポートからの集計', '', '単位は %。差は変更後 − 基準の percentage points。— は分母0。', '',
              '### 全体（4方式）', '']
    rows = []
    for split in ['tune', 'eval']:
        for phase in ['baseline-main', FINAL]:
            r = reports[phase, split]
            for mode, g in r['totals'].items():
                rows.append([split, phase, mode, g['eligible']] + [fmt(100 * g['detectors'][d]['accuracy']) for d in DETECTORS])
    output += [table(['split', '版', '単名/書庫', '分母'] + DETECTORS, rows), '', '### 性能とCF除外', '']
    rows = []
    for (phase, split), r in reports.items():
        n = r['performance']['archive_sampled_members']
        rows.append([split, phase, n, f"{r['timings_seconds']['archives-kaito_ja']:.3f}"] +
                    [f"{r['performance']['archive_microseconds_per_sampled_member'][d]:.3f}" for d in DETECTORS] +
                    [f"{512 * r['performance']['archive_microseconds_per_sampled_member']['kaito_ja'] / 1000:.3f}"] +
                    [r['totals']['single']['cf_table_invalid'], r['totals']['single']['codec_mismatch'],
                     r['totals']['archive']['cf_table_invalid'], r['totals']['archive']['codec_mismatch']])
    output += [table(['split', '版', 'sample名', 'ja秒'] + [d + ' µs/名' for d in DETECTORS] +
                     ['512名×ja ms', '単名CF表不正', '単名CF差', '書庫CF表不正', '書庫CF差'], rows), '',
               '入力全体（codec-mismatch / cf-table-invalid 行を含む）の時間を、実際の sample 構成員数で割った。', '',
               '訂正2の性能基準は sample 上限512 × 実測µs ≤ 50 ms/書庫。表の積は実測平均からの見積もりであり、全入力・全機種のwall-clock上限を保証しない。', '',
               '### 旧49群・既存18言語（eval）', '']
    rows = []
    for mode in ['single', 'archive']:
        for phase in ['baseline-main', FINAL]:
            group = next(r for r in reports[phase, 'eval'][mode + '_by_language'] if r['lang'] == 'ja')
            rows.append([mode, phase, group['eligible']] + [fmt(100 * group['detectors'][d]['accuracy']) for d in DETECTORS])
    output += ['日本語の全単名・全書庫（99.50 / 99.84 の参照分母）:', '',
               table(['群', '版', '分母'] + DETECTORS, rows), '']
    for kind in ['archive10', 'short', 'long']:
        rows = []
        for lang in [None, *generator.TASK_B_ENCODINGS]:
            n, before = select(reports['baseline-main', 'eval'], kind, lang, old=True)
            after_n, after = select(reports[FINAL, 'eval'], kind, lang, old=True)
            assert n == after_n
            rows.append([lang or '旧49全体', n] + [f'{fmt(before[d])} → {fmt(after[d])} ({after[d] - before[d]:+.2f})' if n else '—' for d in DETECTORS])
        output += [f'#### {kind}', '', table(['lang', '分母'] + DETECTORS, rows), '']
    output += ['### 新21言語（eval、CF除外後、report-only対の残差を含む正解率）', '']
    for kind in ['archive10', 'long']:
        rows = []
        for lang in NEW:
            n, values = select(reports[FINAL, 'eval'], kind, lang)
            rows.append([lang, n] + [fmt(values[d]) for d in DETECTORS])
        output += [f'#### {kind}', '', table(['lang', '分母'] + DETECTORS, rows), '']
    output += ['### 2段階 ablation（tune、旧49群、ja）', '',
               'main → 言語だけ（26候補） → 候補追加（54候補、追加規則前） → 最終。段階間の差を分けて示す。', '']
    rows = []
    for lang in generator.TASK_B_ENCODINGS:
        for kind in ['archive10', 'short', 'long']:
            values = [select(r, kind, lang, old=True)[1]['kaito_ja'] for r in [reports['baseline-main', 'tune'], *ablations, reports[FINAL, 'tune']]]
            n = select(reports['baseline-main', 'tune'], kind, lang, old=True)[0]
            assert all(select(r, kind, lang, old=True)[0] == n for r in ablations)
            rows.append([lang, kind, n] + [fmt(v) for v in values] + [f'{values[i+1] - values[i]:+.2f}' if n else '—' for i in range(3)])
    output += [table(['lang', '群', '分母', 'main', '言語', '候補', '最終', '言語Δ', '候補Δ', '規則等Δ'], rows), '']
    c1 = json.loads((args.build / 'cb-correction1-release/tune/report.json').read_text())
    pre_lists = json.loads((args.build / 'cb-correction2-before-lists/tune/report.json').read_text())
    proposed_lists = json.loads((args.build / 'cb-correction2-proposed/tune/report.json').read_text())
    adopted_lists = json.loads((args.build / 'cb-correction2/tune/report.json').read_text())
    output += ['### 識別字追加だけの比較（tune）', '',
               '訂正1 → 共通grave/çの復元・密度2/3超・比率の範囲拡大・序数main（識別字前） → 識別字提示案 → 訂正2の採用リスト。訂正3の規則変更はこの識別字比較に混ぜず、別表に示す。', '']
    rows = []
    for phase, r in [('訂正1', c1), ('識別字前', pre_lists), ('提示案', proposed_lists), ('採用リスト（訂正2）', adopted_lists)]:
        for mode, g in r['totals'].items():
            rows.append([phase, mode, g['eligible']] + [fmt(100 * g['detectors'][d]['accuracy']) for d in DETECTORS])
    output += [table(['版', '群', '分母'] + DETECTORS, rows), '',
               'tr / ru / uk の単名を長さ別・4方式で比較する（旧49群）。', '']
    rows = []
    for lang in ['tr', 'ru', 'uk']:
        for kind in ['short', 'long']:
            n, before = select(pre_lists, kind, lang, old=True)
            after_n, after = select(adopted_lists, kind, lang, old=True)
            assert n == after_n
            rows.append([lang, kind, n] + [f'{fmt(before[d])} → {fmt(after[d])} ({after[d] - before[d]:+.2f})' for d in DETECTORS])
    output += [table(['lang', '群', '分母'] + DETECTORS, rows), '', '既存18言語（旧49群、ja）:', '']
    rows = []
    for lang in generator.TASK_B_ENCODINGS:
        for kind in ['archive10', 'short', 'long']:
            values = [select(r, kind, lang, old=True)[1]['kaito_ja'] for r in [c1, pre_lists, proposed_lists, adopted_lists]]
            n = select(pre_lists, kind, lang, old=True)[0]
            rows.append([lang, kind, n] + [fmt(v) for v in values] + [f'{values[3] - values[1]:+.2f}' if n else '—'])
    output += [table(['lang', '群', '分母', '訂正1', '識別字前', '提示案', '採用リスト', '識別字Δpp'], rows), '',
               '新21言語（ja、追加encodingを含む）:', '']
    rows = []
    for lang in NEW:
        for kind in ['archive10', 'short', 'long']:
            n, before = select(pre_lists, kind, lang)
            after_n, after = select(adopted_lists, kind, lang)
            assert n == after_n
            rows.append([lang, kind, n, fmt(before['kaito_ja']), fmt(after['kaito_ja']), f"{after['kaito_ja'] - before['kaito_ja']:+.2f}" if n else '—'])
    output += [table(['lang', '群', '分母', '識別字前', '識別字後', '識別字Δpp'], rows), '']
    output += ['### 訂正3の規則による変化（訂正2 → 最終）', '',
               'fixtureとguard入力の変更は測定コーパスに含まれない。識別字・prior・分母を固定した規則の差だけを示す。', '']
    for split in ['tune', 'eval']:
        previous = json.loads((args.build / 'cb-correction2' / split / 'report.json').read_text())
        rows = []
        declining_groups = 0
        for lang in generator.ENCODINGS:
            for kind in ['archive10', 'short', 'long']:
                old = lang in generator.TASK_B_ENCODINGS
                n, before = select(previous, kind, lang, old=old)
                final_n, after = select(reports[FINAL, split], kind, lang, old=old)
                assert n == final_n
                if n:
                    declining_groups += sum(after[d] < before[d] - 1e-9 for d in DETECTORS)
                if n and any(abs(before[d] - after[d]) > 1e-9 for d in DETECTORS):
                    rows.append([lang, kind, n] + [f'{fmt(before[d])} → {fmt(after[d])} ({after[d]-before[d]:+.2f})' for d in DETECTORS])
        output += [f'#### {split}', '', '変化した群だけを掲載。既存18言語は旧49群、新言語は追加候補も含む。', '',
                   f'全39言語×3区分×4方式のうち正解率が下がった群は{declining_groups}。群の正解数の比較であり、個々の名前の悪化数ではない。', '',
                   table(['lang', '群', '分母'] + DETECTORS, rows), '']
    name_rows, group_rows = foreign_name_rows(args.build)
    output += ['### cooViewer-y96a の外来名（eval、ja）', '',
               '対象は支給コーパスの同名行と、それを含む合成書庫。実書庫ファイルの再測定ではない。', '',
               table(['ID', 'lang', 'truth encoding', 'truth', 'main', '最終'], name_rows), '',
               '次は当該名を含む旧49群の k≥10 書庫全体の正解数。相関する集計であり、その名前だけに変更の原因を帰していない。', '',
               table(['含む名前', '書庫数', 'main正解数', '最終正解数'], group_rows), '']
    wrong = wrong_predictions(args.build / 'name-corpus-c-eval', args.build / FINAL / 'eval/runs')
    # 生出力から数えた誤りが本測定器の分母・完全一致と同じであることを群ごとに検査する。
    for mode, kind in [('archive', 'archive10'), ('single', 'long')]:
        for lang, encodings in generator.ENCODINGS.items():
            for _, enc in encodings:
                n, rates = select(reports[FINAL, 'eval'], kind, lang, encoding=enc)
                expected_errors = round(n * (1 - rates['kaito_ja'] / 100)) if n else 0
                assert sum(wrong[mode][lang, enc].values()) == expected_errors, (mode, lang, enc)
    output += ['### 指定された report-only 対の混同（eval、ja、原因判定とは区別）', '',
               '下表は誤りだけの混同件数。同じ文字列に復号できた行は誤りに数えない。全体表から事後に分母を引き直していない。', '']
    family_rows = []
    for label, languages, encodings in REPORT_ONLY_GROUPS:
        values = []
        for mode, kind in [('archive', 'archive10'), ('single', 'long')]:
            n = sum(select(reports[FINAL, 'eval'], kind, lang, encoding=enc)[0]
                    for lang in (languages or generator.ENCODINGS) for enc in encodings)
            errors = sum(count for (lang, truth), predictions in wrong[mode].items()
                         for predicted, count in predictions.items() if report_only_family(lang, truth, predicted) == label)
            values.extend([n, errors])
        family_rows.append([label, *values])
    output += [table(['指定群', '書庫分母', '群内混同', '単名≥4分母', '群内混同'], family_rows), '']
    rows = []
    for mode in ['archive', 'single']:
        for (lang, truth), errors in sorted(wrong[mode].items()):
            selected = [(detected, count) for detected, count in errors.items() if report_only(lang, truth, detected)]
            if selected:
                n, values = select(reports[FINAL, 'eval'], 'archive10' if mode == 'archive' else 'long', lang, encoding=truth)
                rows.append([mode, lang, truth, n, fmt(values['kaito_ja']), '<br>'.join(f'{p}: {c}' for p,c in sorted(selected))])
    output += [table(['群', 'lang', 'truth', '分母', 'ja正解率', '指定pairの誤り'], rows), '', '### 目標値を下回る群の混同（eval、ja）', '']
    rows = []
    for mode, threshold in [('archive', 99), ('single', 90)]:
        kind = 'archive10' if mode == 'archive' else 'long'
        for lang in NEW:
            n, values = select(reports[FINAL, 'eval'], kind, lang)
            if not n or values['kaito_ja'] >= threshold:
                continue
            errors = Counter()
            specified = 0
            for (l, truth), counts in wrong[mode].items():
                if l != lang:
                    continue
                for predicted, count in counts.items():
                    errors[f'{truth} → {predicted}'] += count
                    if report_only(lang, truth, predicted):
                        specified += count
            rows.append([mode, lang, n, fmt(values['kaito_ja']), specified, sum(errors.values()) - specified,
                         '<br>'.join(f'{pair}: {count}' for pair, count in errors.most_common(5))])
    output += [table(['群', 'lang', '分母', 'ja正解率', '指定pair誤り数', 'それ以外の誤り', '誤り上位5対'], rows), '',
               '指定pairは混同対の集計であり、全件を本質的曖昧性と断定しない。特に el の Windows / ISO prior の不備は修正対象である。それ以外の対にも言語規則の証拠不足を含む。', '',
               '### 残差の実例（eval、ja）', '']
    rows = []
    for mode, kind, threshold in [('archive', 'archive10', 99), ('single', 'long', 90)]:
        for lang in NEW:
            n, rates = select(reports[FINAL, 'eval'], kind, lang)
            if not n or rates['kaito_ja'] >= threshold:
                continue
            pairs = [(count, truth, predicted) for (l, truth), counts in wrong[mode].items() if l == lang
                     for predicted, count in counts.items() if not report_only(lang, truth, predicted)]
            if not pairs:
                continue
            _, truth, predicted = max(pairs)
            identifier, expected, decoded = wrong['examples'][mode][lang, truth, predicted]
            rows.append([mode, lang, f'{truth} → {predicted}', identifier, expected.replace('|', '\\|'), decoded.replace('|', '\\|')])
    output += [table(['群', 'lang', '対', 'ID', 'truth', '判定後'], rows), '',
               '### 既存言語の許容差を超えた群（eval、ja）', '']
    original = json.loads((args.build / 'cb-final/eval/report.json').read_text())
    correction1 = json.loads((args.build / 'cb-correction1-release/eval/report.json').read_text())
    correction2 = json.loads((args.build / 'cb-correction2/eval/report.json').read_text())
    resolved, remaining = [], []
    for kind, limit in [('archive10', 0), ('short', -1), ('long', -0.5)]:
        for lang in generator.TASK_B_ENCODINGS:
            n, before = select(reports['baseline-main', 'eval'], kind, lang, old=True)
            _, initial = select(original, kind, lang, old=True)
            _, middle = select(correction1, kind, lang, old=True)
            _, second = select(correction2, kind, lang, old=True)
            _, after = select(reports[FINAL, 'eval'], kind, lang, old=True)
            if not n:
                continue
            failed_before = initial['kaito_ja'] - before['kaito_ja'] < limit - 1e-9
            failed_middle = middle['kaito_ja'] - before['kaito_ja'] < limit - 1e-9
            failed_after = after['kaito_ja'] - before['kaito_ja'] < limit - 1e-9
            failed_second = second['kaito_ja'] - before['kaito_ja'] < limit - 1e-9
            if failed_before or failed_middle or failed_second or failed_after:
                row = [kind, lang, n, fmt(before['kaito_ja']), fmt(initial['kaito_ja']), fmt(middle['kaito_ja']), fmt(second['kaito_ja']), fmt(after['kaito_ja']),
                       f"{after['kaito_ja'] - before['kaito_ja']:+.2f}", limit]
                (remaining if failed_after else resolved).append(row)
    headers = ['群', 'lang', '分母', 'main', '初回 C-B', '訂正1', '訂正2', '最終', '最終差pp', '許容下限pp']
    output += ['解消した群:', '', table(headers, resolved), '', '残る群（新たな超過を含む）:', '', table(headers, remaining), '',
               'el の初回 −16.33 pp は prior 同点の不備による回帰であり、report-only として免除しない。', '',
               '### 新言語で udet を下回る encoding 群（eval、ja）', '']
    rows = []
    for kind in ['archive10', 'long']:
        for lang in NEW:
            for _, enc in generator.ENCODINGS[lang]:
                n, values = select(reports[FINAL, 'eval'], kind, lang, encoding=enc)
                if n and values['kaito_ja'] < values['udet']:
                    rows.append([kind, lang, enc, n, fmt(values['kaito_ja']), fmt(values['udet'])])
    output += [table(['群', 'lang', 'encoding', '分母', 'ja', 'udet'], rows), '',
               '### 保存物のSHA-256', '']
    rows = []
    for (phase, split), r in reports.items():
        rows.append([phase, split, r['kaito_sha256'], r['corpus_sha256']['names.tsv'], r['corpus_sha256']['archives.tsv']])
    output += [table(['版', 'split', 'kaito', 'names.tsv', 'archives.tsv'], rows), '']
    text = args.output.read_text()
    marker = '<!-- C-B generated metrics -->'
    history_marker = '<!-- C-B correction history -->'
    history = text.split(history_marker, 1)[1].strip() if history_marker in text else ''
    text = text.split(marker)[0].split(history_marker)[0].rstrip() + '\n\n' + marker + '\n\n' + '\n'.join(output) + '\n'
    if history:
        text += '\n' + history_marker + '\n\n' + history + '\n'
    args.output.write_text(text)
    print(args.output)


if __name__ == '__main__':
    main()
