import CoreML
import Foundation

public actor CoreMLStemSeparator: StemSeparating {
    public nonisolated let segmentFrames = 343_980
    private let model: MLModel

    public init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    public func separate(_ input: StereoChunk) async throws -> [StemKind: StereoChunk] {
        let n = segmentFrames
        guard input.frameCount == n else { throw PipelineError.unsupportedModel }
        let shape: [NSNumber] = [1, 2, NSNumber(value: n)]
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 2 * n)
        for i in 0..<n {
            ptr[i] = input.left[i]
            ptr[n + i] = input.right[i]
        }
        let name = model.modelDescription.inputDescriptionsByName.keys.first ?? "input"
        let provider = try MLDictionaryFeatureProvider(dictionary: [name: array])
        let clock = ContinuousClock()
        let t0 = clock.now
        let out = try await model.prediction(from: provider)
        print("HTDemucs segment \(clock.now - t0)")
        guard let y = out.featureValue(for: out.featureNames.first!)?.multiArrayValue else {
            throw PipelineError.unsupportedModel
        }
        let yPtr = y.dataPointer.bindMemory(to: Float.self, capacity: 4 * 2 * n)
        func channel(_ stem: Int, _ ch: Int) -> [Float] {
            let base = ((stem * 2) + ch) * n
            return Array(UnsafeBufferPointer(start: yPtr + base, count: n))
        }
        return [
            .drums: StereoChunk(left: channel(0, 0), right: channel(0, 1)),
            .bass: StereoChunk(left: channel(1, 0), right: channel(1, 1)),
            .other: StereoChunk(left: channel(2, 0), right: channel(2, 1)),
            .vocals: StereoChunk(left: channel(3, 0), right: channel(3, 1))
        ]
    }
}
