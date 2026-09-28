import Foundation

/// 投げうる処理の結果を、成功した値か error の文字列として比べられる形にしたもの。ZIP の差分試験で使う。
enum ZipTestOutcome<Value: Equatable>: Equatable {
    case success(Value)
    case failure(String)
    init(_ body: () throws -> Value) {
        do { self = .success(try body()) } catch { self = .failure(String(describing: error)) }
    }
}
