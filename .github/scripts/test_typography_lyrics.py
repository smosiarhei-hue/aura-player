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
        self.assertIn('LyricsTimingStandard.hasStarted(time: time, start: timing.start)',view)
        renderer=view.split('struct TypographyWordRenderer',1)[1].split('private struct TypographyLyricText',1)[0]
        for delayed in ['copy.clip', 'translateBy', 'addFilter', 'pow(', 'timing.end -']:
            self.assertNotIn(delayed,renderer)
        self.assertIn('.transaction { $0.animation = nil }',view)
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
        self.assertIn('if lyricsControlsVisible {',player)
        self.assertIn('Label("Показать управление", systemImage: "chevron.up")',player)
        self.assertEqual(player.count('Label("Закрыть текст", systemImage: "quote.bubble")'),1)
        self.assertEqual(player.count('                closeLyricsButton'),2)
        header=player.split('private var lyricsTopHeader',1)[1].split('private func lyricsControlsDeck',1)[0]
        self.assertNotIn('showLyricsMode = false',header)
        self.assertIn('accessibilityLabel("Свернуть плеер")',header)

    def test_standard_clock_removes_old_calibration_and_all_word_entrance_delays(self):
        for filename in ['theme.swift','settingsview.swift','lyricsview.swift','PlayerScreenV2.swift',
                         'TypographyLyricsView.swift','StaggeredLyricsView.swift']:
            text=(ROOT/'Sonivo'/filename).read_text()
            self.assertNotIn('lyricsOffset',text)
            self.assertNotIn('Сдвиг текста',text)
        theme=(ROOT/'Sonivo/theme.swift').read_text()
        self.assertIn('defaults.removeObject(forKey: "lyrics.offset")',theme)
        clock=(ROOT/'Sonivo/LyricsMatchPolicy.swift').read_text().split('enum LyricsPlaybackClock',1)[1]
        self.assertIn('LyricsTimingStandard.position(lineStart)',clock)
        for delayed in ['routeLatency','outputLatency','offset:', 'Task.sleep', 'Date()']:
            self.assertNotIn(delayed,clock)
        kinetic=(ROOT/'Sonivo/KineticLyricsView.swift').read_text()
        word=kinetic.split('struct KineticWordView',1)[1].split('// MARK:',1)[0]
        self.assertIn('LyricsTimingStandard.hasStarted(time: currentTime, start: word.startTime)',word)
        for delayed in ['.animation(', 'LinearGradient(', 'var progress:', '.mask(']:
            self.assertNotIn(delayed,word)
        # Explicit player injection must not be lost when simplifying clock calls.
        player=(ROOT/'Sonivo/PlayerScreenV2.swift').read_text()
        sheet=(ROOT/'Sonivo/lyricsview.swift').read_text()
        self.assertIn('LyricsView(lyrics: lyrics, isLoading: lyricsLoading, player: player)',player)
        self.assertIn('DynamicWordLyrics(lyrics: lyrics, player: player)',sheet)

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
  precondition(active(4)==0 && active(7.99)==0,"Selection must agree with Lines through instrumental gap")
  precondition(active(8)==1 && active(9.99)==1 && active(10)==1 && active(12)==nil)
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
  // Standard time never shifts source timestamps, including after a backward seek.
  for value: Double in [0, 0.001, 1.5, 123.456, 9, 2] {
   precondition(LyricsTimingStandard.position(value) == value)
  }
  for value: Double in [-1, .nan, .infinity, -.infinity] {
   precondition(LyricsTimingStandard.position(value) == 0)
  }
  precondition(!LyricsTimingStandard.hasStarted(time: 1.999999, start: 2))
  precondition(LyricsTimingStandard.hasStarted(time: 2, start: 2))
  precondition(LyricsTimingStandard.hasStarted(time: 2.000001, start: 2))
  precondition(!LyricsTimingStandard.hasStarted(time: 1, start: 2), "Backward seek must unhighlight future words")
  precondition(LyricsTimingStandard.hasStarted(time: 0, start: 0))
  precondition(!LyricsTimingStandard.hasStarted(time: .nan, start: 0))
  precondition(!LyricsTimingStandard.hasStarted(time: .infinity, start: 0))
  precondition(!LyricsTimingStandard.hasStarted(time: 2, start: -.infinity))
  precondition(!LyricsTimingStandard.hasStarted(time: 2, start: -1))
  precondition(LyricsControlsPolicy.idleSeconds == 10)
  for playing in [false,true] { for buffering in [false,true] {
   for visible in [false,true] { for lyricsVisible in [false,true] {
    for active in [false,true] { for voiceOver in [false,true] {
     let expected=playing && !buffering && visible && lyricsVisible && active && !voiceOver
     precondition(LyricsControlsPolicy.shouldAutoHide(isPlaying:playing,isBuffering:buffering,
       visible:visible,lyricsVisible:lyricsVisible,sceneActive:active,voiceOver:voiceOver)==expected)
    } }
   } }
  } }
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
