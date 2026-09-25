import SwiftUI
import UIKit

struct DifySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dify = DifyService.shared

    @State private var apiKeyInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult? = nil
    @State private var copiedPrompt = false

    enum TestResult {
        case success
        case failure(String)
    }

    private let recommendedSystemPrompt = """
    Ты — персональный музыкальный AI-куратор и эксперт-диджей в приложении Sonivo.
    Твоя задача — понимать музыкальные вкусы, настроение, атмосферу и подбирать точные, качественные треки.
    Ты глубоко разбираешься во всех стилях: от современного фонка, хип-хопа, дрилла и инди-рока до синтвейва, эмбиента, классики и электроники.

    Когда пользователь просит создать подборку или плейлист:
    1. Кратко и со вкусом опиши вайб подборки (1-2 предложения).
    2. В самом конце ответа ОБЯЗАТЕЛЬНО добавь JSON-блок строго в следующем формате:

    ```json
    {
      "playlist_title": "Название плейлиста",
      "description": "Краткое описание атмосферы",
      "tracks": [
        { "artist": "Исполнитель", "title": "Название трека" },
        { "artist": "Исполнитель", "title": "Название трека" }
      ]
    }
    ```
    Не выдумывай несуществующие треки, используй реальные известные треки указанных исполнителей.
    """

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        headerSection
                        connectionSection
                        cloudDifyGuideSection
                        systemPromptSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                }
            }
            .navigationTitle("Настройки Dify AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        saveAndDismiss()
                    }
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AG.accent)
                }
            }
            .onAppear {
                apiKeyInput = dify.apiKey
                baseURLInput = dify.baseURL
            }
        }
    }

    // MARK: - Header
    private var headerSection: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 64, height: 64)
                    .shadow(color: Color.purple.opacity(0.4), radius: 12)

                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Интеграция Dify Cloud")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Text("Подключение к вашей подписке Dify Professional для генерации плейлистов на базе Claude 3.7 / DeepSeek / GPT-4o.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Connection Form
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ПАРАМЕТРЫ ПОДКЛЮЧЕНИЯ")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key (app-...)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    SecureField("Вставьте app-...", text: $apiKeyInput)
                        .padding(14)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Base URL")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    TextField("https://api.dify.ai/v1", text: $baseURLInput)
                        .padding(14)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                if let testResult {
                    HStack(spacing: 8) {
                        switch testResult {
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Соединение успешно установлено!")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.green)
                        case .failure(let err):
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                Button {
                    runTest()
                } label: {
                    HStack(spacing: 8) {
                        if isTesting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isTesting ? "Проверка..." : "Проверить подключение")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isTesting || apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .background(Color(white: 0.12).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }

    // MARK: - Guide Section
    private var cloudDifyGuideSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("КАК НАСТРОИТЬ В DIFY")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 12) {
                stepRow(number: "1", text: "Откройте cloud.dify.ai и создайте приложение типа Chatbot или Agent.")
                stepRow(number: "2", text: "В правом верхнем углу выберите любую топовую модель: Claude 3.7 Sonnet, DeepSeek R1 или GPT-4o.")
                stepRow(number: "3", text: "Вставьте системный промпт (ниже) в поле Instructions / System Prompt.")
                stepRow(number: "4", text: "Перейдите в раздел «API Access» слева, нажмите «API Secret Key» и скопируйте ключ.")
            }
            .padding(16)
            .background(Color(white: 0.12).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
        }
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.purple.opacity(0.6), in: Circle())

            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - System Prompt Section
    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("СИСТЕМНЫЙ ПРОМПТ")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))

                Spacer()

                Button {
                    UIPasteboard.general.string = recommendedSystemPrompt
                    copiedPrompt = true
                    Haptics.tap(.light)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedPrompt = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copiedPrompt ? "checkmark" : "doc.on.doc")
                        Text(copiedPrompt ? "Скопировано!" : "Скопировать")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(copiedPrompt ? .green : AG.accent)
                }
            }
            .padding(.horizontal, 4)

            Text(recommendedSystemPrompt)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func runTest() {
        isTesting = true
        testResult = nil
        dify.apiKey = apiKeyInput
        dify.baseURL = baseURLInput.isEmpty ? "https://api.dify.ai/v1" : baseURLInput

        Task {
            do {
                let success = try await dify.testConnection()
                await MainActor.run {
                    isTesting = false
                    testResult = success ? .success : .failure("Сервер не ответил успешным кодом.")
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    testResult = .failure(error.localizedDescription)
                }
            }
        }
    }

    private func saveAndDismiss() {
        dify.apiKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBase = baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        dify.baseURL = cleanBase.isEmpty ? "https://api.dify.ai/v1" : cleanBase
        Haptics.tap(.light)
        dismiss()
    }
}
