import SwiftUI

/// Settings use the app's semantic surfaces, typography and hit targets.
struct SonivoSettingsFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(SN.text(.body))
            .scrollContentBackground(.hidden)
            .background(SonivoScreenBackground(
                colors: [SN.bgRaised, SN.bg, SN.card], showsMesh: false
            ))
            .listRowBackground(SN.card.opacity(0.78))
            .listRowSeparatorTint(SN.ink.opacity(0.10))
            .tint(SN.accent)
    }
}

struct SettingsNavigationRow: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(SN.glyph())
                .foregroundStyle(SN.accent)
                .frame(width: SN.tapTarget, height: SN.tapTarget)
                .background(SN.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: SN.radiusSmall))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(SN.text(.body, .medium))
                    .foregroundStyle(SN.ink)
                Text(subtitle)
                    .font(SN.text(.footnote))
                    .foregroundStyle(SN.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 5)
        }
        .frame(minHeight: SN.tapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

enum SonivoSettingsCategory: String, CaseIterable, Identifiable {
    case music, playback, appearance, lyrics, lyricsSources, haptics, storage, about
    var id: String { rawValue }

    func title(russian: Bool) -> String {
        switch self {
        case .music: russian ? "Аккаунты и музыка" : "Accounts & music"
        case .playback: russian ? "Звук и воспроизведение" : "Sound & playback"
        case .appearance: russian ? "Оформление" : "Appearance"
        case .lyrics: russian ? "Тексты песен" : "Lyrics"
        case .lyricsSources: russian ? "Источники текста" : "Lyrics sources"
        case .haptics: russian ? "Вибрация" : "Haptics"
        case .storage: russian ? "Медиатека и хранилище" : "Library & storage"
        case .about: russian ? "О приложении" : "About"
        }
    }

    func subtitle(russian: Bool) -> String {
        switch self {
        case .music: russian ? "Вход, синхронизация и источник поиска" : "Sign-in, sync & search source"
        case .playback: russian ? "Качество, эквалайзер и переходы" : "Quality, equalizer & transitions"
        case .appearance: russian ? "Тема, иконка, шрифт и видео" : "Theme, icon, font & video"
        case .lyrics: russian ? "Оформление, синхронизация и источники" : "Style, timing & sources"
        case .lyricsSources: "Musixmatch"
        case .haptics: russian ? "Отклик управления и ритм музыки" : "Control feedback & music rhythm"
        case .storage: russian ? "Локальные треки, индекс и кэш" : "Local tracks, index & cache"
        case .about: russian ? "Версия, сборка и интерфейс" : "Version, build & interface"
        }
    }

    var symbol: String {
        switch self {
        case .music: "person.crop.circle"
        case .playback: "slider.horizontal.3"
        case .appearance: "paintpalette"
        case .lyrics: "text.alignleft"
        case .lyricsSources: "link"
        case .haptics: "waveform"
        case .storage: "externaldrive"
        case .about: "info.circle"
        }
    }
}