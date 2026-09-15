import SwiftUI

struct AuraScreenBackground: View {
    let colors: [Color]
    var showsMesh: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedColors: [Color] {
        let fallback = [AG.bgRaised, AG.bg, .black]
        return colors.isEmpty ? fallback : colors
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [resolvedColors[0].opacity(0.72), resolvedColors[min(1, resolvedColors.count - 1)].opacity(0.42), AG.bg],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if showsMesh && !reduceMotion && scenePhase == .active {
                AnimatedMeshBackground(palette: Array(resolvedColors.prefix(3)))
                    .opacity(0.42)
            }

            LinearGradient(
                colors: colorScheme == .dark
                    ? [.black.opacity(0.08), .black.opacity(0.52), .black.opacity(0.92)]
                    : [.white.opacity(0.05), .white.opacity(0.34), .white.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct AuraSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(AG.display(.title3, .bold))
                    .foregroundStyle(AG.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(AG.text(.caption))
                        .foregroundStyle(AG.inkMuted)
                }
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AG.text(.footnote, .semibold))
                    .foregroundStyle(AG.amber)
                    .frame(minWidth: AG.tapTarget, minHeight: AG.tapTarget)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct AuraStatusBadge: View {
    let title: String
    var systemImage: String
    var tint: Color = AG.amber

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(AG.text(.caption, .semibold))
            .foregroundStyle(AG.ink)
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .glassEffect(.regular.tint(tint.opacity(0.32)), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

struct AuraEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(AG.amber)
                .frame(width: 68, height: 68)
                .glassCircle(interactive: false)

            Text(title)
                .font(AG.display(.title3, .bold))
                .foregroundStyle(AG.ink)
                .multilineTextAlignment(.center)

            Text(message)
                .font(AG.text(.body))
                .foregroundStyle(AG.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(AG.text(.body, .semibold))
                    .foregroundStyle(AG.ink)
                    .padding(.horizontal, 18)
                    .frame(minHeight: AG.tapTarget)
                    .glassProminent()
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct AuraErrorState: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        AuraEmptyState(
            systemImage: "exclamationmark.triangle",
            title: "Не удалось загрузить",
            message: message,
            actionTitle: retry == nil ? nil : "Повторить",
            action: retry
        )
    }
}

struct AuraLoadingState: View {
    var title: String = "Загрузка…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(AG.amber)
                .scaleEffect(1.15)
            Text(title)
                .font(AG.text(.subheadline, .medium))
                .foregroundStyle(AG.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
    }
}

struct AuraArtworkCard<Content: View>: View {
    let artwork: Content
    var title: String?
    var subtitle: String?
    var width: CGFloat = 156
    var action: (() -> Void)?

    init(
        title: String? = nil,
        subtitle: String? = nil,
        width: CGFloat = 156,
        action: (() -> Void)? = nil,
        @ViewBuilder artwork: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.action = action
        self.artwork = artwork()
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { cardContent }
                    .buttonStyle(CardPressStyle(haptic: false))
            } else {
                cardContent
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            artwork
                .frame(width: width, height: width)
                .clipShape(RoundedRectangle(cornerRadius: AG.radius, style: .continuous))

            if let title {
                Text(title)
                    .font(AG.text(.subheadline, .semibold))
                    .foregroundStyle(AG.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let subtitle {
                Text(subtitle)
                    .font(AG.text(.caption))
                    .foregroundStyle(AG.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

struct AuraTrackRow: View {
    let track: Track
    var isActive: Bool = false
    var isPlaying: Bool = false
    var trailingTitle: String?
    var action: (() -> Void)?

    var body: some View {
        Button(action: action ?? {}) {
            HStack(spacing: 12) {
                SmallArtwork(track: track, size: 52)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if isActive {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(AG.amber, lineWidth: 2)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(AG.text(.body, .semibold))
                        .foregroundStyle(AG.ink)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(AG.text(.subheadline))
                        .foregroundStyle(AG.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    LiveWaveEqualizer(isPlaying: true)
                } else if let trailingTitle {
                    Text(trailingTitle)
                        .font(AG.text(.caption))
                        .foregroundStyle(AG.inkMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(haptic: false))
        .accessibilityLabel(isPlaying ? "(track.title), играет" : "(track.title), (track.artist)")
    }
}

struct AuraCompactTrackCard: View {
    let item: YandexMusicService.YMTrackItem
    var rank: Int?
    let action: () -> Void
    @State private var presentation = ActivePlayerPresentation()

    private var isActive: Bool {
        guard let track = presentation.displayTrack else { return false }
        return track.title == item.title && track.artist == item.artistName
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let rank {
                    Text(String(format: "%02d", rank))
                        .font(AG.text(.caption2, .bold).monospacedDigit())
                        .foregroundStyle(rank <= 3 ? AG.amber : AG.inkMuted)
                        .frame(width: 20, alignment: .leading)
                }

                RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(AG.text(.caption, .semibold))
                        .foregroundStyle(isActive ? AG.amber : AG.ink)
                        .lineLimit(1)
                    Text(item.artistName)
                        .font(AG.text(.caption2))
                        .foregroundStyle(AG.inkMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(.white.opacity(isActive ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(AG.amber.opacity(0.55), lineWidth: 1)
                }
            }
        }
        .buttonStyle(CardPressStyle(haptic: false))
        .accessibilityLabel(isActive ? "(item.title), играет" : "(item.title), (item.artistName)")
    }
}

struct AuraCatalogTrackRow: View {
    let item: YandexMusicService.YMTrackItem
    var rank: Int?
    let onPlay: () -> Void
    @State private var presentation = ActivePlayerPresentation()

    private var isActive: Bool {
        guard let track = presentation.displayTrack else { return false }
        return track.title == item.title && track.artist == item.artistName
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    if let rank {
                        Text(String(format: "%02d", rank))
                            .font(AG.text(.caption, .bold).monospacedDigit())
                            .foregroundStyle(rank <= 3 ? AG.amber : AG.inkMuted)
                            .frame(width: 24, alignment: .leading)
                    }

                    RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                        .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(AG.text(.body, .semibold))
                            .foregroundStyle(isActive ? AG.amber : AG.ink)
                            .lineLimit(1)
                        Text(item.artistName)
                            .font(AG.text(.subheadline))
                            .foregroundStyle(AG.inkMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(action: onPlay) {
                    Label("Слушать", systemImage: "play.fill")
                }
                Button { SonivoPlay.download(item) } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(AG.glyph(.bold))
                    .foregroundStyle(AG.inkMuted)
                    .frame(width: AG.tapTarget, height: AG.tapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Действия для (item.title)")
        }
        .padding(.vertical, 6)
        .background(isActive ? .white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
