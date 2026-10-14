from pathlib import Path
import shutil, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[2]
def source(name): return (ROOT/'Sonivo'/name).read_text()
class WaveResumeTests(unittest.TestCase):
    def test_checkpoint_is_wired_to_lifecycle_and_media_clocks(self):
        c=source('playercore.swift'); app=source('sonivoapp.swift')
        self.assertIn('player.restorePlaybackState()',app)
        self.assertIn('if phase != .active { PlayerCore.shared.savePlaybackState() }',app)
        self.assertIn('.onChange(of: ym.isRestoringInitialAccount)',app)
        self.assertEqual(c.count('checkpointPlaybackProgress()'),3)
        self.assertIn('now.timeIntervalSince($0) >= 2',c)
        self.assertIn('owner == service.currentUser?.uid',c)
        self.assertIn('copy.streamUrlString = nil',c)
        self.assertIn('Array(queue[range]).map(checkpointTrack)',c)
        restore=c.split('func restorePlaybackState()',1)[1].split('private var saveEQTask',1)[0]
        self.assertIn('isPlaying = false',restore)
        for bad in ['start(at:', 'activateForPlayback()', '.play()']: self.assertNotIn(bad,restore)
        seek=c.split('func seek(to seconds:',1)[1].split('func stopAndClear()',1)[0]
        self.assertIn('savePlaybackState()',seek)
    def test_wave_sources_use_documented_queue_and_bounded_recovery(self):
        wave=source('YandexWaveSession.swift');c=source('playercore.swift')
        self.assertIn('for attempt in 0..<3',wave)
        self.assertIn('for _ in 0..<3',wave)
        accept=wave.split('private func accept(',1)[1].split('func event(',1)[0]
        self.assertLess(accept.index('issued.append(id)'),accept.index('guard fresh, playable(item)'))
        self.assertIn('Self.canonicalID(id)',accept)
        self.assertIn('skipFailedWaveTrack()',c)
        skip=c.split('private func skipFailedWaveTrack()',1)[1].split('private func acceptsCachedPlayback',1)[0]
        self.assertIn('waveRecovery.fail(id)',skip)
        self.assertIn('service.reportSkip(',skip)
        self.assertNotIn('dislike',skip)
        self.assertIn('self.queueContinuationID == requestQueue',c)
        self.assertIn('waveRecovery.heard(seconds: waveListening.seconds)',c)
    @unittest.skipUnless(shutil.which('swiftc'),'Executable Swift checkpoint and recovery fixtures run in macOS CI')
    def test_production_checkpoint_and_skip_logic(self):
        c=source('playercore.swift')
        checkpoint=c[c.index('    private var didRestorePlaybackState'):c.index('    private var saveEQTask')].replace('private ','')
        skip=c[c.index('    private func skipFailedWaveTrack()'):c.index('    private func acceptsCachedPlayback')].replace('private func','func')
        fixture=r'''
import Foundation
nonisolated struct Track: Codable, Equatable {
    var id=UUID(); var fileName:String; var duration:Double=200; var isStream=false; var streamUrlString:String?
    var url:URL { URL(fileURLWithPath:fileName) }
}
@MainActor final class YandexMusicService {
    static let shared=YandexMusicService()
    struct User { let uid:Int }
    var currentUser:User?=User(uid:7)
    var isRestoringInitialAccount=false; var isUserLoggedIn=true
    var activeStationId:String?; var accountGeneration=UUID(); var skips:[String]=[]
    static func ymId(fromFileName:String)->String? { fromFileName.hasPrefix("ym_") ? String(fromFileName.dropFirst(3)) : nil }
    func reportSkip(trackId:String,totalPlayedSeconds:Double) { precondition(totalPlayedSeconds >= 0); skips.append(trackId) }
}
@MainActor final class Node { func pause() {}; func stop() {} }
@MainActor enum SonivoDiagnostics { static func log(_ text:String,tag:String) {} }
@MainActor final class CheckpointCore {
    let defaults:UserDefaults
    var currentTrack:Track?; var queue:[Track]=[]
    var progress:Double=0; var pausedProgress:Double=0; var streamDuration:Double=0
    var isPlaying=false; var updates=0
    var duration:Double { currentTrack?.duration ?? 0 }
    func updateNowPlayingInfo() { updates += 1 }
    CHECKPOINT
    init(_ defaults:UserDefaults) { self.defaults=defaults }
}
@MainActor final class RecoveryCore {
    var currentTrack:Track?=Track(fileName:"ym_1",isStream:true)
    var isPlaying=true; var isYandexWavePlayback=true
    var restoredWaveStation:String?; var waveRecovery=WavePlaybackRecovery()
    let activeStreamingPlayer=Node(), playerA=Node(), playerB=Node()
    var anchorDate:Date?; var activeAudioFile:Int?; var isStreamBuffering=true
    var waveListening=WaveListeningState(); var advances=0
    static func yandexTrackID(from track:Track)->String { YandexMusicService.ymId(fromFileName:track.fileName) ?? "" }
    func stopTimer() {}
    func next() { advances += 1 }
    SKIP
}
@main struct Checks {
    @MainActor static func main() throws {
        precondition(PlaybackResumePolicy.position(.nan,duration:200) == 0)
        precondition(PlaybackResumePolicy.position(.infinity,duration:200) == 0)
        precondition(PlaybackResumePolicy.position(-10,duration:200) == 0)
        precondition(PlaybackResumePolicy.position(201,duration:200) == 200)
        precondition(PlaybackResumePolicy.position(14,duration:0) == 14)
        precondition(PlaybackResumePolicy.queueRange(count:0,currentIndex:nil).isEmpty)
        let suite="wave-resume-fixture-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let service=YandexMusicService.shared
        let writer=CheckpointCore(defaults)
        writer.queue=(1...100).map { Track(fileName:"ym_\($0)",isStream:true,streamUrlString:"https://invalid.example/expired") }
        writer.currentTrack=writer.queue[79]; writer.progress=83.125; writer.streamDuration=200
        service.activeStationId="user:onyourwave"
        writer.savePlaybackState()
        let saved=try JSONDecoder().decode(Track.self,from:defaults.data(forKey:"player.lastTrack")!)
        precondition(saved.streamUrlString == nil)
        let savedQueue=try JSONDecoder().decode([Track].self,from:defaults.data(forKey:"player.lastQueue")!)
        precondition(savedQueue.count <= 60 && savedQueue.contains { $0.id == saved.id })
        precondition(savedQueue.allSatisfy { $0.streamUrlString == nil })
        let reader=CheckpointCore(defaults)
        service.isRestoringInitialAccount=true
        reader.restorePlaybackState(); precondition(reader.currentTrack == nil && !reader.didRestorePlaybackState)
        reader.savePlaybackState(); precondition(defaults.data(forKey:"player.lastTrack") != nil)
        service.isRestoringInitialAccount=false; service.activeStationId=nil
        reader.restorePlaybackState()
        precondition(reader.currentTrack?.id == saved.id && reader.progress == 83.125 && !reader.isPlaying)
        precondition(reader.restoredWaveStation == "user:onyourwave")
        reader.progress=90; reader.restorePlaybackState(); precondition(reader.progress == 90) // Once only.
        reader.queue=[]; reader.savePlaybackState(); precondition(defaults.data(forKey:"player.lastQueue") == nil)
        service.currentUser=YandexMusicService.User(uid:8)
        let other=CheckpointCore(defaults); other.restorePlaybackState()
        precondition(other.currentTrack == nil && defaults.data(forKey:"player.lastTrack") == nil)
        service.currentUser=YandexMusicService.User(uid:7)
        writer.currentTrack=Track(fileName:"/tmp/sonivo-missing-"+UUID().uuidString)
        writer.savePlaybackState()
        let missing=CheckpointCore(defaults); missing.restorePlaybackState(); precondition(missing.currentTrack == nil)
        // Actual periodic checkpoint: no per-frame metadata serialization and two-second throttle.
        writer.currentTrack=writer.queue.first ?? saved; writer.progress=10; writer.isPlaying=true
        writer.savePlaybackState(); writer.progress=11; writer.checkpointPlaybackProgress()
        precondition(defaults.double(forKey:"player.lastProgress") == 10)
        writer.lastPlaybackCheckpoint=Date(timeIntervalSinceNow:-3); writer.checkpointPlaybackProgress()
        precondition(defaults.double(forKey:"player.lastProgress") == 11)
        service.activeStationId="user:onyourwave"
        let recovery=RecoveryCore()
        for id in 1...5 {
            recovery.currentTrack=Track(fileName:"ym_\(id)",isStream:true)
            precondition(recovery.skipFailedWaveTrack())
        }
        recovery.currentTrack=Track(fileName:"ym_6",isStream:true)
        precondition(!recovery.skipFailedWaveTrack() && recovery.advances == 5)
        precondition(recovery.waveRecovery.excludes("3:42"))
        recovery.waveRecovery.heard(seconds:2)
        recovery.currentTrack=Track(fileName:"ym_7",isStream:true)
        precondition(recovery.skipFailedWaveTrack())
        recovery.isPlaying=false
        recovery.currentTrack=Track(fileName:"ym_8",isStream:true)
        precondition(!recovery.skipFailedWaveTrack()) // Late errors cannot undo pause.
        recovery.isPlaying=true; recovery.isYandexWavePlayback=false
        precondition(!recovery.skipFailedWaveTrack()) // Ordinary playlist is not silently skipped.
        precondition(service.skips.count == 6)
        print("Checkpoint: paused restore, account isolation, fresh URLs, queue window, missing files, finite seek and throttled progress; Wave: bounded source skips OK")
    }
}
'''.replace('CHECKPOINT',checkpoint).replace('SKIP',skip)
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder);(p/'Fixture.swift').write_text(fixture)
            result=subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete','-parse-as-library',str(ROOT/'Sonivo/PlaybackResumePolicy.swift'),str(ROOT/'Sonivo/YandexWaveSession.swift'),str(p/'Fixture.swift'),'-o',str(p/'checks')],capture_output=True,text=True,timeout=90)
            self.assertEqual(result.returncode,0,result.stderr[:10000])
            result=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr[:8000])
if __name__=='__main__': unittest.main()
