from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing block: {label}")
    return text.replace(old, new, 1)


player_path = Path("Aurora/PlayerScreenV2.swift")
player = player_path.read_text()

player = replace_once(player, '''    // Controls scale with the system font size and never go below 44x44 pt.
    @ScaledMetric(relativeTo: .body) private var controlSide: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var iconGlyph: CGFloat = 20
    @ScaledMetric(relativeTo: .title) private var skipGlyph: CGFloat = 34
    @ScaledMetric(relativeTo: .largeTitle) private var playGlyph: CGFloat = 46
''', '''    // Native medium control metrics. Touch targets remain 44 pt while glyphs
    // stay at standard iOS sizes instead of growing across the complete player.
    private let tapSide: CGFloat = 44
    private let iconGlyph: CGFloat = 19
    private let skipGlyph: CGFloat = 30
    private let playGlyph: CGFloat = 40
''', "player metrics")

player = replace_once(player, '''    /// Minimum comfortable touch target, grown with Dynamic Type but never shrunk.
    private var tapSide: CGFloat { max(44, min(controlSide, 64)) }

''', '', "computed tap size")

player = replace_once(player, '''                    VideoShotPlayerView(url: videoShotUrl, isActive: true)
                        .scaleEffect(1.02)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
''', '''                    // Extend the AVPlayerLayer through every safe-area inset.
                    // Geometry is taken from the current device, with no fixed model sizes.
                    VideoShotPlayerView(url: videoShotUrl, isActive: true)
                        .frame(
                            width: geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing,
                            height: geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
                        )
                        .offset(
                            x: (geo.safeAreaInsets.trailing - geo.safeAreaInsets.leading) / 2,
                            y: (geo.safeAreaInsets.bottom - geo.safeAreaInsets.top) / 2
                        )
                        .clipped()
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
''', "fullscreen videoshot")

player = replace_once(player, '''            .offset(y: max(0, dragY))
            .scaleEffect(1.0 - (dragProgress * 0.10), anchor: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: dragY > 0 ? (22 + dragProgress * 20) : 0, style: .continuous))
''', '''            // Follow the finger at native resolution. Never rescale the complete
            // AVPlayerLayer: that caused softness and dirty edges while dismissing.
            .offset(y: max(0, dragY))
            .clipShape(
                RoundedRectangle(
                    cornerRadius: dragY > 0 ? min(28, 8 + dragProgress * 20) : 0,
                    style: .continuous
                )
            )
''', "dismiss transform")

start = player.index('    private static let blobAnchors:')
end = player.index('    // MARK: - Contrast Protection Vignette')
player = player[:start] + '''    private var backgroundColors: [Color] {
        let source = palette
        return source.isEmpty ? [AG.amber, AG.ember] : Array(source.prefix(3))
    }

    /// A single edge-to-edge cover-derived surface. There are no independently
    /// moving rectangles, masks or low-frequency timelines that can reveal seams.
    private var artworkGradientBackground: some View {
        let colors = backgroundColors
        let primary = colors[0]
        let secondary = colors.count > 1 ? colors[1] : primary
        let tertiary = colors.count > 2 ? colors[2] : secondary

        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: primary.opacity(0.62), location: 0.00),
                    .init(color: secondary.opacity(0.42), location: 0.36),
                    .init(color: tertiary.opacity(0.20), location: 0.66),
                    .init(color: .black.opacity(0.96), location: 1.00)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [secondary.opacity(0.28), .clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 720
            )
        }
        .compositingGroup()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.70), value: colors)
    }

''' + player[end:]

video_toggle = re.compile(r'''            // Compact Video-Shot / Artwork Toggle Pill.*?                \.padding\(\.bottom, -6\)\n            \}\n\n            // Track Metadata''', re.S)
player, count = video_toggle.subn('''            // VideoShot remains in the More menu. Keeping this switch out of
            // the main deck prevents it from shifting metadata and controls.

            // Track Metadata''', player, count=1)
if count != 1:
    raise SystemExit("missing block: videoshot pill")

player = player.replace('max(30, min(skipGlyph, 44))', 'skipGlyph')
player = player.replace('max(40, min(playGlyph, 58))', 'playGlyph')
player = player.replace('max(19, iconGlyph)', 'iconGlyph')
player = player.replace('max(18, iconGlyph * 0.95)', '18')
player = player.replace('.frame(maxWidth: .infinity, minHeight: max(52, tapSide))', '.frame(maxWidth: .infinity, minHeight: 52)')
player = player.replace('.frame(maxWidth: .infinity, minHeight: max(60, tapSide))', '.frame(maxWidth: .infinity, minHeight: 56)')
player = player.replace('''        .padding(.vertical, 8)
    }

    // MARK: Volume Slider''', '''        .padding(.vertical, 4)
    }

    // MARK: Volume Slider''', 1)
player_path.write_text(player)


