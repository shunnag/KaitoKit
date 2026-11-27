/// Bounds expansion while allowing small, highly compressible archives.
public struct ArchiveExpansionLimit: Sendable, Equatable {
    public let minimumAllowance: UInt64
    public let maximumRatio: UInt64

    public init(minimumAllowance: UInt64, maximumRatio: UInt64) {
        self.minimumAllowance = minimumAllowance
        self.maximumRatio = maximumRatio
    }

    public func maximumOutput(forInputBytes bytes: UInt64) -> UInt64 {
        let product = bytes.multipliedReportingOverflow(by: maximumRatio)
        return max(minimumAllowance, product.overflow ? .max : product.partialValue)
    }
}
