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
        record(MixDiagnosticEvent(
            category: "audio-session",
            message: String(
                format: "preferredRate=%.0f actualRate=%.0f preferredBuffer=%.4f actualBuffer=%.4f",
                preferredSampleRate,
                actualSampleRate,
                preferredBufferDuration,
                actualBufferDuration
            )
        ))
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
        var lines = [
            "Sonivo AutoMix V2 diagnostics",
            "Generated: \(formatter.string(from: generatedAt))",
            "Phase: \(String(describing: playback.phase))",
            "Active deck: \(playback.activeDeck.rawValue)",
            "First sound latency: \(playback.firstSoundLatencySeconds.map(String.init) ?? "n/a") s",
            "Engine running: \(engine.isRunning)",
            "Engine format: \(Int(engine.sampleRate)) Hz, \(engine.channels) ch",
            "PCM preload estimate: \(PCMPreloadPolicy().estimatedTotalQueuedBytes) bytes",
            "Events:"
        ]
        lines.append(contentsOf: events.map {
            "[\(formatter.string(from: $0.timestamp))] [\($0.level.rawValue)] [\($0.category)] \($0.message)"
        })
        return lines.joined(separator: "\n")
    }
}
