// Public LZ4 Block Format Description, revised 2022-07-31.
// The enclosing frame supplies the maximum decoded size and up to 64 KiB of
// preceding decoded bytes. External dictionaries are not accepted by the frame.
enum LZ4BlockDecoder {
    static func decode(_ input: [UInt8], history: [UInt8], maximumSize: Int) throws -> [UInt8] {
        guard maximumSize >= 0, history.count <= 65_536 else {
            throw KaitoError.malformed("LZ4 block bounds")
        }
        var cursor = 0
        var output: [UInt8] = []
        // Small malformed blocks must not cause a maximum-size allocation.
        output.reserveCapacity(min(maximumSize, input.count))
        var lastMatchStart: Int?

        func length(_ nibble: Int, minimum: Int = 0) throws -> Int {
            var result = nibble + minimum
            if nibble == 15 {
                while true {
                    guard cursor < input.count else { throw KaitoError.truncated }
                    let extra = Int(input[cursor])
                    cursor += 1
                    guard result <= maximumSize, extra <= maximumSize - result else {
                        throw KaitoError.limitExceeded("LZ4 block output")
                    }
                    result += extra
                    if extra != 255 { break }
                }
            }
            return result
        }

        while cursor < input.count {
            let token = input[cursor]
            cursor += 1
            let literals = try length(Int(token >> 4))
            guard literals <= input.count - cursor else { throw KaitoError.truncated }
            guard literals <= maximumSize - output.count else {
                throw KaitoError.limitExceeded("LZ4 block output")
            }
            output.append(contentsOf: input[cursor..<(cursor + literals)])
            cursor += literals
            if cursor == input.count {
                // Spec's final literal-only sequence and historical decoder
                // safety restrictions. A wholly literal block may be empty.
                if let lastMatchStart {
                    guard literals >= 5, output.count - lastMatchStart >= 12 else {
                        throw KaitoError.malformed("LZ4 block end conditions")
                    }
                }
                return output
            }
            guard input.count - cursor >= 2 else { throw KaitoError.truncated }
            let distance = Int(input[cursor]) | Int(input[cursor + 1]) << 8
            cursor += 2
            guard distance > 0, distance <= history.count + output.count else {
                throw KaitoError.malformed("LZ4 match distance")
            }
            let count = try length(Int(token & 15), minimum: 4)
            guard count <= maximumSize - output.count else {
                throw KaitoError.limitExceeded("LZ4 block output")
            }
            lastMatchStart = output.count
            // Resolve each byte against output as it grows, so overlapping
            // matches and matches crossing the history boundary are defined.
            for _ in 0..<count {
                let index = output.count - distance
                output.append(index >= 0 ? output[index] : history[history.count + index])
            }
        }
        throw KaitoError.malformed("LZ4 block has no final literal sequence")
    }
}
