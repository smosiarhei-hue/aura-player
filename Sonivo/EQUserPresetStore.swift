import Foundation
import Observation

nonisolated struct SavedEQPreset: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let gains: [Float]
    let frequencies: [Float]?
    init(id: UUID, name: String, gains: [Float], frequencies: [Float]? = nil) {
        self.id = id; self.name = name; self.gains = gains; self.frequencies = frequencies
    }
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
            case .invalidCurve: return "Нужны 10 конечных значений: от −15 до +15 дБ для каждой полосы."
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
            if decoded.contains(where: { $0.frequencies == EQGainLimits.previousCompactFrequencies }),
               defaults.data(forKey:"eq.userPresets.40Hz.backup") == nil {
                defaults.set(data,forKey:"eq.userPresets.40Hz.backup")
            }
            if decoded.contains(where: { $0.frequencies != EQGainLimits.frequencies }),
               defaults.data(forKey: "eq.userPresets.reference6.backup") == nil {
                defaults.set(data, forKey: "eq.userPresets.reference6.backup")
            }
            if decoded.contains(where: {
                $0.frequencies == EQGainLimits.previousReferenceFrequencies
                    || $0.frequencies == EQGainLimits.previousBassTightFrequencies
            }),
               defaults.data(forKey: "eq.userPresets.bassTight6.backup") == nil {
                defaults.set(data, forKey: "eq.userPresets.bassTight6.backup")
            }
            if decoded.contains(where: { $0.frequencies == EQGainLimits.previousStandard10Frequencies }),
               defaults.data(forKey: "eq.userPresets.standard10.backup") == nil {
                defaults.set(data, forKey: "eq.userPresets.standard10.backup")
            }
            if decoded.contains(where: { $0.frequencies != EQGainLimits.frequencies }),
               defaults.data(forKey: "eq.userPresets.bassShake10.backup") == nil {
                defaults.set(data, forKey: "eq.userPresets.bassShake10.backup")
            }
            presets = decoded.map { preset in
                let source = preset.frequencies ?? (preset.gains.count == 29 ? EQGainLimits.denseFrequencies : EQGainLimits.legacyFrequencies)
                let gains: [Float]
                if source == EQGainLimits.frequencies {
                    gains = EQGainLimits.normalized(preset.gains)
                } else {
                    gains = EQGainLimits.normalized(
                        EQGainLimits.resample(preset.gains, from: source, to: EQGainLimits.frequencies)
                    )
                }
                return SavedEQPreset(id:preset.id,name:preset.name,gains:gains,frequencies:EQGainLimits.frequencies)
            }
            if presets != decoded {
                if defaults.data(forKey:"eq.userPresets.compact10.backup") == nil { defaults.set(data,forKey:"eq.userPresets.compact10.backup") }
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
        let preset = SavedEQPreset(id: UUID(), name: trimmed, gains: EQGainLimits.normalized(gains), frequencies: EQGainLimits.frequencies)
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
        return gains.count == EQGainLimits.frequencies.count && gains.enumerated().allSatisfy {
            $0.element.isFinite && EQGainLimits.range(at:$0.offset).contains($0.element)
        }
    }
    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func isValid(_ preset: SavedEQPreset) -> Bool {
        let trimmed = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 64 else { return false }
        if let frequencies = preset.frequencies {
            let known = frequencies == EQGainLimits.frequencies
                || frequencies == EQGainLimits.previousStandard10Frequencies
                || frequencies == EQGainLimits.previousBassTightFrequencies
                || frequencies == EQGainLimits.previousReferenceFrequencies
                || frequencies == EQGainLimits.compact10Frequencies
                || frequencies == EQGainLimits.previousCompactFrequencies
            if frequencies == EQGainLimits.frequencies { return validGains(preset.gains) }
            if frequencies == EQGainLimits.previousStandard10Frequencies
                || frequencies == EQGainLimits.previousBassTightFrequencies
                || frequencies == EQGainLimits.previousReferenceFrequencies {
                return preset.gains.count == frequencies.count && preset.gains.enumerated().allSatisfy {
                    $0.element.isFinite && EQGainLimits.range(at: $0.offset).contains($0.element)
                }
            }
            return known && preset.gains.count == frequencies.count && preset.gains.enumerated().allSatisfy {
                $0.element.isFinite && (-12...(frequencies[$0.offset] <= 250 ? Float(18) : Float(12))).contains($0.element)
            }
        }
        let source = preset.gains.count == 29 ? EQGainLimits.denseFrequencies : EQGainLimits.legacyFrequencies
        return preset.gains.count == source.count && preset.gains.enumerated().allSatisfy {
            $0.element.isFinite && (-12...(source[$0.offset] <= (source.count == 29 ? 250 : 125) ? Float(18) : Float(12))).contains($0.element)
        }
    }
}
