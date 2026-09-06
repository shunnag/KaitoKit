import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// 公開ドメインの LZMA SDK `C/Ppmd7.c` と `C/Ppmd7.h` にある
// PPMd7 allocator を、検証付き offset 表現で再実装する。
// null 参照、AlignOffset、割り当て優先順位、free-list の挿入順序、単方向
// glue walk、`UnitsStart - Text > requestedBytes` の厳密比較を維持する。
// 永続参照は Swift pointer ではなく、常に Base からの offset とする。
final class PPMd7Suballocator {
    typealias Offset = UInt32

    static let unitSize = 12
    static let nullOffset: Offset = 0

    private static let classUnits: [Int] = {
        var units = [Int]()
        var count = 0
        for index in 0..<38 {
            let step = index >= 12 ? 4 : (index >> 2) + 1
            count += step
            units.append(count)
        }
        precondition(units.last == 128)
        return units
    }()

    private static let unitsToClass: [Int] = {
        var result = [Int](repeating: 0, count: 128)
        var index = 0
        for units in 1...128 {
            while classUnits[index] < units { index += 1 }
            result[units - 1] = index
        }
        return result
    }()

    // Unsafe pointer の不変条件: すべての load/store/copy は checkedInt または
    // checkedOffset で Base 内の byte 範囲を検証してから実行する。
    private let storage: UnsafeMutableRawPointer
    // SDK の Size。textBaseOffset から始まる利用可能 byte 数。
    let size: Int
    // Ppmd7_Alloc と同じ `(4 - Size) & 3`。
    let alignOffset: Int
    // Base から見た SDK model 領域の先頭 byte。
    var textBaseOffset: Int { alignOffset }
    // Base から見た SDK model 領域の終端直後。
    var arenaEndOffset: Int { alignOffset + size }

    private var freeList = [Offset](repeating: 0, count: 38)
    private(set) var textOffset = 0
    private(set) var unitsStartOffset = 0
    private(set) var lowUnitOffset = 0
    private(set) var highUnitOffset = 0
    private(set) var glueCount = 0

    init(memorySize: UInt64) throws {
        let byteCount = try Checked.toInt(memorySize)
        let alignment = (4 - byteCount) & 3
        guard byteCount >= 1 << 11,
              byteCount <= Int(UInt32.max) - Self.unitSize * 3 else {
            throw KaitoError.malformed("PPMd7 suballocator size is out of range")
        }
        guard let pointer = malloc(byteCount + alignment) else {
            throw KaitoError.limitExceeded("unable to allocate PPMd7 model arena")
        }
        storage = pointer
        size = byteCount
        alignOffset = alignment
        restart()
    }

    deinit {
        free(storage)
    }

    func restart() {
        freeList = [Offset](repeating: 0, count: Self.classUnits.count)
        textOffset = textBaseOffset
        highUnitOffset = arenaEndOffset
        let groups = (size / 8) / Self.unitSize
        unitsStartOffset = highUnitOffset - groups * 7 * Self.unitSize
        lowUnitOffset = unitsStartOffset
        glueCount = 0
    }

    // SDK AllocContext と同じく、high frontier、class-0 list、rare allocation の順。
    func allocateContext() throws -> Offset? {
        try requireFrontierOrder()
        if highUnitOffset != lowUnitOffset {
            highUnitOffset -= Self.unitSize
            return try checkedUnitOffset(highUnitOffset, byteCount: Self.unitSize)
        }
        if freeList[0] != 0 {
            return try removeNode(classIndex: 0)
        }
        return try allocateUnitsRare(classIndex: 0)
    }

    // 要求値は論理 unit 数で、SDK Units2Indx と同じ class に切り上げる。
    func allocateUnits(_ requestedUnits: Int) throws -> Offset? {
        let classIndex = try Self.classIndex(for: requestedUnits)
        if freeList[classIndex] != 0 {
            return try removeNode(classIndex: classIndex)
        }

        let bytes = try Self.bytes(forClass: classIndex)
        try requireFrontierOrder()
        if highUnitOffset - lowUnitOffset >= bytes {
            let result = lowUnitOffset
            lowUnitOffset += bytes
            return try checkedUnitOffset(result, byteCount: bytes)
        }
        return try allocateUnitsRare(classIndex: classIndex)
    }

