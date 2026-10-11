"""Keep collection processing/disk I/O out of SwiftUI bodies and playback ticks."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
def source(name): return (ROOT / 'Sonivo' / name).read_text()

class LibraryPerformanceTests(unittest.TestCase):
    def test_track_and_playlist_shelves_are_lazy(self):
        s = source('libraryview.swift')
        self.assertIn('LazyVStack(spacing: 2)', s)
        self.assertIn('LazyHStack(spacing: 14)', s)
        self.assertIn('.task(id: projectionKey)', s)
    def test_filter_and_file_checks_are_background_and_revision_owned(self):
        s = source('libraryview.swift')
        self.assertNotIn('fileExists', s)
        self.assertNotIn('localizedCaseInsensitiveContains', s)
        self.assertIn('Task.detached(priority: .userInitiated)', s)
        self.assertIn('projectionKey == key', s)
        self.assertIn('onCancel: { worker.cancel() }', s)
        self.assertIn('projection.key.loggedIn == YandexMusicService.shared.isUserLoggedIn', s)
    def test_constant_time_favorite_lookup_and_linear_cloud_merge(self):
        s = source('librarystore.swift')
        favorite = s.split('func isTrackFavorite(', 1)[1].split('// MARK: - Scan local', 1)[0]
        self.assertIn('trackLookup.matching', favorite)
        self.assertNotIn('tracks.first', favorite)
        cloud = s.split('func setFavoritesFromCloud(', 1)[1].split('func clearFavorites', 1)[0]
        self.assertIn('var indices: [UUID: Int]', cloud)
        self.assertNotIn('firstIndex', cloud)
    def test_metadata_encoding_and_writes_are_not_main_actor(self):
        s = source('librarystore.swift')
        persist = s.split('private func persistTracks()', 1)[1].split('private func loadData()', 1)[0]
        self.assertNotIn('JSONEncoder', persist)
        self.assertNotIn('data.write', persist)
        self.assertIn('LibraryPersistenceWriter.shared.write', persist)
        w = source('LibraryPersistenceWriter.swift')
        self.assertIn('nonisolated final class', w)
        self.assertIn('qos: .utility', w)
        self.assertIn('pending[url] = job', w)
        self.assertIn('options: .atomic', w)
    def test_reset_and_background_flush_cannot_race_old_snapshots(self):
        s = source('librarystore.swift').split('func resetIndex()', 1)[1].split('// MARK:', 1)[0]
        self.assertIn('LibraryPersistenceWriter.shared.remove', s)
        self.assertNotIn('FileManager.default.removeItem', s)
        self.assertIn('LibraryPersistenceWriter.shared.flush()', source('sonivoapp.swift'))
        self.assertIn('beginBackgroundTask', source('sonivoapp.swift'))
    def test_playlist_resolves_once_per_revision_not_per_row(self):
        s = source('PlaylistDetailView.swift')
        self.assertIn('.task(id: trackLoadKey)', s)
        self.assertIn('resolvedTracks', s)
        self.assertIn('key == trackLoadKey', s)
        self.assertNotIn('library.tracks(for:', s)
    def test_account_sync_is_single_flight_and_cancelled_on_logout(self):
        s = source('yandexmusicservice.swift')
        self.assertIn('accountSyncGeneration == generation', s)
        self.assertIn('await task.value; return', s)
        self.assertIn('accountSyncTask?.cancel(); accountSyncTask = nil', s)
        p = source('YandexAccountPlaylists.swift')
        self.assertIn('Task.detached(priority: .utility)', p)
        self.assertIn('accountGeneration == generation', p)
        self.assertIn('guard items.count == entries.count', p)
    def test_local_copy_is_background_without_breaking_scoped_access(self):
        s = source('librarystore.swift')
        copy = s.split('func importFiles(', 1)[1].split('func clearLastError', 1)[0]
        self.assertIn('Task.detached(priority: .userInitiated)', copy)
        self.assertIn('guard !isImportingFiles else', copy)
        self.assertIn('startAccessingSecurityScopedResource', copy)
        self.assertIn('stopAccessingSecurityScopedResource', copy)
    def test_actual_metadata_is_nonisolated_but_ui_palette_is_main_actor(self):
        s = source('models.swift')
        self.assertIn('nonisolated struct Track:', s)
        self.assertIn('nonisolated struct Playlist:', s)
        self.assertIn('@MainActor var palette:', s)
        for model in ['YMArtist', 'YMAlbum', 'YMTrackItem']:
            self.assertIn('nonisolated struct ' + model + ':', source('yandexmusicservice.swift'))
