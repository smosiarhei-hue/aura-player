"""Full pipeline guards, real LRC/native-clock fixtures and upstream request signature."""
from pathlib import Path
import platform,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
def source(name):return (ROOT/'Sonivo'/name).read_text()

class LyricsPipelineAuditTests(unittest.TestCase):
    def test_all_scrolling_surfaces_share_frame_selection_not_published_progress(self):
        for file,marker in [('lyricsview.swift','private struct SyncedLyrics'),
                            ('PlayerScreenV2.swift','struct CoverLyricsScrollView'),
                            ('StaggeredLyricsView.swift','struct StaggeredLyricsView'),
                            ('TypographyLyricsView.swift','struct TypographyLyricsView')]:
            view=source(file).split(marker,1)[1].split('\n}\n',1)[0]
            self.assertIn('LyricsClockSurface(clock: frameClock, player: player, lyrics: lyrics)',view)
            self.assertIn('frameClock.activeIndex',view)
            self.assertNotIn('.onChange(of: player.progress)',view)
            self.assertIn('transaction.disablesAnimations = true',view)
        row=source('PlayerScreenV2.swift').split('private struct CoverLyricLineRow',1)[1].split('private struct LyricsLineButtonStyle',1)[0]
        self.assertNotIn('.animation(',row)
        inline=source('PlayerScreenV2.swift').split('private func inlineLyricsStage',1)[1].split('private var closeLyricsButton',1)[0]
        self.assertNotIn('let playbackTime =',inline)

    def test_native_time_is_read_from_rendered_samples_without_mutating_audio(self):
        core=source('playercore.swift')
        read=core.split('var lyricsPresentationPosition: Double',1)[1].split('private var streamingTimeObservers',1)[0]
        for token in ['activePlayer.lastRenderTime','activePlayer.playerTime(forNodeTime: render)',
                      'localSegmentTokens[key] == segment.token','LyricsTimingStandard.localPosition(']:
            self.assertIn(token,read)
        for forbidden in ['return liveProgress()', 'Date()', '.play()', '.seek(', '.setActive(', 'progress =']:
            self.assertNotIn(forbidden,read)
        self.assertIn('lyricsLocalSegments[key] = (segmentToken, Double(offset) / rate)',core)

    def test_yandex_lrc_is_requested_by_track_id_and_cdn_never_receives_oauth(self):
        service=source('lyricsservice.swift')
        fetch=service.split('private func fetchYandexLyrics',1)[1].split('private func searchYandexTrackId',1)[0]
        self.assertLess(fetch.index('fetchYandexSynchronizedLyrics(track: track'),fetch.index('/supplement'))
        download=fetch.split('var download = URLRequest(url: url)',1)[1]
        for token in ['URLSession.shared.data(for: download)', 'body.count <= 2_000_000', 'LRCParser.parse(text']:
            self.assertIn(token,download)
        for forbidden in ['Authorization', 'setValue(', 'print(', 'log(']:
            self.assertNotIn(forbidden,download)
        selection=service.split('let yandexLyrics = await yandexTask',1)[1]
        self.assertLess(selection.index('yandexLyrics.isSynchronized'),selection.index('await musixmatchTask'))
        self.assertLess(selection.index('return musixmatchLyrics'),selection.index('await geniusTask'))
        request=source('YandexLyricsRequest.swift')
        for token in ['HMAC<SHA256>', 'base64EncodedString()', 'name: "format", value: "LRC"', 'name: "timeStamp"', 'name: "sign"']:
            self.assertIn(token,request)
        self.assertNotIn('dropLast',request)

    @unittest.skipUnless(platform.system()=='Darwin' and shutil.which('swiftc'),'Actual Swift parser/audio/signature fixtures run on macOS')
    def test_actual_lrc_samples_and_signed_request(self):
        fixture=r'''import Foundation
@main struct Checks {
 static func main() {
  func parsed(_ value:String)->Lyrics { LRCParser.parse(value) }
  let plain=parsed("[00:01.25]One\n[00:02.500]Two")
  precondition(plain.lines.count==2 && plain.lines[0].startTime==1.25 && plain.lines[1].startTime==2.5)
  let positive=parsed("[offset:250]\n[00:01.500]One")
  precondition(positive.lines[0].startTime==1.25 && positive.offset==0.25)
  let negative=parsed("[offset:-250]\n[00:01.500]One")
  precondition(negative.lines[0].startTime==1.75)
  let words=parsed("[00:01.00]<00:01.00>Hello <00:01.50>world<00:02.00>")
  precondition(words.lines[0].hasRealWordTimings)
  precondition(words.lines[0].words!.map(\.text)==["Hello","world"])
  precondition(words.lines[0].words![1].startTime==1.5 && words.lines[0].words![1].endTime==2)
  let syllables=parsed("[00:01.00]<00:01.00>При<00:01.20>вет, <00:01.50>мир!<00:02.00>")
  precondition(syllables.lines[0].hasRealWordTimings)
  precondition(syllables.lines[0].words!.map(\.text)==["Привет,","мир!"])
  precondition(syllables.lines[0].words![0].startTime==1 && syllables.lines[0].words![0].endTime==1.5)
  let leading=parsed("[00:01.00]Hello <00:01.50>world<00:02.00>")
  precondition(leading.lines[0].words!.count==2 && leading.lines[0].words![0].startTime==1)
  let repeated=parsed("[offset:250]\n[00:01.00][00:05.00]<00:01.00>Hello <00:01.50>world<00:02.00>")
  precondition(repeated.lines.count==2 && repeated.lines[1].startTime==4.75)
  precondition(repeated.lines[1].words![0].startTime==4.75 && repeated.lines[1].words![1].startTime==5.25)
  let malformed=parsed("[00:01.00]<00:01.50>Hello <00:01.00>world")
  precondition(malformed.lines[0].text=="Hello world" && malformed.lines[0].words==nil)
  let earlier=parsed("[00:01.20]<00:01.00>Hello <00:01.50>world<00:02.00>")
  precondition(earlier.lines[0].startTime==1)
  let unicode=parsed("[00:01.00]<00:01.00>你好 <00:01.50>🎵!<00:02.00>")
  precondition(unicode.lines[0].text=="你好 🎵!" && unicode.lines[0].words!.count==2)
  for rate:Double in [44100,48000,96000] {
   precondition(LyricsTimingStandard.localPosition(segmentStart:40,sampleTime:rate*3,sampleRate:rate,duration:200)==43)
   precondition(LyricsTimingStandard.localPosition(segmentStart:12,sampleTime:0,sampleRate:rate,duration:200)==12)
   // No wall-clock dependency: a stalled node stays still, a resumed one advances.
   precondition(LyricsTimingStandard.localPosition(segmentStart:12,sampleTime:rate,sampleRate:rate,duration:200)==13)
  }
  precondition(LyricsTimingStandard.localPosition(segmentStart:0,sampleTime:100,sampleRate:0,duration:200)==nil)
  precondition(LyricsTimingStandard.localPosition(segmentStart:0,sampleTime:-1,sampleRate:48000,duration:200)==nil)
  precondition(LyricsTimingStandard.localPosition(segmentStart:0,sampleTime:.nan,sampleRate:48000,duration:200)==nil)
  precondition(LyricsTimingStandard.localPosition(segmentStart:199,sampleTime:96000,sampleRate:48000,duration:200)==200)
  let request=YandexLyricsRequest.request(base:"https://api.music.yandex.net",trackID:"115517682",token:"fixture-only",timestamp:1700000000)!
  let items=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
  precondition(items.first(where:{$0.name=="sign"})!.value=="sNTlV1goHvckuDGxRQ2RucEOiRHTA/EP5b6yekoqjtI=")
  precondition(items.first(where:{$0.name=="format"})!.value=="LRC")
  precondition(request.value(forHTTPHeaderField:"Authorization")=="OAuth fixture-only")
  precondition(YandexLyricsRequest.request(base:"https://api.music.yandex.net",trackID:"12/other",token:"fixture-only",timestamp:1700000000)==nil)
  print("LRC units/offsets/syllables/repeats/Unicode, native samples and Yandex signature passed")
 }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp);(p/'Checks.swift').write_text(fixture)
            command=['swiftc','-swift-version','6','-parse-as-library']+[str(ROOT/'Sonivo'/f) for f in ['lyricsmodel.swift','TypographyLyricsPolicy.swift','YandexLyricsRequest.swift']]+[str(p/'Checks.swift'),'-o',str(p/'checks')]
            build=subprocess.run(command,capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stderr[-10000:])
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,(run.stdout+run.stderr)[-10000:])
