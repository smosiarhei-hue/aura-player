import SwiftUI

struct CuratorWebSettingsView: View {
    @ObservedObject private var web = CuratorWebSearch.shared
    @State private var endpoint = ""
    @State private var token = ""
    @State private var notice: String?
    var body: some View {
        Section("Веб-поиск · Firecrawl") {
            Toggle("Использовать источники из интернета", isOn: $web.enabled)
                .disabled(!web.isConfigured)
            Text("Для ответов и сборки подборок. При включении текст запроса, одно предыдущее уточнение и согласованный контекст песни отправляются вашему серверу и Firecrawl; найденные материалы — AI-провайдеру. Аудио, токен Яндекса и история аккаунта не передаются. Поиск может расходовать кредиты Firecrawl.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("HTTPS адрес сервера /search", text: $endpoint).keyboardType(.URL)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Токен доступа к серверу", text: $token)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Сохранить подключение веб-поиска") {
                AIMusicCuratorStore.shared.cancel()
                do { try web.configure(endpoint: endpoint, token: token); notice = "Сохранено. Включите веб-поиск, чтобы использовать его в следующем запросе." }
                catch { notice = error.localizedDescription }
            }
            Button("Удалить токен веб-поиска", role: .destructive) {
                AIMusicCuratorStore.shared.cancel()
                do { try web.removeCredential(); token = ""; notice = "Токен удалён" }
                catch { notice = error.localizedDescription }
            }
            if let notice { Text(notice).font(.callout) }
            Text("Ключ Firecrawl хранится только на сервере. Здесь нужен отдельный токен доступа, не ключ Firecrawl. Сервер необходимо развернуть отдельно.")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { endpoint = web.endpoint; token = web.accessToken }
    }
}
