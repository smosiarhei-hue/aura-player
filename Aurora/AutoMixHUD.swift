import SwiftUI

// MARK: - AutoMix HUD
//
// Compact, always-readable status of the offline AutoMix DSP:
//   • IDLE    — which track is picked next and its vibe match %
//   • ARMED   — grids analysed, beat-sync scheduled, countdown to cue
//   • MIXING  — beat-lock indicator, target BPM, transition strategy,
//               and a thin phase-aligned progress bar
//
// Mounted on the player chrome, above the artwork, never over controls.

struct AutoMixHUD: View {
    @State private var player = PlayerCore.shared
    @State private var dj = AutoMixDJEngine.shared
    @State private var now = Date()

    @State private var matchPercent: Double?
    @State private var nextTitle: String?

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if player.transitionMode == .automix {
                content
                    .onReceive(timer) { now = $0 }
                    .task(id: player.plannedNextTrackID) { await refreshMatch() }
                    .onAppear { Task { await refreshMatch() } }
            }
        }
        .animation(.easeOut(duration: 0.25), value: dj.isTransitionActive)
        .animation(.easeOut(duration: 0.25), value: dj.beatLockActive)
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 10) {
            if dj.isTransitionActive {
                mixingChip
            } else if dj.beatLockActive || player.isGridArmed {
                armedChip
            } else if let nextTitle, let pct = matchPercent {
                idleChip(nextTitle: nextTitle, percent: pct)
            } else {
                idleLabel
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
    }

    // MARK: States

    private var mixingChip: some View {
        HStack(spacing: 9) {
            // Beat-lock pulse dot with breathing ring
            ZStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Circle()
                    .stroke(Color.green.opacity(0.6), lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .scaleEffect(1.0 + 0.4 * sin(dj.transitionProgress * .pi))
                    .opacity(0.85)
            }

            VStack(alignment: .leading, spacing: 1) {
                // Glowing shimmering AUTOMIX label
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let glow = 0.65 + 0.35 * sin(t * 3.5)
                    Text("AutoMix")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [Color(red: 0.4, green: 0.95, blue: 1.0),
                                                    Color(red: 0.45, green: 1.0, blue: 0.7)],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .shadow(color: .cyan.opacity(glow), radius: 7)
                        .shadow(color: .green.opacity(glow * 0.8), radius: 13)
                }
                Text(strategyLabel)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if dj.currentBPM > 0 {
                Text("\(Int(dj.currentBPM.rounded()))")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.14), in: Capsule())
                Text("BPM")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            // Blend progress hairline
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .cyan],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * dj.transitionProgress))
                }
            }
            .frame(width: 46, height: 4)
        }
    }

    private var armedChip: some View {
        HStack(spacing: 8) {
            Image(systemName: "metronome")
                .foregroundStyle(AG.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("СЕТКИ СИНХРОНИЗИРОВАНЫ")
                    .foregroundStyle(AG.amber)
                Text("Свожу по битам • \(dj.currentBPM > 0 ? "\(Int(dj.currentBPM.rounded())) BPM" : "…")")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func idleChip(nextTitle: String, percent: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("AutoMix • дальше: \(nextTitle)")
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Совпадение по вайбу \(Int((percent * 100).rounded()))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(dj.localDSPActive ? "OFFLINE" : "AI")
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(dj.localDSPActive ? .green : .purple)
        }
    }

    private var idleLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .foregroundStyle(.cyan)
            Text("AutoMix следит за битом")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Data

    private var strategyLabel: String {
        let raw = dj.activeStrategyName
        return strategyNames[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private let strategyNames: [String: String] = [
        "BASS_SWAP": "Bass-swap на долю",
        "BEAT_MATCH_EQ": "Бит-матч + EQ",
        "BEAT_MATCH": "Бит-матчинг",
        "ENERGY_BLEND": "Энергетический бленд",
        "FILTER_TRANSITION": "Фильтр-свип",
        "ECHO_OUT": "Эхо-хвост",
        "SIMPLE_CROSSFADE": "Кроссфейд",
        "SILENCE_TRIM": "Срез тишины",
        "VOCAL_CUT": "Без наложения вокала",
        "DROP_SWITCH": "Drop-switch",
        "HARD_CUT": "Резкая склейка"
    ]

    @MainActor
    private func refreshMatch() async {
        guard let current = player.currentTrack,
              let next = player.peekNextForHUD else {
            matchPercent = nil
            nextTitle = nil
            return
        }
        nextTitle = next.title
        async let src = TrackAnalysisService.shared.cachedAnalysis(for: current)
        async let tgt = TrackAnalysisService.shared.cachedAnalysis(for: next)
        let (a, b) = await (src, tgt)
        if let a, let b {
            matchPercent = SmartNextTrackSelector.matchPercent(current: a, candidate: b)
        } else {
            matchPercent = nil
        }
    }
}
