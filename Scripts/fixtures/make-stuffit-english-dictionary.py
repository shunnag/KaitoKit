#!/usr/bin/env python3
# 指定語リストを黒箱の zlib で圧縮し、単一の base64 リテラルとして組み込む。
import argparse
import base64
import hashlib
from pathlib import Path
import textwrap
import zlib

SHA256 = '6095ebdbadd794ac50fe5b53b12a744b5833e046658777ee37dcb6da82512a31'
ROOT = Path(__file__).resolve().parents[2]


def generate(source):
    raw = source.read_bytes()
    if len(raw) != 881863 or raw.count(b'\n') != 100366 or hashlib.sha256(raw).hexdigest() != SHA256:
        raise ValueError('辞書の長さ・語数・SHA-256 が指定値と異なる')
    writer = zlib.compressobj(level=9, wbits=-15)
    compressed = writer.compress(raw) + writer.flush()
    encoded = '\n'.join('        ' + line for line in textwrap.wrap(base64.b64encode(compressed).decode('ascii'), 120))
    return '''// XADMaster 内蔵の StuffItXEnglishDictionary.c を展開した語リスト（research/THIRD_PARTY_DATA.md）。
// 利用者が 2026-09-13 に組み込みを決定。生成は Scripts/fixtures/make-stuffit-english-dictionary.py。
import CryptoKit
import Foundation

enum StuffItXEnglishDictionary {
    static let sha256 = "''' + SHA256 + '''"
    static let words: Result<[Substring], Error> = Result { try expand() }

    private static func expand() throws -> [Substring] {
        guard let packed = Data(base64Encoded: compressed, options: .ignoreUnknownCharacters) else {
            throw KaitoError.malformed("StuffIt X English dictionary base64")
        }
        let decoder = try DeflateDecompressor(source: DataByteSource(packed), offset: 0, compressedSize: UInt64(packed.count))
        var data = Data()
        data.reserveCapacity(881_863)
        try withUnsafeTemporaryAllocation(byteCount: 65_536, alignment: 16) { scratch in
            while true {
                let n = try decoder.read(into: scratch)
                if n == 0 { break }
                guard n <= 881_863 - data.count else { throw KaitoError.malformed("StuffIt X English dictionary length") }
                data.append(scratch.bindMemory(to: UInt8.self).baseAddress!, count: n)
            }
        }
        guard decoder.isFinished, data.count == 881_863,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw KaitoError.malformed("StuffIt X English dictionary SHA-256")
        }
        let words = String(decoding: data, as: UTF8.self).split(separator: "\\n")
        guard words.count == 100_366 else { throw KaitoError.malformed("StuffIt X English dictionary word count") }
        return words
    }
    private static let compressed = """
''' + encoded + '''
        """
}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, default=ROOT / 'inbox/stuffit/report/tables/english-dictionary.txt')
    parser.add_argument('--output', type=Path, default=ROOT / 'Sources/KaitoKit/Codecs/StuffItX/StuffItXEnglishDictionary.swift')
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    generated = generate(args.input)
    if args.check:
        if args.output.read_text() != generated:
            raise ValueError('生成済み Swift ファイルとの差分がある')
        print('辞書再生成一致: SHA-256 ' + SHA256)
    else:
        args.output.write_text(generated)
        print(str(args.output.relative_to(ROOT)))


if __name__ == '__main__':
    main()