    func expandUnits(at oldOffset: Offset, oldUnits: Int) throws -> Offset? {
        let oldClass = try Self.classIndex(for: oldUnits)
        let newClass = try Self.classIndex(for: oldUnits + 1)
        try requireAllocatedUnitBlock(oldOffset, classIndex: oldClass)
        if oldClass == newClass { return oldOffset }

        guard let newOffset = try allocateUnits(oldUnits + 1) else { return nil }
        // SDK と同じく、切り上げ class の余白ではなく oldNU unit だけをコピーする。
        try copyBytes(
            from: oldOffset,
            to: newOffset,
            count: try Self.bytes(forUnits: oldUnits)
        )
        try insertNode(oldOffset, classIndex: oldClass)
        return newOffset
    }

    func shrinkUnits(
        at oldOffset: Offset,
        oldUnits: Int,
        newUnits: Int
    ) throws -> Offset {
        guard newUnits > 0, newUnits <= oldUnits else {
            throw KaitoError.malformed("invalid PPMd7 unit shrink")
        }
        let oldClass = try Self.classIndex(for: oldUnits)
        let newClass = try Self.classIndex(for: newUnits)
        try requireAllocatedUnitBlock(oldOffset, classIndex: oldClass)
        if oldClass == newClass { return oldOffset }

        if freeList[newClass] != 0 {
            let newOffset = try removeNode(classIndex: newClass)
            try copyBytes(
                from: oldOffset,
                to: newOffset,
                count: try Self.bytes(forUnits: newUnits)
            )
            try insertNode(oldOffset, classIndex: oldClass)
            return newOffset
        }

        try splitBlock(oldOffset, oldClass: oldClass, newClass: newClass)
        return oldOffset
    }

    func freeUnits(at offset: Offset, units: Int) throws {
        try insertNode(offset, classIndex: Self.classIndex(for: units))
    }

    func appendText(_ byte: UInt8) throws -> Offset? {
        try requireFrontierOrder()
        guard textOffset < unitsStartOffset else { return nil }
        let result = textOffset
        storage.storeBytes(of: byte, toByteOffset: result, as: UInt8.self)
        textOffset += 1
        return try checkedOffset(result, byteCount: 1)
    }

    func retractText() throws {
        guard textOffset > textBaseOffset else {
            throw KaitoError.malformed("PPMd7 text frontier underflow")
        }
        textOffset -= 1
    }

    func byte(at offset: Offset) throws -> UInt8 {
        storage.load(fromByteOffset: try checkedInt(offset, byteCount: 1), as: UInt8.self)
    }

    func storeByte(_ value: UInt8, at offset: Offset) throws {
        storage.storeBytes(
            of: value,
            toByteOffset: try checkedInt(offset, byteCount: 1),
            as: UInt8.self
        )
    }

    func uint16(at offset: Offset) throws -> UInt16 {
        let index = try checkedInt(offset, byteCount: 2)
        var value: UInt16 = 0
        memcpy(&value, storage.advanced(by: index), 2)
        return UInt16(littleEndian: value)
    }

    func storeUInt16(_ value: UInt16, at offset: Offset) throws {
        let index = try checkedInt(offset, byteCount: 2)
        var little = value.littleEndian
        memcpy(storage.advanced(by: index), &little, 2)
    }

    func uint32(at offset: Offset) throws -> UInt32 {
        let index = try checkedInt(offset, byteCount: 4)
        var value: UInt32 = 0
        memcpy(&value, storage.advanced(by: index), 4)
        return UInt32(littleEndian: value)
    }

