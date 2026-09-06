// Path: Packages/AutoMixV2/Sources/MixDiagnostics/MixDiagnosticsStore.swift

import AudioEngineCore
import Foundation
import PlaybackCoordinator

public actor MixDiagnosticsStore {
    public static let defaultCapacity = 500

    private let capacity: Int
    private var events: [MixDiagnosticEvent] = []

    public init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public func record(_ event: MixDiagnosticEvent) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func recordAudioSession(
        preferredSampleRate: Double,
        actualSampleRate: Double,
        preferredBufferDuration: Double,
        actualBufferDuration: Double
    ) {
        let message = String(
            format: "preferredRate=%.0f actualRate=%.0f preferredBuffer=%.4f actualBuffer=%.4f",
            preferredSampleRate,
            actualSampleRate,
            preferredBufferDuration,
            actualBufferDuration
        )
        record(MixDiagnosticEvent(category: "audio-session", message: message))
    }

    public func allEvents() -> [MixDiagnosticEvent] {
        events
    }

    public func clear() {
        events.removeAll(keepingCapacity: true)
    }

    public func textReport(
        coordinator: PlaybackCoordinator,
        generatedAt: Date = Date()
    ) async -> String {
        let playback = await coordinator.snapshot()
        let engine = await coordinator.engineSnapshot()
        let formatter = ISO8601DateFormatter()
        let latencyText: String
        if let latency = playback.firstSoundLatencySeconds {
            latencyText = String(format: "%.3f", latency)
        } else {
            latencyText = "n/a"
        }

        var lines: [String] = []
        lines.append("Sonivo AutoMix V2 diagnostics")
        lines.append("Generated: \(formatter.string(from: generatedAt))")
        lines.append("Phase: \(String(describing: playback.phase))")
        lines.append("Active deck: \(playback.activeDeck.rawValue)")
        lines.append("First sound latency: \(latencyText) s")
        lines.append("Engine running: \(engine.isRunning)")
        lines.append("Engine format: \(Int(engine.sampleRate)) Hz, \(engine.channels) ch")
        lines.append("PCM preload estimate: \(PCMPreloadPolicy().estimatedTotalQueuedBytes) bytes")
        lines.append("Events:")

        for event in events {
            let timestamp = formatter.string(from: event.timestamp)
            lines.append("[\(timestamp)] [\(event.level.rawValue)] [\(event.category)] \(event.message)")
        }
        return lines.joined(separator: "\n")
    }
}
