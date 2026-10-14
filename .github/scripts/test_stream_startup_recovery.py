from pathlib import Path
import subprocess, sys, tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]
def source(name): return (ROOT/'Sonivo'/name).read_text()
class StreamStartupRecoveryTests(unittest.TestCase):
    def test_equal_bitrate_keeps_legacy_source(self):
        s=source('PlaybackQualityFacts.swift').split('func isPreferred',1)[1].split('var isLossless',1)[0]
        self.assertIn('return false',s)
        self.assertNotIn('let rank',s)
        self.assertIn('if isLossless != other.isLossless',s)
    def test_recovery_cannot_resolve_the_same_signed_source(self):
        s=source('yandexmusicservice.swift').split('func getStreamInfo',1)[1].split('// MARK: - Convert',1)[0]
        self.assertEqual(s.count('if !legacyOnly &&'),2)
        self.assertIn('if legacyOnly {',s)
        self.assertIn('$0.codec.lowercased() == "mp3"',s)
        c=source('playercore.swift')
        self.assertIn('preferredBitrate: 320, legacyOnly: true',c)
        self.assertIn('observeStreamStartup(item, at: seconds, token: token)',c)
        self.assertIn('observed.status == .failed',c)
        self.assertIn('reason: "startup-timeout"',c)
    def test_optional_probe_timeouts_and_recovery_are_bounded(self):
        s=source('yandexmusicservice.swift')
        self.assertIn('request.timeoutInterval = transport == "encraw" ? 6 : 12',s)
        c=source('playercore.swift').split('private func recoverStreamStartup',1)[1].split('private func acceptsCachedPlayback',1)[0]
        for t in ['streamRecoveryInFlightToken != token','streamRecoveryAttemptedToken != token','service.accountGeneration == account','activeStreamingPlayer.currentItem === failedItem','self.generation == token']:
            self.assertIn(t,c)
        self.assertNotIn('audioQuality =',c)
    @unittest.skipUnless(sys.platform=='darwin','Executable production recovery fixture requires macOS AVFoundation')
    def test_production_recovery_guards_and_single_retry(self):
        c=source('playercore.swift')
        recovery=c[c.index('    private func recoverStreamStartup'):c.index('    private func skipFailedWaveTrack')].replace('private func','func')
        fixture=r'''
import Foundation
import AVFoundation
nonisolated struct Track { let id=UUID(); var fileName="ym_1.mp3" }
nonisolated enum AudioQuality { case hq }
@MainActor final class YandexMusicService {
    static let shared=YandexMusicService()
    var accountGeneration=UUID(); var calls=0; var shouldFail=false
    static func ymId(fromFileName: String)->String? { fromFileName.hasPrefix("ym_") ? "1" : nil }
    func recordStreamPlaybackFailure(_ reason:String) {}
    struct Info { let url:URL; let codec="mp3"; let bitrate=192 }
    func getStreamInfo(for id:String, preferredQuality:AudioQuality, preferredBitrate:Int?, legacyOnly:Bool) async throws -> Info {
        precondition(legacyOnly && preferredBitrate == 320); calls += 1
        try await Task.sleep(for:.milliseconds(30))
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return Info(url:URL(fileURLWithPath:"/tmp/generated-recovery-fixture.mp3"))
    }
}
@MainActor final class PlayerCore {
    var generation=1; var isPlaying=true; var isUsingStreamPlayer=true
    let activeStreamingPlayer=AVPlayer()
    var currentTrack:Track?=Track(); var progress=2.5
    var streamRecoveryAttemptedToken:Int?; var streamRecoveryInFlightToken:Int?
    var currentCodec:String?; var currentBitrate:Int?
    var streamStartupTask:Task<Void,Never>?; var isStreamBuffering=true
    var transitionScheduled=false; var playError:String?; var starts=0
    static func yandexTrackID(from track:Track)->String { "1" }
    func findLocalOrCachedAudioFile(for track:Track,respectingQuality:Bool)->URL? { nil }
    func startLocal(_ track:Track,at seconds:Double,token:Int,fileURL:URL) { preconditionFailure("no cached fixture") }
    func beginStream(_ url:URL,at seconds:Double,token:Int) {
        precondition(seconds == progress && token == generation); starts += 1
        activeStreamingPlayer.replaceCurrentItem(with:AVPlayerItem(url:url))
    }
    func skipFailedWaveTrack() -> Bool { false } // Ordinary playlist fixture; Wave tested separately.
    RECOVERY
    init() { activeStreamingPlayer.replaceCurrentItem(with:AVPlayerItem(url:URL(fileURLWithPath:"/tmp/generated-invalid-fixture"))) }
}
@main struct Checks {
    @MainActor static func settle(_ core: PlayerCore) async throws {
        // Await the real task boundary, not a wall-clock assumption on a loaded macOS runner.
        for _ in 0..<500 {
            if core.streamRecoveryInFlightToken == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Recovery fixture did not finish within five seconds")
    }
    @MainActor static func main() async throws {
        let service=YandexMusicService.shared
        let core=PlayerCore(); let failed=core.activeStreamingPlayer.currentItem!
        core.recoverStreamStartup(failed,token:1,reason:"fixture")
        core.recoverStreamStartup(failed,token:1,reason:"duplicate-fixture")
        precondition(core.isPlaying)
        try await settle(core)
        precondition(service.calls == 1 && core.starts == 1 && core.currentBitrate == 192)
        core.recoverStreamStartup(failed,token:1,reason:"stale-item")
        precondition(core.isPlaying && service.calls == 1)
        core.recoverStreamStartup(core.activeStreamingPlayer.currentItem!,token:1,reason:"second-source-failed")
        precondition(!core.isPlaying && core.playError != nil && service.calls == 1)
        for change in ["generation","account","pause","item","track"] {
            service.calls=0
            let stale=PlayerCore(); let old=stale.activeStreamingPlayer.currentItem!
            stale.recoverStreamStartup(old,token:1,reason:"fixture")
            // Ensure the mock request started before changing its captured identity.
            for _ in 0..<500 {
                if service.calls == 1 { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            precondition(service.calls == 1, "Recovery fixture request never started")
            switch change {
            case "generation": stale.generation += 1
            case "account": service.accountGeneration=UUID()
            case "pause": stale.isPlaying=false
            case "item": stale.activeStreamingPlayer.replaceCurrentItem(with:nil)
            default: stale.currentTrack=Track()
            }
            try await settle(stale)
            precondition(stale.starts == 0, "stale recovery committed")
        }
        service.shouldFail=true
        let unavailable=PlayerCore()
        unavailable.recoverStreamStartup(unavailable.activeStreamingPlayer.currentItem!,token:1,reason:"fixture")
        try await settle(unavailable)
        precondition(!unavailable.isPlaying && !unavailable.isStreamBuffering)
        print("Production recovery: single retry, duplicate/stale item, generation/account/pause/track guards and offline failure passed")
    }
}
'''.replace('RECOVERY',recovery)
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'Checks.swift').write_text(fixture)
            result=subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True,timeout=120)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            result=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__':unittest.main()