    func storeUInt32(_ value: UInt32, at offset: Offset) throws {
        let index = try checkedInt(offset, byteCount: 4)
        var little = value.littleEndian
        memcpy(storage.advanced(by: index), &little, 4)
    }

    private func allocateUnitsRare(classIndex: Int) throws -> Offset? {
        guard freeList.indices.contains(classIndex) else {
            throw KaitoError.malformed("PPMd7 free-list class is out of range")
        }
        if glueCount == 0 {
            try glueFreeBlocks()
            if freeList[classIndex] != 0 {
                return try removeNode(classIndex: classIndex)
            }
        }

        var largerClass = classIndex
        repeat {
            largerClass += 1
            if largerClass == Self.classUnits.count {
                let bytes = try Self.bytes(forClass: classIndex)
                let oldUnitsStart = unitsStartOffset
                guard glueCount > 0 else {
                    throw KaitoError.malformed("PPMd7 glue counter underflow")
                }
                glueCount -= 1
                // SDK の動作と一致させるため、この比較は厳密な `>` のままとする。
                guard oldUnitsStart - textOffset > bytes else { return nil }
                unitsStartOffset = oldUnitsStart - bytes
                return try checkedUnitOffset(unitsStartOffset, byteCount: bytes)
            }
        } while freeList[largerClass] == 0

        let block = try removeNode(classIndex: largerClass)
        try splitBlock(block, oldClass: largerClass, newClass: classIndex)
        return block
    }

    // Ppmd7_SplitBlock の処理順を offset 表現へ移す。
    private func splitBlock(
        _ offset: Offset,
        oldClass: Int,
        newClass: Int
    ) throws {
        guard Self.classUnits.indices.contains(oldClass),
              Self.classUnits.indices.contains(newClass),
              oldClass > newClass else {
            throw KaitoError.malformed("invalid PPMd7 free-block split")
        }
        try requireAllocatedUnitBlock(offset, classIndex: oldClass)
        var remainderUnits = Self.classUnits[oldClass] - Self.classUnits[newClass]
        let remainderOffset = try Self.advanced(
            offset,
            byUnits: Self.classUnits[newClass]
        )
        var remainderClass = try Self.classIndex(for: remainderUnits)

        if Self.classUnits[remainderClass] != remainderUnits {
            remainderClass -= 1
            let lowerUnits = Self.classUnits[remainderClass]
            let tailOffset = try Self.advanced(remainderOffset, byUnits: lowerUnits)
            let tailClass = remainderUnits - lowerUnits - 1
            guard Self.classUnits.indices.contains(tailClass),
                  Self.classUnits[tailClass] == remainderUnits - lowerUnits else {
                throw KaitoError.malformed("PPMd7 split tail is not an SDK class")
            }
            try insertNode(tailOffset, classIndex: tailClass)
            remainderUnits = lowerUnits
        }
        guard Self.classUnits[remainderClass] == remainderUnits else {
            throw KaitoError.malformed("PPMd7 split remainder is invalid")
        }
        try insertNode(remainderOffset, classIndex: remainderClass)
    }

