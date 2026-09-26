import SwiftUI
import AVFoundation

// MARK: - Synchronized Karaoke Lyrics View (Apple Music Style, 120 FPS ProMotion, Syllable Sweep)

struct LyricsView: View {
    let lyrics: Lyrics?
    let isLoading: Bool
    var player: ActivePlayerPresentation = .shared
    @State private var settings = SettingsStore.shared
    @State private var showAddCustomLyrics = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if isLoading {
                    AuraLoadingState(title: "Загрузка текста…")
                } else if let lyrics, !lyrics.lines.isEmpty {
                    if lyrics.isSynchronized {
                        SyncedLyrics(lyrics: lyrics, player: player, onEditLyrics: { showAddCustomLyrics = true })
                    } else {
                        StaticLyricsList(lyrics: lyrics, onEditLyrics: { showAddCustomLyrics = true })
                    }
                } else {
                    EmptyLyricsState(player: player, onAddLyrics: { showAddCustomLyrics = true })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Real-time Apple Music Sing style vocal isolation slider overlay
            VocalIsolationControlView()
                .padding(.trailing, 22)
                .padding(.bottom, 38)
        }
        .sheet(isPresented: $showAddCustomLyrics) {
            if let track = player.displayTrack {
                AddCustomLyricsSheet(track: track)
            }
        }
        .background {
            ZStack {
                Color.black.ignoresSafeArea()
                if let img = player.displayTrack.flatMap({ LibraryStore.cachedArtworkImage(for: $0) }) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 24)
                        .scaleEffect(1.15)
                        .opacity(0.38)
                        .clipped()
                        .ignoresSafeArea()
                }
                Color.black.opacity(0.45).ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
        .task { await player.observeTimeline() }
    }
}

// MARK: - Synchronized Scrolling Lyrics (Auto-centered, Smooth Glide Scrolling)

private struct SyncedLyrics: View {
    let lyrics: Lyrics
    let player: ActivePlayerPresentation
    var onEditLyrics: (() -> Void)? = nil
    @State private var settings = SettingsStore.shared
    @State private var userScrolledUntil: Date = .distantPast

    private var isUserInteracting: Bool {
        Date() < userScrolledUntil
    }

    private var activeIndex: Int? {
        guard lyrics.isSynchronized, !lyrics.lines.isEmpty else { return nil }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let currentTime = max(0, player.progress - latency + settings.lyricsOffset)
        if let first = lyrics.lines.first, currentTime < first.startTime {
            return nil
        }
        for (idx, line) in lyrics.lines.enumerated() {
            let nextStart = (idx + 1 < lyrics.lines.count) ? lyrics.lines[idx + 1].startTime : (line.startTime + 20.0)
            if currentTime >= line.startTime && currentTime < nextStart {
                return idx
            }
        }
        return lyrics.lines.count - 1
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 28) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { idx, line in
                        Button {
                            Haptics.tap(.medium)
                            userScrolledUntil = .distantPast
                            if lyrics.isSynchronized {
                                player.seek(to: max(0, line.startTime))
                                if !player.isPlaying {
                                    player.resume()
                                }
                            }
                            withAnimation(.easeInOut(duration: 0.42)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        } label: {
                            LyricsLineView(
                                line: line,
                                isActive: idx == activeIndex
                            )
                        }
                        .buttonStyle(LyricsLineButtonStyle())
                        .accessibilityLabel(line.text)
                        .accessibilityHint("Перемотать к этой строке")
                        .id(idx)
                    }

                    // Source badge placed directly at the end of the text
                    if !lyrics.sourceName.isEmpty {
                        VStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: "music.note")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("Источник: \(lyrics.sourceName)")
                                    .font(.system(size: 12, weight: .medium, design: .default))
                            }
                            .foregroundStyle(.white.opacity(0.45))

