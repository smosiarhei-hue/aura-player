import unittest
from pathlib import Path


class MusixmatchProxySpecTests(unittest.TestCase):
    def setUp(self):
        root = Path(__file__).resolve().parent.parent.parent
        self.worker = root / "workers" / "musixmatch-proxy" / "src" / "index.js"
        self.readme = root / "workers" / "musixmatch-proxy" / "README.md"
        self.swift = root / "Sonivo" / "MusixmatchProxyClient.swift"

    def test_files_exist(self):
        self.assertTrue(self.worker.exists())
        self.assertTrue(self.readme.exists())
        self.assertTrue(self.swift.exists())

    def test_secret_never_shipped_or_accepted_from_client(self):
        content = self.worker.read_text(encoding="utf-8")
        self.assertIn("env.MUSIXMATCH_API_KEY", content)
        self.assertIn('wrangler secret put MUSIXMATCH_API_KEY', self.readme.read_text(encoding="utf-8"))
        self.assertNotIn("5a57b98e0e4b4c1b8f8c8e8c8e8c8e8c", content)
        self.assertNotIn('url.searchParams.get("apikey")', content)

    def test_full_read_only_api_allowlist(self):
        content = self.worker.read_text(encoding="utf-8")
        methods = (
            "matcher.track.get", "matcher.lyrics.get", "matcher.subtitle.get",
            "track.search", "track.get", "track.lyrics.get",
            "track.lyrics.translation.get", "track.snippet.get",
            "track.subtitle.get", "track.subtitle.translation.get",
            "track.richsync.get", "chart.tracks.get", "artist.search",
            "artist.get", "album.get",
        )
        for method in methods:
            self.assertIn(method, content)
        self.assertIn('request.method !== "GET"', content)
        self.assertIn("caches.default", content)
        self.assertIn('path === "/track/get"', content)
        self.assertIn("Object.keys(identifiers).length !== 1", content)

    def test_swift_client_exposes_full_stack(self):
        content = self.swift.read_text(encoding="utf-8")
        methods = (
            "matcherLyrics", "matcherSubtitle", "trackSearch", "trackMetadata",
            "trackLyrics", "trackLyricsTranslation", "trackSnippet",
            "trackSubtitleTranslation", "chartTracks", "artistSearch",
            "artistMetadata", "albumMetadata",
        )
        for method in methods:
            self.assertIn(f"func {method}", content)
        self.assertIn('appendingPathComponent("richsync")', content)
        self.assertIn('appendingPathComponent("subtitle")', content)
        self.assertIn("private func plainLyrics", content)


if __name__ == "__main__":
    unittest.main()
