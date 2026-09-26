import SwiftUI
import UIKit

struct DifySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var dify = DifyService.shared

    @State private var selectedProvider: AIProvider = .nvidia
    @State private var nvidiaKeyInput: String = ""
    @State private var nvidiaURLInput: String = ""
    @State private var selectedModelId: String = "deepseek-ai/deepseek-v4.1-flash"

    @State private var difyKeyInput: String = ""
    @State private var difyURLInput: String = ""

    @State private var isTesting = false
    @State private var testResult: TestResult? = nil
    @State private var copiedPrompt = false

    enum TestResult {
        case success(Int)
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
                    VStack(spacing: 20) {
                        providerPickerSection

                        if selectedProvider == .nvidia {
                            nvidiaHeaderSection
                            nvidiaModelsSection
                            nvidiaConnectionSection
                        } else {
                            difyHeaderSection
                            difyConnectionSection
                            cloudDifyGuideSection
                            systemPromptSection
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Настройки AI Куратора")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") {
                        saveAndDismiss()
                    }
                    .font(AG.text(.body, .bold))
                    .foregroundStyle(AG.accent)
                }
            }
            .onAppear {
                selectedProvider = dify.provider
                nvidiaKeyInput = dify.nvidiaApiKey
                nvidiaURLInput = dify.nvidiaBaseURL
                selectedModelId = dify.nvidiaSelectedModel

                difyKeyInput = dify.apiKey
                difyURLInput = dify.baseURL
            }
        }
    }

    // MARK: - Provider Selector
    private var providerPickerSection: some View {
        HStack(spacing: 8) {
            ForEach(AIProvider.allCases) { prov in
                let isSelected = selectedProvider == prov
                Button {
                    Haptics.tap(.light)
                    withAnimation(AG.fastSpring) {
                        selectedProvider = prov
                        testResult = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: prov == .nvidia ? "cpu.fill" : "cloud.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(prov.title)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.6))
                    .background(
                        isSelected
                            ? LinearGradient(colors: [Color.green.opacity(0.8), Color.teal.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [Color.white.opacity(0.08), Color.white.opacity(0.04)], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.white.opacity(0.06))
        .clipShape(Capsule())
    }

    // MARK: - NVIDIA NIM Sections
    private var nvidiaHeaderSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color(hex: "#76B900") ?? .green, Color.teal],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 54, height: 54)
                    .shadow(color: (Color(hex: "#76B900") ?? .green).opacity(0.4), radius: 12)

                Image(systemName: "bolt.badge.automatic.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("NVIDIA NIM Cloud (2026)")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Text("Прямой высокоскоростной API для генерации плейлистов и рекомендаций без сторонних серверов.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    private var nvidiaModelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("МОДЕЛЬ NVIDIA (СЕНТЯБРЬ 2026)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)

            VStack(spacing: 8) {
                ForEach(NVIDIAAIModel.availableModels) { model in
                    let isSelected = selectedModelId == model.id
                    Button {
                        Haptics.tap(.light)
                        withAnimation(AG.fastSpring) {
                            selectedModelId = model.id
                        }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(isSelected ? (Color(hex: "#76B900") ?? .green) : .white.opacity(0.3))
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    Text(model.displayName)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)

                                    Text(model.badge)
                                        .font(.system(size: 10, weight: .black))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            model.id.contains("deepseek")
                                                ? Color.purple.opacity(0.8)
                                                : (Color(hex: "#76B900") ?? .green).opacity(0.8)
                                        )
                                        .clipShape(Capsule())
                                        .foregroundStyle(.white)
                                }

                                Text(model.summary)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(isSelected ? Color.white.opacity(0.12) : Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(isSelected ? (Color(hex: "#76B900") ?? .green).opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var nvidiaConnectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ПАРАМЕТРЫ NVIDIA NIM")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NVIDIA API Key (nvapi-...)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    SecureField("nvapi-...", text: $nvidiaKeyInput)
                        .padding(14)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Endpoint Base URL")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    TextField("https://integrate.api.nvidia.com/v1", text: $nvidiaURLInput)
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
                        case .success(let ms):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Соединение установлено! Пинг: \(ms) мс")
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
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isTesting ? "Проверка..." : "Проверить API ключ")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isTesting || nvidiaKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // MARK: - Dify Sections
    private var difyHeaderSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.8), Color.blue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 54, height: 54)
                    .shadow(color: Color.purple.opacity(0.4), radius: 12)

                Image(systemName: "sparkles")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Интеграция Dify Cloud")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)

            Text("Подключение к кастомным пайплайнам и ботам в облаке cloud.dify.ai.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
    }

    private var difyConnectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ПАРАМЕТРЫ DIFY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)

            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key (app-...)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))

                    SecureField("Вставьте app-...", text: $difyKeyInput)
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

                    TextField("https://api.dify.ai/v1", text: $difyURLInput)
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
                        case .success(let ms):
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Соединение успешно установлено! (\(ms) мс)")
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
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                        }
                        Text(isTesting ? "Проверка..." : "Проверить подключение")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .disabled(isTesting || difyKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    private var cloudDifyGuideSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("КАК НАСТРОИТЬ В DIFY")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 10) {
                stepRow(number: "1", text: "Откройте cloud.dify.ai и создайте приложение Chatbot.")
                stepRow(number: "2", text: "В Settings -> Model Provider добавьте NVIDIA NIM (https://integrate.api.nvidia.com/v1) с вашим nvapi ключом.")
                stepRow(number: "3", text: "Вставьте системный промпт (ниже) в инструкции бота.")
                stepRow(number: "4", text: "Скопируйте ключ API Access (app-...) и вставьте выше.")
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

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("СИСТЕМНЫЙ ПРОМПТ ДЛЯ DIFY")
                    .font(.system(size: 11, weight: .bold))
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

    // MARK: - Actions

    private func runTest() {
        isTesting = true
        testResult = nil

        dify.provider = selectedProvider
        if selectedProvider == .nvidia {
            dify.nvidiaApiKey = nvidiaKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            dify.nvidiaBaseURL = nvidiaURLInput.isEmpty ? "https://integrate.api.nvidia.com/v1" : nvidiaURLInput
            dify.nvidiaSelectedModel = selectedModelId
        } else {
            dify.apiKey = difyKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            dify.baseURL = difyURLInput.isEmpty ? "https://api.dify.ai/v1" : difyURLInput
        }

        Task {
            do {
                let res = try await dify.testConnection()
                await MainActor.run {
                    isTesting = false
                    testResult = res.success ? .success(res.latencyMs) : .failure("Сервер не ответил успешным кодом.")
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
        dify.provider = selectedProvider
        dify.nvidiaApiKey = nvidiaKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        dify.nvidiaBaseURL = nvidiaURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        dify.nvidiaSelectedModel = selectedModelId

        dify.apiKey = difyKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        dify.baseURL = difyURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        Haptics.tap(.light)
        dismiss()
    }
}
