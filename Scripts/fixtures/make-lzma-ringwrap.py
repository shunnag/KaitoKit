#!/usr/bin/env python3
"""LZMA の辞書リング周回を検証する書庫を作る（cooViewer-9epb / 9tlo）。

辞書 D = 4096 バイトに対し、周期 P = D - g の乱数ブロックを N 回繰り返す。
展開量が辞書より十分大きいためリングが周回し、距離 P の match では
dictionaryPosition < byteDistance の wrapped-source 経路に入る。
このとき source は destination の g バイト後ろにあり、論理的な過去参照でも
実メモリ上では重なり得る。長い match が 16 バイト境界をまたぎ、末尾が
16 の倍数にならないと、9tlo で試した inline copy の破損条件が現れる。
変異版は周期ごとに数バイトを変え、match の開始位置と長さをばらつかせる。
g = 0, 15, 16, 32 も境界の比較用に含める。

使用例:
  python3 Scripts/fixtures/make-lzma-ringwrap.py /private/tmp/lzma-ringwrap-new --include-lzma1

Python 標準ライブラリと外部コマンド 7zz を使う。出力先は新規ディレクトリ。
元の 15 本の乱数データは復元できないため、同じ性質の書庫を生成する手順であり、
元の SHA-256 を再現するものではない。差し替える場合は出力した期待 SHA-256 も
テスト内で更新し、decoder を一時的に壊して検出力を再確認すること。
追加の LZMA1 版は既定 seed、g = 1, 8、N = 24 で生成したものを採用する。
元データは一時領域にだけ置き、書庫と .b64、期待 SHA-256 の一覧を出力する。
"""

import argparse
import base64
import hashlib
import lzma
from pathlib import Path
import random
import shutil
import subprocess
import tempfile


DICTIONARY_SIZE = 4096
PERIODIC_GAPS = (0, 1, 8, 15, 16, 32)
VARIED_GAPS = (2, 3, 5, 7, 9, 11, 13, 14, 15)
DEFAULT_SEED = 0x9E9B


def periodic_data(gap, repetitions, mutations, seed):
    # fixture ごとに seed を分離し、他の fixture の追加でデータが変わらないようにする。
    rng = random.Random(seed + gap + (DICTIONARY_SIZE if mutations else 0))
    period = DICTIONARY_SIZE - gap
    block = bytes(rng.getrandbits(8) for _ in range(period))
    result = bytearray()
    for index in range(repetitions):
        current = bytearray(block)
        if index > 0:
            for position in rng.sample(range(period), mutations):
                current[position] ^= rng.randrange(1, 256)
        result.extend(current)
    return bytes(result)


def create_fixture(seven_zip, output, source, name, data, options):
    archive = output / name
    if options is None:
        # .lzma は 13 バイトの Alone ヘッダ付き。辞書サイズを既定値に任せない。
        archive.write_bytes(lzma.compress(
            data,
            format=lzma.FORMAT_ALONE,
            filters=[{"id": lzma.FILTER_LZMA1, "preset": 5, "dict_size": DICTIONARY_SIZE}],
        ))
    else:
        (source / "data.bin").write_bytes(data)
        subprocess.run(
            [seven_zip, "a", *options, "-mx=5", "-md=4k", str(archive), "data.bin"],
            cwd=source,
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

    # 圧縮側の独立した展開結果も照合し、期待値は必ず圧縮前のデータから求める。
    decoded = subprocess.run(
        [seven_zip, "x", "-so", str(archive)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout
    if decoded != data:
        raise ValueError(f"展開結果が元データと一致しません: {name}")
    (output / f"{name}.b64").write_bytes(base64.encodebytes(archive.read_bytes()))
    return name, hashlib.sha256(data).hexdigest(), len(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output_directory", type=Path)
    parser.add_argument("--seven-zip", default="7zz", help="7zz の実行パス")
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=DEFAULT_SEED)
    parser.add_argument("--repetitions", type=int, default=24, help="通常版の周期数")
    parser.add_argument("--varied-repetitions", type=int, default=40, help="変異版の周期数")
    parser.add_argument("--mutations", type=int, default=3, help="変異版の周期ごとの変更バイト数（0 で無効）")
    parser.add_argument("--include-lzma1", action="store_true",
                        help="g = 1, 8 の 7z LZMA1・ZIP method 14・.lzma も生成する")
    args = parser.parse_args()
    if min(args.repetitions, args.varied_repetitions) < 2:
        parser.error("辞書を周回するため、周期数は 2 以上を指定してください")
    if not 0 <= args.mutations <= DICTIONARY_SIZE - max(VARIED_GAPS):
        parser.error("変異数は 0 以上かつ周期以下を指定してください")
    seven_zip = shutil.which(args.seven_zip)
    if seven_zip is None:
        parser.error("7zz が見つかりません。--seven-zip で実行パスを指定してください")

    output = args.output_directory.resolve()
    output.mkdir(parents=True, exist_ok=False)
    records = []
    with tempfile.TemporaryDirectory(prefix="lzma-ringwrap-") as temporary:
        source = Path(temporary)
        for prefix, gaps, repetitions, mutations in (
            ("test", PERIODIC_GAPS, args.repetitions, 0),
            ("vtest", VARIED_GAPS, args.varied_repetitions, args.mutations),
        ):
            for gap in gaps:
                data = periodic_data(gap, repetitions, mutations, args.seed)
                records.append(create_fixture(
                    seven_zip, output, source, f"{prefix}-g{gap}.7z", data,
                    ["-t7z", "-m0=lzma2"],
                ))
                if args.include_lzma1 and prefix == "test" and gap in (1, 8):
                    for name, options in (
                        (f"lzma1-g{gap}.7z", ["-t7z", "-m0=lzma"]),
                        (f"lzma-g{gap}.zip", ["-tzip", "-mm=lzma"]),
                        (f"alone-g{gap}.lzma", None),
                    ):
                        records.append(create_fixture(
                            seven_zip, output, source, name, data, options,
                        ))

    print("書庫名\t期待 SHA-256（展開後）\t展開バイト数")
    for name, digest, size in records:
        print(f"{name}\t{digest}\t{size}")


if __name__ == "__main__":
    main()
