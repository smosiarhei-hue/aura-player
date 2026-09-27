// Path: Aurora/DJAutoMixEngine/SyncEngine.swift
import Foundation
import AVFoundation

public protocol DJSyncEngine: Sendable {
    nonisolated func align(
        incoming: AVAudioPCMBuffer,
        plan: DJMixPlan,
        analysis: DJTrackAnalysis
    ) throws -> (buffer: AVAudioPCMBuffer, phaseOffset: TimeInterval)
}

nonisolated public enum DJSyncError: LocalizedError {
    case invalidBuffer
    case engineFailed(String)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .invalidBuffer:
            return "Недопустимый или пустой PCM-буфер"
        case .engineFailed(let reason):
            return "Сбой AVAudioEngine при подгонке темпа: \(reason)"
        case .unsupportedFormat:
            return "Формат аудио не поддерживается для offline-рендеринга"
        }
    }
}

public final class DefaultDJSyncEngine: DJSyncEngine, Sendable {
    public init() {}

    nonisolated public func align(
        incoming: AVAudioPCMBuffer,
        plan: DJMixPlan,
        analysis: DJTrackAnalysis
    ) throws -> (buffer: AVAudioPCMBuffer, phaseOffset: TimeInterval) {
        guard incoming.frameLength > 0 else {
            throw DJSyncError.invalidBuffer
        }

        // 1. Расчет сдвига фазы: находим ближайшую долю в beatGrid относительно incomingEntryPoint
        let entryPoint = plan.incomingEntryPoint
        var phaseOffset: TimeInterval = 0.0
        if let nearestBeat = analysis.beatGrid.min(by: { abs($0 - entryPoint) < abs($1 - entryPoint) }) {
            phaseOffset = nearestBeat - entryPoint
        }

        // 2. Если темп совпадает (tempoRatio ≈ 1.0), растяжение не требуется
        let ratio = plan.tempoRatio
        if abs(ratio - 1.0) < 0.002 {
            return (incoming, phaseOffset)
        }

        // 3. Тайм-стретчинг без изменения высоты тона через AVAudioUnitTimePitch в manual rendering mode
        let stretched = try timeStretch(buffer: incoming, rate: Float(ratio))
        return (stretched, phaseOffset)
    }

    nonisolated private func timeStretch(buffer: AVAudioPCMBuffer, rate: Float) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()

        timePitch.rate = max(0.5, min(2.0, rate))
        timePitch.pitch = 0.0

        engine.attach(player)
        engine.attach(timePitch)

        let format = buffer.format
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        // Ожидаемое количество фреймов после растяжки
        let estimatedFrames = AVAudioFrameCount(Double(buffer.frameLength) / Double(rate))
        let maxFramesPerRender: AVAudioFrameCount = 4096

        do {
            try engine.enableManualRenderingMode(
                .offline,
                format: format,
                maximumFrameCount: maxFramesPerRender
            )
            try engine.start()
        } catch {
            throw DJSyncError.engineFailed("Включение manual rendering mode не удалось: \(error.localizedDescription)")
        }

        player.scheduleBuffer(buffer, at: nil, options: [])
        player.play()

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: estimatedFrames + maxFramesPerRender * 2) else {
            throw DJSyncError.invalidBuffer
        }

        while engine.manualRenderingSampleTime < AVAudioFramePosition(estimatedFrames) {
            let framesToRender = min(maxFramesPerRender, AVAudioFrameCount(AVAudioFramePosition(estimatedFrames) - engine.manualRenderingSampleTime))
            guard framesToRender > 0 else { break }

            guard let blockBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRender) else { break }

            let status = try engine.renderOffline(framesToRender, to: blockBuffer)
            switch status {
            case .success:
                append(buffer: blockBuffer, to: outputBuffer)
            case .insufficientDataFromInputNode:
                break
            case .cannotDoInCurrentContext, .error:
                throw DJSyncError.engineFailed("Ошибка рендера блока timePitch")
            @unknown default:
                break
            }

            if blockBuffer.frameLength == 0 {
                break
            }
        }

        engine.stop()
        return outputBuffer
    }

    nonisolated private func append(buffer source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }
        let channelCount = Int(source.format.channelCount)
        let sourceFrames = Int(source.frameLength)
        let destCapacity = Int(destination.frameCapacity)
        let destFrames = Int(destination.frameLength)

        let framesToCopy = min(sourceFrames, destCapacity - destFrames)
        guard framesToCopy > 0 else { return }

        if let srcFloat = source.floatChannelData, let dstFloat = destination.floatChannelData {
            for channel in 0..<channelCount {
                let srcPtr = srcFloat[channel]
                let dstPtr = dstFloat[channel].advanced(by: destFrames)
                dstPtr.update(from: srcPtr, count: framesToCopy)
            }
        }

        destination.frameLength = AVAudioFrameCount(destFrames + framesToCopy)
    }
}
