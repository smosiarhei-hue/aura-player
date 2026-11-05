import AVFoundation
import Foundation

public enum AudioPreparer {
    public static func prepare(_ url: URL) async throws -> URL {
        let inFile = try AVAudioFile(forReading: url)
        let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let outFile = try AVAudioFile(forWriting: outURL, settings: outFormat.settings)
        guard let converter = AVAudioConverter(from: inFile.processingFormat, to: outFormat) else {
            throw PipelineError.converterFailed
        }
        let capacity: AVAudioFrameCount = 8192
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: capacity),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw PipelineError.converterFailed
        }
        let cursor = ReadCursor(file: inFile, buffer: inBuf)
        while true {
            var convertError: NSError?
            let status = converter.convert(to: outBuf, error: &convertError) { _, statusPtr in
                cursor.next(statusPtr)
            }
            if status == .error || convertError != nil { throw PipelineError.converterFailed }
            if outBuf.frameLength > 0 { try outFile.write(from: outBuf) }
            if status == .endOfStream { break }
        }
        return outURL
    }
}

private final class ReadCursor: @unchecked Sendable {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    private var eof = false

    init(file: AVAudioFile, buffer: AVAudioPCMBuffer) {
        self.file = file
        self.buffer = buffer
    }

    func next(_ statusPtr: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if eof {
            statusPtr.pointee = .endOfStream
            return nil
        }
        do {
            try file.read(into: buffer)
            if buffer.frameLength == 0 {
                eof = true
                statusPtr.pointee = .endOfStream
                return nil
            }
            statusPtr.pointee = .haveData
            return buffer
        } catch {
            eof = true
            statusPtr.pointee = .endOfStream
            return nil
        }
    }
}
