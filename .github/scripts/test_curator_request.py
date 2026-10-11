import pathlib,unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
class CuratorRequestTests(unittest.TestCase):
    def test_reference_is_explicit_metadata_not_audio(self):
        source=(ROOT/'Sonivo/Dify/AICuratorRequest.swift').read_text()
        self.assertIn('audio', (ROOT/'tools/curator_live_eval.py').read_text())
        self.assertIn('аудио не передано',source)
        self.assertNotIn('reference.id',source)
        store=(ROOT/'Sonivo/Dify/AIMusicCuratorStore.swift').read_text()
        self.assertIn('reference.map(AICuratorRequest.referenceContext)',store)
        self.assertIn('userMessage.songReference = effectiveReference',store)
    def test_period_and_recording_are_catalog_checked(self):
        s=(ROOT/'Sonivo/Dify/AIPlaylistGeneratorService.swift').read_text()
        self.assertIn('catalogYears.min().map(range.contains) ?? false',s)
        self.assertIn('AICuratorPolicy.matchesCatalog',s)
        self.assertIn('version:candidate.version',s)
        self.assertIn('yearRange:yearRange',s)
    def test_reference_picker_lazy_cancellable_and_bounded(self):
        s=(ROOT/'Sonivo/Dify/CuratorReferencePicker.swift').read_text()
        for token in ['LazyVStack','Task.detached','worker.cancel()','filtered.prefix(100)','guard key == request']:
            self.assertIn(token,s)
    def test_extension_keeps_seed_and_small_batches(self):
        store=(ROOT/'Sonivo/Dify/AIMusicCuratorStore.swift').read_text()
        for token in ['count: Int = 10','originalRequest:originalRequest','rules:rules','suggestedBefore:suggestedBefore','extensionMissingCount','catalogProgress']:
            self.assertIn(token,store)
        ui=(ROOT/'Sonivo/Dify/AIMusicAssistantView.swift').read_text()
        self.assertIn('До 50 · дольше',ui)
        self.assertIn('Дополнить · до 10 песен',ui)
        resolver=(ROOT/'Sonivo/Dify/AIPlaylistGeneratorService.swift').read_text()
        self.assertIn('searchCuratorTracks',resolver)
        self.assertNotIn('searchAllFixed',resolver)
        self.assertIn('rules.diverse(ordered,existing:existingTracks)',resolver)
        self.assertIn('seenSuggestions.insert(name)',resolver)
    def test_catalog_lookup_is_tracks_only(self):
        source=(ROOT/'Sonivo/yandexcatalogfix.swift').read_text().split('func searchCuratorTracks',1)[1].split('func searchAllFixed',1)[0]
        for token in ['value:"track"','value:"true"','request.timeoutInterval = 15','data.count <= 2_000_000']:
            self.assertIn(token,source)
        self.assertNotIn('albumsFromTracks',source)
        self.assertNotIn('fetchAlbums',source)
    def test_examples_do_not_claim_training_or_perfect_accuracy(self):
        s=(ROOT/'Sonivo/Dify/AICuratorPrompt.swift').read_text()
        for token in ['2000–2009','ПРИКРЕПЛЁННАЯ ПЕСНЯ','ПРОГУЛКА','УТОЧНЕНИЕ','конкретные записи','Не обещай 100%']:
            self.assertIn(token,s)
if __name__=='__main__':unittest.main()
