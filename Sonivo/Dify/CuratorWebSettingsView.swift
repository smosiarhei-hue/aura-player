import SwiftUI

struct CuratorWebSettingsView: View {
    @ObservedObject private var web = CuratorWebSearch.shared
    @State private var key = ""
    @State private var notice: String?
    var body: some View {
        Section("Веб-поиск · Firecrawl") {
            SecureField("Личный API-ключ Firecrawl", text: $key)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Сохранить и включить") {
                AIMusicCuratorStore.shared.cancel()
                do { try web.configure(key: key); notice = "Ключ сохранён, веб-поиск включён. Адрес API настроен автоматически." }
                catch { notice = error.localizedDescription }
            }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Toggle("Использовать источники из интернета", isOn: $web.enabled)
                .disabled(!web.isConfigured)
            Text("После сохранения ключа Куратор автоматически ищет источники для ответов и подборок. Cloudflare и адрес сервера не нужны. Настройка сохраняется между запусками.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Запрос, одно предыдущее уточнение и согласованный контекст песни отправляются прямо в Firecrawl; найденные материалы — AI-провайдеру. Аудио, токен Яндекса и история аккаунта не передаются. Сохранение включает поиск и означает согласие на эту передачу; запросы расходуют кредиты Firecrawl.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Для экономии: до 3 страниц на поиск, кеш одинаковых запросов на 15 минут, максимум 60 новых поисков в сутки на этом устройстве. Ключ хранится в Keychain; в приложение не встроен общий ключ.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Удалить ключ Firecrawl", role: .destructive) {
                AIMusicCuratorStore.shared.cancel()
                do { try web.removeCredential(); key = ""; notice = "Ключ удалён, веб-поиск выключен" }
                catch { notice = error.localizedDescription }
            }.disabled(!web.isConfigured)
            if let notice { Text(notice).font(.callout) }
        }.onAppear { key = web.apiKey }
    }
}
