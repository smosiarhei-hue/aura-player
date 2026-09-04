// Path: Packages/AutoMixV2/Sources/MixDiagnostics/MixDiagnosticEvent.swift

import Foundation

public enum MixDiagnosticLevel: String, Sendable, Codable {
    case info
    case warning
    case error
}

public struct MixDiagnosticEvent: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let level: MixDiagnosticLevel
    public let category: String
    public let message: String

    public init(
        timestamp: Date = Date(),
        level: MixDiagnosticLevel = .info,
        category: String,
        message: String
    ) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}
