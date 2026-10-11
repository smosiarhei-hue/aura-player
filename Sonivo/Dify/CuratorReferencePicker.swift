import SwiftUI

nonisolated struct CuratorReferenceQueryKey: Hashable {
    let projection: LibraryProjectionKey
    let generation: UUID
}
struct CuratorReferencePicker: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = LibraryStore.shared
    @State private var account = YandexMusicService.shared
    @State private var query = ""
    @State private var tracks: [Track] = []
    @State private var loading = false
    @State private var resolvedKey: CuratorReferenceQueryKey?
    let currentTrack: Track?
    let onSelect: (CuratorSongReference) -> Void
    private var key: CuratorReferenceQueryKey {
        .init(projection:.init(revision:library.tracksRevision,loggedIn:account.isUserLoggedIn,filter:.all,query:query),generation:account.accountGeneration)
    }
    private var visibleTracks: [Track] { resolvedKey == key ? tracks : [] }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment:.leading,spacing:12) {
                    Text("Прикрепим только название и исполнителя. Аудиофайл, избранное и история прослушиваний AI не получит.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let currentTrack { row(currentTrack, subtitle:"Сейчас играет") }
                    if loading { ProgressView("Ищем песни…") }
                    ForEach(visibleTracks) { track in row(track,subtitle:track.artist) }
                    if !loading && visibleTracks.isEmpty { Text("Выберите текущую песню или найдите трек в своей медиатеке.").foregroundStyle(.secondary) }
                }.padding(20)
            }
            .searchable(text:$query,prompt:"Название или исполнитель")
            .navigationTitle("Песня для Куратора").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task(id:key) {
                let request = key, snapshot = library.tracks
                loading = true
                do {
                    if !request.projection.query.isEmpty { try await Task.sleep(for:.milliseconds(150)) }
                    let worker = Task.detached(priority:.userInitiated) {
                        let result = try LibraryTrackProjection.build(snapshot,key:request.projection)
                        return Array(result.filtered.prefix(100))
                    }
                    let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation(); guard key == request else { return }
                    tracks = result; resolvedKey = request; loading = false
                } catch { if key == request && !Task.isCancelled { tracks = []; loading = false } }
            }
        }
    }
    private func row(_ track: Track, subtitle: String) -> some View {
        Button {
            onSelect(.init(id:track.id,title:track.title,artist:track.artist)); dismiss()
        } label: {
            HStack(spacing:12) {
                Image(systemName:"music.note").frame(width:28)
                VStack(alignment:.leading,spacing:4) { Text(track.title).font(.headline);Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer();Image(systemName:"plus.circle")
            }.padding(14).frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
        }.buttonStyle(.plain).background(.thinMaterial,in:RoundedRectangle(cornerRadius:18))
    }
}
