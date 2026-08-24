import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @StateObject private var library = LibraryStore.shared
    @State private var showPicker = false
    @State private var linkText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    filesCard
                    finderCard
                    linkCard
                    servicesCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Импорт")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFromPicker(urls: urls) }
            }
        }
    }

    // MARK: - Local files

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Локальные файлы", systemImage: "folder.fill")
                .font(.subheadline.weight(.semibold))
            Text("MP3, M4A/AAC, WAV, FLAC, AIFF. Файлы копируются в приложение и остаются там.")
                .font(.caption).foregroundStyle(.secondary)
            Button { showPicker = true } label: {
                Label("Выбрать файлы", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent)
        }
        .padding(16).glassCard()
    }

    // MARK: - Finder / Files app

    private var finderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Через Finder / «Файлы»", systemImage: "desktopcomputer")
                .font(.subheadline.weight(.semibold))
            step("1", "Подключите iPhone к Mac и откройте Finder")
            step("2", "Выберите устройство → «Файлы» → Aurora")
            step("3", "Перетащите музыку в папку — она появится в медиатеке")
            Button {
                Task { await library.rescan() }
            } label: {
                Label(library.isScanning ? "Поиск…" : "Обновить медиатеку", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered).disabled(library.isScanning)
        }
        .padding(16).glassCard()
    }

    // MARK: - URL import

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Импорт по ссылке", systemImage: "link")
                .font(.subheadline.weight(.semibold))
            TextField("https://example.com/song.mp3", text: $linkText)
                .keyboardType(.URL).autocapitalization(.none).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            if let p = library.importProgress {
                if p >= 0 { ProgressView(value: p) } else {
                    HStack(spacing: 8) { ProgressView(); Text("Скачивание…").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let err = library.lastError {
                Text(err).font(.caption2).foregroundStyle(.red)
            }
            Button {
                let link = linkText; Task { await library.importFromURL(link) }
            } label: {
                Label("Скачать", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(library.importProgress != nil || linkText.isEmpty)
        }
        .padding(16).glassCard()
    }

    // MARK: - Streaming services (honest)

    private var servicesCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Музыкальные сервисы — честно", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
                .padding(.bottom, 6)
            ServiceRow(icon: "music.note", name: "Spotify", status: "Каталог",
                        detail: "API отдаёт метаданные и 30-секундные превью; полное скачивание треков запрещено — ни один сторонний плеер этого не умеет.")
            ServiceRow(icon: "apple.logo", name: "Apple Music", status: "Нужен dev-аккаунт",
                        detail: "Доступ к личной библиотеке требует платного аккаунта разработчика и entitlements — с личным сертификатом eSign не работает.")
            ServiceRow(icon: "play.rectangle", name: "YT Music / VK / Яндекс", status: "DRM",
                        detail: "Загрузка треков вне официальных приложений нарушает правила сервисов. Легальный путь — купить файлы и импортировать локально.")
            Text("Поэтому Aurora строится вокруг ваших собственных файлов: локальный импорт, ссылки на прямые файлы. В следующих версиях — плейлисты по ссылкам из сервисов.")
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 6)
        }
        .padding(16).glassCard()
    }

    // MARK: - Step helper

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.caption2.weight(.bold)).frame(width: 18, height: 18)
                .background(Circle().fill(SettingsStore.shared.accentColor.opacity(0.2)))
                .foregroundStyle(SettingsStore.shared.accentColor)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Service row

private struct ServiceRow: View {
    let icon: String; let name: String; let status: String; let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 26).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name).font(.subheadline.weight(.semibold))
                    Text(status)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
