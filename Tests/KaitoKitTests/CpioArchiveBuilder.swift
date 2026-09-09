import Foundation

// 公開 cpio byte 表から field ごとに作る project-owned テストデータ。
struct CpioArchiveBuilder {
    enum Variant: CaseIterable { case newc, crc, odc, binLittle, binBig }
    var bytes: [UInt8] = []
    var data: Data { Data(bytes) }

    @discardableResult
    mutating func record(_ name: String = "a", payload: [UInt8] = [], variant: Variant = .newc,
                         mode: UInt32 = 0o100644, ino: UInt32 = 1, nlink: UInt32 = 1,
                         mtime: UInt64 = 0x6AA0B06F, declaredSize: UInt64? = nil,
                         nameBytes: [UInt8]? = nil, check: UInt32? = nil) -> Int {
        let start = bytes.count
        let name: [UInt8] = nameBytes ?? (Array(name.utf8) + [0])
        let size = declaredSize ?? UInt64(payload.count)
        func ascii(_ value: UInt64, _ width: Int, _ radix: Int) -> [UInt8] {
            let s = String(value, radix: radix)
            return Array((String(repeating: "0", count: max(0, width - s.count)) + s).utf8)
        }
        func word(_ value: UInt64) -> [UInt8] {
            let lo = UInt8(truncatingIfNeeded: value), hi = UInt8(truncatingIfNeeded: value >> 8)
            return variant == .binLittle ? [lo, hi] : [hi, lo]
        }
        func pdp(_ value: UInt64) -> [UInt8] { word(value >> 16) + word(value) }
        let alignment: Int
        switch variant {
        case .newc, .crc:
            bytes += Array((variant == .newc ? "070701" : "070702").utf8)
            let sum = check ?? (variant == .crc ? payload.reduce(UInt32(0)) { $0 &+ UInt32($1) } : 0)
            let fields: [UInt64] = [UInt64(ino), UInt64(mode), 12, 34, UInt64(nlink), mtime, size,
                                   1, 2, 0, 0, UInt64(name.count), UInt64(sum)]
            for field in fields { bytes += ascii(field, 8, 16) }
            alignment = 4
        case .odc:
            bytes += Array("070707".utf8)
            for field in [UInt64(1), UInt64(ino), UInt64(mode), 12, 34, UInt64(nlink), 0] { bytes += ascii(field, 6, 8) }
            bytes += ascii(mtime, 11, 8) + ascii(UInt64(name.count), 6, 8) + ascii(size, 11, 8)
            alignment = 1
        case .binLittle, .binBig:
            for field in [UInt64(0x71C7), 1, UInt64(ino), UInt64(mode), 12, 34, UInt64(nlink), 0] { bytes += word(field) }
            bytes += pdp(mtime) + word(UInt64(name.count)) + pdp(size)
            alignment = 2
        }
        bytes += name
        while (bytes.count - start) % alignment != 0 { bytes.append(0) }
        bytes += payload
        for _ in 0..<((alignment - payload.count % alignment) % alignment) { bytes.append(0) }
        return start
    }
    mutating func trailer(_ variant: Variant = .newc) { record("TRAILER!!!", variant: variant, mode: 0) }
}
