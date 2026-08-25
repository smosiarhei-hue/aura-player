import SwiftUI
import UniformTypeIdentifiers

// MARK: - Explore (обзор + импорт)

struct ExploreView: View {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var player = PlayerCore.shared
    @State private var showPicker = false
    @State private var linkText = ""
    @State private var searchText = ""
    @State private var selectedTab: ExploreTab = .browse
    
    enum ExploreTab: String, CaseIterable {
        case browse, local, link
        var label: String {
            switch self {
            case .browse: return "Каталог"
            case .local:  return "Файлы"
            case .link:   return "Ссылка"
            }
        }
        var icon: String {
            switch self {
            case .browse: return "compass"
            case .local:  return "folder"
            case .link:   return "link"
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabPicker
                Group {
                    switch selectedTab {
                    case .browse: DeezerBrowseView()
                    case .local:  localImport
                    case .link:   linkImport
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Обзор")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFromPicker(urls: urls) }
            }
        }
    }
    
    private var tabPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ExploreTab.allCases, id: \.rawValue) { tab in
                    Button { withAnimation(.spring(response: 0.3)) { selectedTab = tab } } label: {
                        Label(tab.label, systemImage: tab.icon)
                            .font(.subheadline.weight(selectedTab == tab ? .semibold : .regular))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(
                                Capsule().fill(selectedTab == tab
                                    ? AnyShapeStyle(SettingsStore.shared.accentGradient)
                                    : AnyShapeStyle(.primary.opacity(0.06)))
                            )
                            .foregroundStyle(selectedTab == tab ? .white : .primary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
    
    private var localImport: some View {
        ScrollView {
            VStack(spacing: 16) {
                filesCard
                finderCard
            }
            .padding(16)
        }
    }
    
    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Локальные файлы", systemImage: "folder.fill")
                .font(.subheadline.weight(.semibold))
            Text("MP3, M4A/AAC, WAV, FLAC, AIFF")
                .font(.caption).foregroundStyle(.secondary)
            Button { showPicker = true } label: {
                Label("Выбрать файлы", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.borderedProminent).tint(SettingsStore.shared.accentColor)
        }
        .liquidGlass(corner: 24, padding: 16)
    }
    
    private var finderCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Через «Файлы»", systemImage: "desktopcomputer")
                .font(.subheadline.weight(.semibold))
            Text("Подключите iPhone к Mac → Finder → Файлы → Aurora → перетащите музыку.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                Task { await library.rescan() }
            } label: {
                Label(library.isScanning ? "Поиск…" : "Обновить", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.bordered).disabled(library.isScanning)
        }
        .liquidGlass(corner: 24, padding: 16)
    }
    
    private var linkImport: some View {
        ScrollView {
            VStack(spacing: 16) {
                linkCard
            }
            .padding(16)
        }
    }
    
    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Импорт по ссылке", systemImage: "link")
                .font(.subheadline.weight(.semibold))
            TextField("https://…song.mp3", text: $linkText)
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
            .buttonStyle(.borderedProminent).tint(SettingsStore.shared.accentColor)
            .disabled(library.importProgress != nil || linkText.isEmpty)
        }
        .liquidGlass(corner: 24, padding: 16)
    }
}

// MARK: - Deezer Browse

struct DeezerBrowseView: View {
    @StateObject private var player = PlayerCore.shared
    @State private var tracks: [DeezerService.DzTrack] = []
    @State private var genres: [DeezerService.DzGenre] = []
    @State private var selectedGenre: Int? = nil
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var error: String? = nil
    @State private var isChart = true
    
    var body: some View {
        VStack(spacing: 0) {
            if !genres.isEmpty {
                genreScroller
            }
            Group {
                if isLoading && tracks.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Загрузка…").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                        Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                        Button("Повторить") { Task { await load() } }.buttonStyle(.borderedProminent).tint(SettingsStore.shared.accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    trackList
                }
            }
        }
        .searchable(text: $searchText, prompt: "Поиск треков, артистов")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: searchText) { _ in
                if searchText.isEmpty { Task { await load() } }
            }
            .task { await load() }
    }
    
    private var genreScroller: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "Чарт", isActive: selectedGenre == nil && isChart) {
                    selectedGenre = nil; isChart = true; Task { await load() }
                }
                ForEach(genres) { g in
                    FilterChip(label: g.name, isActive: selectedGenre == g.id) {
                        selectedGenre = g.id; isChart = false; Task { await loadGenre() }
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }
    
    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(tracks) { track in
                    deezerRow(track)
                }
                if tracks.isEmpty && !isLoading {
                    Text("Ничего не найдено").font(.subheadline).foregroundStyle(.secondary).padding(.top, 40)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 80)
        }
    }
    
    private func deezerRow(_ track: DeezerService.DzTrack) -> some View {
        Button {
            playDeezer(track)
        } label: {
            HStack(spacing: 12) {
                // Album art
                AsyncImage(url: URL(string: track.coverUrl)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ZStack {
                            LinearGradient(colors: SettingsStore.shared.accent.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "music.note").foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.body.weight(.medium)).lineLimit(1).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(track.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Text("·").foregroundStyle(.quaternary)
                        Text(track.albumName).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer()
                // Preview badge
                Text("30с")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.primary.opacity(0.06)))
                    .foregroundStyle(.quaternary)
                Text(formatDuration(Double(track.duration)))
                    .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func playDeezer(_ track: DeezerService.DzTrack) {
        guard let previewUrl = URL(string: track.preview) else { return }
        let fakeTrack = Track(
            fileName: "deezer_\(track.id).mp3",
            title: track.title,
            artist: track.artistName,
            album: track.albumName,
            duration: 30.0,
            artworkSeed: track.id
        )
        player.playJamendoStream(fakeTrack, streamURL: previewUrl)
    }
    
    private func load() async {
        isLoading = true; error = nil
        do {
            if genres.isEmpty { genres = try await DeezerService.genres() }
            tracks = try await DeezerService.charts()
            isChart = true; selectedGenre = nil
        } catch { self.error = "Не удалось загрузить каталог. Проверьте интернет." }
        isLoading = false
    }
    
    private func loadGenre() async {
        guard let gid = selectedGenre else { return }
        isLoading = true; error = nil
        do {
            tracks = try await DeezerService.genreChart(gid)
        } catch { self.error = "Ошибка загрузки жанра." }
        isLoading = false
    }
    
    private func search() async {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { await load(); return }
        isLoading = true; error = nil
        do {
            tracks = try await DeezerService.search(query: searchText)
        } catch { self.error = "Ошибка поиска." }
        isLoading = false
    }
    
    private func formatDuration(_ seconds: Double) -> String {
        let m = Int(seconds) / 60; let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Filter chip

private struct FilterChip: View {
    let label: String; let isActive: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(isActive ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive
                        ? AnyShapeStyle(SettingsStore.shared.accentGradient)
                        : AnyShapeStyle(.primary.opacity(0.06)))
                )
                .foregroundStyle(isActive ? .white : .secondary)
        }.buttonStyle(.plain)
    }
}