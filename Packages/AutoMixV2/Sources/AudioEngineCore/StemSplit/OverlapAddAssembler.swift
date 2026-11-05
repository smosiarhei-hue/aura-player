import Foundation

struct OverlapAddAssembler {
    let segment: Int
    let hop: Int
    private var acc: [StemKind: (l: [Float], r: [Float])] = [:]
    private var weight = [Float]()
    private let window: [Float]

    init(segment: Int) {
        self.segment = segment
        self.hop = segment / 2
        self.window = (0..<segment).map { i in
            Float(min(i + 1, segment - i))
        }
        self.weight = [Float](repeating: 0, count: segment)
    }

    mutating func add(_ stems: [StemKind: StereoChunk]) {
        for (kind, chunk) in stems {
            var slot = acc[kind] ?? (
                [Float](repeating: 0, count: segment),
                [Float](repeating: 0, count: segment)
            )
            for i in 0..<segment {
                let w = window[i]
                slot.l[i] += chunk.left[i] * w
                slot.r[i] += chunk.right[i] * w
            }
            acc[kind] = slot
        }
        for i in 0..<segment { weight[i] += window[i] }
    }

    mutating func ready(count: Int) -> [StemKind: StereoChunk] {
        var out: [StemKind: StereoChunk] = [:]
        for (kind, slot) in acc {
            var l = [Float](repeating: 0, count: count)
            var r = [Float](repeating: 0, count: count)
            for i in 0..<count where weight[i] > 0 {
                l[i] = slot.l[i] / weight[i]
                r[i] = slot.r[i] / weight[i]
            }
            out[kind] = StereoChunk(left: l, right: r)
        }
        return out
    }

    mutating func shift() {
        for kind in Array(acc.keys) {
            var slot = acc[kind]!
            slot.l.removeFirst(hop)
            slot.r.removeFirst(hop)
            slot.l.append(contentsOf: [Float](repeating: 0, count: hop))
            slot.r.append(contentsOf: [Float](repeating: 0, count: hop))
            acc[kind] = slot
        }
        weight.removeFirst(hop)
        weight.append(contentsOf: [Float](repeating: 0, count: hop))
    }
}
