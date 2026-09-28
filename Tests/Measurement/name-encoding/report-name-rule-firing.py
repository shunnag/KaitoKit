#!/usr/bin/env python3
"""実在する tune 記事名だけの規則発火率。派生装飾・切り出し短名を分母に加えない。"""
import argparse
from collections import Counter, defaultdict
from importlib import import_module
from pathlib import Path
import unicodedata

corpus = import_module('make-name-corpus')

RULES = {
    'caret-beside-letter': list(corpus.ENCODINGS),
    'symbol-bridged-script-mixture': list(corpus.ENCODINGS),
    'el-diaeresis-without-vowel': ['el'], 'el-initial-apostrophe-vowel': ['el'],
    'fr-initial-apostrophe': ['fr'],
    'is-y-acute-final': ['is'], 'is-y-acute-initial-upper': ['is'], 'is-y-acute-repeated': ['is'],
    'el-compound-component-boundary': ['el'], 'el-multiple-tonos': ['el'], 'el-final-sigma-internal': ['el'], 'el-sigma-final': ['el'],
    'ru-short-i-ratio': ['ru'], 'he-final-form-evidence': ['he'],
    'bracket-between-letters': list(corpus.ENCODINGS),
    'semitic-symbol-between-letters': list(corpus.ENCODINGS),
    'latin-diacritic-density': [l for l in corpus.ENCODINGS if l != 'vi'],
    'he-final-internal': ['he'], 'he-nominal-final': ['he'], 'he-mark-base': ['he'],
    'arabic-mark-base': ['ar', 'fa'], 'arabic-teh-marbuta-internal': ['ar', 'fa'],
    'ar-alef-maksura-internal': ['ar'], 'ar-hamza-initial': ['ar'],
    'ru-hard-sign-position': ['ru'], 'uk-hard-sign-position': ['uk'], 'be-hard-sign-position': ['be'],
    'ru-hard-sign-ratio': ['ru'], 'ru-shcha-ratio': ['ru'], 'bg-hard-sign-vowel': ['bg'],
    'be-short-u-after-vowel': ['be'], 'is-eth-initial': ['is'], 'is-thorn-final': ['is'], 'is-thorn-cluster': ['is'],
    'alphabet-singleton-in-latin': ['he','ar','fa','ru','uk','be','bg','sr','mk'],
    'semitic-script-mixture': list(corpus.ENCODINGS), 'semitic-mark-after-latin': list(corpus.ENCODINGS),
    'latin-terminal-uppercase': list(corpus.ENCODINGS),
    'cyrillic-south-east-mixture': ['ru','uk','be','bg','sr','mk'],
    'cyrillic-two-consonants': ['ru','uk','be','bg','sr','mk'], 'th-closing-quote-initial': ['th'],
    'semitic-frequent-bonus': ['he','ar','fa'], 'ru-de-frequency-bonus': ['ru'],
    'fa-compatible-main': ['fa'], 'ro-compatible-main': ['ro'],
    'ordinal-main': ['es', 'pt'],
}
for language in ['uk', 'be', 'bg', 'sr', 'mk']:
    for rule in ['short-i-ratio', 'shcha-ratio']:
        RULES[f'{language}-{rule}'] = [language]
    if language in ['uk', 'be']:
        RULES[f'{language}-hard-sign-ratio'] = [language]
