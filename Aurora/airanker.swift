import Foundation

// MARK: - AI Ranker Service
// Отправляет в защищённый Cloudflare Worker только метаданные кандидатов
// (ID, название, исполнитель, альбом, длительность). Никакие музыкальные
// токены и ссылки на поток сюда не передаются. Gemini возвращает лишь
// порядок существующих ID — придумать треки невозможно.

nonisolated struct AIRankerService: Sendable {
    struct Candidate: Codable, Sendable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    struct Seed: Codable, Sendable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    struct RankResponse: Decodable, Sendable {
        let category: String
        let ordered_ids: [String]
        let explanation: String?
    }

    static let shared = AIRankerService()

    var isConfigured: Bool {
        !SonivoAIConfig.endpoint.isEmpty && !SonivoAIConfig.token.isEmpty
    }

    func rank(seed: Seed, intent: String, candidates: [Candidate]) async -> RankResponse? {
        guard isConfigured,
              let url = URL(string: SonivoAIConfig.endpoint + "/rank") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(SonivoAIConfig.token)", forHTTPHeaderField: "Authorization")

        struct Payload: Encodable, Sendable {
            let intent: String
            let seed: Seed
            let candidates: [Candidate]
        }

        request.httpBody = try? JSONEncoder().encode(
            Payload(intent: intent, seed: seed, candidates: candidates)
        )

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }

        return try? JSONDecoder().decode(RankResponse.self, from: data)
    }
}
