// D-T: テストと計測から instance 単位で渡す経路選択。既定の pair 閾値 32768 は threshold sweep で選んだ値。
struct ZstdTuning: Sendable {
    enum MatchPath: Sendable { case automatic, eightByteChunks, byteThenPeriod }
    static let defaultPairTableThreshold: Int = 32768
    var pairTableThreshold: Int = Self.defaultPairTableThreshold
    var huffmanFastLoop = true
    var matchPath: MatchPath = .automatic
    var lazySequenceRefill = true
    static let `default` = Self()
}
