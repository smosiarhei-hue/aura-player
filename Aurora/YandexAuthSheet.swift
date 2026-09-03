import SwiftUI
import WebKit

// MARK: - Yandex OAuth Web Sheet
// Позволяет пользователю безопасно войти под своим Яндекс ID,
// автоматически перехватывает токен из перенаправления
// и синхронизирует профиль, лайки и историю.

struct YandexAuthSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ym = YandexMusicService.shared
    @State private var selectedTab = 0
    @State private var manualToken = ""
    @State private var isProcessing = false
    @State private var statusMessage: String? = nil
    @State private var isError = false

    var onLoggedIn: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "#121214")!.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Tab Picker
                    Picker("Способ входа", selection: $selectedTab) {
                        Text("Яндекс ID").tag(0)
                        Text("Ввести токен").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    if selectedTab == 0 {
                        // Web OAuth
                        YandexOAuthWebView { token in
                            handleTokenReceived(token)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                    } else {
                        // Manual Token Input
                        manualTokenView
                    }
                }

                // Loading / Syncing overlay
                if isProcessing {
                    ZStack {
                        Color.black.opacity(0.80).ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .tint(Color(hex: "#FF334B")!)
                                .scaleEffect(1.4)
                            Text(statusMessage ?? "Авторизация в Яндекс ID...")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(24)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(hex: "#1C1C1E")!))
                    }
                }
            }
            .navigationTitle("Вход в Яндекс Музыку")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") {
                        dismiss()
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var manualTokenView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("OAuth-токен аккаунта")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Если вы уже получали токен Яндекс Музыки ранее (начинается с y0_...), вы можете просто вставить его сюда:")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.70))

                    SecureField("Вставьте токен y0_...", text: $manualToken)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                        .foregroundStyle(.white)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15), lineWidth: 1))
                }

                if let msg = statusMessage {
                    Text(msg)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isError ? Color.red : Color.green)
                }

                Button {
                    handleTokenReceived(manualToken)
                } label: {
                    HStack {
                        Spacer()
                        Text("Войти по токену")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: "#FF334B")!))
                }
                .buttonStyle(GlassPressStyle())
                .disabled(manualToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Зачем нужен вход:")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("• Максимальное качество 320 kbps и Lossless FLAC\n• Синхронизация ваших лайков в раздел «Мне нравится»\n• Персональная «Моя волна», обучающаяся на вашем вкусе\n• Возможность ставить лайки прямо в плеере с сохранением на сервере Яндекса")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.60))
                        .lineSpacing(3)
                }
                .padding(.top, 10)
            }
            .padding(20)
        }
    }

    private func handleTokenReceived(_ token: String) {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }

        isProcessing = true
        statusMessage = "Проверяем токен и профиль..."
        isError = false

        Task {
            let ok = await ym.loginWithToken(clean)
            if ok {
                statusMessage = "Синхронизируем лайки..."
                await ym.syncAccountData()
                isProcessing = false
                onLoggedIn?()
                dismiss()
            } else {
                isProcessing = false
                isError = true
                statusMessage = "Не удалось подтвердить токен. Проверьте правильность."
            }
        }
    }
}

// MARK: - WKWebView Representable for OAuth

struct YandexOAuthWebView: UIViewRepresentable {
    let onTokenExtracted: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTokenExtracted: onTokenExtracted)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        // Предотвращаем ошибку WebAuthn "Couldn't enable quick login" в WKWebView
        let disableWebAuthnScript = WKUserScript(
            source: """
            try {
                delete window.PublicKeyCredential;
                if (navigator.credentials) {
                    navigator.credentials.get = undefined;
                    navigator.credentials.create = undefined;
                }
            } catch(e) {}
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(disableWebAuthnScript)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true

        // Client ID: 23cabbbdc6cd418ac4b8419202a7f335 (Yandex Music iOS official client)
        let authUrlString = "https://oauth.yandex.ru/authorize?response_type=token&client_id=23cabbbdc6cd418ac4b8419202a7f335"
        if let url = URL(string: authUrlString) {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            webView.load(req)
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onTokenExtracted: (String) -> Void
        private var didExtract = false

        init(onTokenExtracted: @escaping (String) -> Void) {
            self.onTokenExtracted = onTokenExtracted
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                if checkForToken(in: url) {
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url {
                _ = checkForToken(in: url)
            }
        }

        private func checkForToken(in url: URL) -> Bool {
            guard !didExtract else { return true }
            let str = url.absoluteString

            if str.contains("access_token=") {
                if let token = extractToken(from: str) {
                    didExtract = true
                    DispatchQueue.main.async {
                        self.onTokenExtracted(token)
                    }
                    return true
                }
            }
            return false
        }

        private func extractToken(from string: String) -> String? {
            // Check fragment and query: access_token=([^&]+)
            if let regex = try? NSRegularExpression(pattern: "access_token=([^&]+)"),
               let match = regex.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)),
               match.numberOfRanges > 1 {
                let r = match.range(at: 1)
                return (string as NSString).substring(with: r)
            }
            return nil
        }
    }
}
