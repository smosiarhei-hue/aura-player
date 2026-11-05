// Path: Packages/AutoMixV2/Sources/MixPlanner/MoodAutomix.swift
//
// Picks how long an AutoMix lasts and where the next song enters.
// A hot outro becomes a short handoff. A fade becomes a long wash.
// A quiet intro is skipped only until the song actually arrives.

import Foundation
import MixModels

public struct MoodAutomixWindow: Sendable, Equatable {
    public let blendSec: Double
    public let incomingStartSec: Double
    public let landProgress: Double
    public let mood: String
    public let reason: String
}

public struct MoodAutomixPlacement: Sendable, Equatable {
    public let outgoingCueSec: Double
    public let blendSec: Double
    public let incomingStartSec: Double
    public let landProgress: Double
    public let mood: String
    public let reason: String
}

public enum MoodAutomix {
    public static let shortestBlendSec: Double = 5.5
    public static let longestBlendSec: Double = 26

    /// Energy bins are one second each, 0…1. Tail index 0 is the oldest second.
    /// Explicit bins win over a profile curve. With neither, the window is only
    /// a preparation runway — playback retargets once the files are scanned.
    public static func window(
        outgoingDuration: Double,
        incomingDuration: Double,
        outgoing: TrackProfile? = nil,
        incoming: TrackProfile? = nil,
        outgoingTail: [Float] = [],
        incomingHead: [Float] = []
    ) -> MoodAutomixWindow {
        let tail = bins(explicit: outgoingTail, curve: outgoing?.energyCurve, fromEnd: true, limit: 36, minimum: 6)
        let head = bins(explicit: incomingHead, curve: incoming?.energyCurve, fromEnd: false, limit: 28, minimum: 4)
        let bpm = resolvedBPM(outgoing: outgoing, incoming: incoming)
        if tail.isEmpty && head.isEmpty {
            return provisional(outgoingDuration: outgoingDuration)
        }
        let entry = incomingEntry(head: head, bpm: bpm, incomingDuration: incomingDuration)
        let shape = outgoingShape(tail: tail, bpm: bpm)
        let blend = clamp(shape.blend, min: shortestBlendSec, max: longestBlendSec)
        return MoodAutomixWindow(
            blendSec: blend,
            incomingStartSec: entry,
            landProgress: shape.land,
            mood: shape.mood,
            reason: String(
                format: "%@ · окно %.1fс · вход %.1fс",
                shape.mood, blend, entry
            )
        )
    }

    /// Place the window on the outgoing timeline. `notBefore` pulls a missed cue
    /// forward when the playhead is already inside the outro.
    public static func placed(
        outgoingDuration: Double,
        incomingDuration: Double,
        outgoing: TrackProfile? = nil,
        incoming: TrackProfile? = nil,
        outgoingTail: [Float] = [],
        incomingHead: [Float] = [],
        notBefore: Double = 0
    ) -> MoodAutomixPlacement {
        let window = window(
            outgoingDuration: outgoingDuration,
            incomingDuration: incomingDuration,
            outgoing: outgoing,
            incoming: incoming,
            outgoingTail: outgoingTail,
            incomingHead: incomingHead
        )
        let dur = max(0, outgoingDuration)
        let floor = dur * 0.75
        let minBlend = 4.0
        var cue = max(0, dur - window.blendSec)
        if cue < floor { cue = floor }
        if notBefore > cue { cue = notBefore }
        let latest = max(0, dur - minBlend)
        if cue > latest { cue = latest }
        let room = max(0, dur - cue)
        let blend = clamp(min(window.blendSec, room), min: min(minBlend, room), max: longestBlendSec)
        let capIn = incomingDuration > 1 ? incomingDuration * 0.25 : 24
        let incoming = clamp(window.incomingStartSec, min: 0, max: max(0, capIn))
        return MoodAutomixPlacement(
            outgoingCueSec: cue,
            blendSec: blend,
            incomingStartSec: incoming,
            landProgress: window.landProgress,
            mood: window.mood,
            reason: window.reason
        )
    }

    // MARK: - Shapes

    private struct Shape {
        var mood: String
        var blend: Double
        var land: Double
    }

