#!/usr/bin/env python3
"""Check that R3 mutation oracles differ from frozen HEAD only by documented adapters."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[3]
rev = '078ca2bf093aa0a1878d4ee236f49580dc585516'
def source(path):
    return subprocess.check_output(['git', 'show', f'{rev}:{path}'], cwd=root, text=True)

original = source('Sources/KaitoKit/Codecs/RAR/RAR29Decoder.swift')
expected = original.replace('import Foundation', 'import Foundation\n@testable import KaitoKit', 1)
expected = expected.replace('RAR29', 'R3BaselineRAR29').replace('RARPPMdRangeDecoder', 'R3BaselineRARPPMdRangeDecoder')
a = expected.index('    struct StoredFilterProgram {')
b = expected.index('\n    private struct ScheduledFilter', a)
expected = expected[:a] + '    typealias StoredFilterProgram = RAR29Decoder.StoredFilterProgram\n' + expected[b:]
actual = (root / 'Tests/KaitoKitTests/RAR/R3Baseline/R3BaselineRAR29Decoder.swift').read_text()
assert '\n'.join(actual.split('\n')[2:]) == expected
expected = source('Sources/KaitoKit/Codecs/PPMd/VariantH/RARPPMdRangeDecoder.swift')
expected = expected.replace('import Foundation', 'import Foundation\n@testable import KaitoKit', 1).replace('RARPPMdRangeDecoder', 'R3BaselineRARPPMdRangeDecoder')
actual = (root / 'Tests/KaitoKitTests/RAR/R3Baseline/R3BaselineRARPPMdRangeDecoder.swift').read_text()
assert '\n'.join(actual.split('\n')[1:]) == expected
print(f'Both frozen oracles match {rev}; only documented adapters differ')