    // SDK の単方向 glue pass と同じ処理順・stamp 動作を維持する。
    private func glueFreeBlocks() throws {
        glueCount = 255

        if lowUnitOffset != highUnitOffset {
            try storeUInt16(1, at: try checkedUnitOffset(lowUnitOffset, byteCount: 2))
        }

        var listHead: Offset = 0
        for classIndex in freeList.indices {
            let units = Self.classUnits[classIndex]
            var next = freeList[classIndex]
            freeList[classIndex] = 0
            var visited = 0
            while next != 0 {
                try requireAllocatedUnitBlock(next, classIndex: classIndex)
                let current = next
                // node header を上書きする前に元の FreeList link を読み取る。
                next = try uint32(at: current)
                try storeUInt16(0, at: current)
                try storeUInt16(UInt16(units), at: try Self.add(current, 2))
                try storeUInt32(listHead, at: try Self.add(current, 4))
                listHead = current
                visited += 1
                guard visited <= size / Self.unitSize else {
                    throw KaitoError.malformed("PPMd7 free list is cyclic")
                }
            }
        }

        var head = listHead
        var previousLinkOwner: Offset? = nil
        var nodeRef = head
        var walked = 0
        while nodeRef != 0 {
            try requireGlueNode(nodeRef)
            var units = Int(try uint16(at: try Self.add(nodeRef, 2)))
            let next = try uint32(at: try Self.add(nodeRef, 4))
            if units == 0 {
                if let owner = previousLinkOwner {
                    try storeUInt32(next, at: try Self.add(owner, 4))
                } else {
                    head = next
                }
                nodeRef = next
                continue
            }

            previousLinkOwner = nodeRef
            while true {
                let adjacentBytes = try Self.bytes(forUnits: units)
                let adjacentValue = Int(nodeRef) + adjacentBytes
                // 正常な model では隣接位置に live root/record または LoUnit guard がある。
                // SDK の読み取りを再現する前にも範囲を検証する。
                guard adjacentValue <= arenaEndOffset - Self.unitSize else { break }
                let adjacent = try checkedUnitOffset(adjacentValue, byteCount: Self.unitSize)
                let adjacentUnits = Int(try uint16(at: try Self.add(adjacent, 2)))
                let combined = units + adjacentUnits
                if try uint16(at: adjacent) != 0 || combined >= 0x1_0000 {
                    break
                }
                guard adjacentUnits > 0 else {
                    throw KaitoError.malformed("PPMd7 glue encountered a zero-sized free node")
                }
                units = combined
                try storeUInt16(UInt16(units), at: try Self.add(nodeRef, 2))
                try storeUInt16(0, at: try Self.add(adjacent, 2))
            }
            nodeRef = next
            walked += 1
            guard walked <= size / Self.unitSize else {
                throw KaitoError.malformed("PPMd7 glue list is cyclic")
            }
        }

        nodeRef = head
        walked = 0
        while nodeRef != 0 {
            try requireGlueNode(nodeRef)
            var units = Int(try uint16(at: try Self.add(nodeRef, 2)))
            let next = try uint32(at: try Self.add(nodeRef, 4))
            if units != 0 {
                var block = nodeRef
                while units > 128 {
                    try insertNode(block, classIndex: Self.classUnits.count - 1)
                    block = try Self.advanced(block, byUnits: 128)
                    units -= 128
                }
                var classIndex = try Self.classIndex(for: units)
                if Self.classUnits[classIndex] != units {
                    classIndex -= 1
                    let lowerUnits = Self.classUnits[classIndex]
                    let tail = try Self.advanced(block, byUnits: lowerUnits)
                    let tailClass = units - lowerUnits - 1
                    guard Self.classUnits.indices.contains(tailClass),
                          Self.classUnits[tailClass] == units - lowerUnits else {
                        throw KaitoError.malformed("PPMd7 glued tail is not an SDK class")
                    }
                    try insertNode(tail, classIndex: tailClass)
                }
                try insertNode(block, classIndex: classIndex)
            }
            nodeRef = next
            walked += 1
            guard walked <= size / Self.unitSize else {
                throw KaitoError.malformed("PPMd7 glue fill list is cyclic")
            }
        }
    }

    private func insertNode(_ offset: Offset, classIndex: Int) throws {
        try requireAllocatedUnitBlock(offset, classIndex: classIndex)
        try storeUInt32(freeList[classIndex], at: offset)
        freeList[classIndex] = offset
    }

    private func removeNode(classIndex: Int) throws -> Offset {
        guard freeList.indices.contains(classIndex) else {
            throw KaitoError.malformed("PPMd7 free-list class is out of range")
        }
        let result = freeList[classIndex]
        guard result != 0 else {
            throw KaitoError.malformed("PPMd7 free list is empty")
        }
        try requireAllocatedUnitBlock(result, classIndex: classIndex)
        let next = try uint32(at: result)
        if next != 0 {
            try requireAllocatedUnitBlock(next, classIndex: classIndex)
        }
        freeList[classIndex] = next
        return result
    }

