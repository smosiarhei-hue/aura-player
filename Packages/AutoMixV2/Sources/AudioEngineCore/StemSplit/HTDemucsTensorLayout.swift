import Foundation

/// Validate the model's dense stereo output before pointer-based unpacking.
/// Core ML may permute axes via strides, but padded/overlapping layouts are
/// deliberately rejected rather than assuming an allocation size from count.
struct HTDemucsTensorLayout {
    let channelBases: [Int]
    let frameStride: Int

    static func checked(shape: [Int], strides: [Int], count: Int, frames: Int) -> Self? {
        guard frames > 0, shape.count == strides.count, strides.allSatisfy({ $0 > 0 }) else { return nil }
        let packed = shape == [1, 8, frames]
        let separated = shape == [1, 4, 2, frames]
        guard packed || separated else { return nil }
        let (expected, overflow) = frames.multipliedReportingOverflow(by: 8)
        guard !overflow, count == expected else { return nil }
        let axes = zip(shape, strides).filter { $0.0 > 1 }.sorted { $0.1 < $1.1 }
        var dense = 1
        for (length, stride) in axes {
            guard stride == dense else { return nil }
            let (next, overflow) = dense.multipliedReportingOverflow(by: length)
            guard !overflow else { return nil }
            dense = next
        }
        guard dense == count else { return nil }
        let bases = (0..<8).map { i in
            packed ? i * strides[1] : (i / 2) * strides[1] + (i % 2) * strides[2]
        }
        return Self(channelBases: bases, frameStride: strides.last!)
    }
}
