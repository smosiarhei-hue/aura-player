import SwiftUI
import UIKit

struct YandexAuthSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedTab = 0
    @State private var manualToken = ""
    @State private var code: YandexDeviceCode?
    @State private var isProcessing = false
    @State private var statusMessage: String?
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    var onLoggedIn: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Подключите свой аккаунт: музыка, избранное и рекомендации будут связаны с ним.")
                        .foregroundStyle(SN.inkMuted)
                    Picker("Способ входа", selection: $selectedTab) {
                        Text("Войти по коду").tag(0)
                        Text("Ввести токен").tag(1)
                    }.pickerStyle(.segmented)
                    if selectedTab == 0 { deviceCodeView } else { manualTokenView }
                    if isProcessing { ProgressView("Ожидаем вход…") }
                    if let statusMessage {
                        Text(statusMessage).font(.footnote).foregroundStyle(SN.inkMuted)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Text("Подключение использует неофициальный API Яндекс Музыки. На странице согласия может отображаться имя исходного OAuth-клиента библиотеки. Доступ и качество зависят от аккаунта и ограничений Яндекса.")
                        .font(.footnote).foregroundStyle(SN.inkMuted)
                }.padding(20)
            }
            .background(SN.bgRaised)
            .navigationTitle("Вход в Яндекс Музыку")
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

    private var deviceCodeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let code, let url = code.verificationURL {
                Text("1. Откройте страницу Яндекса.
2. Введите код и подтвердите свой аккаунт.
3. Вернитесь в Sonivo.")
                    .font(.subheadline)
                Text(code.user_code).font(.system(.largeTitle, design: .monospaced).bold())
                    .textSelection(.enabled).accessibilityLabel("Код входа: " + code.user_code)
                Button("Скопировать код") { UIPasteboard.general.string = code.user_code }
                Button("Открыть Яндекс") { openURL(url) }.buttonStyle(.borderedProminent)
                Button("Отменить ожидание") { cancel() }
            } else {
                Button("Получить код входа", action: startDeviceLogin)
                    .buttonStyle(.borderedProminent).disabled(isProcessing)
            }
        }
    }

    private var manualTokenView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Если у вас уже есть личный OAuth-токен музыкального API, вставьте его здесь.")
                .font(.subheadline)
            SecureField("OAuth-токен", text: $manualToken)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(.roundedBorder).disabled(isProcessing)
            Button("Подключить аккаунт") { startManualLogin() }
                .buttonStyle(.borderedProminent)
                .disabled(isProcessing || manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if isProcessing { Button("Отменить", action: cancel) }
        }
    }

    private func cancel() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        code = nil
        isProcessing = false
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
        statusMessage = "Проверяем доступ к музыкальному аккаунту…"
        let ok = await YandexMusicService.shared.loginWithOAuthToken(token)
        guard !Task.isCancelled, operationID == id else { return }
        isProcessing = false
        if ok {
            manualToken = ""
            onLoggedIn?()
            dismiss()
        } else {
            code = nil
            statusMessage = "Не удалось подтвердить доступ к Яндекс Музыке или сохранить сессию. Предыдущий аккаунт не изменён."
        }
    }
}
