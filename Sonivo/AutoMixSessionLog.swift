import Foundation
import UIKit

/// Second-by-second AutoMix/Duet flight recorder for field debugging.
/// Copy the report from Settings / player menu and paste it in chat.
@MainActor
final class AutoMixSessionLog {
    static let shared = AutoMixSessionLog()

    private let defaultsKey = "automix.sessionLog.enabled"
    private let maxLines = 2_400
    private var lines: [String] = []
    private var heartbeat: Timer?
    private var lastActionFingerprint = ""
    private var lastTickPos: Double?
    private var stuckTickCount = 0
    private var lastFrozenFaultAt: Date?
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// On by default so a user can reproduce once and share logs without digging.
    var isEnabled: Bool {
        get {
            if defaults.object(forKey: defaultsKey) == nil { return true }
            return defaults.bool(forKey: defaultsKey)
        }
        set {
            defaults.set(newValue, forKey: defaultsKey)
            if newValue {
                action("log.enabled")
                startHeartbeatIfNeeded()
            } else {
                action("log.disabled")
                stopHeartbeat()
            }
        }
    }

    private var defaults: UserDefaults { .standard }

    private init() {
        appendRaw("BOOT AutoMix session log ready (enabled=\(isEnabled))")
        startHeartbeatIfNeeded()
    }

    // MARK: - Public API

    func action(_ name: String, details: String = "") {
        guard isEnabled else { return }
        let payload = details.isEmpty ? name : "\(name) | \(details)"
        append(tag: "ACTION", payload)
        // Force an immediate state snapshot after meaningful user actions.
        // Skip while PlayerCore.shared is still initializing — snapshot would
        // re-enter its dispatch_once and SIGTRAP ("trying to lock recursively").
        if PlayerCore.isSharedReady,
           ["seek", "play", "pause", "next", "previous", "toggle", "mode", "scrub"].contains(where: { name.hasPrefix($0) }) {
            snapshot(tag: "STATE")
        }
    }

    func event(_ message: String) {
        guard isEnabled else { return }
        append(tag: "EVENT", message)
    }

    /// High-signal AutoMix fault — forces an immediate STATE snapshot for field triage.
    /// Use for bake/LAND/playback freezes so pasted reports always include context.
    func fault(_ message: String) {
        guard isEnabled else { return }
        append(tag: "FAULT", message)
        if PlayerCore.isSharedReady {
            snapshot(tag: "STATE")
        }
        SonivoDiagnostics.log("[AUTOMIX] FAULT \(message)", tag: "AUTOMIX")
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        lastTickPos = nil
        stuckTickCount = 0
        lastFrozenFaultAt = nil
        appendRaw("CLEARED session log")
    }

    func buildReport() -> String {
        guard let core = playerCoreIfReady() else {
            return """
            Sonivo AutoMix Session Log
            Generated: \(ISO8601DateFormatter().string(from: Date()))
            PlayerCore: not ready
            Lines: \(lines.count)

            """ + lines.joined(separator: "\n")
        }
        let track = core.displayTrack ?? core.currentTrack
        let header = """
        Sonivo AutoMix Session Log
        Generated: \(ISO8601DateFormatter().string(from: Date()))
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))
        Device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Mode: \(core.transitionMode.rawValue)
        Playing: \(core.isPlaying)
        Track: \(track?.title ?? "none") — \(track?.artist ?? "none")
        Lines: \(lines.count)

        """
        return header + lines.joined(separator: "\n")
    }

    func copyReportToClipboard() {
        if PlayerCore.isSharedReady {
            snapshot(tag: "STATE")
        }
        UIPasteboard.general.string = buildReport()
        append(tag: "ACTION", "clipboard.copy lines=\(lines.count)")
        SonivoDiagnostics.log("AutoMix session log copied (\(lines.count) lines)", tag: "DIAG")
    }

    func ensureHeartbeat() {
        startHeartbeatIfNeeded()
    }

    // MARK: - Heartbeat

    private func startHeartbeatIfNeeded() {
        guard isEnabled else { return }
        guard heartbeat == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.heartbeatTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
    }

