import SwiftUI
import StreamAudioProbe

/// Fixed-size vector: SwiftUI interpolates all ten controls with one render clock.
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

/// Soft fill under the control curve for hero atmosphere (same geometry as stroke).
nonisolated struct EQControlCurveFillShape: Shape {
    var vector: EQCurveVector
    var animatableData: EQCurveVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let points = vector.values.indices.map { index in
            CGPoint(x: EQGainLimits.graphX(at: index, width: Double(rect.width)),
                    y: EQGainLimits.graphY(gain: Float(vector.values[index]), height: Double(rect.height)))
        }
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: rect.maxY))
        path.addLine(to: first)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index], midX = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: midX, y: a.y), control2: CGPoint(x: midX, y: b.y))
        }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.closeSubpath()
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

/// Filled theoretical response underlay for the hero EQ visual.
nonisolated struct EQFrequencyResponseFillShape: Shape {
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
        let zeroY = 36.0 / 72.0 * Double(rect.height)
        for (index, db) in response.enumerated() {
            let x = Double(index) / Double(pointCount - 1) * Double(rect.width)
            let y = (36 - min(36, max(-36, Double(db)))) / 72 * Double(rect.height)
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: zeroY))
                path.addLine(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: zeroY))
        path.closeSubpath()
        return path
    }
}

/// Summed PCM response drawn in the SAME coordinate space as the band nodes
/// (log axis 32 Hz–16 kHz through `graphX`, ±15 dB through `graphY`), so the
/// filled area always sits under the curve points instead of drifting sideways.
nonisolated enum EQAlignedResponse {
    static let pointCount = 192
    static func points(_ values: [Double], in rect: CGRect) -> [CGPoint] {
        let gains = values.map(Float.init)
        guard !gains.isEmpty, rect.width > 28, rect.height > 28 else { return [] }
        var response = [Float](repeating: 0, count: pointCount)
        let count = pointCount
        gains.withUnsafeBufferPointer { input in
            response.withUnsafeMutableBufferPointer { output in
                SonivoStreamEQResponse(input.baseAddress!, input.count, 48000, output.baseAddress!, count)
            }
        }
        let first = Double(EQGainLimits.frequencies.first ?? 32)
        let last = Double(EQGainLimits.frequencies.last ?? 16000)
        let width = Double(rect.width), height = Double(rect.height)
        let x0 = EQGainLimits.graphX(at: 0, width: width)
        let x1 = EQGainLimits.graphX(at: EQGainLimits.frequencies.count - 1, width: width)
        let span = log2(last / first)
        let top = min(20000, 48000 * 0.44) // matches SonivoEQResponse sampling
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for (index, db) in response.enumerated() {
            let hz = 20 * pow(top / 20, Double(index) / Double(count - 1))
            let x = x0 + log2(hz / first) / span * (x1 - x0)
            guard x >= 0, x <= width else { continue }
            let clamped = max(-EQGainLimits.maximum, min(EQGainLimits.maximum, db.isFinite ? db : 0))
            result.append(CGPoint(x: Double(rect.minX) + x,
                                  y: Double(rect.minY) + EQGainLimits.graphY(gain: clamped, height: height)))
        }
        return result
    }
}

nonisolated struct EQAlignedResponseFillShape: Shape {
    var vector: EQCurveVector
    var animatableData: EQCurveVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let points = EQAlignedResponse.points(vector.values, in: rect)
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        let zeroY = Double(rect.minY) + EQGainLimits.graphY(gain: 0, height: Double(rect.height))
        path.move(to: CGPoint(x: first.x, y: zeroY))
        for point in points { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: zeroY))
        path.closeSubpath()
        return path
    }
}

/// Thin outline of the aligned summed response (reference line, not a fill).
nonisolated struct EQAlignedResponseShape: Shape {
    var vector: EQCurveVector
    var animatableData: EQCurveVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let points = EQAlignedResponse.points(vector.values, in: rect)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

/// Area between the node curve and the 0 дБ line: boosts glow up, cuts hang down.
nonisolated struct EQControlCurveZeroFillShape: Shape {
    var vector: EQCurveVector
    var animatableData: EQCurveVector { get { vector } set { vector = newValue } }
    func path(in rect: CGRect) -> Path {
        let points = vector.values.indices.map { index in
            CGPoint(x: EQGainLimits.graphX(at: index, width: Double(rect.width)),
                    y: EQGainLimits.graphY(gain: Float(vector.values[index]), height: Double(rect.height)))
        }
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        let zeroY = EQGainLimits.graphY(gain: 0, height: Double(rect.height))
        path.move(to: CGPoint(x: first.x, y: zeroY))
        path.addLine(to: first)
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index], midX = (a.x + b.x) / 2
            path.addCurve(to: b, control1: CGPoint(x: midX, y: a.y), control2: CGPoint(x: midX, y: b.y))
        }
        path.addLine(to: CGPoint(x: last.x, y: zeroY))
        path.closeSubpath()
        return path
    }
}
