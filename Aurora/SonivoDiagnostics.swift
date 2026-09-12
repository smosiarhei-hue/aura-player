import Foundation
import UIKit

/// Local diagnostics only. No tokens, chat identifiers, remote telemetry or
/// automatic network uploads are stored in the application.
@MainActor
final class SonivoDiagnostics {
    static let shared = SonivoDiagnostics()
    private(set) var logs: [String] = []
    private let maxLogs = 1000
    private init() { Self.log("Local diagnostics initialized", tag: "DIAG") }

    nonisolated static func log(_ message: String, tag: String = "APP") {
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        let entry = "[\(formatter.string(from: Date()))][\(tag)] \(message)"
        #if DEBUG
        print(entry)
        #endif
        Task { @MainActor in shared.append(entry) }
    }
    private func append(_ entry: String) {
        logs.append(entry)
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
    }
    func buildReport() -> String { report(title: "Sonivo Diagnostic Report", autoMixOnly: false) }
    func buildAutoMixReport() -> String { report(title: "Sonivo AutoMix Diagnostic Report", autoMixOnly: true) }
    func buildAutoMixPlainTextReport() -> String { buildAutoMixReport() }

    private func report(title: String, autoMixOnly: Bool) -> String {
        let v2 = AutoMixV2Runtime.shared
        let track = v2.currentTrack ?? PlayerCore.shared.currentTrack
        let selected = autoMixOnly ? logs.filter { $0.contains("[AUTOMIX]") || $0.contains("[DIAG]") } : logs
        return """
        \(title)
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
        Device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Player: \(v2.isPlaying || PlayerCore.shared.isPlaying ? "playing" : "paused")
        Track: \(track?.title ?? "None") — \(track?.artist ?? "None")
        V2 error: \(v2.lastError ?? "none")

        Recent local logs (\(min(selected.count, 220))/\(selected.count)):
        \(selected.suffix(220).joined(separator: "\n"))
        """
    }
    func copyAutoMixReportToClipboard() {
        UIPasteboard.general.string = buildAutoMixReport()
        Self.log("Diagnostic report copied locally", tag: "DIAG")
    }
    func sendReportToTelegram() async -> Bool {
        Self.log("Remote diagnostic upload is disabled; copy the local report instead", tag: "DIAG")
        return false
    }
    func sendAutoMixReportToTelegram() async -> Bool { await sendReportToTelegram() }
}
