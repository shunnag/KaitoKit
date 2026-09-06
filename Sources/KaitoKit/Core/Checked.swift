/// Checked integer operations used for values read from untrusted archives.
public enum Checked {
    /// Adds two unsigned values, throwing instead of trapping on overflow.
    public static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw KaitoError.malformed("unsigned integer addition overflow")
        }
        return result
    }

    /// Subtracts two unsigned values, throwing instead of trapping on underflow.
    public static func sub(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else {
            throw KaitoError.malformed("unsigned integer subtraction underflow")
        }
        return result
    }

    /// Multiplies two unsigned values, throwing instead of trapping on overflow.
    public static func mul(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw KaitoError.malformed("unsigned integer multiplication overflow")
        }
        return result
    }

    /// Shifts an unsigned value left, validating the shift and the result.
    public static func shiftLeft(_ value: UInt64, by shift: UInt64) throws -> UInt64 {
        guard shift < UInt64(UInt64.bitWidth) else {
            throw KaitoError.malformed("invalid left-shift count")
        }
        if value == 0 {
            return 0
        }

        let availableBits = UInt64(value.leadingZeroBitCount)
        guard shift <= availableBits else {
            throw KaitoError.malformed("unsigned integer left-shift overflow")
        }
        return value << Int(shift)
    }

    /// Converts an unsigned value to `Int`, throwing if it is not representable.
    public static func toInt(_ value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw KaitoError.limitExceeded("value does not fit in Int")
        }
        return Int(value)
    }

    /// Validates a size against a configured upper bound.
    @discardableResult
    public static func size(_ value: UInt64, limit: UInt64) throws -> UInt64 {
        guard value <= limit else {
            throw KaitoError.limitExceeded("size \(value) exceeds limit \(limit)")
        }
        return value
    }
}
