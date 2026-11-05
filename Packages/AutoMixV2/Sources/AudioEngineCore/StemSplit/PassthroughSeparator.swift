import Foundation

/// Used when HTDemucs.mlmodelc is not in the app bundle. The whole mix stays in `.other`.
public struct PassthroughSeparator: StemSeparating {
    public let segmentFrames = 343_980
    public init() {}

    public func separate(_ input: StereoChunk) async throws -> [StemKind: StereoChunk] {
        let n = input.frameCount
        let silent = StereoChunk(
            left: [Float](repeating: 0, count: n),
            right: [Float](repeating: 0, count: n)
        )
        return [.vocals: silent, .drums: silent, .bass: silent, .other: input]
    }
}
