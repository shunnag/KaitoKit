#!/usr/bin/env python3
"""ローカル CLDR XML の主・補助文字集合から大小文字を含む Swift 表を生成する。

入力: inbox/cldr/{言語}.xml と LICENSE（ネットワークは使用しない）。
出力: 閉区間の端点列を持つ Sources/KaitoKit/Text/LanguageExemplars.swift とルートの NOTICE。
--cldr-dir / --output / --notice で各パスを変更できる。
"""

import argparse
from pathlib import Path
import re
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = "ja zh zh-Hant ko vi th uk ru es pt fr de it pl cs hu el tr en".split()
SOURCE = "https://github.com/unicode-org/cldr/tree/main/common/main"


def parse_unicode_set(pattern):
    """範囲・文字列・エスケープを解釈し、集合内の Unicode scalar を返す。"""
    pattern = pattern.strip()
    if not (pattern.startswith("[") and pattern.endswith("]")):
        raise ValueError(f"UnicodeSet の括弧がありません: {pattern!r}")
    body = pattern[1:-1]
    tokens = []
    index = 0
    in_string = False
    while index < len(body):
        char = body[index]
        index += 1
        if char == "\\":
            match = re.match(r"u\{([0-9A-Fa-f]+)\}|u([0-9A-Fa-f]{4})|U([0-9A-Fa-f]{8})", body[index:])
            if match:
                scalar = int(next(g for g in match.groups() if g is not None), 16)
                if scalar > 0x10FFFF or 0xD800 <= scalar <= 0xDFFF:
                    raise ValueError(f"Unicode scalar ではありません: {scalar:x}")
                char = chr(scalar)
                index += len(match.group())
            else:
                if index == len(body) or body[index] in "uU":
                    raise ValueError("不完全なエスケープ")
                char = body[index]
                index += 1
            tokens.append(ord(char))
        elif char == "{":
            if in_string:
                raise ValueError("文字列の入れ子")
            in_string = True
        elif char == "}":
            if not in_string:
                raise ValueError("対応しない文字列の終端")
            in_string = False
        elif char.isspace():
            continue
        elif char == "-" and not in_string:
            tokens.append("-")
        elif char in "[]&^" and not in_string:
            raise ValueError(f"未対応の UnicodeSet 演算子: {char}")
        else:
            tokens.append(ord(char))
    if in_string:
        raise ValueError("閉じていない文字列")

    scalars = set()
    index = 0
    while index < len(tokens):
        first = tokens[index]
        if not isinstance(first, int):
            raise ValueError("範囲の始点がありません")
        if index + 1 < len(tokens) and tokens[index + 1] == "-":
            if index + 2 >= len(tokens) or not isinstance(tokens[index + 2], int):
                raise ValueError("範囲の終点がありません")
            last = tokens[index + 2]
            if last < first or (first <= 0xDFFF and last >= 0xD800):
                raise ValueError("不正な scalar 範囲")
            scalars.update(range(first, last + 1))
            index += 3
        else:
            scalars.add(first)
            index += 1
    # 一文字が複数文字になる大文字化も、結合記号を含め scalar ごとに展開する。
    return sorted(scalars | {ord(c) for s in scalars for c in chr(s).upper()})


def compress_ranges(values):
    """昇順の scalar 列を、連続する閉区間の端点列にまとめる。"""
    ranges = []
    for value in values:
        if ranges and ranges[-1] + 1 == value:
            ranges[-1] = value
        else:
            ranges.extend([value, value])
    return ranges


def swift_array(values, indent):
    if not values:
        return "[]"
    lines = [", ".join(f"0x{v:04X}" for v in values[i:i + 12]) for i in range(0, len(values), 12)]
    return "[\n" + "\n".join(indent + "    " + line + "," for line in lines) + "\n" + indent + "]"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cldr-dir", type=Path, default=ROOT / "inbox/cldr")
    parser.add_argument("--output", type=Path, default=ROOT / "Sources/KaitoKit/Text/LanguageExemplars.swift")
    parser.add_argument("--notice", type=Path, default=ROOT / "NOTICE")
    args = parser.parse_args()
    lines = [
        "// このファイルは Tests/Tools/make-exemplars.py により生成されています。",
        f"// 生成元: CLDR の文字集合 {SOURCE}",
        "// 取得日: 2026-09-14。Unicode License v3、NOTICE 参照。",
        "// 主集合と補助集合だけを使い、構成 scalar と大文字を展開しています。",
        "// 配列は閉区間の下端・上端を交互に並べ、連続する区間を統合しています。",
        "",
        "enum LanguageExemplars {",
        "    enum Kind { case main, auxiliary }",
        "",
        "    static func contains(_ scalar: UInt32, language: String, kind: Kind) -> Bool {",
        "        guard let entry = table.first(where: { $0.language == language }) else { return false }",
        "        let ranges: [UInt32]",
        "        switch kind {",
        "        case .main: ranges = entry.main",
        "        case .auxiliary: ranges = entry.auxiliary",
        "        }",
        "        var lower = 0",
        "        var upper = ranges.count / 2",
        "        while lower < upper {",
        "            let middle = lower + (upper - lower) / 2",
        "            if scalar < ranges[middle * 2] {",
        "                upper = middle",
        "            } else if scalar > ranges[middle * 2 + 1] {",
        "                lower = middle + 1",
        "            } else {",
        "                return true",
        "            }",
        "        }",
        "        return false",
        "    }",
        "",
        "    static let table: [(language: String, main: [UInt32], auxiliary: [UInt32])] = [",
    ]
    counts = []
    for language in LANGUAGES:
        root = ET.parse(args.cldr_dir / (language.replace("-", "_") + ".xml")).getroot()
        sets = {}
        for entry in root.findall("./characters/exemplarCharacters"):
            kind = entry.get("type", "main")
            if kind in ("main", "auxiliary") and entry.get("alt") is None:
                if kind in sets:
                    raise ValueError(f"{language}: {kind} が複数あります")
                sets[kind] = parse_unicode_set(entry.text or "")
        if set(sets) != {"main", "auxiliary"}:
            raise ValueError(f"{language}: 主集合または補助集合がありません")
        ranges = {kind: compress_ranges(values) for kind, values in sets.items()}
        lines.extend([
            "        (",
            f'            language: "{language}",',
            "            main: " + swift_array(ranges["main"], "            ") + ",",
            "            auxiliary: " + swift_array(ranges["auxiliary"], "            "),
            "        ),",
        ])
        counts.append(f"{language}: {len(ranges['main']) // 2}/{len(ranges['auxiliary']) // 2}")
    lines.extend(["    ]", "}", ""])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    notice = ("対象ファイル: Sources/KaitoKit/Text/LanguageExemplars.swift\n"
              f"生成元: Unicode CLDR ({SOURCE})、取得日 2026-09-14\n"
              "主・補助文字集合を加工したデータ。適用ライセンス: Unicode License v3。\n"
              "以下は配布元 inbox/cldr/LICENSE の全文です。\n\n")
    args.notice.write_bytes(notice.encode("utf-8") + (args.cldr_dir / "LICENSE").read_bytes())
    print(f"{len(counts)} 言語を生成（主/補助の範囲数）: " + ", ".join(counts))


if __name__ == "__main__":
    main()
