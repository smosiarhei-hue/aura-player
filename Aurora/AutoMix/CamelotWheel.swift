import Foundation

// MARK: - Camelot Wheel
//
// Static harmonic-compatibility table used by the transition planner.
// Minor keys are the A side, major keys the B side, e.g. A minor = 8A,
// C major = 8B (relative keys always share the same number).

nonisolated struct CamelotPosition: Codable, Sendable, Equatable {
    /// 1...12
    var number: Int
    var isMajor: Bool

    var label: String { "\(number)\(isMajor ? "B" : "A")" }

    init(number: Int, isMajor: Bool) {
        self.number = ((number - 1) % 12 + 12) % 12 + 1
        self.isMajor = isMajor
    }

    init(key: MusicalKey) {
        // Every minor key shares its Camelot number with its relative major,
        // which sits three semitones above it.
        let relativeMajor = key.mode == .major
            ? key.normalizedPitchClass
            : (key.normalizedPitchClass + 3) % 12
        // Position on the circle of fifths, C major = 8B.
        let fifths = (relativeMajor * 7) % 12
        self.init(number: 8 + fifths, isMajor: key.mode == .major)
    }

    init?(label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespaces).uppercased()
        guard let side = trimmed.last, side == "A" || side == "B" else { return nil }
        guard let value = Int(trimmed.dropLast()), value >= 1, value <= 12 else { return nil }
        self.init(number: value, isMajor: side == "B")
    }

    /// 0 = same position, 1 = neighbour on the wheel or relative major/minor,
    /// higher values are progressively more dissonant.
    func distance(to other: CamelotPosition) -> Int {
        let raw = abs(number - other.number)
        let ring = min(raw, 12 - raw)
        if isMajor == other.isMajor { return ring }
        return ring == 0 ? 1 : ring + 1
    }

    /// Same key, one step around the wheel, or the relative major/minor.
    func isHarmonic(with other: CamelotPosition) -> Bool {
        distance(to: other) <= 1
    }
}

nonisolated enum CamelotWheel {
    /// All 24 positions, in wheel order, for UI and debugging.
    nonisolated static var allPositions: [CamelotPosition] {
        var result: [CamelotPosition] = []
        for number in 1...12 {
            result.append(CamelotPosition(number: number, isMajor: false))
            result.append(CamelotPosition(number: number, isMajor: true))
        }
        return result
    }

    /// 0...1 harmonic compatibility score used by the transition planner.
    nonisolated static func compatibility(_ first: CamelotPosition?, _ second: CamelotPosition?) -> Float {
        guard let first, let second else { return 0.5 }
        switch first.distance(to: second) {
        case 0: return 1.0
        case 1: return 0.85
        case 2: return 0.55
        case 3: return 0.35
        default: return 0.15
        }
    }
}
