// Path: Aurora/DJAutoMixEngine/CamelotKey.swift
import Foundation

public struct CamelotKey: Equatable, Sendable, Codable {
    public enum Letter: String, Codable, Sendable {
        case a // Minor
        case b // Major
    }

    public let number: Int      // 1...12
    public let letter: Letter   // .a (минор) / .b (мажор)

    public init(number: Int, letter: Letter) {
        self.number = max(1, min(12, number))
        self.letter = letter
    }

    public var description: String {
        "\(number)\(letter.rawValue.uppercased())"
    }

    /// Проверка гармонической совместимости по правилам Camelot Wheel:
    /// - Та же тональность (8A -> 8A)
    /// - Соседний сектор того же лада (8A -> 7A или 8A -> 9A, с закольцовкой 12 <-> 1)
    /// - Параллельный мажор/минор (тот же номер, другая буква: 8A -> 8B)
    public func isHarmonicallyCompatible(with other: CamelotKey) -> Bool {
        // 1. Идентичная тональность
        if self.number == other.number && self.letter == other.letter {
            return true
        }

        // 2. Параллельный мажор/минор (Relative major/minor: 8A <-> 8B)
        if self.number == other.number && self.letter != other.letter {
            return true
        }

        // 3. Соседний сектор того же лада (+1 или -1 по часовой стрелке)
        if self.letter == other.letter {
            let diff = abs(self.number - other.number)
            if diff == 1 || diff == 11 { // 11 соответствует переходу между 12 и 1
                return true
            }
        }

        return false
    }
}
