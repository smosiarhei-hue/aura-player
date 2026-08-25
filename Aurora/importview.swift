import SwiftUI
import UniformTypeIdentifiers

// MARK: - Explore & Import View (Удобный импорт музыки + Онлайн каталог)

struct ExploreView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var showDocumentPicker = false
    @State private var linkText = ""
    @State private var selectedTab: ExploreSegment = .importLocal

    enum ExploreSegment: String, CaseIterable {
        case importLocal = "Импорт файлов", online = "Онлайн-каталог"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segment Picker
                Picker("Раздел", selection: $selectedTab) {
                    ForEach(ExploreSegment.allCases, id: \.self) { seg in
                        Text(seg.rawValue).tag(seg)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if selectedTab == .importLocal {
                    localImportContent
                } else {
                    JamendoBrowseView()
                }
            }
            .navigationTitle("Обзор и импорт")
            .fileImporter(
                isPresented: $showDocumentPicker,
                allowedContentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    library.importFromPicker(urls: urls)
                }
            }
        }
    }

    // MARK: - Local Import Content

    private var localImportContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Card 1: Select files from iPhone Files App
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                            .font(.title2)
                            .foregroundStyle(settings.accentColor)
                        Text("Выбрать из «Файлов»")
                            .font(.headline.weight(.semibold))
                    }

                    Text("Выберите аудиофайлы (MP3, FLAC, M4A, WAV, AIFF) из iCloud Drive или памяти iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        showDocumentPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Выбрать файлы")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accentColor)
                }
                .liquidGlass(corner: 20, padding: 16)

                // Card 2: Transfer via Mac / PC (Finder)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "macbook.and.iphone")
                            .font(.title2)
                            .foregroundStyle(settings.accentColor)
                        Text("Перенос с компьютера")
                            .font(.headline.weight(.semibold))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Подключите iPhone к Mac по кабелю.")
                        Text("2. Откройте **Finder** → ваше устройство → вкладка **«Файлы»**.")
                        Text("3. Найдите папку **Aurora** и перетащите туда музыку.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        Task { await library.rescan() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text(library.isScanning ? "Поиск музыки..." : "Обновить медиатеку")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .disabled(library.isScanning)
                }
                .liquidGlass(corner: 20, padding: 16)

                // Card 3: Download by URL
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Image(systemName: "link.circle.fill")
                            .font(.title2)
                            .foregroundStyle(settings.accentColor)
                        Text("Скачать по прямой ссылке")
                            .font(.headline.weight(.semibold))
                    }

                    TextField("https://example.com/audio.mp3", text: $linkText)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                    if let err = library.lastError {
                        Text(err).font(.caption2).foregroundStyle(.red)
                    }

                    Button {
                        let link = linkText
                        Task {
                            await library.importFromURL(link)
                            linkText = ""
                        }
                    } label: {
                        HStack {
                            if library.importProgress != nil {
                                ProgressView().tint(.white)
                            }
                            Text(library.importProgress != nil ? "Скачивание..." : "Скачать в медиатеку")
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(settings.accentColor)
                    .disabled(linkText.isEmpty || library.importProgress != nil)
                }
                .liquidGlass(corner: 20, padding: 16)
            }
            .padding(16)
            .padding(.bottom, 80)
        }
    }
}

// MARK: - Online Discovery (Jamendo API Catalog)

struct JamendoBrowseView: View {
    @StateObject private var player = PlayerCore.shared
    @StateObject private var settings = SettingsStore.shared
    @State private var tracks: [JamendoService.JTrack] = []
    @State private var genres: [JamendoService.JGenre] = []
    @State private var selectedGenre: String? = nil
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if !genres.isEmpty {
                genrePicker
            }

            if isLoading && tracks.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Загрузка треков...").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text(errorText).font(.subheadline).foregroundStyle(.secondary)
                    Button("Повторить") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                trackList
            }
        }
        .searchable(text: $searchText, prompt: "Поиск в онлайн-каталоге")
        .onSubmit(of: .search) { Task { await search() } }
        .task { await load() }
    }

    private var genrePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    selectedGenre = nil; Task { await load() }
                } label: {
                    Text("Популярное")
                        .font(.caption.weight(selectedGenre == nil ? .semibold : .regular))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(selectedGenre == nil ? AnyShapeStyle(settings.accentGradient) : AnyShapeStyle(.primary.opacity(0.06))))
                        .foregroundStyle(selectedGenre == nil ? .white : .primary)
                }
                .buttonStyle(.plain)

                ForEach(genres) { g in
                    Button {
                        selectedGenre = g.id; Task { await loadGenre() }
                    } label: {
                        Text(g.displayName)
                            .font(.caption.weight(selectedGenre == g.id ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(selectedGenre == g.id ? AnyShapeStyle(settings.accentGradient) : AnyShapeStyle(.primary.opacity(0.06))))
                            .foregroundStyle(selectedGenre == g.id ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(tracks) { item in
                    Button {
                        playOnlineTrack(item)
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: item.coverUrl ?? "")) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    ZStack {
                                        LinearGradient(colors: settings.accent.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                                        Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8))
                                    }
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                                Text(item.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }

                            Spacer()

                            Text(formatDuration(item.duration))
                                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 80)
        }
    }

    private func playOnlineTrack(_ item: JamendoService.JTrack) {
        let t = Track(
            fileName: "online_\(item.id).mp3",
            title: item.title,
            artist: item.artist,
            album: item.album,
            duration: item.duration,
            artworkSeed: Int(item.id) ?? 42,
            isStream: true,
            streamUrlString: item.audio
        )
        player.play(t)
    }

    private func load() async {
        isLoading = true; errorText = nil
        do {
            if genres.isEmpty { genres = try await JamendoService.genres() }
            tracks = try await JamendoService.popular()
        } catch {
            errorText = "Не удалось загрузить каталог"
        }
        isLoading = false
    }

    private func loadGenre() async {
        guard let gid = selectedGenre else { return }
        isLoading = true; errorText = nil
        do {
            tracks = try await JamendoService.tracksByGenre(gid)
        } catch {
            errorText = "Ошибка загрузки жанра"
        }
        isLoading = false
    }

    private func search() async {
        guard !searchText.isEmpty else { await load(); return }
        isLoading = true; errorText = nil
        do {
            tracks = try await JamendoService.search(query: searchText)
        } catch {
            errorText = "Поиск не дал результатов"
        }
        isLoading = false
    }

    private func formatDuration(_ s: Double) -> String {
        let m = Int(s) / 60; let sec = Int(s) % 60
        return String(format: "%d:%02d", m, sec)
    }
}
