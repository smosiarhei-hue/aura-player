// Path: Tests/UnitTests/PlaybackAudioSessionSetupTests.swift

import AudioEngineCore
import Foundation
import Testing

@Suite("Playback audio session setup")
@MainActor
struct PlaybackAudioSessionSetupTests {
    @Test("Playback category does not explicitly enable input-only routing options")
    func playbackCategoryOptions() {
        #expect(SystemPlaybackAudioSessionConfiguration.categoryOptions.isEmpty)
    }

    @Test("V2 configures category and activation without requesting hardware preferences")
    func successfulV2Setup() {
        let client = RecordingAudioSession()
        var reportedSteps: [AudioSessionSetupStep] = []
        let result = PlaybackAudioSessionSetup.configure(session: client, usesV2: true) { _, step in
            reportedSteps.append(step)
        }

        #expect(result.isActive)
        #expect(result.failedSteps.isEmpty)
        #expect(reportedSteps.isEmpty)
        #expect(client.steps == [.category, .activation])
        #expect(client.preferredSampleRate == nil)
        #expect(client.preferredBufferDuration == nil)
    }

    @Test("Legacy configures category and activation without requesting hardware preferences")
    func legacySetup() {
        let client = RecordingAudioSession()
        let result = PlaybackAudioSessionSetup.configure(session: client, usesV2: false) { _, _ in }

        #expect(result.isActive)
        #expect(client.steps == [.category, .activation])
        #expect(client.preferredSampleRate == nil)
        #expect(client.preferredBufferDuration == nil)
    }

    @Test("Category failure stops setup before activation")
    func categoryFailure() {
        let client = RecordingAudioSession(failures: [.category])
        var reportedSteps: [AudioSessionSetupStep] = []
        let result = PlaybackAudioSessionSetup.configure(session: client, usesV2: true) { _, step in
            reportedSteps.append(step)
        }

        #expect(!result.isActive)
        #expect(result.failedSteps == [.category])
        #expect(reportedSteps == [.category])
        #expect(client.steps == [.category])
    }

    @Test("Activation failure is not reported as an active session")
    func activationFailure() {
        let client = RecordingAudioSession(failures: [.activation])
        var reportedSteps: [AudioSessionSetupStep] = []
        let result = PlaybackAudioSessionSetup.configure(session: client, usesV2: true) { _, step in
            reportedSteps.append(step)
        }

        #expect(!result.isActive)
        #expect(result.failedSteps == [.activation])
        #expect(reportedSteps == [.activation])
        #expect(client.steps == [.category, .activation])
    }
}

@MainActor
private final class RecordingAudioSession: PlaybackAudioSessionConfiguring {
    private let failures: [AudioSessionSetupStep]
    private(set) var steps: [AudioSessionSetupStep] = []
    private(set) var preferredSampleRate: Double?
    private(set) var preferredBufferDuration: TimeInterval?

    init(failures: [AudioSessionSetupStep] = []) {
        self.failures = failures
    }

    func setPlaybackCategory() throws {
        try record(.category)
    }

    func setPreferredSampleRate(_ sampleRate: Double) throws {
        preferredSampleRate = sampleRate
        try record(.sampleRate)
    }

    func setPreferredIOBufferDuration(_ duration: TimeInterval) throws {
        preferredBufferDuration = duration
        try record(.bufferDuration)
    }

    func activate() throws {
        try record(.activation)
    }

    private func record(_ step: AudioSessionSetupStep) throws {
        steps.append(step)
        if failures.contains(step) {
            throw SessionTestError.rejected
        }
    }
}

private enum SessionTestError: Error {
    case rejected
}