                            if let onEditLyrics {
                                Button {
                                    onEditLyrics()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "pencil")
                                        Text("Изменить текст")
                                    }
                                    .font(AG.text(.caption2, .semibold))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .glassCapsule(interactive: true)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 24)
                        .padding(.bottom, 40)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 240)
                .frame(maxWidth: .infinity)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        userScrolledUntil = Date().addingTimeInterval(4.5)
                    }
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.10),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .bottomTrailing) {
                if isUserInteracting, let activeIndex {
                    Button {
                        Haptics.tap(.light)
                        userScrolledUntil = .distantPast
                        withAnimation(.easeInOut(duration: 0.42)) {
                            proxy.scrollTo(activeIndex, anchor: .center)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 11, weight: .bold))
                            Text("К текущей")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.70), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.30), lineWidth: 0.8))
                        .shadow(color: Color.black.opacity(0.4), radius: 6, y: 2)
                    }
                    .buttonStyle(TactileButtonStyle(scale: 0.95))
                    .padding(.trailing, 20)
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex, !isUserInteracting else { return }
                withAnimation(.easeInOut(duration: 0.42)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onAppear {
                if let activeIndex {
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Single Line (Large Bold Centered Typography — Matching Reference)

private struct LyricsLineView: View {
    let line: LyricsLine
    let isActive: Bool

    var body: some View {
        Text(line.text)
            .font(.system(size: 32, weight: .heavy, design: .default))
            .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.35))
            .shadow(color: isActive ? Color.black.opacity(0.40) : Color.clear, radius: 4, y: 1.5)
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .minimumScaleFactor(0.80)
            .lineSpacing(6)
            .frame(maxWidth: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .animation(.easeInOut(duration: 0.32), value: isActive)
    }
}

private struct LyricsLineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.65 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Static (unsynced) Lyrics List

private struct StaticLyricsList: View {
    let lyrics: Lyrics
    var onEditLyrics: (() -> Void)? = nil
    @State private var settings = SettingsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 22) {
                if let title = lyrics.title, !title.isEmpty {
                    Text(title)
                        .font(AG.display(.title2, .heavy))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    if let artist = lyrics.artist, !artist.isEmpty {
                        Text(artist)
                            .font(AG.text(.callout, .semibold))
                            .foregroundStyle(.white.opacity(0.70))
                            .multilineTextAlignment(.center)
                    }
                    Divider().overlay(Color.white.opacity(0.2)).padding(.vertical, 6)
                }
                ForEach(lyrics.lines) { line in
                    Text(line.text)
                        .font(.system(size: 26, weight: .bold, design: .default))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if !lyrics.sourceName.isEmpty {
                    VStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Источник: \(lyrics.sourceName)")
                                .font(.system(size: 13, weight: .medium, design: .default))
                        }
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial.opacity(0.40), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))

                        if let onEditLyrics {
                            Button {
                                onEditLyrics()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "pencil.and.list.clipboard")
                                    Text("Синхронизировать или изменить")
                                }
                                .font(AG.text(.caption, .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .glassCapsule(interactive: true)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.top, 24)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 80)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

// MARK: - Empty / Not Found State

private struct EmptyLyricsState: View {
    var player: ActivePlayerPresentation = .shared
    var onAddLyrics: (() -> Void)? = nil
    @State private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.white.opacity(0.35))

            Text("Текст песни не найден")
                .font(AG.display(.headline, .bold))
                .foregroundStyle(.white)

            if let staticText = player.displayTrack?.lyricsText, !staticText.isEmpty {
                ScrollView {
                    Text(staticText)
                        .font(AG.text(.subheadline))
                        .foregroundStyle(Color.white.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .lineSpacing(6)
                        .padding(.horizontal, 28)
                }
            } else {
                Text("Для этого трека пока нет текста песни.")
                    .font(AG.text(.footnote))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let onAddLyrics {
                Button {
                    Haptics.tap(.light)
                    onAddLyrics()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Добавить текст песни")
                    }
                    .font(AG.text(.subheadline, .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .glassCapsule(interactive: true)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .padding(28)
    }
}

// MARK: - Add / Edit Custom Lyrics Sheet

struct AddCustomLyricsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let track: Track

    @State private var lyricsInput: String = ""
    @State private var isDynamic: Bool = true
    @State private var hasExistingCustomLyrics: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 16) {
                    // Track header info
                    VStack(spacing: 4) {
                        Text(track.title)
                            .font(AG.rounded(.headline, .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(track.artist)
                            .font(AG.text(.subheadline))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .padding(.top, 8)

                    // Mode picker
                    Picker("Тип текста", selection: $isDynamic) {
                        Text("Динамический (Караоке)").tag(true)
                        Text("Обычный текст").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)

                    if isDynamic {
                        HStack {
                            Text("Поддерживает таймкоды [mm:ss.xx] или авто-разметку")
                                .font(AG.text(.caption2))
                                .foregroundStyle(.white.opacity(0.5))

                            Spacer()

                            Button {
                                generateAutoTimings()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "sparkles")
                                    Text("Авто-тайминг")
                                }
                                .font(AG.text(.caption2, .bold))
                                .foregroundStyle(AG.amber)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .glassCapsule(interactive: true)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 22)
                    }

                    // Text Editor
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                            )

                        if lyricsInput.isEmpty {
                            Text(isDynamic
                                ? "Вставьте текст песни или LRC файл с таймкодами:\n[00:12.30] Первая строка...\n[00:15.80] Вторая строка..."
                                : "Вставьте или введите текст песни построчно...")
                                .font(AG.text(.body))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(16)
                        }

                        TextEditor(text: $lyricsInput)
                            .font(AG.text(.body))
                            .foregroundStyle(.white)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                    }
                    .padding(.horizontal, 20)

                    // Bottom action buttons
                    HStack(spacing: 12) {
                        if hasExistingCustomLyrics {
                            Button(role: .destructive) {
                                Haptics.tap(.medium)
                                LyricsService.shared.removeCustomLyrics(for: track)
                                dismiss()
                            } label: {
                                Text("Удалить свой текст")
                                    .font(AG.text(.subheadline, .semibold))
                                    .foregroundStyle(.red)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity)
                                    .glassCapsule(interactive: true)
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            saveLyrics()
                        } label: {
                            Text("Сохранить")
                                .font(AG.text(.subheadline, .bold))
                                .foregroundStyle(.white)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity)
                                .glassProminent(AG.amber)
                        }
                        .buttonStyle(.plain)
                        .disabled(lyricsInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
            .navigationTitle("Редактор текста")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .onAppear {
                loadExisting()
            }
        }
    }

    private func loadExisting() {
        let key = "custom_lyrics_\(track.id.uuidString)"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            lyricsInput = saved
            hasExistingCustomLyrics = true
            isDynamic = UserDefaults.standard.bool(forKey: "custom_lyrics_dynamic_\(track.id.uuidString)") || saved.contains("[")
        }
    }

    private func generateAutoTimings() {
        let rawLines = lyricsInput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("[offset:") }
        guard !rawLines.isEmpty else { return }

        Haptics.tap(.light)
        let total = track.duration > 10 ? track.duration : 180.0
        let interval = max(1.8, (total - 6.0) / Double(rawLines.count))

        var timedLines: [String] = []
        for (idx, line) in rawLines.enumerated() {
            // Remove existing timestamps if any
            let cleanLine = line.replacingOccurrences(of: #"^\[\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?\]"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            let seconds = Double(idx) * interval + 1.0
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            let hundredths = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
            let tag = String(format: "[%02d:%02d.%02d]", mins, secs, hundredths)
            timedLines.append("\(tag) \(cleanLine)")
        }

        lyricsInput = timedLines.joined(separator: "\n")
        isDynamic = true
    }

    private func saveLyrics() {
        let trimmed = lyricsInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Haptics.tap(.heavy)
        LyricsService.shared.saveCustomLyrics(text: trimmed, isDynamic: isDynamic, for: track)
        dismiss()
    }
}