for language in ['lt', 'lv', 'et', 'ro', 'hr', 'sl', 'sk', 'da', 'nb', 'sv', 'fi', 'is', 'nl', 'sr-Latn', 'bg', 'sr', 'mk', 'be']:
    RULES[f'identifying-letter-bonus-{language}'] = [language]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--names', type=Path, default=Path('.build/name-corpus-c-tune/names.tsv'))
    parser.add_argument('--raw', type=Path, default=Path('inbox/name-corpus/raw'))
    parser.add_argument('--events', type=Path, default=Path('.build/cb-correction3/rules.tsv'))
    parser.add_argument('--output', type=Path, default=Path('.build/cb-correction3/rules.md'))
    args = parser.parse_args()
    titles = {}
    for lang, encodings in corpus.ENCODINGS.items():
        raw = corpus.raw_path(args.raw, lang).read_text().splitlines()
        if lang in ['sr', 'sr-Latn']:
            raw = [s for s in raw if corpus.serbian_script(s) == lang]
        raw = {unicodedata.normalize('NFC', s.strip()) for s in raw if s.strip() and not any(c in s for c in '\t\r\n\0')}
        raw = {s for s in raw if corpus.eligible(s, lang) and corpus.article_split(s) == 'tune'}
        for codec, iana in encodings:
            converted = {corpus.legacy_text(s, lang, codec) for s in raw}
            if codec == 'cp1258':
                converted = {corpus.cp1258_text(s) for s in converted}
            titles[lang, iana] = converted
    names = {r[0]: r for r in (s.split('\t') for s in args.names.read_text().splitlines()[1:])}
    observed = defaultdict(set)
    excluded = Counter()
    real_rows = 0
    for line in args.events.read_text().splitlines():
        identifier, lang, events, invalid = line.split('\t')
        _, _, encoding, hex_value, title = names[identifier]
        if encoding in ['cp861', 'viscii'] or title not in titles[lang, encoding]:
            continue
        real_rows += 1
        observed[lang, title].update(events.split(',') if events else [])
        excluded[int(invalid)] += 1
    output = ['## 規則の発火率（tune 実在名）', '',
              f'支給 raw の元記事名に一致する {real_rows:,} encoding 行、重複をまとめた {len(observed):,}（言語, truth文字列）を観測した。',
              'CP861 / VISCII を除く。装飾名・切り出し短名を足さず、CF差のある名前は言語事実の観測には残す。互換綴りで文字列が変わる場合は別の観測名になる。',
              'これは正しい truth に規則が発火する率であり、誤復号の検出率ではない。0%の規則も、交差復号・自作の負例で検証する。', '',
              '| 規則 | 対象言語 | 実在名分母 | 発火名 | % | 例（最大2） |', '|---|---|---:|---:|---:|---|']
    for rule, langs in RULES.items():
        relevant = [(lang,t) for lang,t in observed if lang in langs]
        hits = [(l,t) for l,t in relevant if rule in observed[l,t]]
        examples = '; '.join(f'{l}: {t}'.replace('|','\\|') for l,t in sorted(hits)[:2]) or '—'
        labels = '全39' if len(langs)==39 else ','.join(langs)
        output.append(f'| {rule} | {labels} | {len(relevant)} | {len(hits)} | {100*len(hits)/len(relevant) if relevant else 0:.3f} | {examples} |')
    output += ['', '### 括弧・密度の言語別発火率', '',
               '| 言語 | 実在名 | 括弧 | 密度 |', '|---|---:|---:|---:|']
    for lang in corpus.ENCODINGS:
        relevant = [events for (l,t),events in observed.items() if l == lang]
        counts = [sum(rule in e for e in relevant) for rule in ['bracket-between-letters','latin-diacritic-density']]
        output.append(f'| {lang} | {len(relevant)} | ' + ' | '.join(f'{n} ({100*n/len(relevant) if relevant else 0:.3f}%)' for n in counts) + ' |')
    mean = sum(n*c for n,c in excluded.items()) / real_rows
    output += ['', f'未定義byteの事前除外: 実在名1行あたり平均 {mean:.3f} / 48 single-byte候補（{100*mean/48:.2f}%）。',
               f'少なくとも1候補を事前除外する行: {real_rows-excluded[0]:,} / {real_rows:,}（{100*(real_rows-excluded[0])/real_rows:.2f}%）。', '',
               '字母頻度の加点と互換集合は違反検出ではない。bg-hard-sign-vowel は ъ を母音にしたことで音韻得点が変わった名前の率。', '']
    args.output.write_text('\n'.join(output))
    print(args.output)


if __name__ == '__main__':
    main()
