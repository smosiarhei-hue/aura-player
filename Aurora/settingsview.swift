import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsStore.shared
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Оформление") {
                    Picker("Тема", selection: $settings.theme) {
                        ForEach(AppTheme.allCases) { t in Text(t.name).tag(t) }
                    }
                    HStack {
                        Text("Акцент")
                        Spacer()
                        ForEach(AccentChoice.allCases) { a in
                            Button { settings.accent = a } label: {
                                Circle()
                                    .fill(LinearGradient(colors: a.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 26, height: 26)
                                    .overlay(Circle().strokeBorder(settings.accent == a ? Color.primary : .clear, lineWidth: 2.5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section("Воспроизведение") {
                    Toggle("Automix (плавный переход)", isOn: $player.automixEnabled)
                        .tint(settings.accentColor)
                    LabeledContent("Длительность перехода", value: "2.0 сек")
                        .foregroundStyle(.secondary)
                }
                Section("Тактильная отдача") {
                    Toggle("Вибрация при управлении", isOn: $settings.hapticsEnabled)
                        .tint(settings.accentColor)
                    Toggle("Вибрация при перемотке", isOn: $settings.scrubHapticsEnabled)
                        .tint(settings.accentColor)
                }
                Section("Медиатека") {
                    LabeledContent("Треков", value: "\(library.tracks.count)")
                    Button(role: .destructive) { library.resetIndex() } label: {
                        Text("Сбросить индекс медиатеки")
                    }
                }
                Section("О приложении") {
                    LabeledContent("Версия", value: appVersion)
                    LabeledContent("Сборка", value: "GitHub Actions · unsigned IPA · подпись eSign/GBox")
                    Text("Aurora — персональный плеер с эквалайзером, спектром и живыми обложками.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Настройки")
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}