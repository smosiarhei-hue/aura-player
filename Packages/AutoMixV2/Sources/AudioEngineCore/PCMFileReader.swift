// Path: Packages/AutoMixV2/Sources/AudioEngineCore/PCMFileReader.swift

@preconcurrency import AVFAudio
import Foundation

/// A buffer is written only by the decoder, then transferred once to the control queue.
/// Neither the decoder nor control code mutates it after publication to the player.
struct DecodedPCMChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
}

/// Invariant: file/converter/input state is used exclusively on one decoder queue.
/// The converter's input block is synchronous with readChunk(); it never escapes that queue.
final class PCMFileReader: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let capacity: AVAudioFrameCount
    private var inputBuffer: AVAudioPCMBuffer?
    private var inputError: Error?
    private var finished = false

    init(fileURL: URL, startTimeSeconds: Double, policy: PCMPreloadPolicy) throws {
        guard policy.isValid, startTimeSeconds.isFinite,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: policy.sampleRate,
                                         channels: policy.channels, interleaved: false) else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }
        let sourceFile = try AVAudioFile(forReading: fileURL)
        guard let converter = AVAudioConverter(from: sourceFile.processingFormat, to: format) else {
            throw AudioEngineCoreError.cannotCreateConverter
        }
        file = sourceFile
        outputFormat = format
        capacity = AVAudioFrameCount(policy.framesPerChunk)
        self.converter = converter
        let sourceRate = file.processingFormat.sampleRate
        guard sourceRate.isFinite, sourceRate > 0 else {
            throw AudioEngineCoreError.unsupportedOutputFormat
        }
        // Clamp in seconds before converting to Int64, including enormous seek requests.
        let duration = Double(file.length) / sourceRate
        let seconds = min(max(0, startTimeSeconds), duration)
        file.framePosition = seconds >= duration ? file.length : AVAudioFramePosition(seconds * sourceRate)
    }

    func readChunk(isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> DecodedPCMChunk? {
        if isCancelled() { throw CancellationError() }
        guard !finished else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw AudioEngineCoreError.cannotCreatePCMBuffer
        }
        inputError = nil
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [self] requested, inputStatus in
            if isCancelled() {
                inputError = CancellationError()
                inputStatus.pointee = .noDataNow
                return nil
            }
            guard file.framePosition < file.length else {
                // EOF is a property of the file, never a boundary between output chunks.
                inputStatus.pointee = .endOfStream
                return nil
            }
            let count = max(1, min(requested, 4_096))
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                inputError = AudioEngineCoreError.cannotCreatePCMBuffer
                inputStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: input, frameCount: count)
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputBuffer = input
                inputStatus.pointee = .haveData
                return input
            } catch {
                inputError = error
                inputStatus.pointee = .noDataNow
                return nil
            }
        }
        if let inputError { throw inputError }
        if status == .error {
            throw AudioEngineCoreError.conversionFailed(conversionError?.localizedDescription ?? "PCM conversion failed")
        }
        if isCancelled() { throw CancellationError() }
        finished = status == .endOfStream
        guard output.frameLength > 0 else {
            if finished { return nil }
            throw AudioEngineCoreError.conversionFailed("PCM converter made no progress before EOF")
        }
        return DecodedPCMChunk(buffer: output)
    }
}

/// Invariant: reader is confined to queue; cancellation is the only cross-queue state,
/// protected by cancellationLock. No AVAudioEngine/node objects enter this worker.
final class PCMDecodeWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.sonivo.automix.pcm-decoder", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancelled = false
    private var reader: PCMFileReader?
    private let fileURL: URL
    private let startTimeSeconds: Double
    private let policy: PCMPreloadPolicy

    init(fileURL: URL, startTimeSeconds: Double, policy: PCMPreloadPolicy) {
        self.fileURL = fileURL
        self.startTimeSeconds = startTimeSeconds
        self.policy = policy
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    private var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    func next(_ completion: @escaping @Sendable (Result<DecodedPCMChunk?, Error>) -> Void) {
        queue.async { [self] in
            do {
                if isCancelled { throw CancellationError() }
                if reader == nil {
                    reader = try PCMFileReader(fileURL: fileURL, startTimeSeconds: startTimeSeconds, policy: policy)
                }
                let chunk = try reader?.readChunk(isCancelled: { self.isCancelled })
                completion(.success(chunk))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func next() async throws -> DecodedPCMChunk? {
        try await withCheckedThrowingContinuation { continuation in
            next { continuation.resume(with: $0) }
        }
    }
}
