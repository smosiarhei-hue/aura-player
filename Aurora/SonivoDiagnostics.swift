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
        buildReport(title: "Sonivo Diagnostic Report", includeOnlyAutoMix: false, html: true)
    }

    func buildAutoMixReport() -> String {
        buildReport(title: "Sonivo AutoMix Diagnostic Report", includeOnlyAutoMix: true, html: true)
    }

    func buildAutoMixPlainTextReport() -> String {
        buildReport(title: "Sonivo AutoMix Diagnostic Report", includeOnlyAutoMix: true, html: false)
    }

    private func buildReport(title: String, includeOnlyAutoMix: Bool, html: Bool) -> String {
        let device = UIDevice.current
        let player = PlayerCore.shared
        let curTrack = player.currentTrack
        let incoming = player.incomingTrack
        let metadata = player.metadataTrack
        let dj = AutoMixDJEngine.shared
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"

        if html {
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
            text += formattedLogs(includeOnlyAutoMix: includeOnlyAutoMix, html: true)
            return text
        }

        var text = "📱 \(title)\n"
        text += "• App: Sonivo \(appVersion) (\(build))\n"
        text += "• Device: \(device.name) (\(device.systemName) \(device.systemVersion))\n"
        text += "• Player State: \(player.isPlaying ? "Playing" : "Paused")\n"
        text += "• Current Track: \(curTrack?.title ?? "None") — \(curTrack?.artist ?? "None")\n"
        text += "• Incoming Track: \(incoming?.title ?? "None") — \(incoming?.artist ?? "None")\n"
        text += "• Displayed Track: \(metadata?.title ?? curTrack?.title ?? "None")\n"
        text += "• Track ID: \(curTrack?.id.uuidString ?? "-")\n"
        text += "• Stream URL/ID: \(curTrack?.streamUrlString ?? "-")\n"
        text += "• Progress: \(String(format: "%.1f", player.progress))s / \(String(format: "%.1f", player.duration))s\n"
        text += "• Quality: \(player.audioQuality.label) (\(player.currentCodec ?? "local") \(player.currentBitrate ?? 0) kbps)\n"
        text += "• AutoMix Mode: \(player.transitionMode.rawValue)\n"
        text += "• AutoMix Active: \(dj.isTransitionActive ? "YES (\(Int(dj.transitionProgress * 100))%)" : "NO")\n"
        text += "• Strategy: \(dj.activeStrategyName)\n"
        text += "• BPM: \(Int(dj.currentBPM))\n"
        if let plan = dj.activePlan {
            text += "• Plan: \(plan.strategy.rawValue), cue=\(String(format: "%.2f", plan.cueTime))s, lead=\(String(format: "%.2f", plan.leadTime))s, targetStart=\(String(format: "%.2f", plan.targetTrack.startPosition))s, reverb=\(plan.effects.resolvedReverbPreset)\n"
            text += "• Reason: \(plan.decision.reason)\n"
            text += "• Actions: \(plan.actions.count)\n"
        } else {
            text += "• Plan: none\n"
        }
        text += "\n"
        text += formattedLogs(includeOnlyAutoMix: includeOnlyAutoMix, html: false)
        return text
    }

    private func formattedLogs(includeOnlyAutoMix: Bool, html: Bool) -> String {
        let selectedLogs = includeOnlyAutoMix
            ? logs.filter { $0.contains("[AUTOMIX]") || $0.contains("[DIAG]") || $0.contains("[LIBRARY]") }
            : logs
        let limit = includeOnlyAutoMix ? 220 : 60
        let slice = selectedLogs.suffix(limit).joined(separator: "\n")
        if html {
            return "📜 <b>Recent Logs (\(min(selectedLogs.count, limit))/\(selectedLogs.count)):</b>\n<pre>\(escapeHTML(slice))</pre>"
        }
        return "📜 Recent Logs (\(min(selectedLogs.count, limit))/\(selectedLogs.count)):\n\(slice)"
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
        let fileSent = await sendTelegramDocument(
            fileName: "sonivo-automix-report.txt",
            content: buildAutoMixPlainTextReport(),
            caption: "Sonivo AutoMix diagnostic report"
        )
        if fileSent { return true }
        return await sendTelegramMessage(buildAutoMixReport())
    }

    private func sendTelegramMessage(_ report: String) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendMessage") else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "chat_id": chatID,
            "text": String(report.prefix(3900)),
            "parse_mode": "HTML"
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        req.httpBody = data

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let body = String(data: data, encoding: .utf8) ?? ""
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, body.contains("\"ok\":true") {
                Self.log("Diagnostic report sent to Telegram successfully as message", tag: "DIAG")
                return true
            }
            Self.log("Telegram message failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(body.prefix(400))", tag: "DIAG")
        } catch {
            Self.log("Failed to send report to Telegram: \(error.localizedDescription)", tag: "DIAG")
        }
        return false
    }

    private func sendTelegramDocument(fileName: String, content: String, caption: String) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(botToken)/sendDocument") else { return false }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        appendFormField(name: "chat_id", value: chatID, boundary: boundary, to: &body)
        appendFormField(name: "caption", value: caption, boundary: boundary, to: &body)
        appendFileField(name: "document", fileName: fileName, mimeType: "text/plain", data: Data(content.utf8), boundary: boundary, to: &body)
        body.appendString("--\(boundary)--\r\n")
        req.httpBody = body

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            if let http = resp as? HTTPURLResponse, http.statusCode == 200, responseBody.contains("\"ok\":true") {
                Self.log("AutoMix diagnostic report sent to Telegram successfully as file", tag: "DIAG")
                return true
            }
            Self.log("Telegram document failed: HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) \(responseBody.prefix(500))", tag: "DIAG")
        } catch {
            Self.log("Failed to send AutoMix file to Telegram: \(error.localizedDescription)", tag: "DIAG")
        }
        return false
    }

    private func appendFormField(name: String, value: String, boundary: String, to body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendString("\(value)\r\n")
    }

    private func appendFileField(name: String, fileName: String, mimeType: String, data: Data, boundary: String, to body: inout Data) {
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        body.appendString("\r\n")
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
