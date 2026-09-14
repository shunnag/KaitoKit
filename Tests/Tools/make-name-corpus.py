#!/usr/bin/env python3
"""記事名から再現可能な legacy encoding の名前・擬似書庫コーパスを生成する。

入力: inbox/name-corpus/raw/<lang>.txt（UTF-8、1 行 1 記事名、18 言語）。
出力: .build/name-corpus/{names.tsv,archives.tsv,summary.json}。
TSV はヘッダ付き、引用符処理なし。k は非 ASCII 名数で、ASCII 名は追加する。
--split all|tune|eval は元記事名の SHA-256 で分割し、派生名も同じ側へ置く。
CP1258 の正解 text は、表現できない前合成文字の声調を結合文字にした列。
入力が未到着なら 30 秒ごとに最大 10 分待つ。ネットワークは使用しない。
"""

import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import re
import sys
import time
import unicodedata


ROOT = Path(__file__).resolve().parents[2]
WESTERN = [("cp1252", "windows-1252"), ("iso8859_15", "iso-8859-15"),
           ("mac_roman", "macintosh"), ("cp850", "cp850")]
CENTRAL = [("cp1250", "windows-1250"), ("iso8859_2", "iso-8859-2"),
           ("mac_latin2", "x-mac-centraleurroman")]
CYRILLIC = [("iso8859_5", "iso-8859-5"), ("cp866", "cp866"), ("mac_cyrillic", "x-mac-cyrillic")]
ENCODINGS = {
    "ja": [("cp932", "cp932"), ("euc_jp", "euc-jp")],
    "zh-cn": [("gb18030", "gb18030")],
    "zh-tw": [("cp950", "cp950"), ("big5hkscs", "big5-hkscs")],
    "ko": [("cp949", "cp949")],
    "vi": [("cp1258", "windows-1258")],
    "th": [("cp874", "cp874")],
    "uk": [("cp1251", "windows-1251"), ("koi8_u", "koi8-u")] + CYRILLIC,
    "ru": [("cp1251", "windows-1251"), ("koi8_r", "koi8-r")] + CYRILLIC,
    **{lang: WESTERN for lang in ("es", "pt", "fr", "de", "it")},
    **{lang: CENTRAL for lang in ("pl", "cs", "hu")},
    "el": [("cp1253", "windows-1253")],
    "tr": [("cp1254", "windows-1254")],
}
SIZES = (1, 2, 3, 5, 10, 30, 100)
ASCII_NAMES = ("cover.jpg", "001.png", "readme.txt", "Vol.01/index.html", "002.jpg", "folder/page03.png")
SHAPE_MARKS = frozenset("\u0302\u0306\u031b")
TONE_MARKS = frozenset("\u0300\u0301\u0303\u0309\u0323")


def article_split(title):
    canonical = unicodedata.normalize("NFC", title.strip())
    return "tune" if hashlib.sha256(canonical.encode("utf-8")).digest()[0] < 179 else "eval"


def random_stream(seed, *parts):
    # 書庫の大きさや選択 split によって、後続言語の派生名が変わらないようにする。
    value = json.dumps([seed, *parts], ensure_ascii=False).encode("utf-8")
    return random.Random(int.from_bytes(hashlib.sha256(value).digest(), "big"))


def cp1258_text(text):
    """CP1258 で表現できない文字の形状だけを再合成し、声調をその直後に置く。"""
    result = []
    for char in text:
        try:
            char.encode("cp1258", errors="strict")
        except UnicodeEncodeError:
            decomposed = unicodedata.normalize("NFD", char)
            shaped = "".join(c for c in decomposed if c not in TONE_MARKS)
            # 形状以外の結合記号も失わない。残った未対応文字は符号化時に除外する。
            if all(not unicodedata.combining(c) or c in SHAPE_MARKS for c in shaped):
                char = unicodedata.normalize("NFC", shaped) + "".join(c for c in decomposed if c in TONE_MARKS)
        result.append(char)
    return "".join(result)


def target_character(char, lang):
    cp = ord(char)
    if lang == "ja" or lang.startswith("zh-"):
        han = (0x3400 <= cp <= 0x4DBF or 0x4E00 <= cp <= 0x9FFF or
               0xF900 <= cp <= 0xFAFF or 0x20000 <= cp <= 0x323AF)
        return han or (lang == "ja" and (0x3040 <= cp <= 0x30FF or 0xFF66 <= cp <= 0xFF9D))
    if lang == "ko":
        return (0xAC00 <= cp <= 0xD7A3 or 0x1100 <= cp <= 0x11FF or
                0x3130 <= cp <= 0x318F or 0xA960 <= cp <= 0xA97F or 0xD7B0 <= cp <= 0xD7FF)
    if lang == "th":
        return 0x0E00 <= cp <= 0x0E7F and unicodedata.category(char).startswith(("L", "M"))
    if lang in ("uk", "ru"):
        return "CYRILLIC" in unicodedata.name(char, "") and unicodedata.category(char).startswith("L")
    if lang == "el":
        return "GREEK" in unicodedata.name(char, "") and unicodedata.category(char).startswith("L")
    return cp > 127 and "LATIN" in unicodedata.name(char, "") and unicodedata.category(char).startswith("L")


