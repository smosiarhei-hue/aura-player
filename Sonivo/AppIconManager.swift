import SwiftUI
import UIKit
import Observation

enum SonivoAppIcon: String, CaseIterable, Identifiable {
    case music, signature, wordmark, classic

    var id: String { rawValue }
    var assetName: String {
        switch self {
        case .music: "SonivoMusic"
        case .signature: "SignatureS"
        case .wordmark: "SonivoWordmark"
        case .classic: "ClassicWave"
        }
    }
    /// nil restores the primary icon. Never pass its asset name as an alternate.
    var alternateName: String? { self == .music ? nil : assetName }
    var previewName: String { "AppIconPreview" + assetName }

    func title(russian: Bool) -> String {
        switch self {
        case .music: russian ? "S + звук" : "S + Sound"
        case .signature: russian ? "Фирменная S" : "Signature S"
        case .wordmark: "Sonivo"
        case .classic: russian ? "Классическая волна" : "Classic Wave"
        }
    }

    func detail(russian: Bool) -> String {
        switch self {
        case .music: russian ? "Новый знак · по умолчанию" : "New mark · default"
        case .signature: russian ? "Оригинальная буква" : "Original letter"
        case .wordmark: russian ? "Полная надпись" : "Full wordmark"
        case .classic: russian ? "Прежний знак в новом оформлении" : "Previous mark, new appearance"
        }
    }

    static func current(in application: UIApplication) -> SonivoAppIcon? {
        guard let name = application.alternateIconName else { return .music }
        return allCases.first { $0.alternateName == name }
    }
}

@Observable
@MainActor
final class AppIconManager {
    static let shared = AppIconManager()
    private(set) var selected: SonivoAppIcon?
    private(set) var isChanging = false
    var errorMessage: String?

    var supportsAlternates: Bool { UIApplication.shared.supportsAlternateIcons }

    private init() { synchronize() }

    /// iOS owns persistence; do not report a UserDefaults preference as a successful change.
    func synchronize() {
        selected = SonivoAppIcon.current(in: .shared)
    }

    func select(_ icon: SonivoAppIcon, russian: Bool) {
        guard !isChanging else { return }
        synchronize()
        guard selected != icon else { return }
        guard supportsAlternates, UIApplication.shared.applicationState == .active else {
            errorMessage = russian
                ? "Смена иконки сейчас недоступна. Попробуйте снова, когда приложение открыто."
                : "Icon changes are unavailable right now. Try again while the app is open."
            return
        }
        isChanging = true
        UIApplication.shared.setAlternateIconName(icon.alternateName) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isChanging = false
                self.synchronize()
                if let error {
                    self.errorMessage = error.localizedDescription
                } else {
                    Haptics.tap(.light)
                }
            }
        }
    }
}