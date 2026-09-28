// Okumura LZSS / LArc -lz5- / LZHUF 由来の初期化値。
// LArcDecoder・LZHUFDecoder・StuffItLZAH がストリームの初期化時に共有する。

/// ゼロ初期化済みの 4096 バイト窓に LArc -lz5- の固定履歴を設定する。
/// 昇順列は 3346、降順列は 3602、空白は 3986 から始まる。
func seedLArcLZ5Window(_ window: UnsafeMutablePointer<UInt8>) {
    // 固定履歴は位置 18...4095。位置 0...17 はゼロのまま、出力の書き込み開始位置となる。
    var position = 18
    for value in 0..<256 {
        for _ in 0..<13 {
            window[position] = UInt8(value)
            position += 1
        }
    }
    for value in 0..<256 {
        window[position] = UInt8(value)
        position += 1
    }
    for value in 0..<256 {
        window[position] = UInt8(255 - value)
        position += 1
    }
    position += 128 // この範囲は呼び出し元でゼロ初期化済み。
    while position < 4_096 {
        window[position] = 0x20
        position += 1
    }
}

/// LZHUF の位置上位 6 ビットを表す 64 記号の正準符号長。
let lzhufPositionCodeLengths: [Int] = {
    var lengths = [Int](repeating: 0, count: 64)
    lengths[0] = 3
    for index in 1...3 { lengths[index] = 4 }
    for index in 4...11 { lengths[index] = 5 }
    for index in 12...23 { lengths[index] = 6 }
    for index in 24...47 { lengths[index] = 7 }
    for index in 48...63 { lengths[index] = 8 }
    return lengths
}()
