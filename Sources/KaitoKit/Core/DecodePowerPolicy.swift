/// 自動復号並列数に適用する電力方針。明示した decodeThreads には作用しない。
public enum DecodePowerPolicy: Sendable, Hashable {
    /// Low Power Mode のときだけ並列数を減らす。
    case reduceInLowPowerMode
    /// Low Power Mode または serious / critical のとき並列数を減らす。
    case reduceInLowPowerModeOrThermalPressure
    /// 電力・温度による削減をしない。GiB と codec のメモリ制限は引き続き適用する。
    case alwaysUseAllCores
}
