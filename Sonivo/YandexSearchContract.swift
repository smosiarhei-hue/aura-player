import Foundation

nonisolated enum YandexSearchKind: String, CaseIterable, Identifiable, Sendable {
    case all, track, artist, album
    var id: String { rawValue }
    var title: String {
        switch self { case .all: "Всё"; case .track: "Треки"; case .artist: "Исполнители"; case .album: "Альбомы" }
    }
}

nonisolated enum YandexSearchError: Error, LocalizedError {
    case authentication, limited, unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .authentication: "Яндекс не подтвердил доступ. Переподключите аккаунт в настройках."
        case .limited: "Яндекс временно ограничил запросы. Повторите поиск чуть позже."
        case .unavailable: "Не удалось подключиться к Яндекс Музыке. Проверьте интернет и повторите поиск."
        case .invalidResponse: "Яндекс вернул непонятный ответ. Попробуйте повторить поиск."
        }
    }
}

nonisolated enum YandexSearchContract {
    static func clean(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
    static func url(base: String, text: String, kind: YandexSearchKind, page: Int, noCorrect: Bool) throws -> URL {
        guard var parts=URLComponents(string: base+"/search") else { throw URLError(.badURL) }
        parts.queryItems=[URLQueryItem(name: "text",value: clean(text)),
                          URLQueryItem(name: "type",value: kind.rawValue),
                          URLQueryItem(name: "page",value: String(max(0,page))),
                          URLQueryItem(name: "nocorrect",value: noCorrect ? "true" : "false"),
                          URLQueryItem(name: "playlist-in-best",value: "false")]
        guard let url=parts.url else { throw URLError(.badURL) }
        return url
    }
    static func validate(_ response: URLResponse, bytes: Int) throws {
        guard let http=response as? HTTPURLResponse else { throw YandexSearchError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401,403: throw YandexSearchError.authentication
        case 429: throw YandexSearchError.limited
        default: throw YandexSearchError.unavailable
        }
        guard bytes <= 8_000_000 else { throw YandexSearchError.invalidResponse }
    }
    static func hasNext(total: Int?, perPage: Int?, page: Int) -> Bool {
        guard let total, let perPage, total>0, perPage>0, page>=0 else { return false }
        return page < (total-1)/perPage
    }
}
