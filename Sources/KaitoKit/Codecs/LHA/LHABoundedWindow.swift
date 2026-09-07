import Darwin

/// Copies a previously validated LHA LZ match into the caller buffer and the
/// power-of-two history window.
///
/// Token decoders validate the distance, remaining length, and output bounds
/// before entering their symbol loops. Keeping those checks at the token
/// boundary lets this shared primitive use wrapping arithmetic without a
/// throwing access in the hot path. The initial period is staged into the
/// caller buffer before the ring is updated, preserving forward-overlap LZSS
/// semantics even when either side wraps.
@inline(__always)
func lhaCopyMatch(
    window: UnsafeMutablePointer<UInt8>,
    windowMask: Int,
    windowPosition: inout Int,
    distance: Int,
    remaining: inout Int,
    output: UnsafeMutablePointer<UInt8>,
    outputPosition: inout Int,
    outputLimit: Int
) {
    let windowCount = windowMask &+ 1
    // One invocation mirrors at most one full turn of the ring. Callers keep
    // `remaining` and invoke us again, avoiding a multi-wrap raw copy when a
    // future LHA-family method permits matches larger than its dictionary.
    let count = min(
        remaining,
        min(outputLimit &- outputPosition, windowCount)
    )
    guard count > 0 else { return }

    let destination = output.advanced(by: outputPosition)

    if distance == 1 {
        let previous = window[(windowPosition &- 1) & windowMask]
        Darwin.memset(destination, Int32(previous), count)
    } else {
        let sourcePosition = (windowPosition &- distance) & windowMask
        let periodCount = min(distance, count)
        let firstSourceCount = min(periodCount, windowCount &- sourcePosition)

        destination.update(
            from: window.advanced(by: sourcePosition),
            count: firstSourceCount
        )
        if firstSourceCount < periodCount {
            destination.advanced(by: firstSourceCount).update(
                from: window,
                count: periodCount &- firstSourceCount
            )
        }

        // The first `distance` bytes are old history. Once staged, every
        // further byte is the same period repeated. Doubling already-written
        // caller output keeps every individual raw copy non-overlapping.
        var copied = periodCount
        while copied < count {
            let batch = min(copied, count &- copied)
            destination.advanced(by: copied).update(from: destination, count: batch)
            copied &+= batch
        }
    }

    let firstWindowCount = min(count, windowCount &- windowPosition)
    window.advanced(by: windowPosition).update(
        from: destination,
        count: firstWindowCount
    )
    if firstWindowCount < count {
        window.update(
            from: destination.advanced(by: firstWindowCount),
            count: count &- firstWindowCount
        )
    }

    windowPosition = (windowPosition &+ count) & windowMask
    outputPosition &+= count
    remaining &-= count
}