overlay_path = Path("Aurora/AutoMixTransitionOverlay.swift")
overlay_path.write_text('''import SwiftUI

// MARK: - AutoMix visual hand-off
// A restrained glow/flash only. The AutoMix label stays in the dedicated slot
// below the timeline, so this overlay can never cover transport controls.

struct AutoMixTransitionOverlay: View {
    @State private var player = PlayerCore.shared
    @State private var dj = AutoMixDJEngine.shared
    @Environment(\\.accessibilityReduceMotion) private var reduceMotion

    private var palette: [Color] {
        let values = player.currentTrack?.palette ?? []
        return values.isEmpty ? [AG.amber, AG.ember] : values
    }

    var body: some View {
        if dj.isTransitionActive {
            GeometryReader { proxy in
                let progress = min(1, max(0, dj.transitionProgress))
                let flash = flashIntensity(progress)
                let accent = palette.first ?? AG.amber
                let companion = palette.dropFirst().first ?? AG.ember

                ZStack {
                    RadialGradient(
                        colors: [accent.opacity(0.18), companion.opacity(0.10 * progress), .clear],
                        center: .center,
                        startRadius: 12,
                        endRadius: max(proxy.size.width, proxy.size.height) * 0.72
                    )
                    .blendMode(.plusLighter)

                    RadialGradient(
                        colors: [.white.opacity(flash * 0.38), accent.opacity(flash * 0.18), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: max(proxy.size.width, proxy.size.height) * (0.18 + flash * 0.24)
                    )
                    .blendMode(.screen)
                    .opacity(reduceMotion ? flash * 0.25 : flash)
                }
                .ignoresSafeArea()
            }
            .transition(.opacity)
        }
    }

    private func flashIntensity(_ progress: Double) -> Double {
        let distance = abs(progress - 0.5) / 0.15
        return max(0, 1 - distance * distance)
    }
}
''')


core_path = Path("Aurora/playercore.swift")
core = core_path.read_text()
core = replace_once(core, '''    private var nowPlayingActivationInFlight = false
    private var lastRemoteCommand: (name: String, date: Date)?
''', '''    private var nowPlayingActivationInFlight = false
    private var lastRemoteCommand: (name: String, date: Date)?
    private var applicationIsActive = true
''', "scene state")
core = replace_once(core, '''    private var incomingTrack: Track?
    private var generation = 0
''', '''    private var incomingTrack: Track?
    private var transitionDisplayDidSwitch = false
    private var generation = 0
''', "transition display state")
core = replace_once(core, '''    func activateNowPlayingSessionIfNeeded() {
        guard let session = nowPlayingSession else { return }
''', '''    func activateNowPlayingSessionIfNeeded() {
        guard !applicationIsActive else { return }
        guard let session = nowPlayingSession else { return }
''', "foreground activation gate")
old_publish = '''    private func publishNowPlaying(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        defaultCenter.nowPlayingInfo = info
        defaultCenter.playbackState = state

        if let sessionCenter = nowPlayingSession?.nowPlayingInfoCenter, sessionCenter !== defaultCenter {
            sessionCenter.nowPlayingInfo = info
            sessionCenter.playbackState = state
        }
    }
'''
new_publish = '''    private func publishNowPlaying(_ info: [String: Any]?, state: MPNowPlayingPlaybackState) {
        let defaultCenter = MPNowPlayingInfoCenter.default()
        let sessionCenter = nowPlayingSession?.nowPlayingInfoCenter

        if applicationIsActive {
            defaultCenter.nowPlayingInfo = nil
            defaultCenter.playbackState = .stopped
            if let sessionCenter, sessionCenter !== defaultCenter {
                sessionCenter.nowPlayingInfo = nil
                sessionCenter.playbackState = .stopped
            }
            return
        }

        defaultCenter.nowPlayingInfo = info
        defaultCenter.playbackState = state
        if let sessionCenter, sessionCenter !== defaultCenter {
            sessionCenter.nowPlayingInfo = info
            sessionCenter.playbackState = state
        }
    }

    func setApplicationSceneActive(_ active: Bool) {
        guard applicationIsActive != active else { return }
        applicationIsActive = active
        if active {
            publishNowPlaying(nil, state: .stopped)
        } else {
            updateNowPlayingInfo()
        }
    }
'''
core = replace_once(core, old_publish, new_publish, "now playing publication")
core = replace_once(core, '''        incomingTrack = nextTrack
        currentAutoMixStyle = .bassSwapBlend(duration: transitionDuration)
''', '''        incomingTrack = nextTrack
        transitionDisplayDidSwitch = false
        currentAutoMixStyle = .bassSwapBlend(duration: transitionDuration)
''', "transition start")
core = replace_once(core, '''        AutoMixDJEngine.shared.transitionProgress = p

        let strategy''', '''        AutoMixDJEngine.shared.transitionProgress = p

        // Hand the visible player to the incoming song at the musical midpoint,
        // while both audio decks continue their real crossfade to completion.
        if p >= 0.5, !transitionDisplayDidSwitch, let incomingTrack {
            currentTrack = incomingTrack
            transitionDisplayDidSwitch = true
        }

        let strategy''', "midpoint handoff")
core = replace_once(core, '''        incomingTrack = nil
        prebufferedTrackId = nil
        currentTrack = nextTrack
''', '''        incomingTrack = nil
        transitionDisplayDidSwitch = false
        prebufferedTrackId = nil
        currentTrack = nextTrack
''', "transition completion")
core = replace_once(core, '''        planIsProvisional = false
        guard isTransitioning else { return }
''', '''        planIsProvisional = false
        transitionDisplayDidSwitch = false
        guard isTransitioning else { return }
''', "transition cancellation")
core_path.write_text(core)


app_path = Path("Aurora/auroraapp.swift")
app = app_path.read_text()
app = replace_once(app, '''struct RootView: View {
    @State private var player = PlayerCore.shared
''', '''struct RootView: View {
    @Environment(\\.scenePhase) private var scenePhase
    @State private var player = PlayerCore.shared
''', "root scene phase")
app = replace_once(app, '''        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
        }
''', '''        .onAppear {
            PlaybackAudioSessionCoordinator.shared.install()
            player.setApplicationSceneActive(scenePhase == .active)
        }
        .onChange(of: scenePhase) { _, phase in
            player.setApplicationSceneActive(phase == .active)
        }
''', "scene phase sync")
app_path.write_text(app)
