import SwiftUI

/// This screen never converts Spotify IDs into Yandex tracks or writes to the playback queue.
struct SpotifyCatalogSearchView: View {
    @State private var query = ""
    @State private var results: [SpotifyCatalogTrack] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedTrack: SpotifyCatalogTrack?
    @State private var retry = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Поиск в Spotify через wolfXspotify. Это каталог, не полный стриминг. Выбор каталога не меняет текущую музыку Sonivo.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("Каталог Spotify", systemImage: "magnifyingglass",
                        description: Text("Найдите трек, откройте его в Spotify или прослушайте доступное превью в браузере."))
                } else if isLoading {
                    ProgressView("Ищем в Spotify…")
                } else if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Повторить") { retry += 1 }
                    }
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { track in
                        Button { selectedTrack = track } label: {
                            HStack(spacing: 12) {
                                RemoteArtwork(urlString: track.artworkURLString, corner: 10)
                                    .frame(width: 48, height: 48)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Spotify · каталог")
            .searchable(text: $query, prompt: "Название трека или исполнитель")
            .task(id: SearchRequest(query: query, retry: retry)) { await search() }
            .sheet(item: $selectedTrack) { track in SpotifyCatalogTrackSheet(track: track) }
        }
    }
    private struct SearchRequest: Equatable { let query: String; let retry: Int }
    private func search() async {
        results = []; errorMessage = nil; isLoading = false
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isLoading = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            let tracks = try await WolfSpotifyCatalogClient.shared.search(text)
            try Task.checkCancellation()
            results = tracks; isLoading = false
        } catch {
            // Removed screen/provider and superseded queries cannot publish stale results/errors.
            guard !Task.isCancelled else { return }
            errorMessage = (error as? SpotifyCatalogError)?.errorDescription
                ?? "Не удалось подключиться к каталогу Spotify. Проверьте интернет и повторите поиск."
            isLoading = false
        }
    }
}

private struct SpotifyCatalogTrackSheet: View {
    let track: SpotifyCatalogTrack
    @Environment(\.dismiss) private var dismiss
    @State private var detail: SpotifyCatalogTrack?
    @State private var loading = true
    @State private var unavailable = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(track.title).font(.title2.weight(.semibold))
                    Text(track.artist).foregroundStyle(.secondary)
                    if let url = track.spotifyURL { Link("Открыть полный трек в Spotify", destination: url) }
                }
                Section("Превью") {
                    if loading { ProgressView("Проверяем доступность превью…") }
                    else if let url = detail?.previewURL {
                        Link("Прослушать превью в браузере", destination: url)
                    } else {
                        Text(unavailable ? "Сервис временно не ответил. Трек можно открыть в Spotify." : "Для этого трека превью недоступно.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Полное воспроизведение Spotify внутри Sonivo этим API не поддерживается. Очередь и качество Яндекс Музыки не изменяются.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task(id: track.id) {
                do {
                    let value = try await WolfSpotifyCatalogClient.shared.detail(track)
                    try Task.checkCancellation()
                    detail = value; loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    unavailable = true; loading = false
                }
            }
        }
    }
}
