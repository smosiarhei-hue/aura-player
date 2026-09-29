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
                            .foregroundStyle(SN.positive)
                        Text(toast)
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(SN.ink)
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
                        .font(SN.text(.headline))
                        .foregroundStyle(SN.ink)
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
                    .font(SN.display(.title2, .bold))
                    .foregroundStyle(SN.ink)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(SN.amber)
                    Text("\(tracks.count) треков\(totalDurationText)")
                        .font(SN.text(.subheadline))
                        .foregroundStyle(SN.inkMuted)
                }

                Text("Собрано AI-Куратором")
                    .font(SN.text(.caption, .semibold))
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
                    .font(SN.text(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassProminent(SN.amber)
                }
                .buttonStyle(TactileButtonStyle(scale: 0.96))
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
                    .font(SN.text(.subheadline, .semibold))
                    .foregroundStyle(SN.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .glassCapsule(interactive: true)
                }
                .buttonStyle(TactileButtonStyle(scale: 0.96))
                .disabled(tracks.isEmpty)
            }

            // Кнопка «Дополнить ещё +50»
            Button {
                extendPlaylistWithAI()
            } label: {
                HStack(spacing: 8) {
                    if isExtending {
                        ProgressView().tint(SN.ink).scaleEffect(0.9)
                        Text("AI подбирает +50 треков…")
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(SN.amber)
                        Text("Дополнить ещё +50")
                    }
                }
                .font(SN.text(.subheadline, .bold))
                .foregroundStyle(SN.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .glassCard(corner: 14)
            }
            .buttonStyle(TactileButtonStyle(scale: 0.97))
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
                    .font(SN.text(.caption, .semibold).monospacedDigit())
                    .foregroundStyle(SN.inkFaint)
                    .frame(width: 24, alignment: .trailing)

                SmallArtwork(track: track, size: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if player.currentTrack?.id == track.id {
                            Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                .font(.caption2)
                                .foregroundStyle(settings.accentColor)
                        }
                        Text(track.title)
                            .font(SN.text(.body, .medium))
                            .lineLimit(1)
                            .foregroundStyle(player.currentTrack?.id == track.id ? settings.accentColor : SN.ink)

                        if library.isTrackFavorite(track) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(SN.heart)
                        }
                    }

                    Text(track.artist)
                        .font(SN.text(.caption))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(1)
                }

                Spacer()

                Text(player.formatted(track.duration))
                    .font(SN.text(.caption).monospacedDigit())
                    .foregroundStyle(SN.inkFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))
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
                .foregroundStyle(SN.inkFaint)
                .padding(.top, 30)

            Text("В плейлисте пока нет треков")
                .font(SN.text(.subheadline, .medium))
                .foregroundStyle(SN.inkMuted)

            Button("Дополнить +50 треков через AI") {
                extendPlaylistWithAI()
            }
            .font(SN.text(.subheadline, .bold))
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
