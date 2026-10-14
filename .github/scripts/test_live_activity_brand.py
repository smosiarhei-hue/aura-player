from pathlib import Path
import base64, datetime, importlib.util, json, tempfile, unittest
from configure_live_activity import configure_project, validate_profile
from patch_project_signing import patch_project
ROOT=Path(__file__).resolve().parents[2]
def source(path):return (ROOT/path).read_text()
class LiveActivityBrandTests(unittest.TestCase):
    def test_signed_build_without_extension_profile_remains_installable(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'project.yml';p.write_text(source('project.yml'))
            patch_project(p,'app.example.sonivo','TEAM','Distribution','app-profile')
            self.assertFalse(configure_project(p,'app.example.sonivo','TEAM','',True))
            text=p.read_text()
            self.assertNotIn('- target: SonivoLiveActivity',text)
            self.assertIn('NSSupportsLiveActivities: false',text)
            self.assertIn('SonivoLiveActivityEmbedded: false',text)
            self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: app.example.sonivo.LiveActivity',text)
            self.assertIn('PROVISIONING_PROFILE_SPECIFIER: "app-profile"',text)
            extension=text.split('  SonivoLiveActivity:',1)[1].split('  SonivoUnitTests:',1)[0]
            self.assertIn('CODE_SIGNING_ALLOWED: NO',extension)
    def test_separate_per_target_profiles_and_distinct_bundle_ids(self):
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder)/'project.yml';p.write_text(source('project.yml'))
            patch_project(p,'app.example.sonivo','TEAM','Distribution','app-profile')
            self.assertTrue(configure_project(p,'app.example.sonivo','TEAM','widget-profile',True))
            text=p.read_text()
            self.assertIn('- target: SonivoLiveActivity',text)
            self.assertIn('NSSupportsLiveActivities: true',text)
            self.assertEqual(text.count('PROVISIONING_PROFILE_SPECIFIER: "app-profile"'),1)
            self.assertEqual(text.count('PROVISIONING_PROFILE_SPECIFIER: "widget-profile"'),1)
            for suffix in ['LiveActivity','UnitTests','UITests']:
                self.assertIn('PRODUCT_BUNDLE_IDENTIFIER: app.example.sonivo.'+suffix,text)
    def test_profile_rejects_foreign_team_bundle_certificate_devices_and_expiry(self):
        now=datetime.datetime.now(datetime.timezone.utc)
        app={'Entitlements':{'get-task-allow':False},'DeveloperCertificates':[b'fixture-certificate'],'ProvisionedDevices':['device-A']}
        valid={'UUID':'widget-profile','Entitlements':{'application-identifier':'TEAM.app.example.sonivo.LiveActivity','com.apple.developer.team-identifier':'TEAM','get-task-allow':False},'DeveloperCertificates':[b'fixture-certificate'],'ProvisionedDevices':['device-A'],'ExpirationDate':now+datetime.timedelta(days=30)}
        self.assertEqual(validate_profile(valid,app,'app.example.sonivo','TEAM',now),'widget-profile')
        import copy
        changes=[('Entitlements','application-identifier','TEAM.another.app'),('Entitlements','com.apple.developer.team-identifier','OTHER'),('Entitlements','get-task-allow',True),(None,'ExpirationDate',now-datetime.timedelta(days=1)),(None,'DeveloperCertificates',[b'another-certificate']),(None,'ProvisionedDevices',[])]
        for nested,key,value in changes:
            bad=copy.deepcopy(valid)
            (bad[nested] if nested else bad)[key]=value
            with self.assertRaises(ValueError):validate_profile(bad,app,'app.example.sonivo','TEAM',now)
    def test_branding_uses_real_safe_area_not_system_recording_or_post_capture_overlay(self):
        text=source('Sonivo/SonivoCaptureBrand.swift')
        self.assertIn('@Environment(\\.isSceneCaptured)',text)
        self.assertIn('alwaysVisible || isCaptured',text)
        self.assertIn('.safeAreaInset(edge: .top',text)
        for bad in ['userDidTakeScreenshot','UIScreen.main.isCaptured','UIWindow(', 'ReplayKit','RPScreenRecorder','AVAudioSession']:self.assertNotIn(bad,text)
        appearance=source('Sonivo/SonivoAppearanceView.swift')
        self.assertIn('!SonivoLiveActivityController.isEmbedded',appearance)
        self.assertIn('System recording indicators are unchanged',appearance)
    def test_activity_is_bounded_and_does_not_own_audio(self):
        text=source('Sonivo/SonivoLiveActivityController.swift')
        self.assertIn('UIApplication.shared.applicationState == .active',text)
        self.assertIn('private var worker: Task<Void, Never>?',text)
        self.assertIn('while true',text)
        self.assertIn('if version == self.revision { break }',text)
        self.assertIn('abs(old.timelineEnd.timeIntervalSince(state.timelineEnd)) < 2',text)
        self.assertIn('pushType: nil',text)
        self.assertIn('@concurrent static func apply(currentID: String?',text)
        self.assertIn('private var currentID: String?',text)
        self.assertNotIn('private var current: Activity',text)
        self.assertNotIn('@preconcurrency import',text)
        self.assertNotIn('@unchecked Sendable',text)
        self.assertIn('.end(nil, dismissalPolicy: .immediate)',text)
        for bad in ['getStreamInfo','AVAudioSession','activateForPlayback','Timer(','.resume()', 'player.play(']:self.assertNotIn(bad,text)
        payload=source('SharedActivity/SonivoActivityAttributes.swift')
        for bad in ['accessToken','streamUrl','cookie','account','artist']:self.assertNotIn(bad,payload)
        widget=source('SonivoLiveActivity/SonivoLiveActivityWidget.swift')
        for required in ['compactLeading','compactTrailing','minimal','timerInterval','sonivo://player','SonivoBrandGlyph']:self.assertIn(required,widget)
    def test_versioned_transparent_masks_and_approved_preview(self):
        for key in ['Music','Signature','Wordmark','Classic']:
            data=base64.b64decode(source(f'design/dynamic-island/assets/{key}.png.b64').strip(),validate=True)
            self.assertEqual(data[:8],b'\x89PNG\r\n\x1a\n')
            metadata=json.loads(source(f'SharedActivity/BrandAssets.xcassets/SonivoBrand{key}.imageset/Contents.json'))
            self.assertEqual(metadata['properties']['template-rendering-intent'],'template')
        preview=base64.b64decode(source('design/dynamic-island/preview.png.b64').strip(),validate=True)
        self.assertEqual(preview[:8],b'\x89PNG\r\n\x1a\n')
        self.assertIn('КОММИТА НЕТ',source('design/dynamic-island/preview.svg')) # Versioned approved pre-commit mock.
    def test_eq_icon_preserves_action_audio_and_touch_target(self):
        player=source('Sonivo/PlayerScreenV2.swift')
        controls=player.split('private var secondaryPlayerActions',1)[1].split('private var sleepTimerBottomButton',1)[0]
        for required in ['SonivoEqualizerGlyph()','openModal(.equalizer)','SN.tapTarget','SN.accent','accessibilityLabel("Эквалайзер")']:self.assertIn(required,controls)
        glyph=source('Sonivo/SonivoEqualizerGlyph.swift')
        self.assertIn('StrokeStyle(lineWidth: 2 * unit, lineCap: .round)',glyph)
        for bad in ['PlayerCore','eqGains','AVAudio','setGain']:self.assertNotIn(bad,glyph)
if __name__=='__main__':unittest.main()
