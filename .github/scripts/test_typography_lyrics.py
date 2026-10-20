"""Native integration contracts; source-time policy is also executed with Swift on macOS."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]

class TypographyLyricsTests(unittest.TestCase):
    def test_all_surfaces_and_saved_choices(self):
        player=(ROOT/'Sonivo/PlayerScreenV2.swift').read_text()
        sheet=(ROOT/'Sonivo/lyricsview.swift').read_text()
        theme=(ROOT/'Sonivo/theme.swift').read_text()
        self.assertEqual(player.count('TypographyLyricsView(lyrics: lyrics'),2)
        self.assertIn('TypographyLyricsView(lyrics: lyrics',sheet)
        self.assertIn('LyricsTypographyModeBar()',sheet)
        self.assertIn('LyricsTypographyModeBar()',player)
        self.assertIn('case typography',theme)
        self.assertIn('case classic',theme)
        self.assertIn('case staggered',theme)
        self.assertIn('LyricsDesign(rawValue: defaults.string(forKey: "lyrics.design")',theme)
        self.assertIn('defaults.set(lyricsDesign.rawValue, forKey: "lyrics.design")',theme)

    def test_native_display_never_invents_timing_or_changes_audio(self):
        view=(ROOT/'Sonivo/TypographyLyricsView.swift').read_text()
        policy=(ROOT/'Sonivo/TypographyLyricsPolicy.swift').read_text()
        self.assertIn('LyricsPlaybackClock.time(',view)
        self.assertIn('LyricsPlaybackClock.seekTime(',view)
        self.assertIn('TypographyLyricsPolicy.matchedWords(for: line)',view)
        self.assertIn('time >= words[pair.offset].startTime',view)
        self.assertIn('guard line.hasRealWordTimings',policy)
        self.assertIn('guard tokens == words.map',policy)
        for token in ['URLSession','AVAudioEngine','AVPlayer','TimelineView','player.resume()','player.play(','duration /','wordCount']:
            self.assertNotIn(token,view)
        self.assertNotIn('LyricPhrase.from',view)

    def test_accessibility_manual_scroll_and_lifecycle(self):
        view=(ROOT/'Sonivo/TypographyLyricsView.swift').read_text()
        for token in ['accessibilityReduceMotion','colorSchemeContrast','@ScaledMetric',
                      'Button("К текущей")','onDisappear { browsingTask?.cancel() }',
                      'scenePhase == .active','if !browsing { centerCurrent(proxy) }',
                      '.fixedSize(horizontal: false, vertical: true)', '.accessibilityLabel(line.text)',
                      'Text("Типографика").tag(LyricsDesign.typography)',
                      'Text("Строки").tag(LyricsDesign.classic)', 'SN.accent']:
            self.assertIn(token,view)
        self.assertNotIn('.lineLimit(1)',view)
        player=(ROOT/'Sonivo/PlayerScreenV2.swift').read_text()
        self.assertIn('lyricsControlsVisible || SettingsStore.shared.lyricsDesign == .typography',player)
        self.assertIn('withAnimation(reduceMotion ? nil : SN.slowSpring) { showLyricsMode = false }',player)

    @unittest.skipUnless(platform.system()=='Darwin' and shutil.which('swiftc'), 'Native timing fixture executes on macOS')
    def test_actual_swift_source_timings_and_unicode(self):
        fixture=r'''
import Foundation
@main struct Checks {
 static func main() {
  let lines = [LyricsLine(text:"Intro",startTime:2,endTime:4),
               LyricsLine(text:"Next",startTime:8,endTime:10)]
  func active(_ t:Double)->Int? {
   TypographyLyricsPolicy.activeIndex(lines:lines,synchronized:true,time:t,duration:12)
  }
  precondition(active(0)==nil && active(1.99)==nil)
  precondition(active(2)==0 && active(3.99)==0)
  precondition(active(4)==nil && active(7.99)==nil,"Instrumental gap must not sing")
  precondition(active(8)==1 && active(9.99)==1 && active(10)==nil)
  precondition(active(.nan)==nil && active(.infinity)==nil && active(-1)==nil)
  precondition(TypographyLyricsPolicy.activeIndex(lines:lines,synchronized:false,time:3,duration:12)==nil)
  precondition(TypographyLyricsPolicy.activeIndex(lines:[],synchronized:true,time:3,duration:12)==nil)
  let zero=[LyricsLine(text:"At zero",startTime:0),LyricsLine(text:"Last",startTime:4)]
  precondition(TypographyLyricsPolicy.activeIndex(lines:zero,synchronized:true,time:0,duration:8)==0)
  precondition(TypographyLyricsPolicy.activeIndex(lines:zero,synchronized:true,time:4,duration:8)==1)
  precondition(TypographyLyricsPolicy.activeIndex(lines:zero,synchronized:true,time:8,duration:8)==nil)
  for text in ["", "Привет,  мир!", "one\ntwo\tthree", "  музыка 🎵✨", "你好 世界", "Не-е-ет…"] {
   precondition(TypographyLyricsPolicy.segments(text).joined()==text,"Text must remain exact")
  }
  let words=[LyricsWord(text:"Привет,",startTime:1,endTime:1.4),LyricsWord(text:"мир!",startTime:1.5,endTime:2)]
  let good=LyricsLine(text:"Привет,  мир!",startTime:1,words:words)
  precondition(TypographyLyricsPolicy.matchedWords(for:good)==words)
  precondition(TypographyLyricsPolicy.matchedWords(for:LyricsLine(text:"Другой текст",startTime:1,words:words))==nil)
  precondition(TypographyLyricsPolicy.matchedWords(for:LyricsLine(text:"Привет, мир!",startTime:1))==nil)
  let invalid=LyricsLine(text:"Broken",startTime:1,words:[LyricsWord(text:"Broken",startTime:2,endTime:1)])
  precondition(TypographyLyricsPolicy.matchedWords(for:invalid)==nil)
  print("Typographic lyrics: boundaries, gaps, plain text, source words and Unicode passed")
 }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'Checks.swift').write_text(fixture)
            build=subprocess.run(['swiftc','-swift-version','6','-parse-as-library',str(ROOT/'Sonivo/lyricsmodel.swift'),str(ROOT/'Sonivo/TypographyLyricsPolicy.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stderr[-10000:])
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,(run.stdout+run.stderr)[-10000:])
