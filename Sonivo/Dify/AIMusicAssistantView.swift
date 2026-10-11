import SwiftUI

/// A music editorial, not another radio engine. AI suggests; the catalog verifies.
struct AIMusicAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store = AIMusicCuratorStore.shared
    @ObservedObject private var dify = DifyService.shared
    @State private var service = YandexMusicService.shared
    @State private var player = PlayerCore.shared
    @State private var input = ""
    @State private var showSettings = false
    @State private var showLogin = false
    @State private var clearConfirmation = false
    @State private var expanded = Set<UUID>()
    @State private var revealed = false
    @AppStorage("ai_curator.share_current_track") private var shareCurrentTrack = false
    @FocusState private var composerFocused: Bool

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    editorialHeader
                        .opacity(revealed ? 1 : 0)
                        .offset(y: revealed || reduceMotion ? 0 : 12)
                    if !dify.isConfigured { configurationCard }
                    if store.messages.isEmpty { discovery }
                    ForEach(store.messages) { message in messageView(message) }
                    if store.isBusy { workingCard.transition(.opacity) }
                    if let notice = store.copiedToastMessage {
                        HStack(alignment: .top) {
                            Text(notice).font(.callout)
                            Spacer()
                            Button { store.copiedToastMessage = nil } label: { Image(systemName: "xmark") }
                                .frame(minWidth: 44, minHeight: 44).accessibilityLabel("Скрыть сообщение")
                        }.padding().background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    }
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(SN.bg)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.phase)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle("AI Куратор").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { store.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Настройки AI", systemImage: "slider.horizontal.3") { showSettings = true }
                        Button("Очистить диалог", systemImage: "trash", role: .destructive) { clearConfirmation = true }
                    } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Действия куратора")
                }
            }
            .sheet(isPresented: $showSettings) { DifySettingsSheet() }
            .sheet(isPresented: $showLogin) { YandexAuthSheet() }
            .confirmationDialog("Удалить этот диалог? Сохранённые плейлисты останутся в медиатеке.",
                                isPresented: $clearConfirmation, titleVisibility: .visible) {
                Button("Удалить диалог", role: .destructive) { store.clearChat() }
            }
            .onChange(of: service.accountGeneration) { _, _ in store.switchAccount() }
            .onChange(of: dify.configurationID) { _, _ in if store.isBusy { store.cancel() } }
            .onDisappear { store.cancel() }
            .task {
                store.switchAccount()
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.45)) { revealed = true }
            }
        }.tint(.pink)
    }

    private var editorialHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("MUSIC EDITORIAL", systemImage: "sparkles")
                    .font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                CuratorMotionMark(active: store.isBusy).frame(width: 44, height: 44)
            }
            SonivoAuthWordmark(size: 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Найди свой\nследующий звук.")
                .font(.system(.largeTitle, design: .rounded).weight(.bold)).tracking(-0.7)
                .foregroundStyle(SN.ink).fixedSize(horizontal: false, vertical: true)
            Text("Идея → подборка → музыка. Расскажи, что хочется услышать — я предложу направление и проверю песни.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle().fill(dify.isConfigured ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(dify.isConfigured ? "AI подключён · отдельная подборка, не Моя волна" : "Для начала подключи своего AI-провайдера")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var configurationCard: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 16) {
                Image(systemName: "key.horizontal").font(.title2)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Подключить AI").font(.headline)
                    Text("Ваш ключ · безопасное хранение на устройстве").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0); Image(systemName: "arrow.up.right")
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain).glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 24))
    }
    private var discovery: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let track = player.currentTrack {
                VStack(alignment: .leading, spacing: 12) {
                    Label("ОТ ТЕКУЩЕЙ ПЕСНИ", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(.pink)
                    Text(track.title).font(.title3.bold()).lineLimit(2)
                    Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                    Toggle("Передать AI название и исполнителя", isOn: $shareCurrentTrack).font(.subheadline)
                    Button("Найти похожее, но не очевидное", systemImage: "arrow.up.right") {
                        if shareCurrentTrack { submit("Предложи 12–20 менее очевидных песен, близких текущему треку по характеру. Объясни направление, избегай повторов.") }
                        else { store.showToast("Включи передачу названия и исполнителя, или опиши звучание в запросе."); composerFocused = true }
                    }.buttonStyle(.bordered).frame(minHeight: 44)
                    Text("Аудио, избранное и история прослушиваний не отправляются.").font(.caption).foregroundStyle(.secondary)
                }.padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
            Text("С чего начнём?").font(.title3.bold())
            LazyVGrid(columns: columns, spacing: 12) {
                scenario("Под занятие", detail: "Работа, дорога, тренировка", icon: "figure.walk") {
                    input = "Подбери музыку для "; composerFocused = true
                }
                scenario("Под настроение", detail: "Как ты себя чувствуешь?", icon: "sun.horizon") {
                    input = "Хочу музыку с настроением "; composerFocused = true
                }
                scenario("Открыть новое", detail: "За пределами привычного", icon: "safari") {
                    submit("Предложи 12–20 неочевидных песен для знакомства с альтернативной электроникой. Без случайных хитов, коротко объясни выбор.")
                }
                scenario("Своя идея", detail: "Опиши сцену или звучание", icon: "text.alignleft") { composerFocused = true }
            }
            Text("Подборка — рекомендация AI, не анализ звучания. Количество зависит от точных совпадений в каталоге.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func scenario(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(.pink)
                Text(title).font(.headline).foregroundStyle(SN.ink)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading).padding(16)
        }.buttonStyle(.plain).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
    @ViewBuilder private func messageView(_ message: AIMessage) -> some View {
        if message.role == .user {
            Text(message.text).font(.body).padding(16)
                .background(.pink.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
                .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 16) {
                Label("Куратор", systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let clean = DifyService.cleanDisplayText(from: message.text)
                if !clean.isEmpty { Text(.init(clean)).font(.body).textSelection(.enabled) }
                if let error = message.error { Text(error).font(.callout).foregroundStyle(.orange) }
                if let playlist = message.playlist { playlistCard(message, playlist: playlist) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func playlistCard(_ message: AIMessage, playlist: AIGeneratedPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ТВОЯ ПОДБОРКА").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(.pink)
                    Text(playlist.playlistTitle).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "square.stack.fill").font(.title2).foregroundStyle(.pink.opacity(0.8))
            }
            if !playlist.description.isEmpty { Text(playlist.description).font(.subheadline).foregroundStyle(.secondary) }
            if message.isResolvingTracks {
                Label("Проверяем доступность…", systemImage: "magnifyingglass").font(.callout)
            } else {
                Text((message.extendedCount ?? 0) > 0
                     ? "В подборке \(message.resolvedTracks.count) песен · добавлено \(message.extendedCount ?? 0)"
                     : "Найдено \(message.resolvedTracks.count) песен · предложено \(playlist.tracks.count)")
                    .font(.subheadline.weight(.medium))
                if let missing = message.unresolvedCount, missing > 0, service.isUserLoggedIn {
                    Text("\(missing) рекомендаций без точного доступного совпадения. Мы не заменяем их случайными песнями.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            let visible = expanded.contains(message.id) ? message.resolvedTracks : Array(message.resolvedTracks.prefix(5))
            ForEach(visible) { track in
                HStack(spacing: 12) {
                    Image(systemName: "music.note").foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            if message.resolvedTracks.count > 5 {
                Button(expanded.contains(message.id) ? "Свернуть список" : "Все \(message.resolvedTracks.count) песен") {
                    if expanded.contains(message.id) { expanded.remove(message.id) } else { expanded.insert(message.id) }
                }.frame(minHeight: 44)
            }
            if !service.isUserLoggedIn {
                Text("Рекомендации готовы. Подключи музыкальный аккаунт, чтобы проверить и слушать их.").font(.callout)
                ForEach(Array(playlist.tracks.prefix(5))) { suggestion in
                    Text("\(suggestion.artist) — \(suggestion.title)").font(.subheadline).foregroundStyle(.secondary)
                }
                Button("Подключить аккаунт", systemImage: "person.crop.circle") { showLogin = true }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
                Text("После входа повтори запрос — каталог будет проверен для твоего аккаунта.").font(.caption).foregroundStyle(.secondary)
            } else if !message.resolvedTracks.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { playlistActions(message) }
                    VStack(alignment: .leading) { playlistActions(message) }
                }
                Button("Найти ещё до 50 новых песен", systemImage: "plus") { store.extend(message.id) }
                    .disabled(store.isBusy).frame(minHeight: 44)
                if let id = message.savedPlaylistID, let saved = LibraryStore.shared.playlist(byId: id) {
                    NavigationLink("Открыть в медиатеке") { PlaylistDetailView(playlist: saved) }.frame(minHeight: 44)
                }
            }
        }.padding(20).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 26))
    }
    @ViewBuilder private func playlistActions(_ message: AIMessage) -> some View {
        Button("Слушать", systemImage: "play.fill") { AIPlaylistGeneratorService.shared.playNow(tracks: message.resolvedTracks) }
            .buttonStyle(.borderedProminent).frame(minHeight: 44)
        Button(message.savedPlaylistID.flatMap { LibraryStore.shared.playlist(byId: $0) } == nil ? "Сохранить" : "Сохранено",
               systemImage: "bookmark") { store.save(message.id) }.buttonStyle(.bordered).frame(minHeight: 44)
    }
    private var workingCard: some View {
        HStack(spacing: 12) {
            CuratorMotionMark(active: true).frame(width: 36, height: 36)
            Text(store.phase.title).font(.callout.weight(.medium)).accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            Button("Стоп") { store.cancel() }.frame(minWidth: 44, minHeight: 44)
        }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                TextField("Какую музыку хочется?", text: $input, axis: .vertical)
                    .lineLimit(1...5).focused($composerFocused).font(.body).padding(.vertical, 12)
                    .accessibilityLabel("Запрос куратору")
                Button { submit(input) } label: {
                    Image(systemName: "arrow.up").font(.headline).frame(width: 48, height: 48)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled(store.isBusy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Отправить запрос")
            }.padding(.horizontal, 16).padding(.vertical, 8)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 28))
            Text("AI может ошибаться. Внешний провайдер получает текст диалога.")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8).background(.bar)
    }
    private func submit(_ prompt: String) {
        guard dify.isConfigured else { input = prompt; showSettings = true; return }
        if store.send(prompt, shareCurrentTrack: shareCurrentTrack) { input = ""; composerFocused = false }
    }
}

/// Decorative motion stops off-screen/in the background and respects Reduce Motion.
private struct CuratorMotionMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0,
                                paused: !active || reduceMotion || scenePhase != .active)) { context in
            let time = active && !reduceMotion && scenePhase == .active ? context.date.timeIntervalSinceReferenceDate : 0
            HStack(spacing: 3) {
                ForEach(0..<5) { index in
                    Capsule().fill(LinearGradient(colors: [.pink, .orange], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: 8 + 20 * (active && !reduceMotion ? (sin(time * 2.4 + Double(index)) + 1) / 2 : Double(3 - abs(index - 2)) / 3))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.accessibilityHidden(true)
    }
}
