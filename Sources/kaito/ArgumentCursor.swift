import KaitoKit

/// サブコマンドの引数を先頭から順に読む。
///
/// flag の重複や位置引数の数の検査はコマンドごとに異なるため、呼出側が行う。
struct ArgumentCursor {
    private let arguments: [String]
    private var position = 0

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    /// 次の引数を返して進む。末尾では nil。
    mutating func next() -> String? {
        guard position < arguments.count else { return nil }
        defer { position += 1 }
        return arguments[position]
    }

    /// 直前の flag に続く値を返して進む。
    ///
    /// 同じ flag の値が既にある場合（`current` が nil でない）と、値が欠けている場合は usage エラー。
    mutating func value(unlessSet current: String?) throws -> String {
        guard current == nil, let value = next() else { throw CLIError.usage(usage) }
        return value
    }
}

/// auto を含め、--threads の重複・範囲外を全コマンドで同じ規則で拒否する。
struct DecodeThreadsArgument {
    private var supplied: String?
    private(set) var value: Int?

    mutating func parse(from cursor: inout ArgumentCursor) throws {
        let text = try cursor.value(unlessSet: supplied)
        if text == "auto" { value = nil }
        else {
            guard let count = Int(text), ReaderOptions.decodeThreadsRange.contains(count) else {
                throw CLIError.usage("threads must be auto or between 1 and 1024\n\(usage)")
            }
            value = count
        }
        supplied = text
    }
}
