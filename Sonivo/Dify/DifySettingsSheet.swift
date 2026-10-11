import SwiftUI

struct DifySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = DifyService.shared
    @State private var provider: AIProvider = .nvidia
    @State private var key = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var models: [AIAvailableModel] = []
    @State private var notice: String?
    @State private var checking = false
    @State private var connectionProgress = "Проверяем подключение…"
    @State private var loadingModels = false
    @State private var operation: Task<Void, Never>?
    @State private var operationID = UUID()
    @State private var deleteConfirmation = false
    @AppStorage("nvidia_curator.auto_selection") private var autoSelection = true
    @AppStorage("ai_curator.share_current_track") private var shareCurrentTrack = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Подключение куратора", systemImage: "sparkles").font(.title3.bold())
                    Text("Сохранённое подключение подхватится автоматически. Для нового подключения достаточно ключа: адрес уже заполнен, модель можно подобрать и проверить автоматически.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Подключение") {
                    Picker("Сервис", selection: $provider) {
                        Text("NVIDIA NIM").tag(AIProvider.nvidia)
                        Text("Dify").tag(AIProvider.dify)
                    }.onChange(of: provider) { _, _ in loadFields(); refreshModels() }
                    SecureField("API-ключ", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider == .nvidia {
                        Picker("Модель", selection: $model) {
                            Text("Лучшая доступная для Куратора · авто").tag("")
                            if !model.isEmpty && !models.contains(where: { $0.id == model }) {
                                Text(model).tag(model)
                            }
                            ForEach(models) { item in Text(item.displayName).tag(item.id) }
                        }.onChange(of: model) { _, _ in if checking { cancel() } }
                        if loadingModels { ProgressView("Получаем доступные модели…") }
                        Button("Обновить список моделей") { refreshModels() }
                            .disabled(checking || loadingModels || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("Подобрать автоматически: проверим подходящие модели из актуального каталога, включая формат подборок. Не более 3 проверок; недоступные модели пропускаются. Ручной выбор не меняется сам.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Модель берётся из настроек приложения Dify", systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                    DisclosureGroup("Дополнительно") {
                        TextField("HTTPS адрес API", text: $endpoint).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .onChange(of: endpoint) { _, _ in models = [] }
                        if provider == .nvidia {
                            TextField("Точный ID модели, если каталог недоступен", text: $model)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                }
                .disabled(checking || loadingModels)
                Section {
                    Button(checking ? "Проверяем подключение…" : "Подключить и проверить") { connect() }
                        .disabled(checking || loadingModels || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if checking {
                        ProgressView(connectionProgress)
                        Text("Каталог: до 45 секунд. Автовыбор: до 2 минут суммарно и не более 3 моделей. Ручная проверка: до 2 минут. Можно остановить.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if checking || loadingModels { Button("Остановить") { cancel() } }
                    if let notice { Text(notice).font(.callout).textSelection(.enabled) }
                    Text("Ключ и выбранная модель сохранятся только после успешной проверки. Автовыбор может выполнить до 3 коротких запросов, которые учитываются в тарифе сервиса. Успех проверки формата не гарантирует точность каждой рекомендации.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                CuratorWebSettingsView()
                Section("Данные и приватность") {
                    Toggle("Передавать название и исполнителя текущей песни", isOn: $shareCurrentTrack)
                    Text("Ключ хранится в Keychain на этом устройстве. AI получает текст запросов и предыдущие уточнения. Название и исполнитель песни — только с вашим согласием.")
                    Text("Аудио, избранное и история прослушиваний не отправляются. Для дополнения подборки передаются названия уже выбранных песен.")
                    Text("Вход в музыкальный аккаунт не даёт AI-ключ. Нужен личный ключ выбранного сервиса или отдельно настроенное подключение приложения.")
                    Button("Удалить ключ этого сервиса", role: .destructive) { deleteConfirmation = true }
                }.font(.subheadline)
            }
            .navigationTitle("Настройки куратора").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { cancel(); dismiss() } }
            }
            .confirmationDialog("Удалить сохранённый API-ключ?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                Button("Удалить ключ", role: .destructive) {
                    cancel()
                    do { try service.removeCredential(provider); key = ""; notice = "Ключ удалён" }
                    catch { notice = error.localizedDescription }
                }
            }
            .onAppear { provider = service.provider; loadFields(); refreshModels() }
            .onDisappear { cancel() }
        }
    }
    private func cancel() {
        operation?.cancel(); operation = nil; operationID = UUID(); checking = false; loadingModels = false
    }
    private func loadFields() {
        cancel(); notice = nil; models = []
        key = provider == .nvidia ? service.nvidiaApiKey : service.apiKey
        endpoint = provider == .nvidia ? service.nvidiaBaseURL : service.baseURL
        model = provider == .nvidia ? (autoSelection ? "" : service.nvidiaSelectedModel) : ""
    }
    private func refreshModels() {
        guard provider == .nvidia, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancel(); loadingModels = true
        let token = operationID, selectedKey = key, selectedEndpoint = endpoint
        operation = Task {
            do {
                let available = try await service.discoverModels(key: selectedKey, endpoint: selectedEndpoint)
                try Task.checkCancellation(); guard operationID == token else { return }
                models = available
                if available.isEmpty { notice = "Сервис вернул пустой каталог. Попробуйте позже или укажите модель в дополнительных настройках." }
            } catch {
                guard operationID == token, !Task.isCancelled else { return }
                notice = "Список моделей недоступен: \(error.localizedDescription) Сохранённую модель можно продолжить использовать."
            }
            guard operationID == token else { return }; loadingModels = false; operation = nil
        }
    }
    private func connect() {
        cancel(); checking = true; notice = nil; connectionProgress = "Проверяем подключение…"
        let token = operationID, selectedProvider = provider, selectedKey = key, selectedEndpoint = endpoint, selectedModel = model
        AIMusicCuratorStore.shared.cancel()
        operation = Task {
            do {
                let chosen = try await service.connect(provider: selectedProvider, key: selectedKey,
                    endpoint: selectedEndpoint, model: selectedModel.isEmpty ? nil : selectedModel) { progress in
                    if operationID == token { connectionProgress = progress }
                }
                try Task.checkCancellation(); guard operationID == token else { return }
                // Finish the operation before updating Picker state so onChange does not cancel success.
                checking = false; operation = nil
                if selectedProvider == .nvidia { autoSelection = selectedModel.isEmpty }
                model = selectedModel.isEmpty ? "" : chosen
                notice = selectedProvider == .dify ? "Подключено. Модель настроена в Dify." : "Подключено · \(chosen)"
            } catch {
                guard operationID == token, !Task.isCancelled else { return }
                checking = false; operation = nil; notice = error.localizedDescription
            }
        }
    }
}
