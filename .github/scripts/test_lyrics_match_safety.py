"""Source regression guards + reference identity/timing cases. Device songs need QA."""
import re
import unicodedata
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def normal(value):
    value = ''.join(c for c in unicodedata.normalize('NFKD', value.casefold()) if not unicodedata.combining(c))
    return ' '.join(''.join(c if c.isalnum() else ' ' for c in value).split())


def canonical(value):
    value = re.sub(r'[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]', '', value, flags=re.I)
    value = re.sub(r'[\(\[]\s*(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?\s*[\)\]]', '', value, flags=re.I)
    return normal(value)


def matches(title, artist, candidate_title, candidate_artist):
    if not artist or not candidate_artist or not candidate_title:
        return False
    return canonical(title) == canonical(candidate_title) and normal(artist) == normal(candidate_artist)


class LyricsMatchSafetyTests(unittest.TestCase):
    def test_title_substrings_and_first_hit_fallback_are_rejected(self):
        self.assertFalse(matches('Love', 'Artist', 'Love Story', 'Artist'))
        self.assertFalse(matches('Song', 'Artist', 'Song', 'Other artist'))
        self.assertFalse(matches('Song', 'Artist', None, 'Artist'))
        source = (ROOT / 'Sonivo/MusixmatchClient.swift').read_text()
        self.assertNotIn('?? tracks.first', source)
        service = (ROOT / 'Sonivo/lyricsservice.swift').read_text()
        self.assertNotIn('contains(targetTitle)', service)
        self.assertIn('result.primary_artist?.name', service)

    def test_recording_qualifiers_remain_distinct(self):
        for qualifier in ['Slowed', 'Sped Up', 'Remix', 'Live', 'Acoustic', 'Instrumental', 'Reverb']:
            self.assertFalse(matches(f'Song ({qualifier})', 'Artist', 'Song', 'Artist'))
            self.assertTrue(matches(f'Song ({qualifier})', 'Artist', f'Song [{qualifier.lower()}]', 'artist'))
        self.assertTrue(matches('Song (Remastered 2011)', 'Artist', 'Song', 'Artist'))
        yandex = (ROOT / 'Sonivo/yandexmusicservice.swift').read_text()
        self.assertIn('LyricsMatchPolicy.recordingTitle(baseTitle, version: version)', yandex)

    def test_search_all_sources_uses_identity_policy(self):
        for file in ['lyricsservice.swift', 'MusixmatchClient.swift', 'MusixmatchProxyClient.swift']:
            self.assertIn('LyricsMatchPolicy.matches(', (ROOT / 'Sonivo' / file).read_text())
        worker = (ROOT / 'workers/musixmatch-proxy/src/index.js').read_text()
        self.assertIn('name: track.track_name || ""', worker)
        self.assertIn('track_length: track.track_length || null', worker)

    def test_duration_gate_does_not_stretch_other_versions(self):
        def compatible(expected, candidate):
            return candidate is not None and candidate > 0 and abs(expected - candidate) <= max(2, min(5, expected * .015))
        self.assertTrue(compatible(180, 181))
        self.assertFalse(compatible(180, 210))
        self.assertFalse(compatible(180, None))
        self.assertFalse(compatible(180, 0))
        source = (ROOT / 'Sonivo/lyricsservice.swift').read_text()
        self.assertIn('LyricsMatchPolicy.plain(result)', source)
        self.assertIn('var plainFallback: Lyrics?', source)
        self.assertIn('LyricsMatchPolicy.durationMatches(track.duration, detail.duration)', source)

    def test_safe_yandex_id_uses_track_not_album_or_random_filename(self):
        def extract(name):
            if not name.startswith('ym_') or not name.endswith('.mp3'): return None
            parts = name[3:-4].split(':')
            return parts[0] if 1 <= len(parts) <= 2 and all(p.isdigit() for p in parts) else None
        self.assertEqual(extract('ym_12345:67890.mp3'), '12345')
        self.assertEqual(extract('ym_12345.mp3'), '12345')
        for file in ['song2026.mp3', 'vocal_123456.mp3', 'ym_UUID.mp3', 'ym_:67890.mp3']:
            self.assertIsNone(extract(file))
        source = (ROOT / 'Sonivo/lyricsservice.swift').read_text()
        self.assertIn('LyricsMatchPolicy.yandexID(fileName: track.fileName)', source)
        self.assertNotIn('.last ?? ymId', source)

    def test_no_fake_song_timing_or_auto_transcription_in_player(self):
        player = (ROOT / 'Sonivo/PlayerScreenV2.swift').read_text()
        for token in ['.synthesizeKaraoke(', '.transcribe(track: requested)']:
            self.assertNotIn(token, player)
        aligner = (ROOT / 'Sonivo/OnDeviceVocalAligner.swift').read_text()
        self.assertNotIn('synthesizeKaraokeTimings', aligner)
        analyzer = aligner.split('func getOrAnalyzeLyrics', 1)[1].split('// MARK: - Forced Alignment', 1)[0]
        self.assertNotIn('self.transcribe(', analyzer)
        self.assertIn('candidate.confidence >= 0.65', aligner)
        self.assertIn('anchors.count == lines.count', aligner)

    def test_plain_custom_lyrics_no_longer_get_generated_timestamps(self):
        service = (ROOT / 'Sonivo/lyricsservice.swift').read_text()
        custom = service.split('func parseCustomLyrics', 1)[1].split('func saveCustomLyrics', 1)[0]
        self.assertNotIn('Double(rawLines.count)', custom)
        self.assertIn('isLegacyEstimatedLRC', custom)
        view = (ROOT / 'Sonivo/lyricsview.swift').read_text()
        self.assertNotIn('generateAutoTimings', view)
        self.assertIn('авторазметка по длительности отключена', view)

    def test_bad_word_timing_is_rejected(self):
        model = (ROOT / 'Sonivo/lyricsmodel.swift').read_text()
        self.assertIn('$0.endTime > $0.startTime', model)
        self.assertIn('pair.1.startTime > pair.0.startTime', model)
        self.assertIn('$0.startTime.isFinite', model)
        self.assertNotIn('words[1].startTime >= words[0].startTime', model)

    def test_richsync_merges_fragments_only_if_the_words_match(self):
        source = (ROOT / 'Sonivo/MusixmatchClient.swift').read_text()
        self.assertIn('words: wordsMatchingText(words, text: text)', source)
        self.assertIn('expected == actual', source)
        self.assertIn('characterTimes[cursor].start', source)
        self.assertIn('characterTimes[cursor + count - 1].end', source)

    def test_fast_lyrics_do_not_hold_prior_phrase_for_1_2_seconds(self):
        kinetic = (ROOT / 'Sonivo/KineticLyricsView.swift').read_text()
        self.assertNotIn('let duration = max(1.2', kinetic)
        self.assertIn('min(sourceEnd, nextStart)', kinetic)
        self.assertIn('max(0.02, w.endTime - w.startTime)', kinetic)

    def test_shared_clock_avoids_double_bluetooth_compensation(self):
        policy = (ROOT / 'Sonivo/LyricsMatchPolicy.swift').read_text()
        self.assertIn('player.currentTrack?.isStream == true ? 0', policy)
        for filename in ['lyricsview.swift', 'PlayerScreenV2.swift', 'StaggeredLyricsView.swift']:
            source = (ROOT / 'Sonivo' / filename).read_text()
            self.assertIn('LyricsPlaybackClock.time(', source)
            self.assertIn('LyricsPlaybackClock.seekTime(', source)
        staggered = (ROOT / 'Sonivo/StaggeredLyricsView.swift').read_text()
        self.assertIn('elapsed: time - start, index: 0', staggered)
        self.assertIn('delay: 0)', staggered)

    def test_cache_key_is_recording_specific_and_keeps_manual_text(self):
        source = (ROOT / 'Sonivo/lyricsservice.swift').read_text()
        self.assertIn('lyrics_v3|', source)
        self.assertIn('LyricsMatchPolicy.normalized(track.title)', source)
        self.assertIn('custom_lyrics_\\(track.id.uuidString)', source)
        self.assertIn('legacyCacheKey(for: track)', source)
        self.assertIn('agreesWithOfficialText', source)


if __name__ == '__main__':
    unittest.main()
