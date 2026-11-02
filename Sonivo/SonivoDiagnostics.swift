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
        // Session log already mirrors into this ring with AUTOMIX_LOG — skip echo loops.
        if entry.contains("[AUTOMIX_LOG]") { return }
        logs.append(entry)
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
    }
    func buildReport() -> String { report(title: "Sonivo Diagnostic Report", autoMixOnly: false) }
    func buildAutoMixReport() -> String {
        let session = AutoMixSessionLog.shared.buildReport()
        let ring = report(title: "Sonivo AutoMix Diagnostic Ring", autoMixOnly: true)
        return session + "\n\n---- ring buffer ----\n" + ring
    }
    func buildAutoMixPlainTextReport() -> String { buildAutoMixReport() }

    private func report(title: String, autoMixOnly: Bool) -> String {
        let v2 = AutoMixV2Runtime.shared
        let track = v2.currentTrack ?? PlayerCore.shared.currentTrack
        let selected: [String]
        if autoMixOnly {
            selected = logs.filter {
                $0.contains("[AUTOMIX]") || $0.contains("[AUDIO]") || $0.contains("[DIAG]")
                    || $0.contains("[ACTION]") || $0.contains("Mashup") || $0.contains("LAND")
            }
        } else {
            selected = logs
        }
        return """
        \(title)
        App: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")
        Device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Player: \(v2.isPlaying || PlayerCore.shared.isPlaying ? "playing" : "paused")
        Track: \(track?.title ?? "None") — \(track?.artist ?? "None")
        Mode: \(PlayerCore.shared.transitionMode.rawValue)
        V2 error: \(v2.lastError ?? "none")

        Recent local logs (\(min(selected.count, 220))/\(selected.count)):
        \(selected.suffix(220).joined(separator: "\n"))
        """
    }
    func copyAutoMixReportToClipboard() {
        UIPasteboard.general.string = buildAutoMixReport()
        Self.log("AutoMix session log copied locally", tag: "DIAG")
    }
    func sendReportToTelegram() async -> Bool {
        // Local-only: put the AutoMix session flight recorder on the pasteboard.
        copyAutoMixReportToClipboard()
        return true
    }
    func sendAutoMixReportToTelegram() async -> Bool { await sendReportToTelegram() }
}
