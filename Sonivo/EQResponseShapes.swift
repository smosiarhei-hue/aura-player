import SwiftUI
import StreamAudioProbe

/// Fixed-size vector: SwiftUI interpolates all six controls with one render clock.
/// Rendered geometry is independent of the control/audio state (no DSP commands per frame).
nonisolated struct EQCurveVector: VectorArithmetic {
    var values: [Double]
    init(_ gains: [Float]) { values = EQGainLimits.normalized(gains).map(Double.init) }
    private init(values: [Double]) { self.values = values }
    static var zero: Self { Self(values: Array(repeating: 0, count: EQGainLimits.frequencies.count)) }
    static func + (lhs: Self, rhs: Self) -> Self { Self(values: zip(lhs.values, rhs.values).map { $0 + $1 }) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(values: zip(lhs.values, rhs.values).map { $0 - $1 }) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

nonisolated struct EQControlCurveShape: Shape {
    var vector: EQCurveVector
    var animatableData: EQCurveVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let points = vector.values.indices.map { index in
            CGPoint(x: EQGainLimits.graphX(at: index, width: Double(rect.width)),
                    y: EQGainLimits.graphY(gain: Float(vector.values[index]), height: Double(rect.height)))
        }
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index], midX = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: midX, y: a.y), control2: CGPoint(x: midX, y: b.y))
        }
        return path
    }
}

/// Theoretical small-signal PCM response, not a spectrum meter or hardware measurement.
/// Native AU filters use equivalent centers/types/widths but may differ in implementation.
nonisolated struct EQFrequencyResponseShape: Shape {
    var vector: EQCurveVector
    var animatableData: EQCurveVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let gains = vector.values.map(Float.init)
        var response = [Float](repeating: 0, count: 160)
        let pointCount = response.count
        gains.withUnsafeBufferPointer { input in
            response.withUnsafeMutableBufferPointer { output in
                SonivoStreamEQResponse(input.baseAddress!, input.count, 48000, output.baseAddress!, pointCount)
            }
        }
        var path = Path()
        for (index, db) in response.enumerated() {
            let x = Double(index) / Double(pointCount - 1) * Double(rect.width)
            // Separate ±36 dB response scale: overlapping bands can exceed any one slider.
            let y = (36 - min(36, max(-36, Double(db)))) / 72 * Double(rect.height)
            let point = CGPoint(x: x, y: y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
