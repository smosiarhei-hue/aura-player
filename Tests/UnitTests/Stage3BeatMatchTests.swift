import Foundation
import MixModels
import MixPlanner
import Testing
import TrackAnalysis

@Suite("AutoMix Stage 3")
struct Stage3BeatMatchTests {
    @Test("Close tempos lock with A held", arguments: [(120.0,128.0),(128.0,120.0),(110.0,112.0)])
    func tempoPairs(pair: (Double, Double)) {
        let match = BeatGridSynchronization.tempoMatch(aBPM: Float(pair.0), bBPM: Float(pair.1))
        #expect(match != nil)
        // Prefer A locked when B can stretch within ±8%.
        if abs(Float(pair.0) / Float(pair.1) - 1) <= 0.085 {
            #expect(match?.rateA == 1.0)
            #expect(match?.targetBPM == Float(pair.0))
            #expect(abs((match?.rateB ?? 0) - 1) <= 0.08)
        } else {
            #expect(match?.rateB == 1.0)
            #expect(abs((match?.rateA ?? 0) - 1) <= 0.08)
        }
        let rateA = match?.rateA ?? 0
        let rateB = match?.rateB ?? 0
        #expect(abs(Float(pair.0) * rateA - Float(pair.1) * rateB) < 0.5)
    }

    @Test("Moderate gaps balance both decks within their actual playback range")
    func balancedTempo() {
        let balancedPairs: [(Float, Float)] = [(123, 136), (136, 123), (105.5, 94)]
    for (a, b) in balancedPairs {
            let match = BeatGridSynchronization.tempoMatch(aBPM: a, bBPM: b)
            #expect(match != nil)
            guard let match else { continue }
            #expect(abs(match.rateA - 1) <= 0.080001)
            #expect(abs(match.rateB - 1) <= 0.080001)
            #expect(abs(a * match.rateA - b * match.rateB) < 0.001)
        }
    }

    @Test("Unsafe / wide tempo falls back")
    func unsafeTempo() {
        #expect(BeatGridSynchronization.tempoMatch(aBPM: 100, bBPM: 135) == nil)
        // Field 1148/1151 sludge pairs — must not fake a common grid.
        #expect(BeatGridSynchronization.tempoMatch(aBPM: 66, bBPM: 99) == nil)
        #expect(BeatGridSynchronization.tempoMatch(aBPM: 91, bBPM: 120) == nil)
        #expect(BeatGridSynchronization.tempoMatch(aBPM: 90, bBPM: 174) == nil)
    }

    @Test("Camelot wheel compatibility")
    func camelot() {
        #expect(CamelotCompatibility.areCompatible("8A", "8B"))
        #expect(CamelotCompatibility.areCompatible("8A", "9A"))
        #expect(CamelotCompatibility.areCompatible("1A", "12A"))
        #expect(!CamelotCompatibility.areCompatible("8A", "2B"))
    }

    @Test("Camelot search considers shifted neighboring keys without exceeding the limit")
    func camelotShiftedNeighbors() {
        // 12A shifted by one semitone becomes 5A or 7A, adjacent to 6A.
        let match = CamelotCompatibility.match("6A", "12A", maxSemitones: 1)
        #expect(match.isHarmonicallyViable)
        #expect(!match.isNaturallyCompatible)
        #expect(abs(match.pitchShiftCents) == 100)
        #expect(match.description.contains("совместимо с 6A"))
        let withoutPitch = CamelotCompatibility.match("6A", "12A", maxSemitones: 0)
        #expect(!withoutPitch.isHarmonicallyViable)
        #expect(withoutPitch.pitchShiftCents == 0)
        // E minor (9A) cannot be made compatible with G minor (6A) by ±1.
        let clash = CamelotCompatibility.match("6A", "9A", maxSemitones: 1)
        #expect(!clash.isHarmonicallyViable)
        #expect(abs(clash.pitchShiftCents) == 100)
        #expect(clash.description.contains("partial"))
    }

    @Test("Reliable pair selects beatmatched transition")
    func beatmatchedPlan() {
        let plan = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A"),
                                   to: profile("b", bpm: 128, key: "8B"),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(plan.type == .beatmatchedLong)
        #expect(plan.bars == 16)
        #expect(plan.rateA == 1.0)
        #expect(plan.rateB != 1.0)
    }

    @Test("Confidence ladder selects expected duration and type")
    func confidenceLadder() {
        let high = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A", confidence: 0.9, stability: 0.95),
                                   to: profile("b", bpm: 128, key: "8B", confidence: 0.9, stability: 0.95),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(high.type == .beatmatchedLong); #expect(high.bars == 16)

        let medium = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A", confidence: 0.75, stability: 0.88),
                                     to: profile("b", bpm: 128, key: "8B", confidence: 0.75, stability: 0.88),
                                     aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(medium.type == .beatmatchedShort); #expect(medium.bars == 8)

        let low = MixPlanner.plan(from: profile("a", bpm: 120, key: "8A", confidence: 0.60, stability: 0.78),
                                  to: profile("b", bpm: 128, key: "8B", confidence: 0.60, stability: 0.78),
                                  aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(low.type == .crossfade)
    }

    @Test("Phase comparison preserves opposite signs")
    func signedPhaseError() {
        let error = BeatGridSynchronization.phaseErrorMilliseconds(
            outgoingBeat: 0.1, incomingBeat: -0.1, rateA: 1, rateB: 1
        )
        #expect(abs(error - 200) < 0.001)
    }

    @Test("Low confidence uses crossfade")
    func fallback() {
        let plan = MixPlanner.plan(from: profile("a", bpm: 120, confidence: 0.4),
                                   to: profile("b", bpm: 128),
                                   aMeta: meta("a"), bMeta: meta("b"), settings: MixSettings())
        #expect(plan.type == .crossfade)
        #expect(plan.reason.contains("Fallback"))
    }

    private func meta(_ id: String) -> TrackMeta {
        TrackMeta(id: TrackID(raw: id), title: id, artist: "Test", albumID: nil, durationSec: 240, artworkURL: nil)
    }
    private func profile(_ id: String, bpm: Float, key: String? = nil, confidence: Float = 1, stability: Float = 1) -> TrackProfile {
        TrackProfile(trackID: TrackID(raw: id), durationSec: 240, sourceSampleRate: 48_000,
                     sourceBitrateKbps: nil, bpm: bpm,
                     beatsSec: Array(stride(from: 0.0, to: 240, by: 0.5)),
                     downbeatsSec: Array(stride(from: 0.0, to: 240, by: 2)),
                     phraseStartsSec: Array(stride(from: 0.0, to: 240, by: 16)),
                     tempoStability: stability, camelotKey: key, integratedLUFS: -14,
                     loudnessCurveLUFS: [], energyCurve: [], hasFadeOut: false,
                     endsInSilence: false, vocalPresence: [], segments: [],
                     mixInSec: 8, mixOutSec: 220, mixable: true,
                     confidence: Confidence(bpm: confidence, downbeats: confidence, key: key == nil ? 0 : 1))
    }
}
