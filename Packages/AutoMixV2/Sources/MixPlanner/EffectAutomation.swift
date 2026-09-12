import Foundation
import MixModels

public enum EffectAutomation {
    public static func value(for event: FxEvent, atBar bar: Double) -> Float? {
        guard bar >= event.startBar else { return nil }
        if event.endBar <= event.startBar { return event.toValue }
        let raw = min(1, max(0, (bar - event.startBar) / (event.endBar - event.startBar)))
        let progress: Double
        switch event.curve {
        case .linear: progress = raw
        case .sCurve: progress = raw * raw * (3 - 2 * raw)
        case .exp:
            if event.fromValue > 0, event.toValue > 0 {
                return Float(Double(event.fromValue) * pow(Double(event.toValue / event.fromValue), raw))
            }
            progress = raw * raw
        }
        return event.fromValue + (event.toValue - event.fromValue) * Float(progress)
    }

    public static func bar(atSeconds seconds: Double, bpm: Float) -> Double {
        guard seconds.isFinite, bpm > 0 else { return 0 }
        return max(0, seconds * Double(bpm) / 240)
    }

    public static func seconds(atBar bar: Double, bpm: Float) -> Double {
        guard bar.isFinite, bpm > 0 else { return 0 }
        return max(0, bar * 240 / Double(bpm))
    }
}
