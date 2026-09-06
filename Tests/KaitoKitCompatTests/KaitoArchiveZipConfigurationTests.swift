import Dispatch
import Foundation
import KaitoKitCompat
import XCTest

final class KaitoArchiveZipConfigurationTests: XCTestCase {
    func testLazyLocalHeaderDefaultIsThreadSafeAndUsedByBothInitializers() throws {
        let original = KaitoArchive.defaultZipLazyLocalHeaders
        defer { KaitoArchive.setDefaultZipLazyLocalHeaders(original) }
        XCTAssertTrue(original)

        DispatchQueue.concurrentPerform(iterations: 128) { iteration in
            KaitoArchive.setDefaultZipLazyLocalHeaders(iteration.isMultiple(of: 2))
            _ = KaitoArchive.defaultZipLazyLocalHeaders
        }

        let data = zipWithInvalidLocalHeader()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KaitoArchiveZipConfigurationTests-\(UUID().uuidString).zip"
        )
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        KaitoArchive.setDefaultZipLazyLocalHeaders(true)
        XCTAssertTrue(KaitoArchive.defaultZipLazyLocalHeaders)
        let lazyDataArchive = try XCTUnwrap(KaitoArchive(data: data))
        let lazyFileArchive = try XCTUnwrap(KaitoArchive(file: temporary.path))
        XCTAssertNil(lazyDataArchive.contents(ofEntry: 0))
        XCTAssertNil(lazyFileArchive.contents(ofEntry: 0))

        KaitoArchive.setDefaultZipLazyLocalHeaders(false)
        XCTAssertFalse(KaitoArchive.defaultZipLazyLocalHeaders)
        XCTAssertNil(KaitoArchive(data: data))
        XCTAssertNil(KaitoArchive(file: temporary.path))
    }

    private func zipWithInvalidLocalHeader() -> Data {
        let name = Array("a.txt".utf8)
        var data = Data()

        appendZIP32(0x0403_4b51, to: &data) // 中央ディレクトリだけを有効に保つ。
        appendZIP16(20, to: &data)
        appendZIP16(0, to: &data) // フラグ
        appendZIP16(0, to: &data) // stored 方式
        appendZIP16(0, to: &data) // 時刻
        appendZIP16(0, to: &data) // 日付
        appendZIP32(0, to: &data) // 空データの CRC32
        appendZIP32(0, to: &data) // 圧縮サイズ
        appendZIP32(0, to: &data) // 展開サイズ
        appendZIP16(UInt16(name.count), to: &data)
        appendZIP16(0, to: &data) // 追加フィールド長
        data.append(contentsOf: name)

        let centralOffset = UInt32(data.count)
        appendZIP32(0x0201_4b50, to: &data)
        appendZIP16(20, to: &data) // 作成元バージョン
        appendZIP16(20, to: &data) // 展開に必要なバージョン
        appendZIP16(0, to: &data) // フラグ
        appendZIP16(0, to: &data) // stored 方式
        appendZIP16(0, to: &data) // 時刻
        appendZIP16(0, to: &data) // 日付
        appendZIP32(0, to: &data) // CRC32
        appendZIP32(0, to: &data) // 圧縮サイズ
        appendZIP32(0, to: &data) // 展開サイズ
        appendZIP16(UInt16(name.count), to: &data)
        appendZIP16(0, to: &data) // 追加フィールド長
        appendZIP16(0, to: &data) // コメント長
        appendZIP16(0, to: &data) // 開始ディスク
        appendZIP16(0, to: &data) // 内部属性
        appendZIP32(0, to: &data) // 外部属性
        appendZIP32(0, to: &data) // ローカルヘッダ位置
        data.append(contentsOf: name)

        let centralSize = UInt32(data.count) - centralOffset
        appendZIP32(0x0605_4b50, to: &data)
        appendZIP16(0, to: &data) // ディスク
        appendZIP16(0, to: &data) // 中央ディレクトリのディスク
        appendZIP16(1, to: &data) // ディスク内エントリ数
        appendZIP16(1, to: &data) // 全エントリ数
        appendZIP32(centralSize, to: &data)
        appendZIP32(centralOffset, to: &data)
        appendZIP16(0, to: &data) // コメント長
        return data
    }

    private func appendZIP16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendZIP32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
