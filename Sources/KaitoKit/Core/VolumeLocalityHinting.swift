protocol VolumeLocalityHinting {
    var isOnNonLocalVolume: Bool { get }
}

func byteSourceIsOnNonLocalVolume(_ source: any ByteSource) -> Bool {
    (source as? any VolumeLocalityHinting)?.isOnNonLocalVolume ?? false
}
