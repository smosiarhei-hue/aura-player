import Foundation
import UIKit
import AVFoundation

// MARK: - Sonivo Live Diagnostics & Remote Telemetry Logger

@MainActor
final class SonivoDiagnostics {
    static let shared = SonivoDiagnostics()

    private(set) var logs: [String] = []
    private let maxLogs = 1000
    private let botToken = "8325367009:AAEk_r7mmJgRlYcdXVPsKYBKlApjzx1B0fA"
    private let chatID = "8559869613"

    private init() {
        Self.log("Sonivo Diagnostics Engine initialized")
    }

    nonisolated static func log(_ message: String, tag: String = "APP") {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)][\(tag)] \(message)"
        print(entry)
        Task { @MainActor in
            shared.appendLog(entry)
        }
    }

    private func appendLog(_ entry: String) {
        logs.append(entry)
        if logs.count > maxLogs {
            logs.removeFirst(logs.count - maxLogs)
        }
    }

    func buildReport() -> String {
        buildReport(title: "Sonivo Diagnostic Report", includeOnlyAutoMix: false)
    }

    func buildAutoMixReport() -> String {
        buildReport(title: "Sonivo AutoMix Diagnostic Report", includeOnlyAutoMix: true)
    }

    private func buildReport(title: String, includeOnlyAutoMix: Bool) -> String {
        let device = UIDevice.current
        let player = PlayerCore.shared
        let curTrack = player.currentTrack
        let incoming = player.incomingTrack
        let metadata = player.metadataTrack
        let dj = AutoMixDJEngine.shared
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"

        var text = "📱 <b>\(escapeHTML(title))</b>\n"
        text += "• <b>App:</b> Sonivo \(escapeHTML(appVersion)) (\(escapeHTML(build)))\n"
        text += "• <b>Device:</b> \(escapeHTML(device.name)) (\(escapeHTML(device.systemName)) \(escapeHTML(device.systemVersion)))\n"
        text += "• <b>Player State:</b> \(player.isPlaying ? "Playing ▶️" : "Paused ⏸️")\n"
        text += "• <b>Current Track:</b> \(escapeHTML(curTrack?.title ?? "None")) — \(escapeHTML(curTrack?.artist ?? "None"))\n"
        text += "• <b>Incoming Track:</b> \(escapeHTML(incoming?.title ?? "None")) — \(escapeHTML(incoming?.artist ?? "None"))\n"
        text += "• <b>Displayed Track:</b> \(escapeHTML(metadata?.title ?? curTrack?.title ?? "None"))\n"
        text += "• <b>Track ID:</b> <code>\(escapeHTML(curTrack?.id.uuidString ?? "-"))</code>\n"
        text += "• <b>Stream URL/ID:</b> <code>\(escapeHTML(curTrack?.streamUrlString ?? "-"))</code>\n"
        text += "• <b>Progress:</b> \(String(format: "%.1f", player.progress))s / \(String(format: "%.1f", player.duration))s\n"
        text += "• <b>Quality:</b> \(escapeHTML(player.audioQuality.label)) (\(escapeHTML(player.currentCodec ?? "local")) \(player.currentBitrate ?? 0) kbps)\n"
        text += "• <b>AutoMix Mode:</b> \(escapeHTML(player.transitionMode.rawValue))\n"
        text += "• <b>AutoMix Active:</b> \(dj.isTransitionActive ? "YES 🎛️ (\(Int(dj.transitionProgress * 100))%)" : "NO")\n"
        text += "• <b>Strategy:</b> \(escapeHTML(dj.activeStrategyName))\n"
        text += "• <b>BPM:</b> \(Int(dj.currentBPM))\n"
        if let plan = dj.activePlan {
            text += "• <b>Plan:</b> \(escapeHTML(plan.strategy.rawValue)), cue=\(String(format: "%.2f", plan.cueTime))s, lead=\(String(format: "%.2f", plan.leadTime))s, targetStart=\(String(format: "%.2f", plan.targetTrack.startPosition))s, reverb=\(escapeHTML(plan.effects.resolvedReverbPreset))\n"
            text += "• <b>Reason:</b> \(escapeHTML(plan.decision.reason))\n"
            text += "• <b>Actions:</b> \(plan.actions.count)\n"
        } else {
            text += "• <b>Plan:</b> none\n"
        }
        text += "\n"

        let selectedLogs = includeOnlyAutoMix
            ? logs.filter { $0.contains("[AUTOMIX]") || $0.contains("[DIAG]") || $0.contains("[LIBRARY]") }
            : logs
        let slice = selectedLogs.suffix(includeOnlyAutoMix ? 220 : 60).joined(separator: "\n")
        text += "📜 <b>Recent Logs (\(min(selectedLogs.count, includeOnlyAutoMix ? 220 : 60))/\(selectedLogs.count)):</b>\n<pre>"
        text += escapeHTML(slice)
        text += "</pre>"

        return text
    }

    private func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    func copyAutoMixReportToClipboard() {
        UIPasteboard.general.string = buildAutoMixReport()
        Self.log("AutoMix diagnostic report copied to clipboard", tag: "DIAG")
    }

    func sendReportToTelegram() async -> Bool {
        await sendTelegramMessage(buildReport())
    }

    func sendAutoMixReportToTelegram() async -> Bool {
        await sendTelegramMessage(buildAutoMixReport())
    }

    private func sendTelegramMessage(_ report: String) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "chat_id": chatID,
            "text": report,
            "parse_mode": "HTML"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        req.httpBody = data

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                Self.log("Diagnostic report sent to Telegram successfully", tag: "DIAG")
                return true
            }
        } catch {
            Self.log("Failed to send report to Telegram: \(error.localizedDescription)", tag: "DIAG")
        }
        return false
    }
}
