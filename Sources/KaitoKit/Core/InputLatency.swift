/// 入力の往復遅延に合わせた読み取り方針。展開結果のバイト列は値によらず同じ。
/// 高遅延では 7z LZMA2 のヘッダ走査を避け、直列復号と観測した reset 点または
/// 先頭からの後方再開を使い、RAR ヘッダには適応窓を使う。また RAR5 Quick Open の
/// highLatencyInput 方針の成立条件となる。NAS 上で low を明示するとこれらはすべて無効になる。
///
/// Selects reads for input round-trip latency without changing extracted bytes. High latency
/// avoids 7z LZMA2 header scans, uses serial decoding and observed resets or the head for backward
/// seeks, enables adaptive RAR header windows, and satisfies the RAR5 Quick Open highLatencyInput
/// policy. Explicit low disables all these optimizations even on a NAS.
public enum InputLatency: Sendable, Hashable {
    /// 最上位の入力が非ローカル volume のヒントを持つ場合だけ high、それ以外は low。
    ///
    /// Resolves to high only when the top-level source reports a nonlocal volume, otherwise low.
    case automatic
    /// 低遅延入力として従来の走査と固定ヘッダ窓を使う。
    ///
    /// Uses scanning and fixed header windows for low-latency input.
    case low
    /// 高遅延入力として走査を避け、適応ヘッダ窓を使う。
    ///
    /// Avoids scans and uses adaptive header windows for high-latency input.
    case high
}
