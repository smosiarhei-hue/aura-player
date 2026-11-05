import CoreML
import Foundation

public actor CoreMLStemSeparator: StemSeparating {
    public nonisolated let segmentFrames = 343_980
    // prediction(from:) is a nonisolated async method. An actor-isolated
    // MLModel cannot be sent into it under Swift 6, which failed the IPA build.
    private nonisolated(unsafe) let model: MLModel

    public init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        // This FP32 graph is not stable on the Neural Engine.
        config.computeUnits = .cpuOnly
        // iOS does not open an unpacked .mlpackage the way macOS does.
        // Compile once next to the download and reuse the .mlmodelc.
        let compiled = try Self.compiledURL(for: modelURL)
        self.model = try MLModel(contentsOf: compiled, configuration: config)
    }

    /// Compiled model beside the downloaded package. Rebuilt when the package is newer.
    private static func compiledURL(for url: URL) throws -> URL {
        if url.pathExtension == "mlmodelc" { return url }
        let cached = url.deletingLastPathComponent().appendingPathComponent("htdemucs.mlmodelc", isDirectory: true)
        if FileManager.default.fileExists(atPath: cached.path), !isNewer(url, than: cached) {
            return cached
        }
        let folder = url.deletingLastPathComponent()
        let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        if free > 0, free < 700_000_000 {
            throw HTDemucsModelError("мало места, чтобы открыть модель")
        }
        do {
            return try compile(url, into: cached)
        } catch let packageError {
            let inner = url.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
            guard FileManager.default.fileExists(atPath: inner.path) else { throw packageError }
            do {
                return try compile(inner, into: cached)
            } catch {
                throw HTDemucsModelError("не открылась: \(packageError.localizedDescription)")
            }
        }
    }

    private static func compile(_ source: URL, into dest: URL) throws -> URL {
        let compiled = try MLModel.compileModel(at: source)
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.moveItem(at: compiled, to: dest)
        } catch {
            try FileManager.default.copyItem(at: compiled, to: dest)
            try? FileManager.default.removeItem(at: compiled)
        }
        return dest
    }

    private static func isNewer(_ a: URL, than b: URL) -> Bool {
        let aDate = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let bDate = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let aDate, let bDate else { return false }
        return aDate > bDate
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
