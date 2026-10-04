import Foundation
import Testing

@Suite("Equalizer configuration")
struct EqualizerConfigurationTests {
    @Test("Every preset has ten finite bands inside the UI range")
    func presetRanges() {
        for preset in EQPresets.all {
            #expect(preset.gains.count == PlayerCore.bandFrequencies.count)
            #expect(preset.gains.allSatisfy(\.isFinite))
            #expect(preset.gains.allSatisfy { abs($0) <= PlayerCore.maximumEQGain })
        }
    }

    @Test("Persisted or imported curves are normalized to ten safe values")
    func normalization() {
        let values: [Float] = [.infinity, -99, -12, 0, 7, 12, 99]
        let normalized = PlayerCore.normalized(values)

        #expect(normalized.count == PlayerCore.bandFrequencies.count)
        #expect(normalized.allSatisfy(\.isFinite))
        #expect(normalized.allSatisfy { abs($0) <= PlayerCore.maximumEQGain })
        #expect(normalized[0] == 0)
        #expect(normalized[1] == -12)
        #expect(normalized[6] == 12)
    }
}