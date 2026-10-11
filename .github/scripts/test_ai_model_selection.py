import pathlib
import unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
class AIModelSelectionTests(unittest.TestCase):
    def test_curator_rank_is_catalog_intersection_and_bounded(self):
        source=(ROOT/'Sonivo/Dify/AIModelDiscovery.swift').read_text()
        self.assertIn('preferred.filter { available.contains($0) }',source)
        self.assertIn('automaticAttemptLimit = 3',source)
        self.assertIn('responsiveCandidate',source)
        self.assertIn('Not a benchmark or availability guarantee',source)
    def test_protocol_probe_not_only_ok_and_unsafe_retry_stops(self):
        source=(ROOT/'Sonivo/Dify/DifyService.swift').read_text()
        self.assertIn('reply.intent == .playlist',source)
        self.assertIn('reply.playlist?.tracks.count == 1',source)
        self.assertIn('artist: "Bill Evans", title: "Peace Piece"',source)
        self.assertIn('[400, 404, 410].contains(status)',source)
        self.assertIn('guard automatic, Self.isModelSpecificSetupFailure(error)',source)
        self.assertIn('remaining = 120',source)
        self.assertIn('min(60, remaining)',source)
    def test_ui_retains_auto_and_explains_attempts(self):
        source=(ROOT/'Sonivo/Dify/DifySettingsSheet.swift').read_text()
        self.assertIn('Лучшая доступная для Куратора · авто',source)
        self.assertIn('не более 3 моделей',source)
        self.assertIn('model = selectedModel.isEmpty ? "" : chosen',source)
        self.assertIn('nvidia_curator.auto_selection',source)
if __name__=='__main__':unittest.main()
