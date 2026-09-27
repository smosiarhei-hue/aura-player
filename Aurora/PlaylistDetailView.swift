import SwiftUI

// MARK: - Playlist Detail View

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var library = LibraryStore.shared
    @State private var player = PlayerCore.shared
    @State private var settings = SettingsStore.shared

    let playlist: Playlist

    @State private var isExtending = false
    @State private var toastMessage: String? = nil
    @State private var showDeleteAlert = false

    private var currentPlaylist: Playlist {
        library.playlist(byId: playlist.id) ?? playlist
    }

    private var tracks: [Track] {
        library.tracks(for: currentPlaylist)
    }

    private var totalDurationText: String {
        let totalSeconds = tracks.reduce(0) { $0 + $1.duration }
        guard totalSeconds > 0 else { return "" }
        let minutes = Int(totalSeconds) / 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remMin = minutes % 60
            return " • \(hours) ч \(remMin) мин"
        }
        return " • \(minutes) мин"
    }

    var body: some View {
        ZStack {
            SonivoBackdrop()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        playlistHeroHeader
                        actionButtonsRow

                        if tracks.isEmpty {
                            emptyPlaylistView
                        } else {
                            tracksListSection
                        }
                    }
                    .padding(.bottom, 120)
                }
            }

            if let toast = toastMessage {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AG.positive)
                        Text(toast)
                            .font(AG.text(.subheadline, .semibold))
                            .foregroundStyle(AG.ink)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassCapsule(interactive: false)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))

                    Spacer()
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label("Удалить плейлист", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(AG.text(.headline))
                        .foregroundStyle(AG.ink)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .alert("Удалить плейлист?", isPresented: $showDeleteAlert) {
            Button("Удалить", role: .destructive) {
                library.deletePlaylist(currentPlaylist)
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Плейлист «\(currentPlaylist.title)» будет удален из медиатеки.")
        }
    }

    // MARK: - Hero Header
    private var playlistHeroHeader: some View {
        HStack(spacing: 16) {
            PlaylistCoverArtView(
                playlist: currentPlaylist,
                cornerRadius: 22,
                size: CGSize(width: 110, height: 110)
            )
            .shadow(color: .black.opacity(0.22), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text(currentPlaylist.title)
                    .font(AG.display(.title2, .bold))
                    .foregroundStyle(AG.ink)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(AG.amber)
                    Text("\(tracks.count) треков\(totalDurationText)")
                        .font(AG.text(.subheadline))
                        .foregroundStyle(AG.inkMuted)
                }

                Text("Собрано AI-Куратором")
                    .font(AG.text(.caption, .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.pink, Color.purple, Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.top, 2)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    // MARK: - Action Buttons
    private var actionButtonsRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    guard let first = tracks.first else { return }
                    Haptics.tap(.heavy)
                    PlaybackCommandRouter.shared.play(first, queue: tracks)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Слушать")
                    }
                    .font(AG.text(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassProminent(AG.amber)
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)

                Button {
                    let shuffled = tracks.shuffled()
                    guard let first = shuffled.first else { return }
                    Haptics.tap(.medium)
                    PlaybackCommandRouter.shared.play(first, queue: shuffled)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "shuffle")
                        Text("Перемешать")
                    }
                    .font(AG.text(.subheadline, .semibold))
                    .foregroundStyle(AG.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(tracks.isEmpty)
            }

            // Кнопка «Дополнить ещё +50»
            Button {
                extendPlaylistWithAI()
            } label: {
                HStack(spacing: 8) {
                    if isExtending {
                        ProgressView().tint(AG.ink).scaleEffect(0.9)
                        Text("AI подбирает +50 треков…")
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(AG.amber)
                        Text("Дополнить ещё +50")
                    }
                }
                .font(AG.text(.subheadline, .bold))
                .foregroundStyle(AG.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .glassCard(corner: 14)
            }
            .buttonStyle(.plain)
            .disabled(isExtending)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Tracks List Section
    private var tracksListSection: some View {
        LazyVStack(spacing: 2) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                trackRow(track: track, index: index + 1)
            }
        }
    }

    // MARK: - Track Row
    private func trackRow(track: Track, index: Int) -> some View {
        Button {
            Haptics.tap(.light)
            PlaybackCommandRouter.shared.play(track, queue: tracks)
        } label: {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(AG.text(.caption, .semibold).monospacedDigit())
                    .foregroundStyle(AG.inkFaint)
                    .frame(width: 24, alignment: .trailing)

                SmallArtwork(track: track, size: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if player.currentTrack?.id == track.id {
                            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                .font(.caption2)
                                .foregroundStyle(settings.accentColor)
                        }
                        Text(track.title)
                            .font(AG.text(.body, .medium))
                            .lineLimit(1)
                            .foregroundStyle(player.currentTrack?.id == track.id ? settings.accentColor : AG.ink)

                        if library.isTrackFavorite(track) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(AG.heart)
                        }
                    }

                    Text(track.artist)
                        .font(AG.text(.caption))
                        .foregroundStyle(AG.inkMuted)
                        .lineLimit(1)
                }

                Spacer()

                Text(player.formatted(track.duration))
                    .font(AG.text(.caption).monospacedDigit())
                    .foregroundStyle(AG.inkFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                library.toggleFavorite(track)
            } label: {
                Label(library.isTrackFavorite(track) ? "Убрать из избранного" : "В избранное",
                      systemImage: library.isTrackFavorite(track) ? "heart.slash" : "heart")
            }

            Button {
                PlaybackCommandRouter.shared.play(track, queue: [track] + tracks)
            } label: {
                Label("Воспроизвести следующим", systemImage: "text.insert")
            }

            Divider()

            Button(role: .destructive) {
                library.removeTrackFromPlaylist(trackId: track.id, playlistId: currentPlaylist.id)
            } label: {
                Label("Удалить из плейлиста", systemImage: "minus.circle")
            }
        }
    }

    // MARK: - Empty State
    private var emptyPlaylistView: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(AG.inkFaint)
                .padding(.top, 30)

            Text("В плейлисте пока нет треков")
                .font(AG.text(.subheadline, .medium))
                .foregroundStyle(AG.inkMuted)

            Button("Дополнить +50 треков через AI") {
                extendPlaylistWithAI()
            }
            .font(AG.text(.subheadline, .bold))
            .foregroundStyle(settings.accentColor)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Extend Logic
    private func extendPlaylistWithAI() {
        guard !isExtending else { return }
        Haptics.tap(.medium)
        isExtending = true

        Task {
            do {
                let added = try await AIPlaylistGeneratorService.shared.extendPlaylistInLibrary(playlistId: currentPlaylist.id)
                showToast("Добавлено +\(added) новых треков в плейлист!")
                Haptics.notification(.success)
            } catch {
                showToast("Ошибка дополнения: \(error.localizedDescription)")
            }

            await MainActor.run {
                isExtending = false
            }
        }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toastMessage == msg {
                toastMessage = nil
            }
        }
    }
}
