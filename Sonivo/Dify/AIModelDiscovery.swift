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
            let lhs = $0.id.lowercased().contains("instruct"), rhs = $1.id.lowercased().contains("instruct")
            return lhs != rhs ? lhs : $0.id < $1.id
        }.first?.id
    }
}
