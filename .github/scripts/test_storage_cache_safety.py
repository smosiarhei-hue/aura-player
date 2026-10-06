import unittest
from pathlib import Path


class StorageCacheSafetyTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parent.parent.parent
        self.player = (root / "Sonivo" / "playercore.swift").read_text(encoding="utf-8")
        self.aligner = (root / "Sonivo" / "OnDeviceVocalAligner.swift").read_text(encoding="utf-8")
        self.cache = (root / "Sonivo" / "MediaCacheManager.swift").read_text(encoding="utf-8")
        self.theme = (root / "Sonivo" / "theme.swift").read_text(encoding="utf-8")

    def test_normal_streaming_never_precaches_complete_track(self):
        self.assertNotIn("func precacheStream", self.player)
        self.assertNotIn("precacheStream(current, url: url)", self.player)
        self.assertIn("Ordinary playback stays streaming-only", self.player)
        self.assertIn("removeLegacyUnboundedStreamCacheIfNeeded()", self.player)
        self.assertIn("storage.removed-unbounded-stream-cache.v1", self.player)

    def test_full_download_requires_explicit_eq_action(self):
        eq_block = self.player.split("var eqEnabled: Bool", 1)[1].split("/// User EQ curve", 1)[0]
        self.assertIn("scheduleStreamMigrationIfNeeded(immediate: true)", eq_block)
        self.assertIn("complete stream may be downloaded", eq_block)

    def test_neural_transcription_is_opt_in_and_cleans_temp_audio(self):
        self.assertIn('lyrics.neuralEngineEnabled") as? Bool ?? false', self.theme)
        self.assertGreaterEqual(
            self.aligner.count("defer { removeGeneratedTemporaryAudioIfNeeded(localURL) }"),
            2,
        )
        self.assertIn('name.hasPrefix("ym_") || name.hasPrefix("stream_")', self.aligner)

    def test_cache_screen_counts_and_removes_all_generated_audio(self):
        for marker in ('"profiles"', '"neuromix-profiles"', 'name.hasPrefix("ym_")', 'name.hasPrefix("stream_")'):
            self.assertIn(marker, self.cache)
        self.assertIn("for file in temporaryAudioFiles", self.cache)
        self.assertIn('hasPrefix("vocal_")', self.cache)


if __name__ == "__main__":
    unittest.main()
