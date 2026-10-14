import SwiftUI

struct SonivoLocalSearchView: View {
    var isActive: Bool = true
    @State private var library = LibraryStore.shared
    @State private var query = ""
    private var tracks: [Track] { library.tracks.filter { !$0.isStream } }
    private var results: [Track] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(text) ||
            $0.artist.localizedCaseInsensitiveContains(text) ||
            $0.album.localizedCaseInsensitiveContains(text)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Добавьте свои аудио" : "Ничего не найдено",
                                           systemImage: "music.note",
                                           description: Text("Поиск выполняется только по локальной медиатеке."))
                } else {
                    ForEach(results) { track in SonivoLocalTrackRow(track: track, queue: results) }
                }
            }
            .navigationTitle("Поиск")
            .safeAreaInset(edge: .top) {
                SonivoSearchField(text: $query,isActive: isActive,prompt: "По локальной музыке")
                    .padding(.horizontal,16).padding(.vertical,10).background(.ultraThinMaterial)
            }
        }
    }
}
