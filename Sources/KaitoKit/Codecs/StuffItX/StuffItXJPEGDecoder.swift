// stuffitx_jpeg_restore.py の dispatch と厳密な member 終端を Decompressor へ接続。
import Foundation

final class StuffItXJPEGDecoder: Decompressor {
    let input: StuffItXJPEGInput
    let limits: ReadLimits
    let expectedSize: UInt64?
    let output: JPEGOutput
    var remaining: UInt64 = 0
    var mode = 0
    var range: StuffItXJPEGRange?
    var headerModel: StuffItXJPEGHeaderModel?
    var baseline: StuffItXJPEGBaseline?
    var mode1: StuffItXJPEGMode1?
    var progressive: StuffItXJPEGProgressive?
    var produced: UInt64 = 0
    var ended = false
    var scanEnded = false
    var postMarkers = 0
    var postTokens: UInt64 = 0
    private(set) var isFinished = false

    init(source: any ByteSource, size: UInt64?, limits: ReadLimits) throws {
        self.limits = limits; expectedSize = size; output = JPEGOutput(limit:limits.maxEntrySize)
        if let size { try Checked.size(size, limit: limits.maxEntrySize) }
        input = try StuffItXJPEGInput(source, limits: limits)
        let mode = try input.wz()
        guard mode <= 2 else { throw jpegUnsupported("unsupported jcodec mode") }
        let declared = try input.wz()
        self.mode = Int(mode)
        if mode == 0 {
            try Checked.size(declared, limit: limits.maxEntrySize)
            guard declared == input.length - input.position else { throw jpegMalformed("raw JPEG extent mismatch") }
            guard size == nil || size == declared else { throw jpegMalformed("output extent mismatch") }
            remaining = declared
        } else {
            let range = try StuffItXJPEGRange(input), model = StuffItXJPEGHeaderModel()
            self.range = range; headerModel = model
            let prefix = try StuffItXJPEGEnvelope.firstScan(limit:limits.maxEntrySize) { try model.byte(range) }
            if prefix.scan == nil && prefix.frame?.marker != 194 {
                try output.append(prefix.header)
            } else if mode == 2 && prefix.frame?.marker == 192 {
                baseline = try StuffItXJPEGBaseline(prefix,range,output,limits)
                try output.append(prefix.header)
            } else if mode == 2 {
                progressive = try StuffItXJPEGProgressive(prefix,range,model,output,limits)
            } else {
                mode1 = try StuffItXJPEGMode1(prefix,range,output,limits)
                try output.append(prefix.header)
            }
        }
    }
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        if buffer.isEmpty || isFinished { return 0 }
        if mode == 0 {
            let n = Int(min(UInt64(buffer.count), remaining)), bytes = buffer.bindMemory(to: UInt8.self)
            for i in 0..<n { bytes[i] = UInt8(try input.byte()) }
            remaining -= UInt64(n); produced += UInt64(n); isFinished = remaining == 0
            return n
        }
        while output.count == 0 && !ended {
            if let baseline, !baseline.done { try baseline.step() }
            else if let mode1, !mode1.done { try mode1.step() }
            else if let progressive, !progressive.done { try progressive.step() }
            else if !scanEnded {
                if progressive != nil { try output.append([255,217]); scanEnded = true }
                else if baseline != nil || mode1 != nil { scanEnded = try postScan() }
                else { scanEnded = true }
            } else { ended = try tail() }
        }
        let n = output.read(into:buffer); produced += UInt64(n)
        isFinished = ended && output.count == 0
        return n
    }
    func get() throws -> Int { try headerModel!.byte(range!) }
    func postScan() throws -> Bool {
        postTokens += 1
        guard postTokens <= limits.maxEntrySize else { throw KaitoError.limitExceeded("StuffIt X JPEG header tokens") }
        let (marker,token) = try StuffItXJPEGEnvelope.wireToken { try self.get() }
        guard let marker else { try output.append(token); return false }
        postMarkers += 1
        guard postMarkers <= 4096 else { throw jpegMalformed("JPEG marker limit") }
        if marker == 216 || marker == 217 { try output.append([255,217]); return true }
        guard ![0,1,192,194,218].contains(marker), !(208...215).contains(marker) else { throw jpegUnsupported("unsupported marker after baseline scan") }
        try output.append(token)
        let high = try get(), low = try get(), length = high*256+low
        guard length >= 2 else { throw jpegMalformed("JPEG segment length") }
        try output.append(high); try output.append(low)
        for _ in 0..<(length-2) { try output.append(get()) }
        return false
    }
    func tail() throws -> Bool {
        let count = try get()
        if count != 0 {
            for _ in 0..<count { try output.append(get()) }
            return false
        }
        guard input.position == input.length else { throw jpegMalformed("JPEG encoded extent mismatch") }
        guard expectedSize == nil || expectedSize == output.produced else { throw jpegMalformed("output extent mismatch") }
        return true
    }
}
