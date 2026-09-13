// 利用者の Python 独立実装による固定値と、外部 CC0 コーパスを照合する。
import CryptoKit
import Foundation
@testable import KaitoKit
import XCTest

final class StuffItXJPEGTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static func decode(_ data: Data, chunk: Int = 65536, limits: ReadLimits = ReadLimits()) throws -> Data {
        let decoder = try StuffItXCodec.make(method: 7, source: DataByteSource(data), size: nil, limits: limits)
        return try StuffItXCodecTests.collect(decoder, chunk: chunk)
    }
    func testStoredAndWZ() throws {
        let wire = StuffItCodecTests.hex("0006ffd8ffd96162")
        for n in [1,7,65536] { XCTAssertEqual(try Self.decode(wire,chunk:n), StuffItCodecTests.hex("ffd8ffd96162")) }
        for (value, hex) in [(UInt64(0),"00"),(127,"7f"),(128,"8100"),(16383,"ff7f"),(16384,"818000"),(UInt64.max,"81ffffffffffffffff7f")] {
            let bytes = StuffItCodecTests.hex(hex)
            XCTAssertEqual(StuffItXJPEGInput.writeWZ(value),Array(bytes))
            let input = try StuffItXJPEGInput(DataByteSource(bytes),limits:ReadLimits())
            XCTAssertEqual(try input.wz(),value)
        }
        for hex in ["0002ff","0000ff","03ff","ffffffffffffffffffff00"] { XCTAssertThrowsError(try Self.decode(StuffItCodecTests.hex(hex))) }
        XCTAssertThrowsError(try Self.decode(wire,limits:ReadLimits(maxEntrySize:7))) {
            guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
        }
    }
    func testDefaultBlockLimit() throws {
        let limits = ReadLimits()
        XCTAssertEqual(limits.maxJPEGBlocks,2_097_152)
        XCTAssertEqual(limits.maxJPEGBlocks*64*MemoryLayout<Int32>.stride,512*1024*1024)
        // 幾何計算のみで大画像の許容範囲を確認し、係数 plane は確保しない。
        for (width,height,h,v,expected) in [(4032,3024,2,2,285_768),(4032,3024,1,1,571_536),
                                           (6000,4000,1,1,1_125_000),(8000,6000,2,2,1_125_000)] {
            let frame = JPEGFrame(marker:194,width:width,height:height,components:[
                JPEGComponent(id:1,horizontal:h,vertical:v),JPEGComponent(id:2),JPEGComponent(id:3)])
            XCTAssertEqual(try JPEGGeometry(frame,limits:limits).blocks,expected)
            XCTAssertThrowsError(try JPEGGeometry(frame,limits:ReadLimits(maxJPEGBlocks:expected-1))) {
                XCTAssertEqual($0 as? KaitoError,.limitExceeded("StuffIt X JPEG coefficient blocks"))
            }
        }
    }
    func testErrorClassification() throws {
        func expect<T>(_ expected: KaitoError, _ operation: () throws -> T,
                       file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try operation(),file:file,line:line) {
                XCTAssertEqual($0 as? KaitoError,expected,file:file,line:line)
            }
        }
        for hex in ["","00","80","020000000000"] {
            expect(.truncated) { try Self.decode(StuffItCodecTests.hex(hex)) }
        }
        for hex in ["0002ff","0000ff"] {
            expect(.malformed("StuffIt X JPEG raw JPEG extent mismatch")) { try Self.decode(StuffItCodecTests.hex(hex)) }
        }
        expect(.unsupportedMethod("StuffIt X JPEG unsupported jcodec mode")) { try Self.decode(Data([3])) }
        expect(.malformed("StuffIt X JPEG WZ integer overflow")) { try Self.decode(Data(repeating:255,count:10)) }
        expect(.malformed("StuffIt X JPEG unterminated WZ integer")) { try Self.decode(Data(repeating:128,count:10)) }
        expect(.malformed("StuffIt X JPEG output extent mismatch")) {
            try StuffItXJPEGDecoder(source:DataByteSource(StuffItCodecTests.hex("0001ff")),size:2,limits:ReadLimits())
        }
        let first = try Self.vectors()["cases"] as! [[String:Any]], wire = StuffItCodecTests.hex(first[0]["input"] as! String)
        // 初期化後の係数・tail 読み取りで起きる入力不足も、そのまま伝播させる。
        let short = try StuffItXJPEGDecoder(source:DataByteSource(wire.dropLast()),size:nil,limits:ReadLimits())
        expect(.truncated) { try StuffItXCodecTests.collect(short,chunk:7) }
        expect(.malformed("StuffIt X JPEG JPEG encoded extent mismatch")) { try Self.decode(wire+Data([0])) }
        let wrongSize = try StuffItXJPEGDecoder(source:DataByteSource(wire),size:0,limits:ReadLimits())
        expect(.malformed("StuffIt X JPEG output extent mismatch")) { try StuffItXCodecTests.collect(wrongSize,chunk:7) }

        var tables = try JPEGTableSet(JPEGPrefix())
        expect(.truncated) { try tables.segment(219,[0]) }
        for selector: UInt8 in [4,32] {
            expect(.malformed("StuffIt X JPEG quantization table selector")) { try tables.segment(219,[selector]) }
        }
        expect(.unsupportedMethod("StuffIt X JPEG only eight-bit quantization tables supported")) { try tables.segment(219,[16]) }
        expect(.malformed("StuffIt X JPEG restart interval length")) { try tables.segment(221,[0]) }
        expect(.malformed("StuffIt X JPEG ambiguous Huffman table")) { try JPEGHuffman([1,1]+Array(repeating:0,count:14),[1,1]) }
        expect(.malformed("StuffIt X JPEG invalid JPEG Huffman code space")) { try JPEGHuffman([2]+Array(repeating:0,count:15),[0,1]) }
        let input = try StuffItXJPEGInput(DataByteSource(Data(repeating:255,count:5)),limits:ReadLimits()), range = try StuffItXJPEGRange(input)
        expect(.malformed("StuffIt X JPEG arithmetic code outside distribution")) { try range.bit() }
        let frequencies = Self.storage([0,0])
        expect(.malformed("StuffIt X JPEG invalid frequency total")) { try range.value(frequencies.p,2) }
        frequencies.p[0] = -1; frequencies.p[1] = 2
        expect(.malformed("StuffIt X JPEG negative frequency")) { try range.value(frequencies.p,2) }

        func prefix(_ bytes: [UInt8]) throws -> JPEGPrefix {
            var offset = 0
            return try StuffItXJPEGEnvelope.firstScan(limit:65536) {
                guard offset < bytes.count else { throw KaitoError.truncated }
                defer { offset += 1 }; return Int(bytes[offset])
            }
        }
        let scan: [UInt8] = [255,218,0,8,1,1,0,0,63,0]
        func header(_ body: [UInt8], marker: UInt8 = 192) -> [UInt8] {
            [255,216,255,marker,0,UInt8(body.count+2)]+body+scan
        }
        expect(.malformed("StuffIt X JPEG JPEG segment length")) { try prefix([255,216,255,224,0,1]) }
        expect(.malformed("StuffIt X JPEG JPEG frame components")) { try prefix(header([8,0,8,0,8,2,1,17,0,1,17,0])) }
        expect(.malformed("StuffIt X JPEG JPEG frame dimensions or precision")) { try prefix(header([8,0,0,0,8,1,1,17,0])) }
        expect(.unsupportedMethod("StuffIt X JPEG JPEG frame dimensions or precision")) { try prefix(header([12,0,8,0,8,1,1,17,0],marker:194)) }
        let components = (1...5).flatMap { i -> [UInt8] in [UInt8(i),17,0] }
        expect(.unsupportedMethod("StuffIt X JPEG JPEG frame components")) { try prefix(header([8,0,8,0,8,5]+components)) }
        expect(.malformed("StuffIt X JPEG JPEG scan layout")) { try prefix([255,216]+scan) }
        expect(.unsupportedMethod("StuffIt X JPEG unsupported JPEG frame marker")) { try prefix(header([8,0,8,0,8,1,1,17,0],marker:193)) }
        let valid = try prefix(header([8,0,8,0,8,1,1,17,0]))
        var badScan = valid; badScan.scan?.se = 62
        expect(.malformed("StuffIt X JPEG unsupported baseline scan")) { try StuffItXJPEGBaseline(badScan,range,JPEGOutput(limit:65536),ReadLimits()) }
        expect(.unsupportedMethod("StuffIt X JPEG mode-1 measured three-component interleaved profile required")) { try StuffItXJPEGMode1(valid,range,JPEGOutput(limit:65536),ReadLimits()) }
        var sampling = valid.frame!; sampling.components[0].horizontal = 2
        expect(.unsupportedMethod("StuffIt X JPEG unsupported sampling arrangement")) { try JPEGGeometry(sampling,limits:ReadLimits()) }
    }
    func testBlockTrace() throws {
        let json = try Self.vectors()["blocks"] as! [String:Any]
        let input = try StuffItXJPEGInput(DataByteSource(StuffItCodecTests.hex(json["input"] as! String)),limits:ReadLimits())
        _ = try input.wz(); _ = try input.wz()
        let range = try StuffItXJPEGRange(input), header = StuffItXJPEGHeaderModel()
        let prefix = try StuffItXJPEGEnvelope.firstScan(limit:1<<24) { try header.byte(range) }
        let geometry = try JPEGGeometry(prefix.frame!,limits:ReadLimits()), tables = try JPEGTableSet(prefix)
        let blocks = try StuffItXJPEGBlocks(range,geometry:geometry,keepAll:false,limits:ReadLimits())
        for rec in json["records"] as! [[String:Any]] {
            let c = rec["c"] as! Int, row = rec["row"] as! Int, col = rec["col"] as! Int
            let q = try tables.scaled(geometry.components[c].quantization)
            let co = try q.withUnsafeBufferPointer { try blocks.block(c,row,col,$0.baseAddress!,rec["hint"] as! Int,rec["profile"] as! Int) }
            let bytes = Data(bytes:co,count:64*4)
            if bytes != StuffItCodecTests.hex(rec["co"] as! String) || UInt64(range.code) != (rec["code"] as! NSNumber).uint64Value {
                XCTFail("block c=\(c) row=\(row) col=\(col) code=\(range.code)/\(rec["code"]!) range=\(range.range)/\(rec["range"]!) actual=\(bytes.map {String(format:"%02x",$0)}.joined()) expected=\(rec["co"]!)")
                return
            }
        }
    }
    static func vectors() throws -> [String:Any] {
        try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("Tests/Fixtures/stuffit/slice7-jpeg-vectors.json"))) as! [String:Any]
    }
    static func integers(_ hex: String) -> [Int] {
        let bytes = StuffItCodecTests.hex(hex)
        return bytes.withUnsafeBytes { p in stride(from:0,to:p.count,by:4).map { Int(Int32(littleEndian:p.loadUnaligned(fromByteOffset:$0,as:Int32.self))) } }
    }
    static func storage<T>(_ values: [T]) -> JPEGStorage<T> {
        let result = JPEGStorage<T>(values.count,values[0])
        for i in values.indices { result.p[i] = values[i] }; return result
    }
    func testHeaderAndRangeFixedValues() throws {
        let v = try Self.vectors()["header"] as! [String:Any]
        let source = try StuffItXJPEGInput(DataByteSource(StuffItCodecTests.hex(v["input"] as! String)),limits:ReadLimits())
        let r = try StuffItXJPEGRange(source), m = StuffItXJPEGHeaderModel()
        var actual = Data()
        for _ in 0..<1000 { actual.append(UInt8(try m.byte(r))) }
        XCTAssertEqual(actual,StuffItCodecTests.hex(v["output"] as! String))
        XCTAssertEqual(UInt64(r.code),(v["code"] as! NSNumber).uint64Value)
        XCTAssertEqual(UInt64(r.range),(v["range"] as! NSNumber).uint64Value)
        XCTAssertEqual(m.rescales,v["rescales"] as! Int)
        XCTAssertEqual(source.position,source.length)
    }
    func testFunctionDistributionsAndPredictors() throws {
        let v = try Self.vectors()["models"] as! [String:Any]
        func ints(_ key: String) -> [Int] { Self.integers(v[key] as! String) }
        let co = Self.storage(ints("co").map(Int32.init)), ln = Self.storage(ints("ln").map(Int32.init))
        let un = Self.storage(ints("un").map(Int32.init)), urn = Self.storage(ints("urn").map(Int32.init))
        let dqBytes = StuffItCodecTests.hex(v["dq"] as! String)
        let dqValues = dqBytes.withUnsafeBytes { p in stride(from:0,to:p.count,by:2).map { Int16(littleEndian:p.loadUnaligned(fromByteOffset:$0,as:Int16.self)) } }
        let dq = Self.storage(dqValues), q = Self.storage(ints("q")), up = Self.storage(ints("up")), left = Self.storage(ints("left")), sizes = Self.storage(ints("sizes"))
        let zx = Self.storage(Array(0..<8)), zy = Self.storage(Array((0..<8).reversed()))
        let m = StuffItXJPEGModel()
        for i in 0..<m.statistics.count { m.statistics.p[i] = UInt8((i*13+i/257)%127) }
        for i in 0..<m.signStatistics.count { m.signStatistics.p[i] = UInt8((i*7+i/19)%50) }
        for rec in v["distributions"] as! [[String:Any]] {
            let name = rec["name"] as! String, args = rec["args"] as! [Any]
            let keys: JPEGModelKeys
            switch name {
            case "dc": keys = try m.dcDist(2,7,3,(-811,1021,-313,700))
            case "h": keys = try m.hDist(2,-719,up.p,left.p,19,43,27,(1,2,3,4))
            case "v": keys = try m.vDist(2,up.p,left.p,19,43,5,27,(1,2,3,4))
            case "ac": keys = try m.acDist(args[0] as! Int,dq.p,args[1] as! Int,co.p,up.p,left.p,q.p,63,1,0,zx.p,zy.p,sizes.p,ln.p,un.p,urn.p)
            default: keys = try m.signDist(args[0] as! Int,co.p,args[1] as! Int,1,up.p,left.p,q.p,ln.p,un.p)
            }
            let expected = Self.integers(rec["frequencies"] as! String)
            XCTAssertEqual(Array(UnsafeBufferPointer(start:m.frequencies.p,count:keys.width)),expected,"\(name) \(args)")
            let offsets = [keys.a,keys.b,keys.c,keys.d]
            for (i,k) in (rec["keys"] as! [[Any]]).enumerated() {
                let p = try m.row(Character(k[0] as! String),k[1] as! Int)
                XCTAssertEqual((keys.sign ? m.signStatistics.p : m.statistics.p).distance(to:p),offsets[i])
            }
            m.update(keys,1,6,129)
        }
        let ln16 = Self.storage(ints("ln").map(Int16.init)), un16 = Self.storage(ints("un").map(Int16.init)), urn16 = Self.storage(ints("urn").map(Int16.init))
        for rec in v["predictors"] as! [[String:Any]] {
            let present = rec["present"] as! Int, quant = rec["q"] as! Int
            let result = jpegDCPrediction(present&1 != 0 ? UnsafePointer(dq.p) : nil,present&2 != 0 ? UnsafePointer(ln16.p) : nil,present&4 != 0 ? UnsafePointer(un16.p) : nil,present&8 != 0 ? UnsafePointer(urn16.p) : nil,57,quant)
            XCTAssertEqual(result.0,rec["pred"] as! Int)
            XCTAssertEqual([result.1.0,result.1.1,result.1.2,result.1.3],rec["contexts"] as! [Int])
        }
        XCTAssertEqual([0,1,5].flatMap { p in (0..<8).map { jpegDirectionalPrediction(dq.p,$0,8,p) } },v["directional"] as! [Int])
        XCTAssertThrowsError(try m.row("h",Int.max))
        // 高い水平文脈は垂直領域と同じアドレスを指す。
        XCTAssertEqual(try m.row("h",2776),try m.row("v",0))
        let k = JPEGModelKeys(a:0,b:16,c:32,d:48,width:16)
        m.statistics.p[1] = 255; m.update(k,1,8,248); XCTAssertEqual(m.statistics.p[1],7)
    }
    func testCompleteFixedStreamsAndLimits() throws {
        for v in try Self.vectors()["cases"] as! [[String:Any]] {
            let data = StuffItCodecTests.hex(v["input"] as! String), expected = StuffItCodecTests.hex(v["output"] as! String), name = v["name"] as! String
            for chunk in [1,7,65536] { XCTAssertEqual(try Self.decode(data,chunk:chunk),expected,name) }
            for end in 0..<data.count { XCTAssertThrowsError(try Self.decode(data.prefix(end)),"\(name): \(end)") }
            XCTAssertThrowsError(try Self.decode(data+Data([0])),name)
            XCTAssertThrowsError(try Self.decode(data,limits:ReadLimits(maxEntrySize:UInt64(data.count-1)))) {
                guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
            }
            let meta = v["metadata"] as! [String:Any], blocks = meta["coefficient_blocks"] as! Int
            if blocks > 0 {
                XCTAssertThrowsError(try Self.decode(data,limits:ReadLimits(maxJPEGBlocks:blocks-1))) {
                    guard case KaitoError.limitExceeded = $0 else { return XCTFail("\($0)") }
                }
            }
        }
    }
    func testHuffmanAndEntropyPrimitives() throws {
        let table = try JPEGHuffman([1,1]+Array(repeating:0,count:14),[0,1])
        let output = JPEGOutput(limit:100), writer = JPEGEntropyWriter(output)
        try table.write(writer,0); try table.write(writer,1); try writer.put(31,5)
        XCTAssertEqual(output.bytes,[0x5f])
        var offset = 0
        XCTAssertEqual(try table.read { defer { offset += 1 }; return [1,0][offset] },1)
        XCTAssertThrowsError(try JPEGHuffman([2]+Array(repeating:0,count:15),[0,1]))
        XCTAssertThrowsError(try JPEGHuffman([1,1]+Array(repeating:0,count:14),[1,1]))
        let delayedOutput = JPEGOutput(limit:100), delayed = JPEGDelayedBits(delayedOutput)
        try delayed.put(255,8); XCTAssertEqual(delayedOutput.bytes,[])
        try delayed.put(0,1); XCTAssertEqual(delayedOutput.bytes,[255,0])
        XCTAssertEqual(try delayed.finish(0x81),1); XCTAssertEqual(delayedOutput.bytes,[255,0,0x81])
        try delayed.restart(9); XCTAssertEqual(Array(delayedOutput.bytes.suffix(4)),[255,0,255,209])
    }
    func testMode1BlockFixedValues() throws {
        let v = try Self.vectors()["mode1blocks"] as! [String:Any]
        let input = try StuffItXJPEGInput(DataByteSource(StuffItCodecTests.hex(v["input"] as! String)),limits:ReadLimits())
        _ = try input.wz(); _ = try input.wz()
        let range = try StuffItXJPEGRange(input), header = StuffItXJPEGHeaderModel()
        let prefix = try StuffItXJPEGEnvelope.firstScan(limit:1<<24) { try header.byte(range) }
        let blocks = StuffItXJPEGMode1Blocks(range,try JPEGGeometry(prefix.frame!,limits:ReadLimits()))
        for rec in v["records"] as! [[String:Any]] {
            let result = try blocks.block(rec["c"] as! Int,rec["row"] as! Int,rec["col"] as! Int,rec["override"] as? Int)
            XCTAssertEqual(Data(bytes:result.0,count:256),StuffItCodecTests.hex(rec["co"] as! String))
            XCTAssertEqual(result.1,rec["old"] as! Int)
            XCTAssertEqual(UInt64(range.code),(rec["code"] as! NSNumber).uint64Value)
            XCTAssertEqual(UInt64(range.range),(rec["range"] as! NSNumber).uint64Value)
            XCTAssertEqual(input.position,(rec["position"] as! NSNumber).uint64Value)
        }
    }
    func testMode1FunctionVectors() throws {
        let v = try Self.vectors()["mode1"] as! [String:Any]
        let input = try StuffItXJPEGInput(DataByteSource(StuffItCodecTests.hex(v["input"] as! String)),limits:ReadLimits()), range = try StuffItXJPEGRange(input)
        let frame = JPEGFrame(marker:192,width:8,height:8,components:[JPEGComponent(id:1),JPEGComponent(id:2),JPEGComponent(id:3)])
        let m = StuffItXJPEGMode1Blocks(range,try JPEGGeometry(frame,limits:ReadLimits()))
        for op in v["operations"] as! [[String:Any]] {
            let c = op["c"] as! Int, context = op["context"] as! Int
            let value: Int, rows: [UnsafeMutablePointer<Int>]
            switch op["kind"] as! String {
            case "dc": value = try m.dc(c,context); rows = try [m.dcrow(c,context),m.dcrow(c,80)]
            case "ac":
                let pos = op["pos"] as! Int; value = try m.ac(c,context,pos)
                rows = try [m.acrow(c,36*pos+context),m.acrow(c,2304+pos),m.acrow(c,2368+context)]
            default: value = try m.sign(c,context); rows = [m.signRows.p+(c*1377+context)*2]
            }
            XCTAssertEqual(value,op["value"] as! Int)
            XCTAssertEqual(UInt64(range.code),(op["code"] as! NSNumber).uint64Value)
            XCTAssertEqual(UInt64(range.range),(op["range"] as! NSNumber).uint64Value)
            for (row,hex) in zip(rows,op["rows"] as! [String]) {
                let expected = Self.integers(hex)
                XCTAssertEqual(Array(UnsafeBufferPointer(start:row,count:expected.count)),expected)
            }
        }
        XCTAssertGreaterThan(m.rescales,0); XCTAssertGreaterThan(m.signRescales,0)
        XCTAssertThrowsError(try m.dcrow(0,81)); XCTAssertThrowsError(try m.acrow(2,0)); XCTAssertThrowsError(try m.sign(0,1377))
    }
    func testProgressiveEmissionBoundaries() throws {
        let vectors = try Self.vectors(), first = (vectors["cases"] as! [[String:Any]])[0]
        let input = try StuffItXJPEGInput(DataByteSource(StuffItCodecTests.hex(first["input"] as! String)),limits:ReadLimits())
        _ = try input.wz(); _ = try input.wz()
        let r = try StuffItXJPEGRange(input), model = StuffItXJPEGHeaderModel()
        let prefix = try StuffItXJPEGEnvelope.firstScan(limit:1<<24) { try model.byte(r) }, tables = try JPEGTableSet(prefix)
        for v in vectors["scans"] as! [[String:Any]] {
            let desc = v["scan"] as! [String:Any], events = v["events"] as! [String:Any]
            let scan = JPEGScan(components:[(1,0)],ss:desc["ss"] as! Int,se:desc["se"] as! Int,ah:desc["ah"] as! Int,al:desc["al"] as! Int)
            let co = Self.storage(Self.integers(v["co"] as! String).map(Int32.init)), output = JPEGOutput(limit:65536)
            let e = JPEGScanEncoder(scan,tables,output)
            for _ in 0..<(v["repeat"] as! Int) { try e.block(co.p,0,0) }
            try e.finish(255)
            XCTAssertEqual(Data(output.bytes),StuffItCodecTests.hex(v["output"] as! String),v["name"] as! String)
            XCTAssertEqual(e.eobRuns,events["eob_runs"] as! Int); XCTAssertEqual(e.zrls,events["zrls"] as! Int)
            XCTAssertEqual(e.correctionBits,events["correction_bits"] as! Int); XCTAssertEqual(e.correctionFlushes,events["correction_buffer_flushes"] as! Int)
            XCTAssertEqual(e.newRefinements,events["new_refinements"] as! Int); XCTAssertEqual(e.bits.total,events["total_bits"] as! Int)
        }
    }
    func testTokensComponentSlotsAndRejectedScans() throws {
        var wire = [42,255,255,255,0,255,216], offset = 0
        func byte() -> Int { defer { offset += 1 }; return wire[offset] }
        XCTAssertEqual(try StuffItXJPEGEnvelope.wireToken(byte).1,[42])
        XCTAssertEqual(try StuffItXJPEGEnvelope.wireToken(byte).1,[255,255])
        XCTAssertEqual(try StuffItXJPEGEnvelope.wireToken(byte).1,[])
        XCTAssertEqual(try StuffItXJPEGEnvelope.wireToken(byte).0,216)
        wire = []; XCTAssertEqual(offset,7)
        let frame = JPEGFrame(marker:192,width:8,height:8,components:[JPEGComponent(id:2,quantization:2),JPEGComponent(id:0,quantization:1),JPEGComponent(id:1,quantization:3)])
        XCTAssertEqual(try JPEGGeometry.componentsByID(frame).map(\.quantization),[1,3,0])
        let scan = try StuffItXJPEGProgressive.parseScan([3,3,0,1,0,2,0,0,0,0],[1,2,3])
        XCTAssertEqual(scan.components.map(\.id),[1,2,3])
        for body: [UInt8] in [[],[1,1,0,0,63,0],[1,1,0,1,63,0x31],[1,1,0x40,1,63,0],[2,1,0,2,0,1,63,0],[1,4,0,1,63,0]] {
            XCTAssertThrowsError(try StuffItXJPEGProgressive.parseScan(body,[1,2,3])) {
                guard case KaitoError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
    }
    func testCipherCompositionAndChecksumScope() throws {
        let v = try Self.vectors()["cases"] as! [[String:Any]]
        let encoded = StuffItCodecTests.hex(v[0]["input"] as! String), expected = StuffItCodecTests.hex(v[0]["output"] as! String)
        for cipher: [(UInt64,UInt64)] in [[],[(0,16)],[(1,16)],[(2,8)],[(3,8)]] {
            for digest: UInt64 in [0,1] {
                let payload = cipher.isEmpty ? encoded : Data(try StuffItXCryptoTests.seal(Array(encoded),ciphers:cipher))
                let prefix = cipher.isEmpty ? 0 : 2+(cipher[0].0 == 0 ? 16 : 8)
                let covered = payload.dropFirst(prefix)
                let checksum = digest == 0 ? StuffItXReaderTests.checksum(Data(covered)) : Data(Insecure.MD5.hash(data:covered))
                var algorithms = [StuffItXAlgorithm(key:1,value:7,keyLength:nil),StuffItXAlgorithm(key:6,value:digest,keyLength:nil)]
                algorithms += StuffItXCryptoTests.records(cipher)
                let element = StuffItXElement(offset:0,flag:false,type:1,attributes:[:],algorithms:algorithms,extra:nil,data:[0..<UInt64(payload.count)],checksums:[UInt64(payload.count)..<UInt64(payload.count+checksum.count)],framedSize:UInt64(payload.count))
                let coordinator = StuffItXStreamCoordinator(source:DataByteSource(payload+checksum),element:element,size:UInt64(expected.count),limits:ReadLimits(),password:"password")
                XCTAssertEqual(try StuffItXCodecTests.collect(coordinator.stream(offset:0,length:UInt64(expected.count)),chunk:1),expected)
                var bad = checksum; bad[0] ^= 1
                let corrupt = StuffItXStreamCoordinator(source:DataByteSource(payload+bad),element:element,size:UInt64(expected.count),limits:ReadLimits(),password:"password")
                XCTAssertThrowsError(try corrupt.stream(offset:0,length:UInt64(expected.count))) { XCTAssertEqual($0 as? KaitoError,.checksumMismatch(entry:-1)) }
            }
        }
        let ciphers: [(UInt64,UInt64)] = [(0,16),(2,8),(3,8)]
        let crypto = try StuffItXCrypto(password:"password",algorithms:StuffItXCryptoTests.records(ciphers))
        let input = try crypto.decrypt(DataByteSource(Data(StuffItXCryptoTests.seal(Array(encoded),ciphers:ciphers))))
        let decoder = try StuffItXCodec.make(method:7,source:input,size:UInt64(expected.count),limits:ReadLimits())
        XCTAssertEqual(try StuffItXCodecTests.collect(decoder,chunk:7),expected)
    }
    func testHistoricalArchives() throws {
        guard ProcessInfo.processInfo.environment["STUFFITX_JPEG_CORPUS"] == "1" else { throw XCTSkip("外部歴史的書庫は明示実行") }
        let folder = Self.root.appendingPathComponent("inbox/stuffit-corpus/cc0")
        let names = ["testfile.stuffit_deluxe_2009.win.sitx","testfile.stuffit_deluxe_2010.win.sitx","testfile.stuffit_deluxe_2009.win.password.des.sitx",
                     "testfile.stuffit_deluxe_2009.win.backcompat.exe","testfile.stuffit_deluxe_2009.win.install.exe","testfile.stuffit_deluxe_2010.win.backcompat.exe","testfile.stuffit_deluxe_2010.win.install.exe"]
        let hash = "e514232511df1a4f4221a75c27523518c3c62a2fe6470fa56e430364428eecd1"
        var historical: [[String:Any]] = [], unencrypted: Data?
        for name in names {
            let data = try Data(contentsOf:folder.appendingPathComponent(name))
            let reader = try ArchiveReader.open(data:data,options:ReaderOptions(password:"password",scanForSFXInData:true))
            let entry = try XCTUnwrap(reader.entries.first { $0.pathComponents.last == "testfile.jpg" })
            let restored = try reader.read(entry)
            XCTAssertEqual(restored.count,220,name); XCTAssertEqual(SHA256.hash(data:restored).map {String(format:"%02x",$0)}.joined(),hash,name)
            for entry in reader.entries where entry.kind != .directory { _ = try reader.read(entry) }
            historical.append(["file":name,"bytes":restored.count,"sha256":hash,"scope":"archive"])
            if name == names[0] {
                let source = DataByteSource(data), elements = try StuffItXElementParser(source:source,limits:ReadLimits()).parse()
                let element = try XCTUnwrap(elements.first { $0.compression == 7 })
                let framed = try StuffItXFramedInput(source:source,ranges:element.data)
                unencrypted = Data(try readByteRange(source:framed,offset:0,count:Int(framed.length)))
                try unencrypted!.write(to:Self.root.appendingPathComponent(".build/jpeg-historical-2009.jc"))
                let decoder = try StuffItXJPEGDecoder(source:DataByteSource(unencrypted!),size:220,limits:ReadLimits())
                _ = try StuffItXCodecTests.collect(decoder,chunk:1)
                XCTAssertEqual(decoder.range?.code,0x00acb00f); XCTAssertEqual(decoder.range?.range,0x0159601f)
            }
        }
        // Ch.25 の第四例は Root recovery に包まれており、許可入力にその復元層は含まれない。
        let redundantName = "testfile.stuffit_deluxe_2009.win.redundancy.sitx"
        let redundancy = try Data(contentsOf:folder.appendingPathComponent(redundantName))
        XCTAssertThrowsError(try ArchiveReader.open(data:redundancy)) {
            XCTAssertEqual($0 as? KaitoError,.unsupportedMethod("StuffIt X Root algorithms 5:0"))
        }
        historical.append(["file":redundantName,"scope":"unsupported Root recovery; JPEG payload unverified"])
        try JSONSerialization.data(withJSONObject:historical,options:[.prettyPrinted,.sortedKeys]).write(to:Self.root.appendingPathComponent(".build/jpeg-historical.json"))
    }
    func testFullSizePerformance() throws {
        guard ProcessInfo.processInfo.environment["STUFFITX_JPEG_BENCHMARK"] == "1" else { throw XCTSkip("性能測定は release で明示実行") }
        let folder = Self.root.appendingPathComponent("inbox/stuffit-corpus/jpeg")
        var records: [[String:Any]] = []
        for suffix in ["b420q75","b444q95","b422q50","gray","restart","prog","sips"] {
            let name = "IMG_0243-full-\(suffix)", data = try Data(contentsOf:folder.appendingPathComponent(name+".p20.jc")), expected = try Data(contentsOf:folder.appendingPathComponent(name+".jpg"))
            var samples: [Double] = []
            for _ in 0..<5 {
                let start = Date(), output = try Self.decode(data,limits:ReadLimits(maxJPEGBlocks:1_048_576))
                samples.append(Date().timeIntervalSince(start)); XCTAssertEqual(output,expected)
            }
            let median = samples.sorted()[2]
            XCTAssertLessThan(median,2.0,name)
            records.append(["stream":name+".p20.jc","seconds":samples,"median":median,"maxJPEGBlocks":1_048_576])
            print("JPEG benchmark \(name) \(samples)")
        }
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:Self.root.appendingPathComponent(".build/jpeg-performance.json"))
    }
    private enum AdversarialConfigurationError: Error {
        case invalid(String)
    }
    private static func adversarialSettings(_ environment: [String:String]) throws -> (seed: UInt64, rounds: Int) {
        var seed: UInt64 = 0x7357_2026, rounds = 128
        if let value = environment["STUFFITX_JPEG_SEED"] {
            let hex = value.lowercased().hasPrefix("0x"), digits = hex ? String(value.dropFirst(2)) : value
            guard let parsed = UInt64(digits,radix:hex ? 16 : 10) else { throw AdversarialConfigurationError.invalid("STUFFITX_JPEG_SEED") }
            seed = parsed
        }
        if let value = environment["STUFFITX_JPEG_ROUNDS"] {
            guard let parsed = Int(value), parsed >= 0 else { throw AdversarialConfigurationError.invalid("STUFFITX_JPEG_ROUNDS") }
            rounds = parsed
        }
        return (seed,rounds)
    }
    func testAdversarialConfiguration() throws {
        let defaults = try Self.adversarialSettings([:])
        XCTAssertEqual(defaults.seed,0x7357_2026); XCTAssertEqual(defaults.rounds,128)
        for value in ["4294967296","0x100000000","0X100000000"] {
            let custom = try Self.adversarialSettings(["STUFFITX_JPEG_SEED":value,"STUFFITX_JPEG_ROUNDS":"17"])
            XCTAssertEqual(custom.seed,4_294_967_296); XCTAssertEqual(custom.rounds,17)
        }
        XCTAssertEqual(try Self.adversarialSettings(["STUFFITX_JPEG_SEED":"0"]).seed,0)
        XCTAssertEqual(try Self.adversarialSettings(["STUFFITX_JPEG_SEED":"0xffffffffffffffff"]).seed,UInt64.max)
        XCTAssertEqual(try Self.adversarialSettings(["STUFFITX_JPEG_ROUNDS":"0"]).rounds,0)
        for value in ["","-1","0x","0xGG","18446744073709551616"] {
            XCTAssertThrowsError(try Self.adversarialSettings(["STUFFITX_JPEG_SEED":value]))
        }
        for value in ["","-1","abc","18446744073709551616"] {
            XCTAssertThrowsError(try Self.adversarialSettings(["STUFFITX_JPEG_ROUNDS":value]))
        }
    }
    func testAdversarialStreams() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["STUFFITX_JPEG_MUTATE"] == "1" else { throw XCTSkip("敵対的 JPEG 入力は明示実行") }
        let settings = try Self.adversarialSettings(environment)
        var seeds = try (Self.vectors()["cases"] as! [[String:Any]]).map { StuffItCodecTests.hex($0["input"] as! String) }
        let folder = Self.root.appendingPathComponent("inbox/stuffit-corpus/jpeg")
        for name in ["IMG_0243-240-b420q75.p00.jc","IMG_0243-240-b420q75.p10.jc","IMG_0243-240-b420q75.p20.jc","IMG_0243-240-b444q95.p20.jc","IMG_0243-240-gray.p20.jc","IMG_0243-240-prog.p20.jc","IMG_0243-240-restart.p20.jc"] { seeds.append(try Data(contentsOf:folder.appendingPathComponent(name))) }
        var counts: [String:Int] = [:], state = settings.seed
        func run(_ data: Data) {
            do {
                let out = try Self.decode(data,chunk:257,limits:ReadLimits(maxEntrySize:65536,maxJPEGBlocks:4096))
                XCTAssertLessThanOrEqual(out.count,65536); counts["accepted",default:0] += 1
            } catch KaitoError.limitExceeded { counts["limitExceeded",default:0] += 1 }
            catch KaitoError.malformed { counts["malformed",default:0] += 1 }
            catch KaitoError.unsupportedMethod { counts["unsupportedMethod",default:0] += 1 }
            catch KaitoError.truncated { counts["truncated",default:0] += 1 }
            catch { XCTFail("\(error)") }
        }
        for seed in seeds {
            let ends = Set(Array(0..<min(192,seed.count))+Array(stride(from:0,to:seed.count,by:max(1,seed.count/64)))+[seed.count-1])
            for end in ends.sorted() { run(Data(seed.prefix(end))) }
            for pos in 0..<min(64,seed.count) { for bit in 0..<8 { var m = seed; m[pos] ^= 1 << bit; run(m) } }
            for _ in 0..<settings.rounds {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let pos = Int(state%UInt64(seed.count)), bit = Int(state >> 32 & 7)
                var m = seed; m[pos] ^= 1 << bit; run(m)
            }
            run(seed+Data([0])); run(seed+seed)
        }
        print("JPEG mutation seed=0x\(String(settings.seed,radix:16)) rounds=\(settings.rounds) \(counts)")
        try JSONSerialization.data(withJSONObject:counts,options:[.prettyPrinted,.sortedKeys]).write(to:Self.root.appendingPathComponent(".build/jpeg-mutation.json"))
    }
    struct Item: Decodable {
        var source: String
        var stream: String?
        var mode: Int
        var second: Int
        var status: String
        var source_sha256: String?
    }
    func testCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["STUFFITX_JPEG_CORPUS"] == "1" else { throw XCTSkip("外部 JPEG コーパスは明示実行") }
        let dir = Self.root.appendingPathComponent("inbox/stuffit-corpus/jpeg")
        let items = try JSONDecoder().decode([Item].self,from:Data(contentsOf:dir.appendingPathComponent("manifest.json")))
        let filter = env["STUFFITX_JPEG_FILTER"] ?? ".*"
        var records: [[String:Any]] = []
        for item in items where item.status == "ok" {
            guard let name = item.stream, name.range(of:filter,options:.regularExpression) != nil else { continue }
            let data = try Data(contentsOf:dir.appendingPathComponent(name)), expected = try Data(contentsOf:dir.appendingPathComponent(item.source))
            let start = Date()
            var record: [String:Any] = ["stream":name,"mode":item.mode,"second":item.second]
            do {
                let output = try Self.decode(data,limits:ReadLimits(maxJPEGBlocks:1_048_576))
                let seconds = Date().timeIntervalSince(start)
                XCTAssertEqual(output,expected,name)
                record["status"] = output == expected ? "match" : "mismatch"
                record["sha256"] = SHA256.hash(data:output).map { String(format:"%02x",$0) }.joined()
                record["bytes"] = output.count; record["seconds"] = seconds
                print("JPEG \(name) \(record["status"]!) \(seconds)")
            } catch KaitoError.unsupportedMethod(let reason) where name.hasPrefix("testfile-") && (name.contains("-b420q75.") || name.contains("-b422q50.")) && item.mode == 2 {
                XCTAssertEqual(reason,"StuffIt X JPEG unsupported sampling arrangement",name)
                record["status"] = "unsupported"; record["error"] = reason
            } catch {
                record["status"] = "error"; record["error"] = String(describing:error)
                XCTFail("\(name): \(error)")
            }
            records.append(record)
        }
        XCTAssertFalse(records.isEmpty)
        let target = Self.root.appendingPathComponent(".build/jpeg-\(env["STUFFITX_JPEG_REPORT"] ?? "corpus").json")
        try JSONSerialization.data(withJSONObject:records,options:[.prettyPrinted,.sortedKeys]).write(to:target)
    }
}
