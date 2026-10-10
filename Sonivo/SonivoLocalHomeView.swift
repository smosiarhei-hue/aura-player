import SwiftUI

/// Guest home: no catalog, rotor requests or synthetic/demo songs.
struct SonivoLocalHomeView: View {
    var onConnect: () -> Void
    var onSettings: () -> Void
    @State private var library = LibraryStore.shared
    @State private var showPicker = false

    private var tracks: [Track] { library.tracks.filter { !$0.isStream } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        SonivoAuthWordmark(size: 24, animates: false)
                        Spacer()
                        Button("Настройки", systemImage: "gearshape", action: onSettings)
                            .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                            .glassCircle()
                    }
                    Label("Локальная музыка", systemImage: "music.note")
                        .font(.caption.weight(.semibold)).padding(.horizontal, 14).padding(.vertical, 9)
                        .glassCapsule()
                    VStack(alignment: .leading, spacing: 14) {
                        Text(tracks.isEmpty ? "Ваша музыка.\nБез входа." : "Музыка\nна вашем iPhone.")
                            .font(.largeTitle.bold())
                        Text("Добавляйте свои аудио и слушайте сразу.")
                            .font(.body).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(tracks.isEmpty ? "Начните с любимого" : "Ваша медиатека").font(.title3.bold())
                                Text(tracks.isEmpty ? "Файлы с вашего iPhone" : "Аудиофайлов: \(tracks.count)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder").font(.title2).foregroundStyle(SN.ember)
                        }
                        Button { showPicker = true } label: {
                            HStack {
                                if library.isImportingFiles { ProgressView() } else { Image(systemName: "plus") }
                                Text(library.isImportingFiles ? "Импортируем…" : "Добавить аудио")
                            }.font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                                .glassProminent(SN.ember)
                        }.buttonStyle(GlassPressStyle()).disabled(library.isImportingFiles)
                    }.glassCard(corner: 26, padding: 20)
                    if !tracks.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Недавно добавленные").font(.headline)
                            ForEach(Array(tracks.sorted { $0.addedAt > $1.addedAt }.prefix(8))) { track in
                                SonivoLocalTrackRow(track: track, queue: tracks)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Хотите персональную волну?").font(.headline)
                        Button(action: onConnect) {
                            HStack(spacing: 14) {
                                Image(systemName: "person.crop.circle").font(.title2).foregroundStyle(SN.ember)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Подключить аккаунт").font(.headline)
                                    Text("Яндекс Музыка").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right").accessibilityHidden(true)
                            }.frame(maxWidth: .infinity, minHeight: 52)
                                .glassCard(corner: 22, padding: 16)
                        }.buttonStyle(GlassPressStyle())
                    }
                    Text("Без входа — только локальные аудио. Подключить аккаунт можно позже.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24).padding(.bottom, 24)
            }
            .background(SN.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                LocalAudioDocumentPicker(onPick: { urls in
                    showPicker = false
                    library.importFromPicker(urls: urls)
                }, onCancel: { showPicker = false }).ignoresSafeArea()
            }
            .alert("Ошибка импорта", isPresented: Binding(get: { library.lastError != nil }, set: { if !$0 { library.clearLastError() } })) {
                Button("ОК") { library.clearLastError() }
            } message: { Text(library.lastError ?? "") }
            .alert("Готово", isPresented: Binding(get: { library.lastImportMessage != nil }, set: { if !$0 { library.clearLastImportMessage() } })) {
                Button("ОК") { library.clearLastImportMessage() }
            } message: { Text(library.lastImportMessage ?? "") }
        }
    }
}

struct SonivoLocalTrackRow: View {
    let track: Track
    let queue: [Track]
    var body: some View {
        Button {
            PlaybackCommandRouter.shared.play(track, queue: queue.filter { !$0.isStream })
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "music.note").frame(width: 40, height: 44).glassCard(corner: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.body.weight(.medium)).lineLimit(2)
                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "play.fill").font(.subheadline).accessibilityHidden(true)
            }.frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
}
