import SwiftUI

struct SonivoScreenBackground: View {
    let colors: [Color]
    var showsMesh: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedColors: [Color] {
        let fallback = [SN.bgRaised, SN.bg, .black]
        return colors.isEmpty ? fallback : colors
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [resolvedColors[0].opacity(0.72), resolvedColors[min(1, resolvedColors.count - 1)].opacity(0.42), SN.bg],
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

struct SonivoSectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(SN.display(.title3, .bold))
                    .foregroundStyle(SN.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(SN.text(.caption))
                        .foregroundStyle(SN.inkMuted)
                }
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(SN.text(.footnote, .semibold))
                    .foregroundStyle(SN.amber)
                    .frame(minWidth: SN.tapTarget, minHeight: SN.tapTarget)
                    .contentShape(Rectangle())
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct SonivoStatusBadge: View {
    let title: String
    var systemImage: String
    var tint: Color = SN.amber

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(SN.text(.caption, .semibold))
            .foregroundStyle(SN.ink)
            .padding(.horizontal, 11)
            .frame(minHeight: 30)
            .glassEffect(.regular.tint(tint.opacity(0.32)), in: .capsule)
            .accessibilityElement(children: .combine)
    }
}

struct SonivoEmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(SN.amber)
                .frame(width: 68, height: 68)
                .glassCircle(interactive: false)

            Text(title)
                .font(SN.display(.title3, .bold))
                .foregroundStyle(SN.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text(message)
                .font(SN.text(.body))
                .foregroundStyle(SN.inkMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(SN.text(.body, .semibold))
                    .foregroundStyle(SN.ink)
                    .padding(.horizontal, 18)
                    .frame(minHeight: SN.tapTarget)
                    .glassProminent()
            }
        }
        .frame(maxWidth: 360)
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}

struct SonivoErrorState: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        SonivoEmptyState(
            systemImage: "exclamationmark.triangle",
            title: "Не удалось загрузить",
            message: message,
            actionTitle: retry == nil ? nil : "Повторить",
            action: retry
        )
    }
}

struct SonivoLoadingState: View {
    var title: String = "Загрузка…"

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(SN.amber)
                .scaleEffect(1.15)
            Text(title)
                .font(SN.text(.subheadline, .medium))
                .foregroundStyle(SN.inkMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityElement(children: .combine)
    }
}

struct SonivoArtworkCard<Content: View>: View {
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
                .clipShape(RoundedRectangle(cornerRadius: SN.radius, style: .continuous))

            if let title {
                Text(title)
                    .font(SN.text(.subheadline, .semibold))
                    .foregroundStyle(SN.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let subtitle {
                Text(subtitle)
                    .font(SN.text(.caption))
                    .foregroundStyle(SN.inkMuted)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SonivoTrackRow: View {
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
                                .strokeBorder(SN.amber, lineWidth: 2)
                        }
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(SN.text(.body, .semibold))
                        .foregroundStyle(SN.ink)
                        .lineLimit(1)
                    Text(track.artist)
                        .font(SN.text(.subheadline))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isPlaying {
                    LiveWaveEqualizer(isPlaying: true)
                } else if let trailingTitle {
                    Text(trailingTitle)
                        .font(SN.text(.caption))
                        .foregroundStyle(SN.inkMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle(haptic: false))
        .accessibilityLabel(isPlaying ? "\(track.title), играет" : "\(track.title), \(track.artist)")
    }
}

struct SonivoCompactTrackCard: View {
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
                        .font(SN.text(.caption2, .bold).monospacedDigit())
                        .foregroundStyle(rank <= 3 ? SN.amber : SN.inkMuted)
                        .frame(width: 20, alignment: .leading)
                }

                RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                    .frame(width: 46, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(SN.text(.caption, .semibold))
                        .foregroundStyle(isActive ? SN.amber : SN.ink)
                        .lineLimit(1)
                    Text(item.artistName)
                        .font(SN.text(.caption2))
                        .foregroundStyle(SN.inkMuted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(SN.ink.opacity(isActive ? 0.12 : 0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if isActive {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(SN.amber.opacity(0.55), lineWidth: 1)
                }
            }
        }
        .buttonStyle(CardPressStyle(haptic: false))
        .accessibilityLabel(isActive ? "\(item.title), играет" : "\(item.title), \(item.artistName)")
    }
}

// MARK: - Apple Design Badges & Iconography

struct AppleRankBadge: View {
    let rank: Int

    private var rankColor: AnyShapeStyle {
        switch rank {
        case 1:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.85, blue: 0.25), Color(red: 0.98, green: 0.65, blue: 0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case 2:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(white: 0.95), Color(white: 0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        case 3:
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color(red: 0.88, green: 0.58, blue: 0.35), Color(red: 0.70, green: 0.40, blue: 0.22)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        default:
            return AnyShapeStyle(SN.inkMuted.opacity(0.80))
        }
    }

    var body: some View {
        Text(String(format: "%02d", rank))
            .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(rankColor)
            .frame(width: 26, alignment: .leading)
    }
}

struct ApplePremiereBadge: View {
    var title: String = "ПРЕМЬЕРА"

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .bold))
                .symbolEffect(.variableColor.iterative.reversing)
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.6)
        }
        .foregroundStyle(SN.ember)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
    }
}

