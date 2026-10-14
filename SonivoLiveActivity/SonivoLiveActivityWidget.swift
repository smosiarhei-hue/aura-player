import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SonivoActivityBundle: WidgetBundle {
    var body: some Widget { SonivoPlaybackActivity() }
}

struct SonivoPlaybackActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SonivoActivityAttributes.self) { context in
            SonivoActivityCard(state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(Color(sonivoHex: context.state.accentHex))
        } dynamicIsland: { context in
            let accent = Color(sonivoHex: context.state.accentHex)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    SonivoBrandGlyph(icon: context.state.icon, size: 52, color: accent)
                }
                DynamicIslandExpandedRegion(.trailing) { SonivoBrandWave(color: accent) }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Sonivo").font(.headline).foregroundStyle(accent)
                                Text(context.state.source).font(.caption).foregroundStyle(.white.opacity(0.65))
                            }
                            Spacer()
                            Text(context.state.isPlaying ? "Играет" : "Пауза")
                                .font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                        SonivoActivityProgress(state: context.state).tint(accent)
                    }
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    SonivoBrandGlyph(icon: context.state.icon, size: 30, color: accent)
                    Text("Sonivo").font(.caption2.weight(.semibold)).foregroundStyle(accent).lineLimit(1)
                }
            } compactTrailing: {
                SonivoBrandWave(color: accent)
            } minimal: {
                SonivoBrandGlyph(icon: context.state.icon, size: 30, color: accent)
            }
            .keylineTint(accent)
            .widgetURL(URL(string: "sonivo://player"))
        }
    }
}

private struct SonivoActivityCard: View {
    let state: SonivoActivityAttributes.ContentState
    var body: some View {
        let accent = Color(sonivoHex: state.accentHex)
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SonivoBrandGlyph(icon: state.icon, size: 48, color: accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sonivo").font(.headline).foregroundStyle(accent)
                    Text(state.source).font(.caption).foregroundStyle(.white.opacity(0.65))
                }
                Spacer()
                SonivoBrandWave(color: accent)
                Image(systemName: state.isPlaying ? "play.fill" : "pause.fill")
                    .foregroundStyle(accent).accessibilityLabel(state.isPlaying ? "Играет" : "Пауза")
            }
            SonivoActivityProgress(state: state).tint(accent)
        }.padding(16).widgetURL(URL(string: "sonivo://player"))
    }
}

private struct SonivoActivityProgress: View {
    let state: SonivoActivityAttributes.ContentState
    var body: some View {
        if state.isPlaying, state.duration > 0, state.timelineEnd > state.timelineStart {
            ProgressView(timerInterval: state.timelineStart...state.timelineEnd, countsDown: false)
                .labelsHidden().accessibilityLabel("Прогресс воспроизведения")
        } else {
            ProgressView(value: state.elapsed, total: max(1, state.duration))
                .accessibilityLabel("Воспроизведение на паузе")
        }
    }
}
