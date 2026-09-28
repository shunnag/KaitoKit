import Foundation

// 参照仕様: LZMA SDK DOC/Methods.txt。coder の method ID から種類と表示名を引く。

enum SevenZipMethodKind: Equatable {
    case copy
    case lzma
    case lzma2
    case ppmd7
    case deflate
    case deflate64
    case bzip2
    case zstd
    case aes
    case delta
    case swap(Int)
    case branch(SevenZipBranchFilter)
    case bcj2
    case unsupported(String)
}

enum SevenZipMethod {
    static func kind(for id: [UInt8]) -> SevenZipMethodKind {
        switch id {
        case [0x00]: return .copy
        case [0x21]: return .lzma2
        case [0x03, 0x01, 0x01]: return .lzma
        case [0x03, 0x04, 0x01]: return .ppmd7
        case [0x04, 0x01, 0x08]: return .deflate
        // 公式 Methods.txt の Deflate64 ID（04 01 09）。
        case [0x04, 0x01, 0x09]: return .deflate64
        case [0x04, 0x02, 0x02]: return .bzip2
        // Methods.txt の external codec 領域 (04 F7 11 xx、Tino Reichardt)。7-Zip ZS /
        // NanaZip / libarchive 3.8 が書く。packed stream は RFC 8878 の frame 列そのもの。
        case [0x04, 0xF7, 0x11, 0x01]: return .zstd
        case [0x06, 0xF1, 0x07, 0x01]: return .aes
        case [0x03]: return .delta
        case [0x02, 0x03, 0x02]: return .swap(2)
        case [0x02, 0x03, 0x04]: return .swap(4)
        case [0x04], [0x03, 0x03, 0x01, 0x03]: return .branch(.x86)
        case [0x05], [0x03, 0x03, 0x02, 0x05]: return .branch(.powerPC)
        case [0x07], [0x03, 0x03, 0x05, 0x01]: return .branch(.arm)
        case [0x08], [0x03, 0x03, 0x07, 0x01]: return .branch(.armThumb)
        case [0x0A]: return .branch(.arm64)
        case [0x03, 0x03, 0x01, 0x1B]: return .bcj2
        case [0x06], [0x03, 0x03, 0x04, 0x01]:
            return .branch(.ia64)
        case [0x09], [0x03, 0x03, 0x08, 0x05]:
            return .branch(.sparc)
        default:
            let text = id.map { String(format: "%02X", $0) }.joined()
            return .unsupported("7z method 0x\(text)")
        }
    }

    static func description(for coder: SevenZipCoder) -> String {
        switch kind(for: coder.methodID) {
        case .copy: return "Copy"
        case .lzma: return "LZMA"
        case .lzma2: return "LZMA2"
        case .ppmd7: return "PPMd7"
        case .deflate: return "Deflate"
        case .deflate64: return "Deflate64"
        case .bzip2: return "BZip2"
        case .zstd: return "Zstandard"
        case .aes: return "7zAES-256"
        case let .swap(width): return "Swap\(width)"
        case .delta:
            return coder.properties.count == 1
                ? "Delta:\(Int(coder.properties[0]) + 1)"
                : "Delta"
        case let .branch(filter):
            switch filter {
            case .x86: return "BCJ"
            case .arm: return "ARM"
            case .armThumb: return "ARMT"
            case .arm64: return "ARM64"
            case .powerPC: return "PPC"
            case .sparc: return "SPARC"
            case .ia64: return "IA64"
            }
        case .bcj2: return "BCJ2"
        case let .unsupported(name): return name
        }
    }
}