    private func requireFrontierOrder() throws {
        guard textBaseOffset <= textOffset,
              textOffset <= unitsStartOffset,
              unitsStartOffset <= lowUnitOffset,
              lowUnitOffset <= highUnitOffset,
              highUnitOffset <= arenaEndOffset else {
            throw KaitoError.malformed("PPMd7 allocator frontiers crossed")
        }
    }

    private func requireAllocatedUnitBlock(_ offset: Offset, classIndex: Int) throws {
        guard Self.classUnits.indices.contains(classIndex) else {
            throw KaitoError.malformed("PPMd7 free-list class is out of range")
        }
        _ = try checkedUnitOffset(Int(offset), byteCount: try Self.bytes(forClass: classIndex))
    }

    private func requireGlueNode(_ offset: Offset) throws {
        _ = try checkedUnitOffset(Int(offset), byteCount: Self.unitSize)
    }

    private func copyBytes(from source: Offset, to destination: Offset, count: Int) throws {
        let sourceIndex = try checkedInt(source, byteCount: count)
        let destinationIndex = try checkedInt(destination, byteCount: count)
        memmove(
            storage.advanced(by: destinationIndex),
            storage.advanced(by: sourceIndex),
            count
        )
    }

    private func checkedInt(_ offset: Offset, byteCount: Int) throws -> Int {
        let value = Int(offset)
        guard byteCount >= 0,
              value >= textBaseOffset,
              value <= arenaEndOffset,
              byteCount <= arenaEndOffset - value else {
            throw KaitoError.malformed("PPMd7 arena offset is out of range")
        }
        return value
    }

    private func checkedOffset(_ value: Int, byteCount: Int) throws -> Offset {
        guard value >= textBaseOffset,
              value <= arenaEndOffset,
              byteCount >= 0,
              byteCount <= arenaEndOffset - value,
              value <= Int(UInt32.max) else {
            throw KaitoError.malformed("PPMd7 arena offset is out of range")
        }
        return Offset(value)
    }

    private func checkedUnitOffset(_ value: Int, byteCount: Int) throws -> Offset {
        let offset = try checkedOffset(value, byteCount: byteCount)
        guard value >= unitsStartOffset,
              (value - unitsStartOffset).isMultiple(of: Self.unitSize) else {
            throw KaitoError.malformed("PPMd7 unit offset is invalid")
        }
        return offset
    }

    private static func classIndex(for units: Int) throws -> Int {
        guard units > 0, units <= 128 else {
            throw KaitoError.malformed("PPMd7 unit request is out of range")
        }
        return unitsToClass[units - 1]
    }

    private static func bytes(forClass classIndex: Int) throws -> Int {
        guard classUnits.indices.contains(classIndex) else {
            throw KaitoError.malformed("PPMd7 unit class is out of range")
        }
        return try bytes(forUnits: classUnits[classIndex])
    }

    private static func bytes(forUnits units: Int) throws -> Int {
        let (result, overflow) = units.multipliedReportingOverflow(by: unitSize)
        guard units >= 0, !overflow else {
            throw KaitoError.malformed("PPMd7 unit byte count overflow")
        }
        return result
    }

    private static func advanced(_ offset: Offset, byUnits units: Int) throws -> Offset {
        let bytes = try bytes(forUnits: units)
        let (result, overflow) = Int(offset).addingReportingOverflow(bytes)
        guard !overflow, result <= Int(UInt32.max) else {
            throw KaitoError.malformed("PPMd7 arena offset overflow")
        }
        return Offset(result)
    }

    private static func add(_ offset: Offset, _ bytes: Int) throws -> Offset {
        let (result, overflow) = Int(offset).addingReportingOverflow(bytes)
        guard bytes >= 0, !overflow, result <= Int(UInt32.max) else {
            throw KaitoError.malformed("PPMd7 arena offset overflow")
        }
        return Offset(result)
    }
}
