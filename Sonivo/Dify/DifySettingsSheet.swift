import SwiftUI

struct DifySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var service = DifyService.shared
    @State private var provider: AIProvider = .nvidia
    @State private var key = ""
    @State private var endpoint = ""
    @State private var model = ""
    @State private var notice: String?
    @State private var checking = false
    @State private var testTask: Task<Void, Never>?
    @State private var deleteConfirmation = false
    @AppStorage("ai_curator.share_current_track") private var shareCurrentTrack = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Ваш AI, ваш доступ", systemImage: "key.horizontal").font(.title3.bold())
                    Text("Sonivo не предоставляет общий AI-ключ. Подключите свой провайдер; его тариф и доступность моделей определяются вашим аккаунтом.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Подключение") {
                    Picker("Провайдер", selection: $provider) {
                        Text("NVIDIA NIM").tag(AIProvider.nvidia)
                        Text("Dify").tag(AIProvider.dify)
                    }.onChange(of: provider) { _, _ in loadFields() }
                    SecureField("API-ключ", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("HTTPS адрес API", text: $endpoint).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if provider == .nvidia {
                        TextField("ID модели из кабинета NVIDIA", text: $model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("Укажите точный ID доступной вам модели. Мы не переключаем модель без вашего решения.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Проверка") {
                    Button(checking ? "Проверяем…" : "Сохранить и проверить соединение") { testConnection() }
                        .disabled(checking || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if checking { Button("Остановить проверку") { testTask?.cancel(); checking = false } }
                    if let notice { Text(notice).font(.callout).textSelection(.enabled) }
                    Text("Проверка отправит провайдеру короткий тестовый запрос; он может учитываться в вашем тарифе.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Данные и приватность") {
                    Toggle("Передавать название и исполнителя текущей песни", isOn: $shareCurrentTrack)
                    Text("Ключ хранится в Keychain на этом устройстве. Провайдер получает текст запросов и последние уточнения диалога. Название и исполнитель текущей песни — только при включённом согласии на экране куратора.")
                    Text("PCM, файлы аудио, избранное и история прослушиваний не отправляются. При дополнении подборки передаются названия её песен, чтобы исключить повторы.")
                    Button("Удалить ключ этого провайдера", role: .destructive) { deleteConfirmation = true }
                }.font(.subheadline)
            }
            .navigationTitle("Настройки AI").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { testTask?.cancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить") {
                    do { try apply(); dismiss() } catch { notice = error.localizedDescription }
                }.disabled(checking) }
            }
            .confirmationDialog("Удалить сохранённый API-ключ?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                Button("Удалить ключ", role: .destructive) {
                    testTask?.cancel(); checking = false
                    do { try service.removeCredential(provider); key = ""; notice = "Ключ удалён" }
                    catch { notice = error.localizedDescription }
                }
            }
            .onAppear { provider = service.provider; loadFields() }
            .onDisappear { testTask?.cancel() }
        }
    }
    private func loadFields() {
        testTask?.cancel(); checking = false; notice = nil
        key = provider == .nvidia ? service.nvidiaApiKey : service.apiKey
        endpoint = provider == .nvidia ? service.nvidiaBaseURL : service.baseURL
        model = service.nvidiaSelectedModel
    }
    private func apply() throws {
        AIMusicCuratorStore.shared.cancel()
        try service.configure(provider: provider, key: key, endpoint: endpoint, model: model)
    }
    private func testConnection() {
        do { try apply() } catch { notice = error.localizedDescription; return }
        checking = true; notice = nil
        testTask = Task {
            do {
                let result = try await service.testConnection()
                try Task.checkCancellation()
                notice = "Соединение работает · \(result.latencyMs) мс"
            } catch {
                if !Task.isCancelled { notice = error.localizedDescription }
            }
            if !Task.isCancelled { checking = false }
        }
    }
}
