import SwiftUI

/// Shared by the full player, lyrics sheet and cover. Keeps all transport commands
/// on ActivePlayerPresentation; this is a display, not another audio/video engine.
struct TypographyLyricsView: View {
    let lyrics: Lyrics
    let player: ActivePlayerPresentation
    var showsSource = true
    var compact = false
    var onEditLyrics: (() -> Void)? = nil
    @State private var settings = SettingsStore.shared
    @State private var frameClock = LyricsDisplayClock()
    @State private var browsing = false
    @State private var browsingTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var typeScale: CGFloat = 1

    private var playbackTime: Double {
        LyricsPlaybackClock.time(for: player)
    }
    private var activeIndex: Int? { frameClock.activeIndex }
    private func refreshFrame() {
        let time = playbackTime
        frameClock.sample(time: time, selection: TypographyLyricsPolicy.activeIndex(
            lines: lyrics.lines, synchronized: lyrics.isSynchronized, time: time, duration: player.duration))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: compact ? 20 : 32) {
                        ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                            lyricRow(line, index: index)
                                .id(line.id)
                        }
                        if showsSource, !lyrics.sourceName.isEmpty {
                            Text("Источник: \(lyrics.sourceName)")
                                .font(.caption).foregroundStyle(.white.opacity(0.55))
                                .padding(.top, 16)
                        }
                        if let onEditLyrics {
                            Button("Изменить текст", action: onEditLyrics)
                                .font(.caption).tint(SN.accent).frame(minHeight: 44)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, compact ? 28 : max(36, geometry.size.height * 0.18))
                    .padding(.bottom, max(80, geometry.size.height * 0.45))
                }
                .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { _ in
                    browsing = true
                    browsingTask?.cancel()
                }.onEnded { _ in
                    browsingTask = Task {
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                        guard scenePhase == .active else { return }
                        browsing = false
                        centerCurrent(proxy)
                    }
                })
                .overlay(alignment: .bottomTrailing) {
                    if browsing, activeIndex != nil {
                        Button("К текущей") {
                            browsingTask?.cancel()
                            browsing = false
                            centerCurrent(proxy)
                        }
                        .font(.caption.bold()).tint(SN.accent)
                        .padding(12).background(.ultraThinMaterial, in: Capsule()).padding(16)
                    }
                }
                .onChange(of: activeIndex) { _, _ in
                    if !browsing { centerCurrent(proxy) }
                }
                .onChange(of: lyrics) { _, _ in
                    browsingTask?.cancel()
                    browsing = false
                    refreshFrame()
                    centerCurrent(proxy)
                }
                .onAppear { refreshFrame(); centerCurrent(proxy) }
                .onDisappear { browsingTask?.cancel() }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        browsingTask?.cancel()
                        browsing = false
                    }
                    else { refreshFrame(); if !browsing { centerCurrent(proxy) } }
                }
            }
        }
        .background { LyricsClockSurface(clock: frameClock, player: player, lyrics: lyrics) }
    }

    @ViewBuilder
    private func lyricRow(_ line: LyricsLine, index: Int) -> some View {
        let selected = index == activeIndex
        let preference = settings.lyricsFontSize.isFinite ? min(60, max(36, settings.lyricsFontSize)) : 46
        let fontSize = CGFloat(preference) * typeScale * (compact ? 0.8 : 1)
        if lyrics.isSynchronized {
            Button {
                browsingTask?.cancel()
                browsing = false
                Haptics.tap(.light)
                player.seek(to: LyricsPlaybackClock.seekTime(lineStart: line.startTime))
                // Seeking a paused song must not unexpectedly start audio.
            } label: {
                TypographyLyricText(line: line, clock: frameClock, active: selected,
                    plain: false, fontSize: fontSize)
                    .padding(.vertical, 6).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(line.text)
            .accessibilityHint("Перемотать к этой строке")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            TypographyLyricText(line: line, clock: frameClock, active: false, plain: true, fontSize: fontSize)
                .padding(.vertical, 6)
        }
    }

    private func centerCurrent(_ proxy: ScrollViewProxy) {
        guard scenePhase == .active, let index = activeIndex else { return }
        let anchor = UnitPoint(x: 0.5, y: 0.32)
        LyricsFocusMotion.scroll(reduceMotion: reduceMotion) {
            proxy.scrollTo(lyrics.lines[index].id, anchor: anchor)
        }
    }
}

nonisolated private struct TypographyWordAttribute: TextAttribute {
    let start: Double
    let end: Double
}

nonisolated private struct TypographyWordRenderer: TextRenderer {
    let time: Double
    let active: Bool
    let glow: Color
    let highContrast: Bool

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                var copy = context
                if active, let timing = run[TypographyWordAttribute.self],
                   !LyricsTimingStandard.hasStarted(time: time, start: timing.start) {
                    copy.opacity *= 0.38
                } else if active && !highContrast {
                    // SDR glow styling, not a claim of EDR/HDR display headroom.
                    // A crisp white glyph is drawn once; only its halo is softened.
                    copy.addFilter(.shadow(color: glow.opacity(0.32), radius: 5))
                }
                // At the actual source start the entire word is immediately legible.
                // No fade-in, transform, blur, sweep completion or delayed transaction.
                copy.draw(run)
            }
        }
    }
}

private struct TypographyLyricText: View {
    let line: LyricsLine
    let clock: LyricsDisplayClock
    let active: Bool
    let plain: Bool
    let fontSize: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    private var time: Double {
        // Inactive and line-only rows do not subscribe to the 120 Hz time field.
        active && TypographyLyricsPolicy.matchedWords(for: line) != nil ? clock.frameTime : 0
    }
    private var rendered: Text {
        guard active, let words = TypographyLyricsPolicy.matchedWords(for: line) else {
            return Text(line.text).foregroundColor(active ? .white : .white.opacity(plain ? 0.90 : (contrast == .increased ? 0.70 : 0.44)))
        }
        return TypographyLyricsPolicy.segments(line.text).enumerated().reduce(Text("")) { result, pair in
            // Accent follows genuine source starts; never distribute line time over words.
            let color: Color = .white
            return result + Text(pair.element).foregroundColor(color)
                .customAttribute(TypographyWordAttribute(start: words[pair.offset].startTime,
                    end: words[pair.offset].endTime))
        }
    }

    var body: some View {
        rendered
            .font(.system(size: fontSize, weight: .bold, design: .default))
            .tracking(-0.7).lineSpacing(4)
            .textRenderer(TypographyWordRenderer(time: time, active: active, glow: SN.accent, highContrast: contrast == .increased))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.animation = nil }
            .accessibilityLabel(line.text)
    }
}

struct LyricsTypographyModeBar: View {
    @State private var settings = SettingsStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Picker("Вид текста", selection: $settings.lyricsDesign) {
                Text("Типографика").tag(LyricsDesign.typography)
                Text("Строки").tag(LyricsDesign.classic)
                if settings.lyricsDesign == .staggered {
                    Text("Staggered").tag(LyricsDesign.staggered)
                }
            }
            .pickerStyle(.segmented)
            .frame(minHeight: 44)
            Menu {
                ForEach([36, 44, 52, 60], id: \.self) { size in
                    Button("\(size) pt", systemImage: Int(settings.lyricsFontSize) == size ? "checkmark" : "textformat.size") {
                        settings.lyricsFontSize = Double(size)
                    }
                }
            } label: {
                Text("Aa").font(.headline).foregroundStyle(SN.accent)
                    .frame(width: 48, height: 44)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
            }
            .accessibilityLabel("Размер текста")
        }
        .tint(SN.accent)
    }
}
