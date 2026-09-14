#!/usr/bin/env python3
"""sample が使えない sandbox 向けの関数別計測。製品ソースは変更せず計測用コピーをコンパイルする。"""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
FUNCTIONS = {
    'NameEncodingScorer.swift': [
        ('allScores', 'static func allScores('), ('score', 'private static func score('),
        ('symbolScore', 'static func symbolScore('), ('scalarScore', 'static func scalarScore('),
        ('repeatedMask', 'private static func repeatedMask<'),
        ('excessiveLetters', 'static func excessiveLetters('),
        ('additionalOrthography', 'static func additionalOrthography('),
        ('westernEvidence', 'private static func westernEvidence('),
        ('vietnameseOrthography', 'static func vietnameseOrthography('),
        ('letterRules', 'static func letterRules('),
        ('LetterRuleState.append', 'struct LetterRuleState', 'mutating func append('),
        ('LetterRuleState.finish', 'struct LetterRuleState', 'mutating func finish('),
    ],
    'NameEncodingCandidates.swift': [('decode', 'func decode('), ('zones', 'func zones('), ('structurallyValid', 'func structurallyValid(')],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out-dir', type=Path, required=True)
    args = parser.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    labels = [f[0] for funcs in FUNCTIONS.values() for f in funcs]
    sources = []
    for filename in ['EncodingPolicy.swift', 'EncodingDetector.swift', 'NameEncodingCandidates.swift', 'NameEncodingScorer.swift', 'LanguageExemplars.swift']:
        original = ROOT / 'Sources/KaitoKit/Text' / filename
        if filename not in FUNCTIONS:
            sources.append(str(original)); continue
        text = original.read_text()
        for specification in FUNCTIONS[filename]:
            label, *needles = specification
            offset = 0
            for needle in needles:
                offset = text.index(needle, offset) + len(needle)
            body = text.index('{', offset) + 1
            code = f'\n        let profileToken = NameFunctionProfile.enter({labels.index(label)})\n        defer {{ NameFunctionProfile.leave(profileToken) }}\n'
            text = text[:body] + code + text[body:]
        if filename == 'NameEncodingScorer.swift':
            text = text.replace('        for index in NameEncodingCandidates.all.indices {', '''        for index in NameEncodingCandidates.all.indices {
            let candidateStart = NameFunctionProfile.enabled ? mach_absolute_time() : nil
            defer { NameFunctionProfile.recordCandidate(index, start: candidateStart) }''')
            text = text.replace('                let same = results[byCandidate[previous.candidateIndex]]', '''                if NameFunctionProfile.enabled { NameFunctionProfile.reused[index] += 1 }
                let same = results[byCandidate[previous.candidateIndex]]''')
            needle = 'nonBMP: &nonBMP, byteEvidence: byteEvidence, collectLanguages: archive) {'
            text = text.replace(needle, needle + '\n                if NameFunctionProfile.enabled { NameFunctionProfile.scored[index] += 1 }')
            text = 'import Darwin\n' + text
        destination = args.out_dir / filename
        destination.write_text(text)
        sources.append(str(destination))
    swift_labels = ', '.join('"' + label + '"' for label in labels)
    observer = args.out_dir / 'main.swift'
    observer.write_text('''import Foundation
import Darwin

// 包含時間から子関数の時間を引き、関数間で二重に計上しない。計測器自身の負荷は残る。
enum NameFunctionProfile {
    struct Frame { var id: Int; var start: UInt64; var children: UInt64 }
    nonisolated(unsafe) static var enabled = false
    nonisolated(unsafe) static var stack = [Frame]()
    nonisolated(unsafe) static var ticks = [UInt64](repeating: 0, count: LABEL_COUNT)
    nonisolated(unsafe) static var calls = [Int](repeating: 0, count: LABEL_COUNT)
    static let labels = [LABELS]
    nonisolated(unsafe) static var candidateTicks = [UInt64](repeating: 0, count: NameEncodingCandidates.all.count)
    nonisolated(unsafe) static var scored = [Int](repeating: 0, count: NameEncodingCandidates.all.count)
    nonisolated(unsafe) static var reused = [Int](repeating: 0, count: NameEncodingCandidates.all.count)
    static func recordCandidate(_ index: Int, start: UInt64?) {
        if let start { candidateTicks[index] += mach_absolute_time() - start }
    }
    static func enter(_ id: Int) -> Bool {
        guard enabled else { return false }
        stack.append(Frame(id: id, start: mach_absolute_time(), children: 0))
        return true
    }
    static func leave(_ token: Bool) {
        guard token else { return }
        let end = mach_absolute_time()
        let frame = stack.removeLast()
        let elapsed = end - frame.start
        ticks[frame.id] += elapsed - frame.children
        calls[frame.id] += 1
        if !stack.isEmpty { stack[stack.count - 1].children += elapsed }
    }
}
@main struct FunctionBenchmark {
    static func main() throws {
        let rows = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).split(separator: "\\n").dropFirst()
        let members = rows.enumerated().filter { $0.offset % 67 == 0 }.map { entry -> [UInt8] in
            let chars = Array(entry.element.split(separator: "\\t")[3])
            return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! }
        }
        for bytes in members.prefix(100) { _ = NameEncodingScorer.allScores(bytes, fromWindows: false, includeHKSCS: true, archive: true) }
        NameFunctionProfile.enabled = true
        var checksum = 0.0
        for bytes in members { checksum += NameEncodingScorer.allScores(bytes, fromWindows: false, includeHKSCS: true, archive: true).reduce(0) { $0 + $1.score } }
        NameFunctionProfile.enabled = false
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let microseconds = Double(info.numer) / Double(info.denom) / 1_000
        let total = Double(NameFunctionProfile.ticks.reduce(0, +))
        print("function\\tcalls\\tself_microseconds\\tself_percent")
        for i in NameFunctionProfile.labels.indices.sorted(by: { NameFunctionProfile.ticks[$0] > NameFunctionProfile.ticks[$1] }) {
            print("\\(NameFunctionProfile.labels[i])\\t\\(NameFunctionProfile.calls[i])\\t\\(Double(NameFunctionProfile.ticks[i]) * microseconds)\\t\\(100 * Double(NameFunctionProfile.ticks[i]) / total)")
        }
        print("members=\\(members.count), checksum=\\(checksum)")
        print("candidate\\tscored\\treused\\tloop_microseconds_per_member")
        for i in NameEncodingCandidates.all.indices {
            print("\\(NameEncodingCandidates.all[i].name)\\t\\(NameFunctionProfile.scored[i])\\t\\(NameFunctionProfile.reused[i])\\t\\(Double(NameFunctionProfile.candidateTicks[i]) * microseconds / Double(members.count))")
        }
    }
}
'''.replace('LABEL_COUNT', str(len(labels))).replace('LABELS', swift_labels))
    command = ['xcrun', 'swiftc', '-O', '-swift-version', '6', '-parse-as-library', '-package-name', 'KaitoKit', '-module-cache-path', str(ROOT / '.build/clang-cache'), *sources, str(observer), '-o', str(args.out_dir / 'profile')]
    subprocess.run(command, check=True)
    print(args.out_dir / 'profile')


if __name__ == '__main__':
    main()
