import Foundation

/// Describes received media, never the user's requested quality or a guessed bitrate.
nonisolated struct PlaybackQualityFacts: Equatable, Sendable {
    let codec: String?
    let bitrate: Int?

    init(codec: String?, bitrate: Int?) {
        let normalized = codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-mp4", with: "")
        self.codec = normalized?.isEmpty == false ? normalized : nil
        self.bitrate = bitrate.flatMap { $0 > 0 ? $0 : nil }
    }
    /// Received source ranking, never requested settings or invented bitrate values.
    func isPreferred(over other: PlaybackQualityFacts) -> Bool {
        if isLossless != other.isLossless { return isLossless }
        if (bitrate ?? 0) != (other.bitrate ?? 0) { return (bitrate ?? 0) > (other.bitrate ?? 0) }
        let rank = ["aac": 3, "he-aac": 2, "mp3": 1]
        return (rank[codec ?? ""] ?? 0) > (rank[other.codec ?? ""] ?? 0)
    }
    var isLossless: Bool { ["flac", "alac", "pcm", "wav", "aiff"].contains(codec ?? "") }
    var isLossy: Bool { ["mp3", "aac", "he-aac", "opus", "ogg", "vorbis"].contains(codec ?? "") }
    var badge: String {
        if isLossless { return "Lossless" }
        if let bitrate { return "\(bitrate) kbps" }
        return codec?.uppercased() ?? "Качество уточняется"
    }
    var title: String {
        if isLossless { return "Без потерь (Lossless)" }
        return codec == nil && bitrate == nil ? "Качество уточняется" : badge
    }
    var detail: String? {
        guard codec != nil || bitrate != nil else { return nil }
        return [codec.map { "Формат: \($0.uppercased())" }, bitrate.map { "\($0) кбит/с" }]
            .compactMap { $0 }.joined(separator: " • ")
    }
    var description: String {
        if isLossless { return "Источник текущего воспроизведения использует кодек без потерь. Битрейт сам по себе не подтверждает Hi-Res; параметры аудиовыхода зависят от устройства и подключения." }
        if isLossy { return "Текущий источник использует сжатие с потерями. Ниже показаны полученные данные формата и битрейта, а не выбранное предпочтение качества." }
        return "Подтверждённых данных о формате текущего воспроизведения пока нет. Выбранное качество — предпочтение, а не гарантия полученного потока."
    }
}
