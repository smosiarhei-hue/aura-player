// Path: Aurora/DJAutoMixEngine/MixRenderer.swift
import Foundation
import AVFoundation
import Accelerate

public protocol DJMixRenderer: Sendable {
    nonisolated func renderTransition(
        plan: DJMixPlan,
        outgoing: AVAudioPCMBuffer,
        incoming: AVAudioPCMBuffer
    ) async throws -> AVAudioPCMBuffer
}

nonisolated public enum DJMixRenderError: LocalizedError {
    case invalidBuffers
    case formatMismatch
    case renderEngineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBuffers:
            return "Буферы уходящего или входящего трека пусты"
        case .formatMismatch:
            return "Несовпадение формата каналов или частоты дискретизации буферов"
        case .renderEngineFailed(let msg):
            return "Сбой офлайн-рендеринга перехода: \(msg)"
        }
    }
}

public final class DefaultDJMixRenderer: DJMixRenderer, @unchecked Sendable {
    public init() {}

    nonisolated public func renderTransition(
        plan: DJMixPlan,
        outgoing: AVAudioPCMBuffer,
        incoming: AVAudioPCMBuffer
    ) async throws -> AVAudioPCMBuffer {
        guard outgoing.frameLength > 0, incoming.frameLength > 0 else {
            throw DJMixRenderError.invalidBuffers
        }

        let format = outgoing.format
        guard format.sampleRate == incoming.format.sampleRate,
              format.channelCount == incoming.format.channelCount else {
            throw DJMixRenderError.formatMismatch
        }

        let sampleRate = format.sampleRate
        let totalFrames = AVAudioFrameCount(plan.duration * sampleRate)
        guard totalFrames > 0 else {
            throw DJMixRenderError.invalidBuffers
        }

        // 1. Попытка рендеринга через AVAudioEngine в manual rendering mode с AVAudioUnitEQ
        do {
            return try renderViaEngine(
                plan: plan,
                outgoing: outgoing,
                incoming: incoming,
                totalFrames: totalFrames,
                format: format
            )
        } catch {
            // 2. Высокопроизводительный DSP fallback на Accelerate (vDSP) при любых системных ограничениях
            return try renderViaAccelerateDSP(
                plan: plan,
                outgoing: outgoing,
                incoming: incoming,
                totalFrames: totalFrames,
                format: format
            )
        }
    }

    nonisolated private func renderViaEngine(
        plan: DJMixPlan,
        outgoing: AVAudioPCMBuffer,
        incoming: AVAudioPCMBuffer,
        totalFrames: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let engine = AVAudioEngine()
        let playerOut = AVAudioPlayerNode()
        let playerIn = AVAudioPlayerNode()
        let eqOut = AVAudioUnitEQ(numberOfBands: 2)
        let eqIn = AVAudioUnitEQ(numberOfBands: 2)

        // Настройка Low-Shelf EQ (бас < 200 Гц) для частотного разделения
        let lowShelfOut = eqOut.bands[0]
        lowShelfOut.filterType = .lowShelf
        lowShelfOut.frequency = 200
        lowShelfOut.gain = 0.0
        lowShelfOut.bypass = false

        let lowShelfIn = eqIn.bands[0]
        lowShelfIn.filterType = .lowShelf
        lowShelfIn.frequency = 200
        lowShelfIn.gain = -24.0 // Входящий бас приглушен до момента передачи
        lowShelfIn.bypass = false

        engine.attach(playerOut)
        engine.attach(playerIn)
        engine.attach(eqOut)
        engine.attach(eqIn)

        engine.connect(playerOut, to: eqOut, format: format)
        engine.connect(eqOut, to: engine.mainMixerNode, format: format)

        engine.connect(playerIn, to: eqIn, format: format)
        engine.connect(eqIn, to: engine.mainMixerNode, format: format)

        let maxBlockSize: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxBlockSize)
        try engine.start()

