from pathlib import Path
import subprocess,sys,tempfile,unittest
R=Path(__file__).resolve().parents[2]
def source(name): return (R/'Sonivo'/name).read_text()
class PlayerQualityNativeTests(unittest.TestCase):
    def test_lossless_endpoint_rejects_lossy_answer_before_legacy_selection(self):
        service=source('yandexmusicservice.swift')
        endpoint=service.split('private func getLosslessFileInfo',1)[1].split('func getStreamInfo',1)[0]
        self.assertIn('return StreamInfo(url: streamURL',endpoint)
        selection=service.split('func getStreamInfo',1)[1].split('// MARK: - Convert',1)[0]
        self.assertIn('PlaybackQualityFacts(codec: losslessInfo.codec, bitrate: losslessInfo.bitrate).isLossless',selection)
        self.assertIn('signedLossyFallback = losslessInfo',selection)
        self.assertIn('if let fallback = signedLossyFallback {',selection)
        self.assertIn('flacs.max',selection)
        self.assertIn('preferredQuality == .lossless',selection)
    def test_unknown_or_lossy_quality_is_not_mislabelled_lossless_or_hires(self):
        facts=source('PlaybackQualityFacts.swift')
        self.assertNotIn('bitrate >= 1000',facts)
        self.assertIn('Качество уточняется',facts)
        screen=source('PlayerScreenV2.swift')
        self.assertNotIn('return player.audioQuality.badgeText',screen)
        self.assertNotIn('16/24 бит, 44,1 кГц',screen)
        self.assertIn('Это не Lossless.',screen)
    def test_local_file_reports_encoded_format_not_extension_guesses(self):
        reader=source('LocalAudioQualityReader.swift')
        for token in ['file.fileFormat.streamDescription','kAudioFormatAppleLossless','AudioFileGetProperty','kAudioFilePropertyBitRate']:
            self.assertIn(token,reader)
        core=source('playercore.swift')
        local=core.split('private func startLocal',1)[1].split('private func scheduleLocalSegment',1)[0]
        self.assertIn('LocalAudioQualityReader.read(audioFile)',local)
        self.assertNotIn('self.currentBitrate = 320',local)
        stream=core.split('private func startStream',1)[1].split('static func yandexTrackID',1)[0]
        self.assertNotIn('currentBitrate = 128',stream)
        self.assertIn('if !isCatalogTrack',stream)
    def test_transition_commits_incoming_source_quality_instead_of_stale_badge(self):
        core=source('playercore.swift')
        complete=core.split('private func completeTransition',1)[1].split('private func ',1)[0]
        self.assertIn('currentCodec = incomingQuality?.codec',complete)
        self.assertIn('currentBitrate = incomingQuality?.bitrate',complete)
    def test_lyrics_control_moves_next_to_favorite_and_is_not_duplicated_below(self):
        screen=source('PlayerScreenV2.swift')
        metadata=screen.split('private var metadataRow:',1)[1].split('@ViewBuilder private var centerStatusLabel',1)[0]
        self.assertLess(metadata.index('library.toggleFavorite'),metadata.index('lyricsToggleButton'))
        self.assertLess(metadata.index('lyricsToggleButton'),metadata.index('moreMenuButton'))
        self.assertIn('accessibilityLabel: "Текст песни"',metadata)
        secondary=screen.split('private var secondaryPlayerActions:',1)[1].split('private var sleepTimerBottomButton',1)[0]
        self.assertNotIn('quote.bubble',secondary)
    @unittest.skipUnless(sys.platform=='darwin','Swift value-model runtime check requires macOS')
    def test_quality_value_model_runtime(self):
        checks='''
        precondition(PlaybackQualityFacts(codec: "aac", bitrate: 192).badge == "192 kbps")
        precondition(!PlaybackQualityFacts(codec: "mp3", bitrate: 1411).isLossless)
        precondition(PlaybackQualityFacts(codec: "flac", bitrate: 192).isLossless)
        precondition(PlaybackQualityFacts(codec: nil, bitrate: nil).badge == "Качество уточняется")
        precondition(PlaybackQualityFacts(codec: "alac", bitrate: 0).bitrate == nil)
        precondition(PlaybackQualityFacts(codec: "FLAC", bitrate: 1200).badge == "Lossless")
        precondition(PlaybackQualityFacts(codec: "flac-mp4", bitrate: 0).isLossless)
        precondition(PlaybackQualityFacts(codec: "aac-mp4", bitrate: 192).isLossy)
        '''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'check.swift';p.write_text(source('PlaybackQualityFacts.swift')+'\n'+checks)
            subprocess.run(['swift',str(p)],check=True,capture_output=True,text=True,timeout=120)
if __name__=='__main__':unittest.main()
