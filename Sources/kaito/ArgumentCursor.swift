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

/// password の入力元・重複を全コマンドで同じ規則で検査する。
struct PasswordArgument {
    private var supplied: String?
    private var usesStdin = false

    mutating func parse(from cursor: inout ArgumentCursor) throws {
        guard !usesStdin else { throw CLIError.usage(usage) }
        supplied = try cursor.value(unlessSet: supplied)
    }

    mutating func parseStdin() throws {
        guard supplied == nil, !usesStdin else { throw CLIError.usage(usage) }
        usesStdin = true
    }

    /// 全引数の検査後に一行だけ読む。空白や CR は password の一部として保つ。
    func read() throws -> String? {
        guard usesStdin else { return supplied }
        guard var line = readLine(strippingNewline: false) else {
            throw CLIError.usage("--password-stdin: empty input")
        }
        if line.unicodeScalars.last?.value == 0x0a { line.unicodeScalars.removeLast() }
        guard !line.isEmpty else { throw CLIError.usage("--password-stdin: empty input") }
        return line
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

/// 入力遅延の値と重複を全コマンドで同じ規則で検査する。
struct InputLatencyArgument {
    private var supplied: String?
    private(set) var value: InputLatency = .automatic
    mutating func parse(from cursor: inout ArgumentCursor) throws {
        let text = try cursor.value(unlessSet: supplied)
        switch text {
        case "auto": value = .automatic
        case "low": value = .low
        case "high": value = .high
        default: throw CLIError.usage("input-latency must be auto, low or high\n\(usage)")
        }
        supplied = text
    }
}