    private static func outgoingShape(tail: [Float], bpm: Double) -> Shape {
        guard tail.count >= 6 else {
            return Shape(mood: "phrase", blend: barSeconds(bpm) * 4, land: 0.78)
        }
        let last = mean(Array(tail.suffix(6)))
        let earlier = mean(Array(tail.prefix(max(1, tail.count - 6))))
        let fall = earlier - last
        var falling = 0
        for index in 1..<tail.count where tail[index] + 0.02 < tail[index - 1] {
            falling += 1
        }
        let fallingRatio = Double(falling) / Double(tail.count - 1)
        let motion = flux(tail)

        if fallingRatio > 0.55, fall > 0.16 {
            let cover = Double(tail.count) * 0.82
            return Shape(mood: "wash", blend: clamp(cover, min: 15, max: longestBlendSec), land: 0.90)
        }
        if last >= 0.60 {
            // The song is still up. A long overlay just sits there.
            let blend = 5.5 + min(3.0, motion * 14)
            return Shape(mood: "tight", blend: blend, land: 0.64)
        }
        if let valley = valleySecondsFromEnd(tail), valley > 8 {
            return Shape(mood: "phrase", blend: clamp(valley, min: 9, max: 18), land: 0.78)
        }
        if last < 0.38 {
            return Shape(mood: "wash", blend: clamp(16 + fall * 10, min: 14, max: longestBlendSec), land: 0.90)
        }
        let phrase = barSeconds(bpm) * (bpm > 0 && bpm < 100 ? 6 : 4)
        return Shape(mood: "phrase", blend: clamp(phrase + motion * 6, min: 9, max: 16), land: 0.78)
    }

    private static func incomingEntry(head: [Float], bpm: Double, incomingDuration: Double) -> Double {
        let cap = min(22, max(0, incomingDuration > 1 ? incomingDuration * 0.22 : 22))
        guard head.count >= 4 else { return 0 }
        let early = mean(Array(head.prefix(3)))
        let peak = Double(head.max() ?? 0)
        if early >= 0.62 || (peak > 0.15 && early >= peak * 0.72) {
            return 0
        }
        for index in 1..<head.count {
            let prev = mean(Array(head[max(0, index - 2)..<index]))
            if Double(head[index]) >= 0.55, Double(head[index]) - prev >= 0.12, prev < 0.48 {
                let raw = max(0, Double(index) - 0.35)
                return snap(raw, bpm: bpm, cap: cap)
            }
        }
        return snap(min(barSeconds(bpm), cap), bpm: bpm, cap: cap)
    }

    private static func provisional(outgoingDuration: Double) -> MoodAutomixWindow {
        // Only a preparation runway until the files are scanned. A 22s silent
        // "scan" window made the player look busy while the mix still started late.
        let dur = max(30, outgoingDuration)
        let blend = clamp(dur * 0.07, min: 8, max: 12)
        return MoodAutomixWindow(
            blendSec: blend,
            incomingStartSec: 0,
            landProgress: 0.78,
            mood: "scan",
            reason: String(format: "scan · окно %.1fс", blend)
        )
    }

    private static func valleySecondsFromEnd(_ tail: [Float]) -> Double? {
        let count = tail.count
        guard count > 10 else { return nil }
        var bestIndex = 0
        var bestDepth = 0.0
        let start = max(2, count - 22)
        let end = count - 4
        guard start < end else { return nil }
        for index in start..<end {
            let left = Double(tail[index - 2])
            let mid = Double(tail[index])
            let right = Double(tail[min(count - 1, index + 3)])
            let depth = (left + right) * 0.5 - mid
            if depth > bestDepth {
                bestDepth = depth
                bestIndex = index
            }
        }
        guard bestDepth > 0.10 else { return nil }
        return Double(count - bestIndex)
    }

    private static func bins(
        explicit: [Float],
        curve: [Float]?,
        fromEnd: Bool,
        limit: Int,
        minimum: Int
    ) -> [Float] {
        let source: [Float]
        if explicit.count >= minimum {
            source = explicit
        } else if let curve, curve.count >= minimum {
            source = curve
        } else {
            return []
        }
        if fromEnd {
            return Array(source.suffix(limit))
        }
        return Array(source.prefix(limit))
    }

    private static func resolvedBPM(outgoing: TrackProfile?, incoming: TrackProfile?) -> Double {
        let a = Double(outgoing?.bpm ?? 0)
        let b = Double(incoming?.bpm ?? 0)
        if a > 50 { return a }
        if b > 50 { return b }
        return 0
    }

    private static func barSeconds(_ bpm: Double) -> Double {
        let tempo = bpm > 50 ? min(180, bpm) : 118
        return 240.0 / tempo
    }

    private static func snap(_ seconds: Double, bpm: Double, cap: Double) -> Double {
        let raw = clamp(seconds, min: 0, max: cap)
        guard bpm > 50 else { return raw }
        let bar = 240.0 / min(180, bpm)
        guard bar > 0.4 else { return raw }
        return clamp((raw / bar).rounded() * bar, min: 0, max: cap)
    }

    private static func mean(_ values: [Float]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, { $0 + Double($1) }) / Double(values.count)
    }

    private static func flux(_ values: [Float]) -> Double {
        guard values.count > 2 else { return 0 }
        var sum = 0.0
        for index in 1..<values.count {
            sum += abs(Double(values[index] - values[index - 1]))
        }
        return sum / Double(values.count - 1)
    }

    private static func clamp(_ value: Double, min lower: Double, max upper: Double) -> Double {
        let hi = max(lower, upper)
        return Swift.min(hi, Swift.max(lower, value))
    }
}