def eligible(text, lang):
    return any(target_character(c, lang) for c in text)


def wait_for_inputs(directory):
    deadline = time.monotonic() + 600
    while True:
        missing = [lang for lang in ENCODINGS if not (directory / f"{lang}.txt").is_file()]
        if not missing:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("入力の待機期限を超過: " + ", ".join(missing))
        print("未到着の入力を待機: " + ", ".join(missing), file=sys.stderr, flush=True)
        time.sleep(min(30, remaining))


def volume_label(lang, number):
    if lang == "ja" or lang.startswith("zh-"):
        return f"第{number:02d}巻"
    prefix = {"vi": "Tập ", "th": "เล่ม ", "uk": "Том ", "ru": "Том ",
              "el": "Τόμος ", "fr": "Tome ", "de": "Band "}.get(lang, "Vol.")
    return f"{prefix}{number:02d}"


def decorate(name, titles, lang, rng):
    styles = ["volume", "version", "year", "image", "zip"]
    if name.upper() != name.lower():
        styles.extend(["upper", "lower"])
    style = rng.choice(styles)
    if style == "volume":
        other = rng.choice(titles)
        if other == name and len(titles) > 1:
            other = titles[(titles.index(name) + 1) % len(titles)]
        return f"[{other}] {name} {volume_label(lang, rng.randint(1, 12))}"
    if style == "version":
        return f"{name} v{rng.randint(1, 20):02d}"
    if style == "year":
        return f"{name} ({rng.randint(1990, 2024)})"
    if style == "image":
        return f"{name} - {rng.randint(1, 120):03d}.jpg"
    if style == "zip":
        return name + ".zip"
    return name.upper() if style == "upper" else name.lower()


def short_names(titles, lang, rng):
    # 先頭語の 1〜3 scalar の接頭辞から、対象文字種を含む候補だけを選ぶ。
    sources = {}
    for title in titles:
        word = re.split(r"[\W_]+", title, maxsplit=1)[0]
        for length in (1, 2, 3):
            if len(word) >= length and eligible(word[:length], lang):
                # 同じ短名を作れる元記事が複数ある場合は、ソート順で最初の記事に固定する。
                sources.setdefault(word[:length], title)
    pool = sorted(sources)
    if not pool:
        raise ValueError(f"{lang}: 先頭語から短名を作れません")
    result = []
    while len(result) < 200:
        shuffled = pool[:]
        rng.shuffle(shuffled)
        result.extend(shuffled[:200 - len(result)])
    return [(name, sources[name], "short") for name in result]


def make_candidates(titles, lang, seed):
    rng = random_stream(seed, "names", lang)
    subsets = {split: [t for t in titles if article_split(t) == split] for split in ("tune", "eval")}
    decorated = set(rng.sample(range(len(titles)), round(len(titles) * 0.3)))
    candidates = [(title, title, "article") for title in titles]
    # 装飾に含める別の記事名も、元記事と同じ split から選ぶ。
    candidates.extend((decorate(t, subsets[article_split(t)], lang, rng), t, "decoration")
                      for i, t in enumerate(titles) if i in decorated)
    candidates.extend(short_names(titles, lang, rng))
    return candidates


def split_counts():
    return {split: {"eligible_articles": 0, "candidates": 0, "rows": 0} for split in ("all", "tune", "eval")}


