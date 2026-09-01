import Foundation
import UIKit
import AVFoundation

// MARK: - Sonivo Live Diagnostics & Remote Telemetry Logger

@MainActor
final class SonivoDiagnostics {
    static let shared = SonivoDiagnostics()

    private(set) var logs: [String] = []
    private let maxLogs = 150
    private let botToken = "8325367009:AAEk_r7mmJgRlYcdXVPsKYBKlApjzx1B0fA"
    private let chatID = "8559869613"

    private init() {
        Self.log("Sonivo Diagnostics Engine initialized")
    }

    static func log(_ message: String, tag: String = "APP") {
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
        let device = UIDevice.current
        let player = PlayerCore.shared
        let curTrack = player.currentTrack
        let dj = AutoMixDJEngine.shared

        var text = "📱 <b>Sonivo Diagnostic Report</b>\n"
        text += "• <b>Device:</b> \(device.name) (\(device.systemName) \(device.systemVersion))\n"
        text += "• <b>Player State:</b> \(player.isPlaying ? "Playing ▶️" : "Paused ⏸️")\n"
        text += "• <b>Current Track:</b> \(curTrack?.title ?? "None") — \(curTrack?.artist ?? "None")\n"
        text += "• <b>Track ID:</b> <code>\(curTrack?.id.uuidString ?? "-")</code>\n"
        text += "• <b>Stream URL/ID:</b> <code>\(curTrack?.streamUrlString ?? "-")</code>\n"
        text += "• <b>Progress:</b> \(String(format: "%.1f", player.progress))s / \(String(format: "%.1f", player.duration))s\n"
        text += "• <b>Quality:</b> \(player.audioQuality.label) (\(player.currentCodec ?? "mp3") \(player.currentBitrate ?? 0) kbps)\n"
        text += "• <b>AutoMix Mode:</b> \(player.transitionMode.rawValue)\n"
        text += "• <b>AutoMix Active:</b> \(dj.isTransitionActive ? "YES 🎛️ (\(Int(dj.transitionProgress * 100))%)" : "NO")\n"
        text += "• <b>BPM:</b> \(Int(dj.currentBPM))\n\n"

        text += "📜 <b>Recent Event Logs (Last \(min(logs.count, 40))):</b>\n<pre>"
        let slice = logs.suffix(40).joined(separator: "\n")
        text += slice.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        text += "</pre>"

        return text
    }

    func sendReportToTelegram() async -> Bool {
        let report = buildReport()
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
