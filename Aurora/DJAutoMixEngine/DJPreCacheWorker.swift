// Path: Aurora/DJAutoMixEngine/DJPreCacheWorker.swift
import Foundation
import AVFoundation

@MainActor
public final class DJPreCacheWorker {
    public static let shared = DJPreCacheWorker()

    private let cacheDirectory: URL
    private var inFlightDownloads: [String: Task<URL, Error>] = [:]
    private var preparedTransitions: [String: PreparedTransition] = [:]

    public init() {
        let temp = FileManager.default.temporaryDirectory
        self.cacheDirectory = temp.appendingPathComponent("AutoMixDJCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    /// Извлечение чистого Yandex Music ID
    public static func yandexTrackID(from track: Track) -> String {
        var raw = track.url.lastPathComponent
        if raw.hasPrefix("ym_") { raw = String(raw.dropFirst(3)) }
        if raw.hasSuffix(".mp3") { raw = String(raw.dropLast(4)) }
        if let dot = raw.firstIndex(of: ".") { raw = String(raw[..<dot]) }
        return raw
    }

    /// Получение локального файла трека (с предварительным кешированием через Yandex API для стриминга)
    public func resolveLocalURL(for track: Track) async throws -> URL {
        if !track.isStream, track.url.isFileURL {
            return track.url
        }

        let ymID = Self.yandexTrackID(from: track)
        let destination = cacheDirectory.appendingPathComponent("\(ymID).mp3")

        if FileManager.default.fileExists(atPath: destination.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let size = attrs?[.size] as? Int ?? 0
            if size > 64 * 1024 {
                return destination
            }
        }

        if let existingTask = inFlightDownloads[ymID] {
            return try await existingTask.value
        }

        let task = Task<URL, Error> {
            let quality = PlayerCore.shared.audioQuality
            let streamInfo = try await YandexMusicService.shared.getStreamInfo(
                for: ymID,
                preferredQuality: quality,
                preferredBitrate: quality.targetBitrate
            )

            let (tempURL, _) = try await URLSession.shared.download(from: streamInfo.url)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        }

        inFlightDownloads[ymID] = task
        defer { inFlightDownloads.removeValue(forKey: ymID) }
        return try await task.value
    }

    /// Пре-кеширование предстоящего трека в фоне
    public func preCacheTrackIfNeeded(_ track: Track) {
        guard track.isStream else { return }
        Task {
            do {
                _ = try await resolveLocalURL(for: track)
                SonivoDiagnostics.log("[DJPreCache] Pre-cached Yandex Music track: \(track.title)", tag: "AUTOMIX")
            } catch {
                SonivoDiagnostics.log("[DJPreCache] Pre-cache failed for \(track.title): \(error.localizedDescription)", tag: "AUTOMIX")
            }
        }
    }

    /// Извлечение фрагмента PCM-буфера из локального аудиофайла
    nonisolated public func extractBuffer(url: URL, start: TimeInterval, duration: TimeInterval) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { throw DJSyncError.invalidBuffer }

        let startFrame = max(0, min(file.length - 1, AVAudioFramePosition(start * sampleRate)))
        let availableFrames = max(0, file.length - startFrame)
        let wantedFrames = AVAudioFramePosition(duration * sampleRate)
        let frameCount = AVAudioFrameCount(min(wantedFrames, availableFrames))
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw DJSyncError.invalidBuffer
        }

        file.framePosition = startFrame
        try file.read(into: buffer, frameCount: frameCount)
        return buffer
    }

    /// Ресемплирование буфера при несовпадении частот дискретизации
    nonisolated public func resample(buffer: AVAudioPCMBuffer, to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer {
        guard buffer.format != targetFormat,
              let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            return buffer
        }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate) + 2048
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return buffer
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: output, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }
        return output
    }

    /// Полная подготовка DJ-перехода (включая скачивание через Yandex API, анализ и офлайн-рендеринг)
    public func prepareTransition(outgoing: Track, incoming: Track, outgoingPosition: TimeInterval, totalDuration: TimeInterval) async -> PreparedTransition {
        let pairKey = "\(outgoing.id.uuidString)_\(incoming.id.uuidString)"
        if let cached = preparedTransitions[pairKey] {
            return cached
        }

        do {
            async let outURLTask = resolveLocalURL(for: outgoing)
            async let inURLTask = resolveLocalURL(for: incoming)
            let (outURL, inURL) = try await (outURLTask, inURLTask)

            // Анализ треков
            let coordinator = DJAutoMixCoordinator.shared
            async let outAnalysisTask = coordinator.analyzer.analyze(outURL)
            async let inAnalysisTask = coordinator.analyzer.analyze(inURL)
            let (outAnalysis, inAnalysis) = try await (outAnalysisTask, inAnalysisTask)

            let planResult = coordinator.planner.plan(outgoing: outAnalysis, incoming: inAnalysis)

            switch planResult {
            case .hardCut:
                preparedTransitions[pairKey] = .hardCut
                return .hardCut

            case .simpleCrossfade(let dur):
                let transition = PreparedTransition.simpleCrossfade(duration: dur)
                preparedTransitions[pairKey] = transition
                return transition

            case .djStyleMix(let plan):
                // Чтение буферов перехода
                let outBuffer = try extractBuffer(url: outURL, start: plan.outgoingExitPoint, duration: plan.duration + 0.5)
                let inRawBuffer = try extractBuffer(url: inURL, start: plan.incomingEntryPoint, duration: plan.duration + 0.5)

                // Согласование форматов
                let inBuffer = resample(buffer: inRawBuffer, to: outBuffer.format)

                // Подгонка темпа и фазы сетки
                let (alignedBuffer, _) = try coordinator.syncEngine.align(incoming: inBuffer, plan: plan, analysis: inAnalysis)

                // Офлайн-рендеринг готового перехода с EQ Bass Swap и DJ-кривой
                let mixBuffer = try await coordinator.renderer.renderTransition(plan: plan, outgoing: outBuffer, incoming: alignedBuffer)

                let prepared = PreparedTransition.offlineRenderedMix(plan: plan, buffer: mixBuffer)
                preparedTransitions[pairKey] = prepared
                SonivoDiagnostics.log("[DJPreCache] Offline DJ Mix successfully rendered: \(plan.duration)s, ratio: \(String(format: "%.3f", plan.tempoRatio))", tag: "AUTOMIX")
                return prepared
            }
        } catch {
            SonivoDiagnostics.log("[DJPreCache] DJ Transition preparation fallback: \(error.localizedDescription)", tag: "AUTOMIX")
            let fallback = PreparedTransition.simpleCrossfade(duration: 4.0)
            preparedTransitions[pairKey] = fallback
            return fallback
        }
    }

    public func clearCache() {
        preparedTransitions.removeAll()
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
