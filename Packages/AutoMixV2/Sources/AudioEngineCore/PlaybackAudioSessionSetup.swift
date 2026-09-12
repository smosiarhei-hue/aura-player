// Path: Packages/AutoMixV2/Sources/AudioEngineCore/PlaybackAudioSessionSetup.swift

@preconcurrency import AVFoundation

public enum AudioSessionSetupStep: String, Sendable {
    case category = "setCategory"
    case sampleRate = "setPreferredSampleRate"
    case bufferDuration = "setPreferredIOBufferDuration"
    case activation = "setActive"
}

public struct AudioSessionSetupResult: Sendable, Equatable {
    public let isActive: Bool
    public let failedSteps: [AudioSessionSetupStep]
}

/// All session mutations belong to the main actor, including injected test clients.
@MainActor
public protocol PlaybackAudioSessionConfiguring {
    func setPlaybackCategory() throws
    func setPreferredSampleRate(_ sampleRate: Double) throws
    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws
    func activate() throws
}

@MainActor
public final class SystemPlaybackAudioSessionConfiguration: PlaybackAudioSessionConfiguring {
    private let session: AVAudioSession

    /// AirPlay and A2DP playback are implicit; input-category options must not be added.
    public static var categoryOptions: AVAudioSession.CategoryOptions { [] }

    public init(session: AVAudioSession) {
        self.session = session
    }

    public func setPlaybackCategory() throws {
        try session.setCategory(
            .playback,
            mode: .default,
            policy: .longFormAudio,
            options: Self.categoryOptions
        )
    }

    public func setPreferredSampleRate(_ sampleRate: Double) throws {
        try session.setPreferredSampleRate(sampleRate)
    }

    public func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {
        try session.setPreferredIOBufferDuration(duration)
    }

    public func activate() throws {
        try session.setActive(true)
    }
}

@MainActor
public enum PlaybackAudioSessionSetup {
    /// Category and activation are mandatory; hardware preferences are best effort.
    public static func configure(
        session: any PlaybackAudioSessionConfiguring,
        usesV2: Bool,
        onError: (Error, AudioSessionSetupStep) -> Void
    ) -> AudioSessionSetupResult {
        var failedSteps: [AudioSessionSetupStep] = []

        func attempt(_ step: AudioSessionSetupStep, operation: () throws -> Void) -> Bool {
            do {
                try operation()
                return true
            } catch {
                failedSteps.append(step)
                onError(error, step)
                return false
            }
        }

        guard attempt(.category, operation: { try session.setPlaybackCategory() }) else {
            return AudioSessionSetupResult(isActive: false, failedSteps: failedSteps)
        }

        if usesV2 {
            _ = attempt(.sampleRate) {
                try session.setPreferredSampleRate(DualDeckAudioEngine.preferredSampleRate)
            }
            _ = attempt(.bufferDuration) {
                try session.setPreferredIOBufferDuration(DualDeckAudioEngine.preferredIOBufferDuration)
            }
        }

        let isActive = attempt(.activation) { try session.activate() }
        return AudioSessionSetupResult(isActive: isActive, failedSteps: failedSteps)
    }
}
