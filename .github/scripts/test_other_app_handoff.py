"""Media ownership and external routing must never be reclaimed by stale UI work."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]

class OtherAppHandoffTests(unittest.TestCase):
    def test_only_owned_links_open_player_and_foreground_does_not_activate_audio(self):
        app=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        route=app.split('.onOpenURL',1)[1].split('.onChange(of: player.isPlaying)',1)[0]
        self.assertIn('guard SonivoExternalPlaybackRoute.accepts(url)',route)
        self.assertNotIn('NSUserActivityTypeBrowsingWeb',app)
        self.assertIn('guard ownURL || ownTrack else',route)
        lifecycle=app.split('.onChange(of: scenePhase)',2)[-1].split('.onOpenURL',1)[0]
        self.assertNotIn('activateForPlayback()',lifecycle)
        project=(ROOT/'project.yml').read_text().split('CFBundleURLTypes:',1)[1].split('SonivoLiveActivity:',1)[0]
        self.assertNotIn('spotify',project.lower())

    def test_metadata_and_late_artwork_cannot_reclaim_a_yielded_surface(self):
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        update=core.split('private func updateNowPlayingInfo()',1)[1].split('func preloadArtwork',1)[0]
        self.assertIn('allowsSystemPlaybackPublication()',update)
        self.assertNotIn('nowPlayingInfo ?? [:]',update)
        self.assertIn('self.ownsSystemNowPlaying',update)
        self.assertIn('as? String == track.id.uuidString',update)
        publish=core.split('private func publishNowPlaying',1)[1].split('func setApplicationSceneActive',1)[0]
        self.assertIn('guard ownsSystemNowPlaying else',publish)
        self.assertIn('allowsSystemPlaybackPublication()',publish)
        activity=(ROOT/'Sonivo/SonivoLiveActivityController.swift').read_text()
        self.assertIn('endForPlaybackHandoff()',activity)
        self.assertIn('allowsSystemPlaybackPublication()',activity)
        v2=(ROOT/'Sonivo/AutoMixV2NowPlayingCenter.swift').read_text()
        self.assertGreaterEqual(v2.count('allowsSystemPlaybackPublication()'),2)

    def test_interruption_yields_before_pause_and_resume_checks_other_audio(self):
        source=(ROOT/'Sonivo/playbackaudiosession.swift').read_text()
        began=source.split('case .began:',1)[1].split('case .ended:',1)[0]
        self.assertLess(began.index('ownership.interruptionBegan()'),began.index('PlayerCore.shared.pause()'))
        self.assertIn('relinquishSystemPlaybackSurface()',began)
        self.assertIn('if activate, result.isActive {',source)
        self.assertIn('ownership.activated()',source)
        core=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertNotIn('beginReceivingRemoteControlEvents()',core)
        self.assertIn('endReceivingRemoteControlEvents()',source)
        self.assertIn('otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying',source)

    @unittest.skipUnless(platform.system()=='Darwin' and shutil.which('swiftc'), 'Swift policy fixture executes on macOS')
    def test_actual_swift_ownership_and_url_policy(self):
        code=r'''
import Foundation
@main struct Checks {
    static func main() {
        var owner=SonivoPlaybackOwnership()
        precondition(!owner.allowsPublication(otherAudioPlaying:false),"Restored metadata must not claim Now Playing")
        owner.activated()
        precondition(owner.allowsPublication(otherAudioPlaying:false))
        // User pause need not discard ownership, but another app must latch a handoff.
        precondition(!owner.allowsPublication(otherAudioPlaying:true))
        precondition(!owner.allowsPublication(otherAudioPlaying:false),"Late artwork reclaimed ownership")
        owner.activated(); owner.interruptionBegan()
        precondition(!owner.allowsPublication(otherAudioPlaying:false))
        owner.interruptionEnded()
        precondition(!owner.allowsPublication(otherAudioPlaying:false),"Interruption ended silently reacquired metadata")
        owner.activated()
        precondition(owner.allowsPublication(otherAudioPlaying:false))
        for system in [false,true] { for wasPlaying in [false,true] { for other in [false,true] {
            precondition(SonivoPlaybackOwnership.mayResume(systemShouldResume:system,wasPlaying:wasPlaying,otherAudioPlaying:other) == (system && wasPlaying && !other))
        } } }
        let id=UUID().uuidString
        for value in ["sonivo://player","aurora://player","sonivo://track/\(id)"] {
            precondition(SonivoExternalPlaybackRoute.accepts(URL(string:value)!))
        }
        for value in ["spotify:track:abc","https://open.spotify.com/track/abc","https://music.yandex.ru","sonivo://unknown","sonivo://player/extra","sonivo://track/not-a-uuid","sonivo://user@player","sonivo://player:443"] {
            precondition(!SonivoExternalPlaybackRoute.accepts(URL(string:value)!),"Foreign route accepted: \(value)")
        }
        print("ownership, interruption and external-route fixtures passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'Checks.swift').write_text(code)
            build=subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(ROOT/'Sonivo/SonivoPlaybackOwnership.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stderr[-10000:])
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,(run.stdout+run.stderr)[-10000:])
