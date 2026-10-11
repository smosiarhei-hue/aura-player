"""macOS integration: actual AVQueuePlayer/AVPlayerLooper, no account/network required."""
from pathlib import Path
import platform
import subprocess
import tempfile

def verify_native_videoshot(root):
    fixture = r'''
import AVFoundation
import CoreVideo
import Foundation

@MainActor enum SonivoDiagnostics {
    nonisolated static func log(_ message: String, tag: String) {}
}

@main struct NativeChecks {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while !input.isReadyForMoreMediaData && ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            precondition(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32ARGB,
                nil, &buffer) == kCVReturnSuccess)
            let pixels = buffer!
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 128, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            precondition(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed)

        let controller = VideoShotPlaybackController()
        controller.configure(url: url)
        // The layer exists before isReady; do not wait for readiness to mount it.
        let layer = AVPlayerLayer(player: controller.player)
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        controller.update(enabled: true, matchingTrack: true, musicPlaying: true,
            sceneActive: true, playerVisible: true, lyricsVisible: false, reduceMotion: false)
        let deadline = ContinuousClock().now.advanced(by: .seconds(15))
        while !controller.isReady && ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(controller.isReady, "Native loop never became ready")
        precondition(controller.player?.isMuted == true)
        try await Task.sleep(for: .milliseconds(350))
        precondition((controller.player?.currentTime().seconds ?? 0) > 0, "Ready native video did not advance")
        precondition(controller.player?.rate == 1)
        controller.update(enabled: true, matchingTrack: true, musicPlaying: false,
            sceneActive: true, playerVisible: true, lyricsVisible: false, reduceMotion: false)
        precondition(controller.player?.rate == 0)
        controller.update(enabled: true, matchingTrack: true, musicPlaying: true,
            sceneActive: false, playerVisible: true, lyricsVisible: false, reduceMotion: false)
        precondition(controller.player?.rate == 0)
        controller.teardown()
        precondition(controller.player == nil && !controller.isReady)
        layer.player = nil
        // Delayed KVO callbacks from the old item cannot resurrect the player.
        try await Task.sleep(for: .milliseconds(100))
        precondition(controller.player == nil && !controller.isReady)
        print("Native VideoShot readiness/play/pause/teardown OK")
    }
}
'''
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        (directory/'NativeChecks.swift').write_text(fixture)
        arch = 'arm64' if platform.machine() == 'arm64' else 'x86_64'
        result = subprocess.run(['swiftc','-swift-version','6','-target',f'{arch}-apple-macosx14.0',
            '-default-isolation','MainActor','-strict-concurrency=complete','-parse-as-library',
            str(root/'Sonivo/VideoShotPlaybackPolicy.swift'),
            str(root/'Sonivo/VideoShotPlaybackController.swift'),str(directory/'NativeChecks.swift'),
            '-o',str(directory/'native-checks')],capture_output=True,text=True,timeout=90)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([str(directory/'native-checks'),str(directory/'fixture.mp4')],
            capture_output=True,text=True,timeout=45)
        assert result.returncode == 0, result.stdout + result.stderr
