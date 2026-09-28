import Foundation

// POSIX pax の extended header と GNU tar の GNU.sparse.* 記録（tar(5)）の公開仕様だけを参照した
// クリーンルーム実装。

/// pax extended header（x / X / g）の key=value 記録。値は byte 列のまま持つ（hdrcharset=BINARY の
/// 名前は UTF-8 とは限らない）。空の値は、その key を消す指示として `merge` が扱う。
struct TarPAXRecords {
    private static let retainedKeys: Set<String> = [
        "path", "linkpath", "size", "mtime", "uid", "gid", "hdrcharset",
        // GNU sparse 0.0 / 0.1 / 1.0（tar(5) "GNU tar pax archives"）。0.0 の offset/numbytes 対は
        // parse が順序を保って GNU.sparse.map.0.0 にまとめる。
        "GNU.sparse.numblocks", "GNU.sparse.size", "GNU.sparse.map", "GNU.sparse.map.0.0",
        "GNU.sparse.major", "GNU.sparse.minor", "GNU.sparse.name", "GNU.sparse.realsize",
    ]

    private var values: [String: [UInt8]] = [:]

    subscript(key: String) -> [UInt8]? { values[key] }

    /// extended header の payload を `"<長さ> <key>=<値>\n"` の記録に分ける。
    static func parse(
        _ payload: [UInt8],
        recordLimit: Int
    ) throws -> TarPAXRecords {
        guard let countLimit = UInt64(exactly: recordLimit) else {
            throw KaitoError.limitExceeded("pax metadata record count")
        }
        var result = TarPAXRecords()
        let payloadLength = UInt64(payload.count)
        var cursor: UInt64 = 0
        var recordCount: UInt64 = 0
        while cursor < payloadLength {
            guard recordCount < countLimit else {
                throw KaitoError.limitExceeded("pax metadata record count")
            }
            recordCount = try Checked.add(recordCount, 1)
            var length: UInt64 = 0
            var digitCount = 0
            var space: Int?
            var position = try Checked.toInt(cursor)
            while position < payload.count {
                let byte = payload[position]
                if byte == 0x20 {
                    space = position
                    break
                }
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    throw KaitoError.malformed("invalid pax record length")
                }
                guard digitCount < 20 else {
                    throw KaitoError.malformed("oversized pax record length")
                }
                digitCount += 1
                length = try Checked.mul(length, 10)
                length = try Checked.add(length, UInt64(byte - UInt8(ascii: "0")))
                position += 1
            }
            guard let space, digitCount > 0 else {
                throw KaitoError.malformed("unterminated pax record length")
            }
            let recordRemaining = try Checked.sub(payloadLength, cursor)
            guard length > 0, length <= recordRemaining else {
                throw KaitoError.truncated
            }
            let endOffset = try Checked.add(cursor, length)
            let bodyStartOffset = try Checked.add(UInt64(space), 1)
            let bodyEndOffset = try Checked.sub(endOffset, 1)
            guard bodyEndOffset >= bodyStartOffset else {
                throw KaitoError.malformed("invalid pax record length")
            }
            let bodyStart = try Checked.toInt(bodyStartOffset)
            let bodyEnd = try Checked.toInt(bodyEndOffset)
            guard payload[bodyEnd] == 0x0a else {
                throw KaitoError.malformed("invalid pax record terminator")
            }
            let body = payload[bodyStart..<bodyEnd]
            guard let equals = body.firstIndex(of: UInt8(ascii: "=")), equals != body.startIndex else {
                throw KaitoError.malformed("invalid pax key/value record")
            }
            let keyBytes = body[..<equals]
            guard keyBytes.count <= 1_024,
                  !keyBytes.contains(0),
                  !keyBytes.contains(0x0a),
                  let key = String(bytes: keyBytes, encoding: .utf8) else {
                throw KaitoError.malformed("invalid UTF-8 pax key")
            }
            let value = Array(body[body.index(after: equals)...])
            if key == "GNU.sparse.offset" || key == "GNU.sparse.numbytes" {
                // 0.0 形式は同じ key を繰り返す。辞書では順序が失われるため、出現順のまま
                // comma 区切りで一つの値にまとめる（0.1 の GNU.sparse.map と同じ表現）。
                var joined = result.values["GNU.sparse.map.0.0"] ?? []
                if !joined.isEmpty { joined.append(UInt8(ascii: ",")) }
                joined += value
                result.values["GNU.sparse.map.0.0"] = joined
            } else {
                result.values[key] = value
            }
            cursor = endOffset
        }
        return result
    }

    /// reader が使う key だけを残した写し。
    func retained() -> TarPAXRecords {
        var result = TarPAXRecords()
        result.values = values.filter { Self.retainedKeys.contains($0.key) }
        return result
    }

    /// `changes` を重ねる。空の値は key の削除。重ねた後の記録数と byte 数が上限を超えるなら、
    /// 何も変えずに投げる。
    mutating func merge(_ changes: TarPAXRecords, limits: ReadLimits) throws {
        try validateMerge(changes, limits: limits)
        for (key, value) in changes.values {
            if value.isEmpty {
                values.removeValue(forKey: key)
            } else {
                values[key] = value
            }
        }
    }

    private func validateMerge(_ changes: TarPAXRecords, limits: ReadLimits) throws {
        var size: UInt64 = 0
        for (key, value) in values {
            size = try Checked.add(size, UInt64(key.utf8.count))
            size = try Checked.add(size, UInt64(value.count))
        }
        var count = UInt64(values.count)
        guard let countLimit = UInt64(exactly: limits.maxMetadataRecordCount) else {
            throw KaitoError.limitExceeded("pax metadata record count")
        }
        for (key, value) in changes.values {
            if value.isEmpty {
                if let previous = values[key] {
                    size = try Checked.sub(size, UInt64(key.utf8.count))
                    size = try Checked.sub(size, UInt64(previous.count))
                    count = try Checked.sub(count, 1)
                }
            } else if let previous = values[key] {
                size = try Checked.sub(size, UInt64(previous.count))
                size = try Checked.add(size, UInt64(value.count))
            } else {
                guard count < countLimit else {
                    throw KaitoError.limitExceeded("pax metadata record count")
                }
                count = try Checked.add(count, 1)
                size = try Checked.add(size, UInt64(key.utf8.count))
                size = try Checked.add(size, UInt64(value.count))
            }
        }
        try Checked.size(size, limit: limits.maxMetadataSize)
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
    }

    /// hdrcharset=BINARY なら path / linkpath を UTF-8 と宣言しない。
    var isBinaryHeaderCharset: Bool {
        guard let bytes = values["hdrcharset"],
              let string = String(bytes: bytes, encoding: .ascii) else { return false }
        return string.uppercased() == "BINARY"
    }

    var hasGNUSparse: Bool {
        values.contains { key, value in !value.isEmpty && key.hasPrefix("GNU.sparse") }
    }

    /// GNU 以外の sparse 表現（star の SCHILY、Solaris の SUN.holesdata）は読まない。
    func rejectForeignSparse() throws {
        if values.contains(where: { key, value in
            !value.isEmpty && (key == "SCHILY.realsize" || key == "SUN.holesdata")
        }) ||
            values["SCHILY.filetype"] == Array("sparse".utf8) {
            throw KaitoError.unsupportedMethod("tar sparse entries")
        }
    }

    /// global header の sparse 記録は entry に属さないので拒否する。
    func rejectGlobalSparse() throws {
        if values.contains(where: { key, value in !value.isEmpty && key.hasPrefix("GNU.sparse") }) {
            throw KaitoError.malformed("GNU sparse attributes in a global pax header")
        }
        try rejectForeignSparse()
    }

    /// size・uid・gid の十進値。
    static func unsigned(
        _ bytes: [UInt8],
        fieldName: String
    ) throws -> UInt64 {
        guard !bytes.isEmpty, bytes.count <= 20 else {
            throw KaitoError.malformed("invalid pax \(fieldName)")
        }
        var value: UInt64 = 0
        for byte in bytes {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw KaitoError.malformed("invalid pax \(fieldName)")
            }
            value = try Checked.mul(value, 10)
            value = try Checked.add(value, UInt64(byte - UInt8(ascii: "0")))
        }
        return value
    }

    /// mtime の十進値。符号と小数部を持てる。
    static func time(_ bytes: [UInt8]) throws -> TimeInterval {
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw KaitoError.malformed("invalid pax mtime")
        }
        var cursor = 0
        var negative = false
        if bytes[cursor] == UInt8(ascii: "-") || bytes[cursor] == UInt8(ascii: "+") {
            negative = bytes[cursor] == UInt8(ascii: "-")
            cursor += 1
        }
        guard cursor < bytes.count else { throw KaitoError.malformed("invalid pax mtime") }

        var integral: UInt64 = 0
        var integralDigits = 0
        while cursor < bytes.count, bytes[cursor] != UInt8(ascii: ".") {
            let byte = bytes[cursor]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw KaitoError.malformed("invalid pax mtime")
            }
            integral = try Checked.mul(integral, 10)
            integral = try Checked.add(integral, UInt64(byte - UInt8(ascii: "0")))
            integralDigits += 1
            cursor += 1
        }
        guard integralDigits > 0 else { throw KaitoError.malformed("invalid pax mtime") }

        var fraction = 0.0
        if cursor < bytes.count {
            cursor += 1
            guard cursor < bytes.count else { throw KaitoError.malformed("invalid pax mtime") }
            var scale = 0.1
            while cursor < bytes.count {
                let byte = bytes[cursor]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                    throw KaitoError.malformed("invalid pax mtime")
                }
                fraction += Double(byte - UInt8(ascii: "0")) * scale
                scale *= 0.1
                cursor += 1
            }
        }
        let value = Double(integral) + fraction
        guard value.isFinite else { throw KaitoError.malformed("pax mtime is out of range") }
        return negative ? -value : value
    }
}
