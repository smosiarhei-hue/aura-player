import SwiftUI

struct AIDJTransitionBadgeView: View {
    @ObservedObject private var dj = AIDJService.shared
    let incomingTrack: Track?

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.pink, Color.purple, Color.cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 18, height: 18)
                    .scaleEffect(pulse ? 1.15 : 0.95)

                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(.white)
            }

            if let commentary = dj.currentDJCommentary, !commentary.isEmpty {
                Text("DJ: \(commentary)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } else {
                Text(incomingTrack != nil ? "DJ: Переход к \(incomingTrack!.artist)" : "DJ: Сведение треков")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Color.black.opacity(0.4)
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.6), Color.cyan.opacity(0.4)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.purple.opacity(0.25), radius: 6, y: 2)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
