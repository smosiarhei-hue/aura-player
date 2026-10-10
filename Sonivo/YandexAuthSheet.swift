import SwiftUI
import UIKit

struct YandexAuthSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedTab = 0
    @State private var isValidating = false
    @State private var isConnected = false
    @State private var codeDeadline: ContinuousClock.Instant?
    @State private var manualToken = ""
    @State private var code: YandexDeviceCode?
    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    var onLoggedIn: (() -> Void)?

    private var phase: Int {
        if isConnected { return 3 }
        if isValidating { return 2 }
        return code == nil ? 0 : 1
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    SonivoAuthWordmark(size: code == nil ? 42 : 34)
                        .frame(maxWidth: .infinity).padding(.top, 20)
                    Group {
                        if isConnected { successView }
                        else if selectedTab == 1 { manualTokenView }
                        else if let code, let url = code.verificationURL { deviceCodeView(code, url: url) }
                        else { introductionView }
                    }
                    .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : 8)))
                    if isProcessing && !isConnected {
                        ProgressView(isValidating ? "Проверяем аккаунт…" : code == nil ? "Получаем код…" : "Ожидаем подтверждение")
                            .frame(maxWidth: .infinity)
                    }
                    if let statusMessage, !isConnected {
                        Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    if !isConnected {
                        Button("Пока без входа") { cancel(); dismiss() }
                            .frame(minHeight: 44)
                        Menu("Другой способ входа") {
                            Button("Войти по коду") { selectedTab = 0 }
                            Button("Ввести личный токен") { selectedTab = 1 }
                        }.font(.footnote).frame(minHeight: 44)
                        Text("Подключение использует неофициальный API Яндекс Музыки. На странице согласия может отображаться имя исходного OAuth-клиента библиотеки. Доступ и качество зависят от аккаунта и ограничений Яндекса.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                    .animation(reduceMotion ? nil : SN.fastSpring, value: phase)
            }
            .background(SN.bgRaised.ignoresSafeArea())
            .navigationTitle("Подключение аккаунта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { cancel(); dismiss() }
                }
            }
            .onChange(of: selectedTab) { _, _ in cancel(); statusMessage = nil }
            .onDisappear { cancel(); manualToken = "" }
        }
    }

    private var introductionView: some View {
        VStack(spacing: 24) {
            Text("Ваша музыка.\nВаш аккаунт.").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Избранное, плейлисты и персональная волна из Яндекс Музыки.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                Label("Без пароля в Sonivo", systemImage: "person.badge.key").font(.headline)
                Text("Подтвердите вход на странице Яндекса. Личная сессия хранится в Keychain.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).glassCard(corner: 24, padding: 20)
            Button(action: startDeviceLogin) {
                Text("Получить код входа").font(.headline).frame(maxWidth: .infinity, minHeight: 56).glassProminent(SN.ember)
            }.buttonStyle(GlassPressStyle()).disabled(isProcessing)
        }
    }

    private func deviceCodeView(_ code: YandexDeviceCode, url: URL) -> some View {
        VStack(spacing: 24) {
            Text(isValidating ? "Подключаем аккаунт" : "Подтвердите вход").font(.title.bold())
                .multilineTextAlignment(.center)
            Text("1. Откройте страницу Яндекса.\n2. Введите код и подтвердите свой аккаунт.\n3. Вернитесь в Sonivo.")
                .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 18) {
                Text("Код входа").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(code.user_code).font(.system(.largeTitle, design: .monospaced).bold())
                    .textSelection(.enabled).multilineTextAlignment(.center)
                    .accessibilityLabel("Код входа: " + code.user_code)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let seconds = max(0, Int(codeDeadline.map { ContinuousClock().now.duration(to: $0).components.seconds } ?? 0))
                    Text(String(format: "Код действует ещё %02d:%02d", seconds / 60, seconds % 60))
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }.frame(maxWidth: .infinity).glassCard(corner: 24, padding: 24)
            Button { UIPasteboard.general.string = code.user_code } label: {
                Text("Скопировать код").font(.headline).frame(maxWidth: .infinity, minHeight: 48).glassCard(corner: 18)
            }.buttonStyle(GlassPressStyle())
            Button { openURL(url) } label: {
                Text("Открыть Яндекс").font(.headline).frame(maxWidth: .infinity, minHeight: 56).glassProminent(SN.ember)
            }.buttonStyle(GlassPressStyle())
            Button("Отменить ожидание") { cancel() }.frame(minHeight: 44)
        }
    }

    private var successView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green).accessibilityHidden(true)
            Text("Вы подключены.").font(.largeTitle.bold()).multilineTextAlignment(.center)
            Text("Загружаем вашу медиатеку").foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 40)
    }

    private var manualTokenView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Личный токен").font(.title.bold())
            Text("Если у вас уже есть OAuth-токен музыкального API, вставьте его здесь.").font(.subheadline).foregroundStyle(.secondary)
            SecureField("OAuth-токен", text: $manualToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).disabled(isProcessing)
            Button { startManualLogin() } label: {
                Text("Подключить аккаунт").font(.headline).frame(maxWidth: .infinity, minHeight: 56).glassProminent(SN.ember)
            }.buttonStyle(GlassPressStyle())
                .disabled(isProcessing || manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if isProcessing { Button("Отменить", action: cancel).frame(minHeight: 44) }
        }
    }

    private func cancel() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        code = nil
        codeDeadline = nil
        isProcessing = false
        isValidating = false
        isConnected = false
    }

    private func startDeviceLogin() {
        cancel()
        let id = operationID
        isProcessing = true
        statusMessage = "Получаем код…"
        operation = Task { @MainActor in
            do {
                let received = try await YandexDeviceAuthClient.shared.requestCode()
                try Task.checkCancellation()
                guard operationID == id else { return }
                code = received
                statusMessage = "Подтвердите вход на странице Яндекса."
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(received.expires_in))
                codeDeadline = deadline
                var interval = received.interval
                while clock.now < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    try Task.checkCancellation()
                    guard operationID == id else { return }
                    guard clock.now < deadline else { throw YandexAuthError.expired }
                    do {
                        let token = try await YandexDeviceAuthClient.shared.pollToken(code: received.device_code)
                        guard clock.now < deadline else { throw YandexAuthError.expired }
                        await connect(token, operationID: id)
                        return
                    } catch YandexAuthError.pending {
                        continue
                    } catch YandexAuthError.slowDown {
                        interval += 5
                    }
                }
                throw YandexAuthError.expired
            } catch {
                guard !Task.isCancelled, operationID == id else { return }
                code = nil
                isProcessing = false
                // Do not show HTTP bodies/URLs: they may contain credentials.
                statusMessage = (error as? YandexAuthError)?.errorDescription ?? "Ошибка сети. Попробуйте снова."
            }
        }
    }

    private func startManualLogin() {
        let clean = manualToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        cancel()
        let id = operationID
        isProcessing = true
        operation = Task { @MainActor in
            await connect(YandexOAuthToken(access_token: clean, refresh_token: nil, expires_in: nil, token_type: nil), operationID: id)
        }
    }

    private func connect(_ token: YandexOAuthToken, operationID id: UUID) async {
        guard !Task.isCancelled, operationID == id else { return }
        isValidating = true
        statusMessage = "Проверяем доступ к музыкальному аккаунту…"
        let ok = await YandexMusicService.shared.loginWithOAuthToken(token)
        guard !Task.isCancelled, operationID == id else { return }
        isProcessing = false
        isValidating = false
        if ok {
            manualToken = ""
            isConnected = true
            if !reduceMotion { Haptics.success() }
            // The success state follows verified Keychain installation, never a fake timer.
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled, operationID == id else { return }
            onLoggedIn?()
            dismiss()
        } else {
            code = nil
            statusMessage = "Не удалось подтвердить доступ к Яндекс Музыке или сохранить сессию. Предыдущий аккаунт не изменён."
        }
    }
}
