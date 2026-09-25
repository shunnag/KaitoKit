@_spi(TarEditLayout) internal import KaitoKit

func tarGoldenOptions(_ options: ReaderOptions, recording: Bool) -> ReaderOptions {
    var result = options
    result.recordsTarEditLayout = recording
    return result
}