def utf8_valid(data):
    try:
        data.decode("utf-8", errors="strict")
        return True
    except UnicodeDecodeError:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw-dir", type=Path, default=ROOT / "inbox/name-corpus/raw")
    parser.add_argument("--out-dir", type=Path, default=ROOT / ".build/name-corpus")
    parser.add_argument("--seed", type=int, default=20260914)
    parser.add_argument("--split", choices=("all", "tune", "eval"), default="all")
    args = parser.parse_args()
    wait_for_inputs(args.raw_dir)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    summary = {"schema_version": 2, "seed": args.seed, "split": args.split,
               "split_rule": "SHA-256(NFC(strip(article))).digest()[0] < 179: tune; otherwise eval",
               "split_counts": split_counts(), "unicode_version": unicodedata.unidata_version,
               "decoration": "keep eligible article names; add decorated variants for 30%, then add 200 short names",
               "short_names": "200 per language before split selection; first-word prefixes inherit the canonical source article split",
               "vietnamese": "unencodable precomposed scalars: NFD, NFC(base + shape marks), then combining tone marks",
               "archives": "k non-ASCII names sampled without replacement; 20% of groups add 1-3 ASCII names",
               "languages": {}, "encodings": [], "name_rows": 0, "archive_groups": 0}
    all_row_id = 0
    with (args.out_dir / "names.tsv").open("w", encoding="utf-8", newline="\n") as names, \
            (args.out_dir / "archives.tsv").open("w", encoding="utf-8", newline="\n") as archives:
        names.write("id\tlang\ttruth_iana\thex\ttext\n")
        archives.write("group\tlang\ttruth_iana\tk\thex1,hex2,...\n")
        for lang, encodings in ENCODINGS.items():
            raw = (args.raw_dir / f"{lang}.txt").read_bytes()
            lines = raw.decode("utf-8").splitlines()
            titles = sorted({unicodedata.normalize("NFC", line.strip()) for line in lines if line.strip() and
                             not any(c in line for c in "\t\r\n\0") and eligible(unicodedata.normalize("NFC", line), lang)})
            if not titles:
                raise ValueError(f"{lang}: 対象文字を含む記事名がありません")
            candidates = make_candidates(titles, lang, args.seed)
            counts_by_split = split_counts()
            for title in titles:
                counts_by_split["all"]["eligible_articles"] += 1
                counts_by_split[article_split(title)]["eligible_articles"] += 1
            for _, source, _ in candidates:
                counts_by_split["all"]["candidates"] += 1
                counts_by_split[article_split(source)]["candidates"] += 1
            selected = [c for c in candidates if args.split == "all" or article_split(c[1]) == args.split]
            shorts = [name for name, _, kind in selected if kind == "short"]
            summary["languages"][lang] = {
                "raw_lines": len(lines), "raw_sha256": hashlib.sha256(raw).hexdigest(),
                "eligible_articles": counts_by_split[args.split]["eligible_articles"],
                "decoration_selections": sum(kind == "decoration" for _, _, kind in selected),
                "short_candidates": len(shorts), "unique_short_candidates": len(set(shorts)),
                "candidates": len(selected), "split_counts": counts_by_split,
            }
            for codec, iana in encodings:
                excluded = Counter()
                encoded = []
                rows_by_split = {split: 0 for split in ("all", "tune", "eval")}
                converted = 0
                for title, source, _ in candidates:
                    split = article_split(source)
                    include = args.split == "all" or split == args.split
                    if not eligible(title, lang):
                        if include:
                            excluded["lost_target_after_case_mapping"] += 1
                        continue
                    if codec == "big5hkscs":
                        try:
                            title.encode("cp950", errors="strict")
                        except UnicodeEncodeError:
                            pass
                        else:
                            if include:
                                excluded["representable_in_cp950"] += 1
                            continue
                    original = title
                    if codec == "cp1258":
                        title = cp1258_text(title)
                    try:
                        data = title.encode(codec, errors="strict")
                    except UnicodeEncodeError:
                        if include:
                            excluded["unencodable"] += 1
                        continue
                    if data.isascii():
                        if include:
                            excluded["ascii_bytes"] += 1
                        continue
                    if utf8_valid(data):
                        if include:
                            excluded["strict_utf8_bytes"] += 1
                        continue
                    all_row_id += 1
                    for partition in ("all", split):
                        rows_by_split[partition] += 1
                        counts_by_split[partition]["rows"] += 1
                    if not include:
                        continue
                    converted += original != title
                    hex_value = data.hex()
                    encoded.append(hex_value)
                    summary["name_rows"] += 1
                    names.write(f"n{all_row_id:07d}\t{lang}\t{iana}\t{hex_value}\t{title}\n")
                # 短名の重複による同一書庫内の水増しを避ける。
                pool = list(dict.fromkeys(encoded))
                rng = random_stream(args.seed, "archives", lang, iana, args.split)
                counts = {}
                for k in SIZES:
                    group_count = min(100, len(pool)) if len(pool) >= k else 0
                    ascii_groups = set(rng.sample(range(group_count), round(group_count * 0.2)))
                    for group_index in range(group_count):
                        members = rng.sample(pool, k)
                        if group_index in ascii_groups:
                            members.extend(s.encode("ascii").hex() for s in rng.sample(ASCII_NAMES, rng.randint(1, 3)))
                            rng.shuffle(members)
                        summary["archive_groups"] += 1
                        archives.write(f"g{summary['archive_groups']:07d}\t{lang}\t{iana}\t{k}\t{','.join(members)}\n")
                    counts[str(k)] = {"groups": group_count, "ascii_mixed_groups": len(ascii_groups)}
                summary["encodings"].append({"lang": lang, "truth_iana": iana, "python_codec": codec,
                                              "rows": len(encoded), "unique_bytes": len(pool),
                                              "rows_by_split": rows_by_split, "converted_text_rows": converted,
                                              "excluded": dict(sorted(excluded.items())), "archives_by_k": counts})
                print(f"{lang}/{iana}: {len(encoded)} names, {sum(c['groups'] for c in counts.values())} groups", flush=True)
            for split, counts in counts_by_split.items():
                for key, value in counts.items():
                    summary["split_counts"][split][key] += value
    summary["files_sha256"] = {name: hashlib.sha256((args.out_dir / name).read_bytes()).hexdigest()
                               for name in ("names.tsv", "archives.tsv")}
    (args.out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"total: {summary['name_rows']} names, {summary['archive_groups']} archives")


if __name__ == "__main__":
    main()