struct AppleInteractiveHeart: View {
    let isFavorite: Bool
    var size: CGFloat = 22
    let onToggle: () -> Void

    var body: some View {
        Button {
            Haptics.tap(.medium)
            onToggle()
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isFavorite ? SN.heart : SN.inkMuted)
                .symbolEffect(.bounce, value: isFavorite)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(TactileButtonStyle(scale: 0.90))
        .accessibilityLabel(isFavorite ? "Убрать из избранного" : "В избранное")
    }
}

// MARK: - Apple Flare Icon (GPT Image 2.0 Optical Flare with Native Motion)

struct AppleFlareIcon: View {
    let name: String
    var size: CGFloat = 34
    var glowColor: Color = SN.amber

    @State private var isBreathing = false
    @State private var isRotating = false
    @State private var isShimmering = false

    var body: some View {
        ZStack {
            // Ambient specular background glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [glowColor.opacity(0.38), glowColor.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 2,
                        endRadius: size * 0.85
                    )
                )
                .frame(width: size * 1.5, height: size * 1.5)
                .scaleEffect(isBreathing ? 1.15 : 0.85)
                .opacity(isShimmering ? 0.90 : 0.50)

            // Transparent flare asset
            Image(name)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .scaleEffect(isBreathing ? 1.05 : 0.95)
                .rotationEffect(.degrees(isRotating ? 5 : -5))
                .brightness(isShimmering ? 0.08 : -0.02)
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
            withAnimation(.easeInOut(duration: 4.8).repeatForever(autoreverses: true)) {
                isRotating = true
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                isShimmering = true
            }
        }
    }
}

struct SonivoCatalogTrackRow: View {
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
                        AppleRankBadge(rank: rank)
                    }

                    ZStack {
                        RemoteArtwork(urlString: item.coverUrlString, corner: 10)
                            .frame(width: 52, height: 52)

                        if isActive {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.42))
                                .frame(width: 52, height: 52)
                            LiveWaveEqualizer(isPlaying: presentation.isPlaying, color: SN.amber)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(SN.text(.subheadline, .semibold))
                            .foregroundStyle(isActive ? SN.amber : SN.ink)
                            .lineLimit(1)
                        Text(item.artistName)
                            .font(SN.text(.caption))
                            .foregroundStyle(SN.inkMuted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CardPressStyle(scale: 0.98, haptic: true))

            Menu {
                Button(action: onPlay) {
                    Label("Слушать", systemImage: "play.fill")
                }
                Button { SonivoPlay.download(item) } label: {
                    Label("Скачать", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(SN.glyph(.bold))
                    .foregroundStyle(SN.inkMuted)
                    .frame(width: SN.tapTarget, height: SN.tapTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Действия для \(item.title)")
        }
        .padding(.vertical, 4)
        .background(isActive ? SN.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
