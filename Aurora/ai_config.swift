import Foundation

// Конфигурация AI-ранжировщика. Endpoint не является секретом.
// Токен пустой в репозитории и подставляется на этапе сборки Codemagic
// из защищённой переменной SONIVO_AI_TOKEN.
enum SonivoAIConfig {
    static let endpoint = "https://sonivo-ai.siarheismazhankoy.workers.dev"
    static let token = ""
}
