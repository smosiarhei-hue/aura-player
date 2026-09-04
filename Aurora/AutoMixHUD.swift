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

    var body: some View {
        if player.transitionMode == .automix {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if dj.isTransitionActive {
            mixingChip.modifier(HUDChipStyle())
        } else if dj.beatLockActive || player.isGridArmed {
            armedChip.modifier(HUDChipStyle())
        }
        // Idle: renders nothing — the plate appears only when AutoMix
        // actually locks the grids / starts mixing.
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
}

/// Shared capsule chrome for the AutoMix status plates.
private struct HUDChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .cyan.opacity(0.25), radius: 10, y: 3)
    }
}
