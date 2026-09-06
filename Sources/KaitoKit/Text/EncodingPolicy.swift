import Foundation

/// A policy for resolving archive entry name bytes.
public enum EncodingPolicy: Sendable, Equatable {
    /// Detects an encoding, optionally biased toward an ISO language code.
    case automatic(likelyLanguage: String? = "ja")

    /// Decodes every undecorated name using one fixed encoding.
    case fixed(String.Encoding)

    /// Accepts only UTF-8, replacing malformed input when needed.
    case utf8Only
}
