import Foundation

// 公開 ar byte 表に基づくクリーンルームの project-owned テスト入力。
// 第三者 archiver / decoder の実装 source は参照しない。
struct ArArchiveBuilder {
    var bytes = Array("!<arch>\n".utf8)
    var data: Data { Data(bytes) }

    @discardableResult
    mutating func member(_ name: String = "a", payload: [UInt8] = [], size: String? = nil,
                         date: String = "0", uid: String = "12", gid: String = "34",
                         mode: String = "100644") -> Int {
        let offset = bytes.count
        let fields = [(name, 16), (date, 12), (uid, 6), (gid, 6), (mode, 8), (size ?? String(payload.count), 10)]
        for (text, width) in fields {
            let field = Array(text.utf8)
            precondition(field.count <= width)
            bytes += field + Array(repeating: 32, count: width - field.count)
        }
        bytes += [0x60, 10] + payload
        if payload.count % 2 == 1 { bytes.append(10) }
        return offset
    }

    @discardableResult
    mutating func extended(_ name: String, payload: [UInt8] = [], padding: Int = 0) -> Int {
        let bytes = Array(name.utf8) + Array(repeating: UInt8(0), count: padding)
        return member("#1/\(bytes.count)", payload: bytes + payload)
    }
}