    private func stopHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = nil
    }

    private func heartbeatTick() {
        guard isEnabled else { return }
        guard let core = playerCoreIfReady() else { return }
        // Keep a continuous trail while playing, transitioning, or shortly after actions.
        if core.isPlaying || core.isTransitioningPublic || AutoMixDJEngine.shared.isTransitionActive {
            snapshot(tag: "TICK")
            detectFrozenPlayback(core)
        } else {
            lastTickPos = nil
            stuckTickCount = 0
        }
    }

    /// Catch the classic "play=1 but timecode stuck" Automix LAND hang without waiting
    /// for the user to notice — one FAULT every 20s max.
    private func detectFrozenPlayback(_ core: PlayerCore) {
        guard core.isPlaying else { return }
        // Buffering at stream start is expected; don't spam FAULT.
        if core.usesStreamingBackend, core.isStreamBuffering { return }
        let pos = core.playbackProgress
        defer { lastTickPos = pos }
        guard let last = lastTickPos, abs(pos - last) < 0.08 else {
            stuckTickCount = 0
            return
        }
        stuckTickCount += 1
        guard stuckTickCount >= 5 else { return }
        if let lastFault = lastFrozenFaultAt, Date().timeIntervalSince(lastFault) < 20 { return }
        lastFrozenFaultAt = Date()
        stuckTickCount = 0
        if !core.isTransitioningPublic, core.usesStreamingBackend {
            core.kickFrozenStreamIfNeeded()
        }
        fault(
            String(
                format: "playback.frozen pos=%.1f dur=%.1f tx=%d bake=%d stream=%d track=%@",
                pos,
                core.playbackDuration,
                core.isTransitioningPublic ? 1 : 0,
                core.mashupBakeActivePublic ? 1 : 0,
                core.usesStreamingBackend ? 1 : 0,
                core.currentTrack?.title ?? "-"
            )
        )
    }

    private func snapshot(tag: String) {
        guard let core = playerCoreIfReady() else { return }
        let dj = AutoMixDJEngine.shared
        let current = core.currentTrack
        let incoming = core.incomingTrackPublic
        let display = core.displayTrack
        let line = [
            "mode=\(shortMode(core.transitionMode))",
            "play=\(core.isPlaying ? 1 : 0)",
            "stream=\(core.usesStreamingBackend ? 1 : 0)",
            "tx=\(core.isTransitioningPublic ? 1 : 0)",
            "txReady=\(core.incomingLaneReadyPublic ? 1 : 0)",
            "txP=\(String(format: "%.3f", dj.transitionProgress))",
            "badge=\(dj.statusBadge ?? "-")",
            "pos=\(String(format: "%.1f", core.playbackProgress))",
            "dur=\(String(format: "%.1f", core.playbackDuration))",
            "dispPos=\(String(format: "%.1f", core.displayProgress))",
            "A=\(shortTrack(current))",
            "B=\(shortTrack(incoming))",
            "UI=\(shortTrack(display))",
            "bake=\(core.mashupBakeActivePublic ? 1 : 0)",
            "volA=\(String(format: "%.2f", core.activeDeckVolumePublic))",
            "volB=\(String(format: "%.2f", core.idleDeckVolumePublic))",
            "rateA=\(String(format: "%.3f", core.mashupLockedRateAPublic))",
            "rateB=\(String(format: "%.3f", core.mashupLockedRateBPublic))",
            "pitchB=\(String(format: "%.0f", core.mashupPitchCentsBPublic))",
            "err=\(core.playError ?? "-")"
        ].joined(separator: " ")
        // Dedupe identical ACTION-adjacent STATE spam within the same second fingerprint.
        let fingerprint = "\(tag)|\(line)"
        if tag == "STATE", fingerprint == lastActionFingerprint { return }
        lastActionFingerprint = fingerprint
        append(tag: tag, line)
    }

    /// Never touch `PlayerCore.shared` until its `dispatch_once` has finished.
    private func playerCoreIfReady() -> PlayerCore? {
        PlayerCore.isSharedReady ? PlayerCore.shared : nil
    }

    // MARK: - Helpers

    private func shortMode(_ mode: TransitionMode) -> String {
        switch mode {
        case .automix: return "automix"
        case .duet: return "duet"
        case .crossfade: return "xfade"
        case .gapless: return "gapless"
        case .off: return "off"
        }
    }

    private func shortTrack(_ track: Track?) -> String {
        guard let track else { return "-" }
        let title = track.title.replacingOccurrences(of: "|", with: "/")
        let clipped = title.count > 28 ? String(title.prefix(27)) + "…" : title
        return "\(clipped)#\(track.id.uuidString.prefix(6))"
    }

    private func append(tag: String, _ message: String) {
        appendRaw("[\(timeFormatter.string(from: Date()))][\(tag)] \(message)")
    }

    private func appendRaw(_ entry: String) {
        lines.append(entry)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        #if DEBUG
        print(entry)
        #endif
    }
}
