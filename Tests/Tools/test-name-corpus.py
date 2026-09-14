#!/usr/bin/env python3
"""測定用の表・互換写像・文字体系選別を、判定器を使わず検査する。"""

from importlib import import_module
from pathlib import Path
import re
import tempfile
import unittest
import unicodedata


corpus = import_module("make-name-corpus")
exemplars = import_module("make-exemplars")


class NameCorpusTests(unittest.TestCase):
    def test_viscii_matches_rfc_table_and_all_134_letters_round_trip(self):
        # 生成器の Unicode 表とは独立に、支給 RFC の VIQR 表記と byte 座標から復元する。
        source = corpus.ROOT / "inbox/specs/rfc1456-viscii.txt"
        self.assertTrue(source.is_file(), "支給 RFC 1456 が必要です")
        marks = {"(": "\u0306", "^": "\u0302", "+": "\u031b", "'": "\u0301",
                 "`": "\u0300", "?": "\u0309", "~": "\u0303", ".": "\u0323"}

        def viqr(token):
            if token in ("DD", "dd"):
                return "Đ" if token == "DD" else "đ"
            return unicodedata.normalize("NFC", token[0] + "".join(marks[c] for c in token[1:]))

        mapping = {}
        rows = 0
        for line in source.read_text().splitlines():
            match = re.match(r"\| x([0-9A-F]) \|", line)
            if not match:
                continue
            rows += 1
            row = int(match[1], 16)
            left, right = line[6:-1].rsplit("|", 1)
            low, high = left.split(), right.split()
            self.assertEqual((len(low), len(high)), (8, 8))
            for column, token in enumerate(high, 8):
                mapping[column * 16 + row] = viqr(token)
            for column, token in enumerate(low[:2]):
                if token[0] in "AY":
                    mapping[column * 16 + row] = viqr(token)
        self.assertEqual(rows, 16)
        self.assertEqual(len(mapping), 134)
        self.assertEqual(len(set(mapping.values())), 134)
        self.assertEqual({b for b in mapping if b < 128}, {2, 5, 6, 20, 25, 30})
        expected = "".join(mapping.get(b, chr(b)) for b in range(256))
        self.assertEqual(corpus.VISCII_DECODE, expected)
        self.assertEqual(bytes(range(256)).decode("viscii"), expected)
        self.assertEqual(expected.encode("viscii"), bytes(range(256)))
        for byte, char in mapping.items():
            self.assertEqual(char.encode("viscii"), bytes([byte]))
            self.assertEqual(bytes([byte]).decode("viscii"), char)
        # C0 の置換先を制御文字と取り違えて二重に符号化できてはいけない。
        for byte in (2, 5, 6, 20, 25, 30):
            with self.assertRaises(UnicodeEncodeError):
                chr(byte).encode("viscii")
        with self.assertRaises(UnicodeEncodeError):
            "日本語".encode("viscii")

    def test_farsi_compatibility_text_preserves_kaf_and_maps_both_digit_sets(self):
        original = "ک ی ۰۱۲۳۴۵۶۷۸۹ ٠١٢٣٤٥٦٧٨٩"
        expected = "ک ي 0123456789 0123456789"
        actual = corpus.legacy_text(original, "fa", "cp1256")
        self.assertEqual(actual, expected)
        self.assertEqual(actual.encode("cp1256").decode("cp1256"), expected)
        self.assertEqual(corpus.legacy_text(actual, "fa", "cp1256"), actual)
        self.assertEqual(corpus.legacy_text(original, "ar", "cp1256"), original)

    def test_romanian_compatibility_mapping_is_encoding_specific(self):
        original = "ȘșȚț Ăă Ââ Îî"
        expected = "ŞşŢţ Ăă Ââ Îî"
        for codec in ("cp1250", "iso8859_2", "cp852"):
            self.assertEqual(corpus.legacy_text(original, "ro", codec), expected)
            self.assertEqual(expected.encode(codec).decode(codec), expected)
        for codec in ("mac_romanian", "iso8859_16"):
            self.assertEqual(corpus.legacy_text(original, "ro", codec), original)
            self.assertEqual(original.encode(codec).decode(codec), original)
        self.assertEqual(corpus.legacy_text(original, "hr", "cp1250"), original)

    def test_serbian_scripts_are_partitioned_without_transliteration(self):
        for text, expected in [("Жута књига 01.jpg", "mixed"), ("Жута књига 01", "sr"),
                               ("Žuta knjiga 01", "sr-Latn"), ("Knjiga 01", "sr-Latn"),
                               ("Књига Book", "mixed"), ("Књига č", "mixed"), ("Књига Ω", "mixed"),
                               ("Knjiga א", "mixed"), ("123 +", "neither")]:
            self.assertEqual(corpus.serbian_script(text), expected)
        self.assertEqual(corpus.raw_path(Path("raw"), "sr-Latn"), Path("raw/sr.txt"))

    def test_target_scripts_and_volume_labels(self):
        for lang, positive, negative in [("he", "א", "ְ"), ("ar", "ب", "َ"), ("fa", "پ", "۱"),
                                         ("sr", "љ", "č"), ("sr-Latn", "č", "љ"), ("be", "ў", "õ")]:
            self.assertTrue(corpus.target_character(positive, lang))
            self.assertFalse(corpus.target_character(negative, lang))
        labels = {"he": "כרך 03", "ar": "المجلد 03", "fa": "جلد 03", "lt": "t. 03", "lv": "sēj. 03",
                  "et": "kd 03", "ro": "Vol. 03", "hr": "zv. 03", "sl": "zv. 03", "sk": "zv. 03",
                  "sr-Latn": "tom 03", "bg": "том 03", "sr": "том 03", "mk": "том 03", "be": "том 03",
                  "da": "bind 03", "nb": "bind 03", "sv": "bind 03", "fi": "osa 03", "nl": "deel 03", "is": "bindi 03"}
        for lang, expected in labels.items():
            self.assertEqual(corpus.volume_label(lang, 3), expected)

    def test_bokmal_inherits_missing_sets_but_local_sets_override_parent(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            (directory / "no.xml").write_text('<ldml><characters><exemplarCharacters>[a æ ø å]</exemplarCharacters>'
                                             '<exemplarCharacters type="auxiliary">[é]</exemplarCharacters></characters></ldml>')
            (directory / "nb.xml").write_text('<ldml><characters><exemplarCharacters type="auxiliary">[ü]</exemplarCharacters></characters></ldml>')
            sets = exemplars.exemplar_sets(directory, "nb")
            self.assertEqual(set(sets["main"]), set(map(ord, "aæøåAÆØÅ")))
            self.assertEqual(set(sets["auxiliary"]), set(map(ord, "üÜ")))
            (directory / "nb.xml").write_text('<ldml><characters><exemplarCharacters type="auxiliary">↑↑↑</exemplarCharacters></characters></ldml>')
            self.assertEqual(set(exemplars.exemplar_sets(directory, "nb")["auxiliary"]), set(map(ord, "éÉ")))


if __name__ == "__main__":
    unittest.main()