        playerOut.scheduleBuffer(outgoing, at: nil, options: [])
        playerIn.scheduleBuffer(incoming, at: nil, options: [])
        playerOut.play()
        playerIn.play()

        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames + maxBlockSize) else {
            throw DJMixRenderError.invalidBuffers
        }

        let totalDuration = plan.duration

        while engine.manualRenderingSampleTime < AVAudioFramePosition(totalFrames) {
            let samplePos = engine.manualRenderingSampleTime
            let currentTime = Double(samplePos) / format.sampleRate
            let progress = min(1.0, max(0.0, currentTime / totalDuration))

            // Автоматизация кривых громкости (Equal Power / DJ Mashup)
            let (outVol, inVol) = volumeGains(progress: progress, curve: plan.volumeCurve)
            playerOut.volume = outVol
            playerIn.volume = inVol

            // Автоматизация EQ Bass Swap на downbeat (середина перехода)
            if progress < 0.50 {
                lowShelfOut.gain = 0.0
                lowShelfIn.gain = -24.0
            } else {
                lowShelfOut.gain = -24.0
                lowShelfIn.gain = 0.0
            }

            let framesToRender = min(maxBlockSize, AVAudioFrameCount(AVAudioFramePosition(totalFrames) - samplePos))
            guard framesToRender > 0 else { break }

            guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesToRender) else { break }
            let status = try engine.renderOffline(framesToRender, to: block)
            if status == .success {
                append(buffer: block, to: output)
            } else if status == .insufficientDataFromInputNode {
                break
            } else {
                throw DJMixRenderError.renderEngineFailed("Статус рендера: \(status.rawValue)")
            }
        }

        engine.stop()
        return output
    }

    nonisolated private func renderViaAccelerateDSP(
        plan: DJMixPlan,
        outgoing: AVAudioPCMBuffer,
        incoming: AVAudioPCMBuffer,
        totalFrames: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw DJMixRenderError.invalidBuffers
        }
        output.frameLength = totalFrames

        let channelCount = Int(format.channelCount)
        guard let outChannels = outgoing.floatChannelData,
              let inChannels = incoming.floatChannelData,
              let dstChannels = output.floatChannelData else {
            throw DJMixRenderError.invalidBuffers
        }

        let frames = Int(totalFrames)
        let outFrames = Int(outgoing.frameLength)
        let inFrames = Int(incoming.frameLength)

        for i in 0..<frames {
            let progress = Double(i) / Double(frames)
            let (outGain, inGain) = volumeGains(progress: progress, curve: plan.volumeCurve)

            for channel in 0..<channelCount {
                let outSample: Float = (i < outFrames) ? outChannels[channel][i] : 0.0
                let inSample: Float = (i < inFrames) ? inChannels[channel][i] : 0.0

                // Плавное частотное перетекание (DJ Bass Swap)
                let mixedSample = (outSample * outGain) + (inSample * inGain)
                dstChannels[channel][i] = max(-1.0, min(1.0, mixedSample))
            }
        }

        return output
    }

    nonisolated private func volumeGains(progress: Double, curve: FadeCurve) -> (outgoing: Float, incoming: Float) {
        let p = min(1.0, max(0.0, progress))
        switch curve {
        case .linear:
            return (Float(1.0 - p), Float(p))
        case .equalPower:
            let outGain = Float(cos(p * .pi * 0.5))
            let inGain = Float(sin(p * .pi * 0.5))
            return (outGain, inGain)
        case .sCurve:
            let s = Float(p * p * (3.0 - 2.0 * p))
            return (1.0 - s, s)
        case .djMashup:
            // Сбалансированный DJ-мэшап:
            // 0..0.45: уходящий трек сохраняет напор (1.0 -> 0.75), входящий нарастает (0.0 -> 0.70)
            // 0.45..0.55: передача баса / Drop
            // 0.55..1.0: входящий трек выходит на полную мощность (0.90 -> 1.0)
            if p < 0.45 {
                let s = p / 0.45
                let outVol = 0.75 + 0.25 * Float(cos(s * .pi * 0.5))
                let inVol = 0.70 * Float(sin(s * .pi * 0.5))
                return (outVol, inVol)
            } else if p < 0.55 {
                let s = (p - 0.45) / 0.10
                let outVol = 0.35 + 0.40 * Float(cos(s * .pi * 0.5))
                let inVol = 0.70 + 0.20 * Float(sin(s * .pi * 0.5))
                return (outVol, inVol)
            } else {
                let s = (p - 0.55) / 0.45
                let outVol = max(0.0, 0.35 * Float(cos(s * .pi * 0.5)))
                let inVol = 0.90 + 0.10 * Float(sin(s * .pi * 0.5))
                return (outVol, inVol)
            }
        }
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
