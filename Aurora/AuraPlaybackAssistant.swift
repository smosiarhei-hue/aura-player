import AppIntents
import Foundation

@MainActor
final class AuraPlaybackAssistant {
    static let shared = AuraPlaybackAssistant()
    private init() {}

    func execute(_ rawCommand: String) -> String {
        let command = normalized(rawCommand)
        guard !command.isEmpty else { return "Скажи, что сделать с воспроизведением." }

        if containsAny(command, ["пауза", "останови", "stop", "pause"]) {
            PlaybackCommandRouter.shared.pause()
            return "Воспроизведение приостановлено."
        }

        if containsAny(command, ["следующий", "дальше", "next", "skip"]) {
            PlaybackCommandRouter.shared.next()
            return "Переключаю на следующий трек."
        }

        if containsAny(command, ["предыдущий", "назад", "previous", "back"]) {
            PlaybackCommandRouter.shared.previous()
            return "Возвращаю предыдущий трек."
        }

        if containsAny(command, ["выключи эквалайзер", "отключи эквалайзер", "eq off", "equalizer off"]) {
            PlayerCore.shared.eqEnabled = false
            return "Эквалайзер выключен."
        }

        if containsAny(command, ["включи эквалайзер", "активируй эквалайзер", "eq on", "equalizer on"]) {
            PlayerCore.shared.eqEnabled = true
            return "Эквалайзер включён независимо от AutoMix."
        }

        if containsAny(command, ["выключи автомикс", "отключи автомикс", "automix off"]) {
            AutoMixEngineSelectionStore.shared.isV2Enabled = false
            return "AutoMix выключен."
        }

        if containsAny(command, ["включи автомикс", "активируй автомикс", "automix on", "start automix"]) {
            AutoMixEngineSelectionStore.shared.isV2Enabled = true
            return "AutoMix включён."
        }

        if containsAny(command, ["включи музыку", "продолжи", "возобнови", "play music", "resume", "play"]) {
            if let requestedTrack = matchingTrack(in: command) {
                PlaybackCommandRouter.shared.play(requestedTrack, queue: LibraryStore.shared.tracks)
                return "Включаю \(requestedTrack.title)."
            }
            PlaybackCommandRouter.shared.play()
            return "Возобновляю воспроизведение."
        }

        return "Не понял команду. Попробуй: «включи музыку», «следующий трек», «включи AutoMix» или «выключи эквалайзер»."
    }

    private func matchingTrack(in command: String) -> Track? {
        let tracks = LibraryStore.shared.tracks
        let searchable = tracks.map { ($0, normalized("\($0.title) \($0.artist) \($0.album)")) }
        return searchable
            .filter { command.contains($0.1) || $0.1.split(separator: " ").contains { command.contains(String($0)) } }
            .sorted { $0.1.count > $1.1.count }
            .first?.0
    }

    private func normalized(_ value: String) -> String {
        value
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains(normalized($0)) }
    }
}

struct AuraPlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Управление Aura Player"
    static let description = IntentDescription("Управляет воспроизведением, AutoMix и эквалайзером в Aura Player.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Команда")
    var command: String

    init() {
        command = ""
    }

    init(command: String) {
        self.command = command
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let response = await MainActor.run {
            AuraPlaybackAssistant.shared.execute(command)
        }
        return .result(dialog: response)
    }
}
