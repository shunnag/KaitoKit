import Foundation

/// Errors produced while identifying, parsing, or extracting an archive.
public enum KaitoError: Error, Sendable, Equatable {
    /// The input does not use a recognized or currently readable archive format.
    case unsupportedFormat

    /// The archive uses a recognized method that is not implemented.
    case unsupportedMethod(String)

    /// The archive contains structurally invalid data.
    case malformed(String)

    /// The input ended before the requested value was complete.
    case truncated

    /// Reading the requested entry requires a password.
    case passwordRequired

    /// The supplied password did not decrypt the requested data.
    case wrongPassword

    /// An entry did not match its stored checksum.
    case checksumMismatch(entry: Int)

    /// A configured resource or allocation limit was exceeded.
    case limitExceeded(String)

    /// A POSIX I/O operation failed with the given errno value.
    case io(Int32)

    /// A requested entry or resource could not be found.
    case notFound(String)
}

extension KaitoError: LocalizedError {
    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "Unsupported archive format"
        case let .unsupportedMethod(method):
            "Unsupported archive method: \(method)"
        case let .malformed(reason):
            "Malformed archive: \(reason)"
        case .truncated:
            "The archive is truncated"
        case .passwordRequired:
            "A password is required"
        case .wrongPassword:
            "The password is incorrect"
        case let .checksumMismatch(entry):
            "Checksum mismatch for entry \(entry)"
        case let .limitExceeded(reason):
            "Read limit exceeded: \(reason)"
        case let .io(code):
            "I/O error (errno \(code))"
        case let .notFound(name):
            "Not found: \(name)"
        }
    }
}

extension KaitoError: CustomStringConvertible {
    /// A concise diagnostic suitable for command-line output.
    public var description: String {
        errorDescription ?? "KaitoKit error"
    }
}
