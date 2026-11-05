import Foundation
import MixPlanner
import Testing

@Suite("Mood AutoMix")
struct MoodAutomixTests {
    @Test("A hot outro hands off in a few seconds at the top of the next song")
    func tightWhenBothEndsAreAlreadyUp() {
        let placed = MoodAutomix.placed(
            outgoingDuration: 210,
            incomingDuration: 200,
            outgoingTail: Array(repeating: 0.9, count: 24),
            incomingHead: Array(repeating: 0.88, count: 20)
        )
        #expect(placed.mood == "tight")
        #expect(placed.blendSec < 9.5)
        #expect(placed.blendSec >= MoodAutomix.shortestBlendSec)
        #expect(placed.incomingStartSec < 1)
        #expect(placed.landProgress < 0.75)
        #expect(placed.outgoingCueSec > 190)
    }

    @Test("A fade under a late vocal is a long wash that waits for the vocal")
    func washWaitsForTheIncomingRise() {
        let tail = (0..<28).map { Float(0.95 - Double($0) * 0.028) }
        var head = Array(repeating: Float(0.18), count: 14)
        head.append(contentsOf: Array(repeating: Float(0.86), count: 12))
        let placed = MoodAutomix.placed(
            outgoingDuration: 200,
            incomingDuration: 220,
            outgoingTail: tail,
            incomingHead: head
        )
        #expect(placed.mood == "wash")
        #expect(placed.blendSec >= 15)
        #expect(placed.incomingStartSec >= 12)
        #expect(placed.incomingStartSec <= 16)
        #expect(placed.landProgress >= 0.88)
    }

    @Test("Hot and fading pairs do not share one blend length")
    func moodsDoNotCollapseToOneLength() {
        let hot = MoodAutomix.placed(
            outgoingDuration: 200,
            incomingDuration: 200,
            outgoingTail: Array(repeating: 0.92, count: 20),
            incomingHead: Array(repeating: 0.9, count: 16)
        )
        let fade = (0..<30).map { Float(0.9 - Double($0) * 0.025) }
        let wash = MoodAutomix.placed(
            outgoingDuration: 200,
            incomingDuration: 200,
            outgoingTail: fade,
            incomingHead: Array(repeating: 0.2, count: 6) + Array(repeating: 0.8, count: 10)
        )
        #expect(wash.blendSec - hot.blendSec > 6)
        #expect(hot.incomingStartSec < 1)
        #expect(wash.incomingStartSec > 4)
    }

    @Test("Cold start is a short runway until the files are scanned")
    func provisionalVariesAndDoesNotSkipAFixedIntro() {
        let short = MoodAutomix.placed(outgoingDuration: 150, incomingDuration: 140)
        let long = MoodAutomix.placed(outgoingDuration: 240, incomingDuration: 230)
        #expect(short.mood == "scan")
        #expect(long.mood == "scan")
        #expect(short.incomingStartSec == 0)
        #expect(long.incomingStartSec == 0)
        // Keep the silent scan short — the live mix retargets after energy read.
        #expect(short.blendSec >= 8 && short.blendSec <= 12)
        #expect(long.blendSec >= 8 && long.blendSec <= 12)
        #expect(long.blendSec >= short.blendSec)
        #expect(abs(short.blendSec - 16) > 0.5)
        #expect(abs(long.blendSec - 22) > 0.5)
    }

    @Test("A phrase dip sets the window from that dip")
    func phraseFollowsTheValley() {
        var tail = Array(repeating: Float(0.55), count: 24)
        tail[8] = 0.22
        tail[9] = 0.20
        tail[10] = 0.24
        let placed = MoodAutomix.placed(
            outgoingDuration: 180,
            incomingDuration: 190,
            outgoingTail: tail,
            incomingHead: Array(repeating: 0.7, count: 12)
        )
        #expect(placed.mood == "phrase")
        #expect(placed.blendSec >= 9)
        #expect(placed.blendSec <= 18)
        #expect(placed.incomingStartSec < 1)
    }
}
