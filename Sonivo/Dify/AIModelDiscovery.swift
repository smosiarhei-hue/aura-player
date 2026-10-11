import Foundation

nonisolated struct AIAvailableModel: Codable, Sendable, Identifiable, Equatable {
    let id: String
    var displayName: String { id }
    var isAutomaticCandidate: Bool {
        let name = id.lowercased()
        let excluded = ["embed", "rerank", "retriev", "whisper", "tts", "speech", "audio", "image", "diffusion", "stable-diffusion", "flux", "guard", "safety", "reward"]
        guard !excluded.contains(where: name.contains) else { return false }
        return ["chat", "instruct", "llama", "qwen", "nemotron", "mistral", "mixtral", "deepseek", "gemma", "phi-", "gpt", "kimi", "jamba", "command"].contains(where: name.contains)
    }
}
nonisolated enum AIModelDiscovery {
    private struct Catalog: Decodable, Sendable { let data: [AIAvailableModel] }
    static func decode(_ data: Data) throws -> [AIAvailableModel] {
        guard data.count <= 2_000_000 else { throw DifyError.invalidResponse }
        var seen = Set<String>()
        return try JSONDecoder().decode(Catalog.self, from: data).data.filter {
            !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.id.count <= 256 && seen.insert($0.id).inserted
        }.sorted { $0.id < $1.id }
    }
    /// Catalog names are hints, not proof of access: the selected model must pass a chat probe.
    static func recommended(in models: [AIAvailableModel], preserving current: String) -> String? {
        if models.contains(where: { $0.id == current && $0.isAutomaticCandidate }) { return current }
        return models.filter(\.isAutomaticCandidate).sorted {
            let lhs = automaticRank($0.id), rhs = automaticRank($1.id)
            return lhs != rhs ? lhs < rhs : $0.id < $1.id
        }.first?.id
    }
    /// Size/reasoning names are only latency hints; access and actual speed still require a probe.
    private static func automaticRank(_ id: String) -> Int {
        let name = id.lowercased()
        let reasoning = ["deepseek-r1", "qwq", "reason", "thinking"].contains(where: name.contains)
        var sizePenalty = 40
        if let range = name.range(of: "[0-9]+(?:\\.[0-9]+)?b(?:[^a-z]|$)", options: .regularExpression) {
            let matched = String(name[range]).split(separator: "b").first.map(String.init) ?? ""
            if let size = Double(matched) { sizePenalty = size <= 16 ? 0 : (size <= 32 ? 20 : 80) }
        }
        return (reasoning ? 200 : 0) + sizePenalty + (name.contains("instruct") ? 0 : 10)
    }

}
