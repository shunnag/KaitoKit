import Foundation

// macOS 26 の Foundation で、Data の slice への追加が trap する条件を調べる（一時的な診断用）。
let which = Int(CommandLine.arguments[1])!
let d = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0) })
var sink = 0
func use(_ x: Data) { sink &+= x.count }
switch which {
case 1: use(d[16384..<16384] + Data())
case 2: use(d[16384..<16384] + Data([1]))
case 3: use(d[100..<200] + Data())
case 4: use(d[100..<200] + Data([1]))
case 5: use(d[0..<0] + Data())
case 6: use(d[0..<0] + Data([1]))
case 7: var s = d[16384..<16384]; s.append(Data()); use(s)
case 8: var s = d[16384..<16384]; s.append(contentsOf: [UInt8]()); use(s)
case 9: var s = d[16384..<16384]; s.append(contentsOf: [1, 2, 3] as [UInt8]); use(s)
case 10: var s = Data(d[16384..<16384]); s.append(Data([1])); use(s)
case 11: use(d[16384..<16384] + d[100..<200])
case 12: var s = d[16384..<16384]; s.reserveCapacity(10); s.append(Data([1])); use(s)
case 13: var s = d[16384..<16384]; s.replaceSubrange(s.startIndex..<s.endIndex, with: Data([1])); use(s)
case 14: var e = Data(); e.append(d[16384..<16384]); use(e)
case 15: var e = Data([1, 2]); e.append(d[16384..<16384]); use(e)
case 16: use(d[16384..<16385] + Data())
case 17: var s = d[16384..<16384]; s += Data([1]); use(s)
case 18: use(d.subdata(in: 16384..<16384) + Data([1]))
case 19: use(d.prefix(0) + Data([1]))
case 20: use(d.dropFirst(65536) + Data([1]))
case 21: var s = d[16384..<16384]; s.append(0x41); use(s)
case 22: var s = Data(count: 65536)[16384..<16384]; s.append(Data([1])); use(s)
case 23: var s = Data(count: 65536)[16384..<16384]; s.append(Data()); use(s)
case 24: var s = d[16384..<16400]; s.removeAll(keepingCapacity: true); s.append(Data([1])); use(s)
case 25: var s = d[16384..<16400]; s.removeSubrange(s.startIndex..<s.endIndex); s.append(Data([1])); use(s)
case 26: var s = d[16384..<16400]; s.removeFirst(16); s.append(Data([1])); use(s)
case 27: var s = d; s.removeAll(); s.append(Data([1])); use(s)
case 28: var s = d[100..<200]; s.append(contentsOf: d[300..<300]); use(s)
case 29: use(Data(d[16384..<16384]) + Data([1]))
case 30: use(Data(Array(d[16384..<16384])) + Data([1]))
default: print("none"); exit(0)
}
withExtendedLifetime(d) { print("case \(which) ok \(sink)") }
