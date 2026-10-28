import SwiftUI

struct AIDJTransitionBadgeView: View {
    let incomingTrack: Track?
    var phaseLabel: String?

    init(incomingTrack: Track? = nil, phaseLabel: String? = nil) {
        self.incomingTrack = incomingTrack
        self.phaseLabel = phaseLabel
    }

    @State private var pulse = false

    private var title: String {
        if let phaseLabel, !phaseLabel.isEmpty { return phaseLabel }
        return "Automix"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: phaseLabel == nil ? "waveform" : "metronome.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .opacity(pulse ? 1.0 : 0.75)

            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color(white: 0.92)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.white.opacity(0.55), radius: 6, x: 0, y: 0)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5.5)
        .background(Color.black.opacity(0.45))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 6, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
