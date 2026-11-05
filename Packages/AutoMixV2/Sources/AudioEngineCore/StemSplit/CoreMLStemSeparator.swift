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
        let inputName = model.modelDescription.inputDescriptionsByName["mix"] != nil
            ? "mix"
            : (model.modelDescription.inputDescriptionsByName.keys.first ?? "mix")
        let inStrides = array.strides.map(\.intValue)
        let inPtr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let leftBase = inStrides.count > 1 ? inStrides[1] : n
        let step = inStrides.last ?? 1
        for i in 0..<n {
            inPtr[i * step] = input.left[i]
            inPtr[leftBase + i * step] = input.right[i]
        }
        let feature = MLFeatureValue(multiArray: array)
        let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: feature])
        let clock = ContinuousClock()
        let t0 = clock.now
        let out = try await model.prediction(from: provider)
        print("HTDemucs segment \(clock.now - t0)")
        let outputName = out.featureNames.contains("sources") ? "sources" : out.featureNames.first
        guard let outputName, let y = out.featureValue(for: outputName)?.multiArrayValue else {
            throw PipelineError.unsupportedModel
        }
        guard y.dataType == .float32 else { throw PipelineError.unsupportedModel }
        let yShape = y.shape.map(\.intValue)
        let yStrides = y.strides.map(\.intValue)
        let packedPairs = yShape.count == 3 && yShape[1] == 8 && yStrides.count == 3
        let stemMajor = yShape.count == 4 && yStrides.count == 4
        guard packedPairs || stemMajor else { throw PipelineError.unsupportedModel }
        let yPtr = y.dataPointer.bindMemory(to: Float.self, capacity: y.count)
        func channel(_ stem: Int, _ ch: Int) -> [Float] {
            var samples = [Float](repeating: 0, count: n)
            if packedPairs {
                let base = yStrides[1] * (stem * 2 + ch)
                let hop = yStrides[2]
                for i in 0..<n { samples[i] = yPtr[base + i * hop] }
            } else {
                let base = yStrides[1] * stem + yStrides[2] * ch
                let hop = yStrides[3]
                for i in 0..<n { samples[i] = yPtr[base + i * hop] }
            }
            return samples
        }
        return [
            .drums: StereoChunk(left: channel(0, 0), right: channel(0, 1)),
            .bass: StereoChunk(left: channel(1, 0), right: channel(1, 1)),
            .other: StereoChunk(left: channel(2, 0), right: channel(2, 1)),
            .vocals: StereoChunk(left: channel(3, 0), right: channel(3, 1))
        ]
    }
}
