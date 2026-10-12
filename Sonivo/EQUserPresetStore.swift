import Foundation
import Observation

nonisolated struct SavedEQPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let gains: [Float]
}

/// Only control metadata is persisted. No audio, PCM or system volume is stored.
@Observable @MainActor
final class EQUserPresetStore {
    private(set) var presets: [SavedEQPreset] = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "eq.userPresets.v1"

    nonisolated enum SaveError: LocalizedError {
        case invalidName, duplicateName, invalidCurve, invalidArchive
        var errorDescription: String? {
            switch self {
            case .invalidName: return "Введи название от 1 до 64 символов."
            case .duplicateName: return "Пресет с таким названием уже есть. Выбери другое название."
            case .invalidCurve: return "Нужны 29 конечных значений: НЧ от −12 до +18 дБ, остальные от −12 до +12 дБ."
            case .invalidArchive: return "Сохранённые пресеты повреждены. Они не были перезаписаны."
            }
        }
    }
    @ObservationIgnored private var archiveIsValid = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: key) else { return }
        do {
            let decoded = try JSONDecoder().decode([SavedEQPreset].self, from: data)
            guard decoded.allSatisfy({ Self.isValid($0) }),
                  Set(decoded.map(\.id)).count == decoded.count,
                  Set(decoded.map { Self.nameKey($0.name) }).count == decoded.count else {
                archiveIsValid = false
                return
            }
            presets = decoded.map { SavedEQPreset(id:$0.id,name:$0.name,gains:EQGainLimits.normalized($0.gains)) }
            if decoded.contains(where: { $0.gains.count == 10 }) {
                if defaults.data(forKey:"eq.userPresets.dense29.backup") == nil { defaults.set(data,forKey:"eq.userPresets.dense29.backup") }
                defaults.set(try JSONEncoder().encode(presets),forKey:key)
            }
        } catch { archiveIsValid = false }
    }

    @discardableResult
    func save(name: String, gains: [Float]) throws -> SavedEQPreset {
        guard archiveIsValid else { throw SaveError.invalidArchive }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { throw SaveError.invalidName }
        guard Self.validGains(gains) else { throw SaveError.invalidCurve }
        guard !presets.contains(where: { Self.nameKey($0.name) == Self.nameKey(trimmed) }) else {
            throw SaveError.duplicateName
        }
        let preset = SavedEQPreset(id: UUID(), name: trimmed, gains: EQGainLimits.normalized(gains))
        try persist(presets + [preset])
        return preset
    }

    func delete(id: UUID) throws {
        guard archiveIsValid else { throw SaveError.invalidArchive }
        try persist(presets.filter { $0.id != id })
    }

    private func persist(_ next: [SavedEQPreset]) throws {
        let encoded = try JSONEncoder().encode(next)
        defaults.set(encoded, forKey: key)
        presets = next
    }
    private static func validGains(_ gains: [Float]) -> Bool {
        if gains.count == 10 {
            return gains.enumerated().allSatisfy { $0.element.isFinite && (-12...($0.offset < 3 ? Float(18) : Float(12))).contains($0.element) }
        }
        return gains.count == EQGainLimits.frequencies.count && gains.enumerated().allSatisfy {
            $0.element.isFinite && EQGainLimits.range(at:$0.offset).contains($0.element)
        }
    }
    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func isValid(_ preset: SavedEQPreset) -> Bool {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 64 && validGains(preset.gains)
    }
}
