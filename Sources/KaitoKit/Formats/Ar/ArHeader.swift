import Foundation

// ar(5)、System V ABI、SDK ar.h / mach-o/ranlib.h、Solaris ar.h(3HEAD)、
// GNU binutils の manual、deb(5) に基づく利用者提供 byte 表・prose だけを
// 形式入力としたクリーンルーム実装。XADMaster / The Unarchiver / libarchive /
// GNU binutils / LLVM / ELF Tool Chain の実装 source は参照しない。
struct ArHeader {
    enum NameForm {
        case plain([UInt8]), extended(UInt64), reference(UInt64), stringTable, symbolTable
    }
    let nameField: [UInt8]
    let size: UInt64
    let date, uid, gid, mode: UInt64?

    init(_ bytes: [UInt8]) throws {
        guard bytes.count == 60 else { throw KaitoError.truncated }
        guard bytes[58] == 0x60, bytes[59] == 0x0A else { throw KaitoError.malformed("ar header magic") }
        nameField = Array(bytes[0..<16].reversed().drop(while: { $0 == 32 }).reversed())
        guard let size = try Self.number(bytes[48..<58], field: "size") else {
            throw KaitoError.malformed("ar header size")
        }
        self.size = size
        date = try Self.number(bytes[16..<28])
        uid = try Self.number(bytes[28..<34])
        gid = try Self.number(bytes[34..<40])
        mode = try Self.number(bytes[40..<48], radix: 8)
    }

    private static func number(_ bytes: ArraySlice<UInt8>, radix: UInt64 = 10,
                               field: String = "field") throws -> UInt64? {
        let digits = bytes.drop(while: { $0 == 32 }).reversed().drop(while: { $0 == 32 }).reversed()
        guard !digits.isEmpty else { return nil }
        var value: UInt64 = 0
        for byte in digits {
            guard byte >= 48, UInt64(byte - 48) < radix else { throw KaitoError.malformed("ar header \(field)") }
            value = try Checked.add(Checked.mul(value, radix), UInt64(byte - 48))
        }
        return value
    }

    func nameForm() throws -> NameForm {
        if nameField.starts(with: Array("#1/".utf8)) {
            let digits = nameField.dropFirst(3)
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
                  let length = try Self.number(digits) else {
                throw KaitoError.malformed("ar extended name length")
            }
            return .extended(length)
        }
        if nameField == [47, 47] { return .stringTable }
        if nameField == [47] || nameField == Array("/SYM64/".utf8) { return .symbolTable }
        let digits = nameField.dropFirst()
        // BSD の実名 /123 は SysV 参照と区別できないため、参照として扱う。
        if nameField.first == 47, !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
           let offset = try Self.number(digits) { return .reference(offset) }
        return .plain(nameField.last == 47 ? Array(nameField.dropLast()) : nameField)
    }

    func layout(at offset: UInt64) throws -> (data: UInt64, end: UInt64, next: UInt64) {
        let data = try Checked.add(offset, 60)
        let end = try Checked.add(data, size)
        return (data, end, try Checked.add(end, size & 1))
    }
}
