#!/usr/bin/env python3
"""C-B の測定差分だけを検査する。符号化の推測や製品の規則は複製しない。"""
from importlib import import_module
import unittest

measure = import_module('measure-name-detection')


class MeasurementTests(unittest.TestCase):
    def test_invalid_cf_table_is_separate_from_codec_mismatch_for_every_detector(self):
        detectors = list(measure.LABELS)
        results = {d: ('cp861', ['same'], 0) for d in detectors}
        group = measure.new_group(detectors)
        measure.accumulate(group, True, ['same'], 'cp861', results)
        measure.accumulate(group, False, ['same'], 'cp861', results)
        self.assertEqual(group['rows'], 2)
        self.assertEqual(group['cf_table_invalid'], 2)
        self.assertEqual(group['codec_mismatch'], 0)
        self.assertEqual(group['eligible'], 0)
        self.assertTrue(all(m['correct'] == 0 for m in group['detectors'].values()))

    def test_other_mismatches_and_exact_equality_are_unchanged(self):
        group = measure.new_group(['kaito_ja'])
        results = {'kaito_ja': ('windows-1252', ['é'], 0)}
        measure.accumulate(group, True, ['é'], 'windows-1252', results)
        measure.accumulate(group, False, ['e\u0301'], 'windows-1252', results)
        measure.accumulate(group, False, ['é'], 'windows-1252', results)
        report = measure.finish(group)
        self.assertEqual(report['cf_table_invalid'], 0)
        self.assertEqual(report['codec_mismatch'], 1)
        self.assertEqual(report['eligible'], 2)
        self.assertEqual(report['detectors']['kaito_ja']['accuracy'], 0.5)

    def test_sampling_counts_include_repetition_and_respect_both_limits(self):
        self.assertEqual(measure.archive_sample_counts([b"a", b"a", b"b"]), (3, 2))
        self.assertEqual(measure.archive_sample_counts([b"a"] * 1000), (512, 1))
        self.assertEqual(measure.archive_sample_counts([b"a" * 1024] * 1000), (255, 1))
        self.assertEqual(measure.archive_sample_counts([b"a" * (256 * 1024 + 1)]), (0, 0))
        self.assertFalse(measure.strict_utf8(b"\xff"))
        self.assertTrue(measure.strict_utf8("日本語".encode()))

    def test_only_mac_arabic_and_farsi_cf_direction_controls_are_removed(self):
        text = '\u202a\u202b\u202c\u202d\u202e 01-ب\u2066\u2067\u2068\u2069\u200c\u200e\u200f'
        for encoding in ['x-mac-arabic', 'x-mac-farsi', 'X-MAC-FARSI']:
            self.assertEqual(measure.cf_comparison_text(text, encoding), ' 01-ب\u200c\u200e\u200f')
            self.assertIsNone(measure.cf_comparison_text(None, encoding))
        self.assertEqual(measure.cf_comparison_text(text, 'windows-1256'), text)
        self.assertEqual(measure.cf_comparison_text('e\u0301', 'x-mac-farsi'), 'e\u0301')


if __name__ == '__main__':
    unittest.main()
