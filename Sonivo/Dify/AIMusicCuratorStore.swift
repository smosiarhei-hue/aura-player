import Foundation
import UIKit
import Combine

@MainActor
final class AIMusicCuratorStore: ObservableObject {
    static let shared = AIMusicCuratorStore()

    @Published var messages: [AIMessage] = []
    @Published var savedPlaylistTitles: Set<String> = []
    @Published var copiedToastMessage: String? = nil

    private let messagesDefaultsKey = "sonivo.ai_curator.messages.v1"
    private let savedTitlesDefaultsKey = "sonivo.ai_curator.saved_titles.v1"

    private init() {
        loadPersistedState()
    }

    // MARK: - Persistence

    func loadPersistedState() {
        if let data = UserDefaults.standard.data(forKey: messagesDefaultsKey),
           let decoded = try? JSONDecoder().decode([AIMessage].self, from: data) {
            self.messages = decoded
        }

        if let titles = UserDefaults.standard.stringArray(forKey: savedTitlesDefaultsKey) {
            self.savedPlaylistTitles = Set(titles)
        }
    }

    func savePersistedState() {
        // Save non-streaming messages
        let safeMessages = messages.map { msg -> AIMessage in
            var copy = msg
            copy.isStreaming = false
            return copy
        }

        if let encoded = try? JSONEncoder().encode(safeMessages) {
            UserDefaults.standard.set(encoded, forKey: messagesDefaultsKey)
        }

        UserDefaults.standard.set(Array(savedPlaylistTitles), forKey: savedTitlesDefaultsKey)
    }

    func clearChat() {
        messages.removeAll()
        savedPlaylistTitles.removeAll()
        UserDefaults.standard.removeObject(forKey: messagesDefaultsKey)
        UserDefaults.standard.removeObject(forKey: savedTitlesDefaultsKey)
        DifyService.shared.resetConversation()
    }

    // MARK: - Clipboard & Toast

    func copyToClipboard(_ text: String, notice: String = "Скопировано в буфер") {
        UIPasteboard.general.string = text
        Haptics.tap(.medium)
        copiedToastMessage = notice

        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.copiedToastMessage == notice {
                self.copiedToastMessage = nil
            }
        }
    }
}
