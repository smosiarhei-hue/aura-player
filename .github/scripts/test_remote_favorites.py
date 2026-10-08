"""Source guards for native remote favorites; iOS controls require device validation."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[2]
PLAYER=(ROOT/'Sonivo/playercore.swift').read_text()
LIBRARY=(ROOT/'Sonivo/librarystore.swift').read_text()
ROUTER=(ROOT/'Sonivo/AutoMixV2AppBridge.swift').read_text()
class RemoteFavoritesTests(unittest.TestCase):
    def test_single_native_feedback_target_no_custom_player(self):
        config=PLAYER.split('private func configureRemoteCommands',1)[1].split('nonisolated private static func nowPlayingArtwork',1)[0]
        self.assertEqual(config.count('likeCommand.addTarget'),1)
        self.assertIn('likeCommand.removeTarget(nil)',config)
        self.assertIn('MPFeedbackCommandEvent',config)
        self.assertIn('!feedback.isNegative',config)
        self.assertIn('return .noSuchContent',config)
        self.assertIn('commandCenter.dislikeCommand.isEnabled = false',config)
        self.assertIn('commandCenter.bookmarkCommand.isEnabled = false',config)
        self.assertNotIn('AVPlayer(',config)
    def test_identity_is_captured_before_main_actor_and_revalidated(self):
        action=PLAYER.split('commandCenter.likeCommand.addTarget',1)[1].split('commandCenter.playCommand.addTarget',1)[0]
        self.assertLess(action.index('snapshot.read()'),action.index('Task { @MainActor'))
        self.assertLess(action.index('self.currentTrack?.id == track.id'),action.index('setTrackFavorite'))
        self.assertIn('nonisolated private final class RemoteFavoriteSnapshot',PLAYER)
        self.assertIn('defer { lock.unlock() }',PLAYER)
    def test_absolute_state_is_idempotent_and_uses_existing_server_path(self):
        setter=LIBRARY.split('func setTrackFavorite',1)[1].split('func toggleFavorite',1)[0]
        self.assertIn('guard isTrackFavorite(track) != isFavorite else { return }',setter)
        self.assertIn('toggleFavorite(track)',setter)
        self.assertNotIn('download',setter)
        self.assertIn('likeTrackOnServer',LIBRARY)
        self.assertIn('unlikeTrackOnServer',LIBRARY)
    def test_system_state_refreshes_on_library_changes_and_track_publication(self):
        self.assertIn('forName: LibraryStore.tracksDidChange',PLAYER)
        self.assertIn('NotificationCenter.default.post(name: Self.tracksDidChange',LIBRARY)
        self.assertIn('private func updateNowPlayingInfo() {\n        refreshFavoriteCommandState()',PLAYER)
        refresh=PLAYER.split('private func refreshFavoriteCommandState()',1)[1].split('private func configureRemoteCommands',1)[0]
        self.assertIn('remoteFavoriteSnapshot.publish(track)',refresh)
        self.assertIn('isEnabled = track != nil',refresh)
        self.assertIn('isActive = favorite',refresh)
        self.assertIn('l10n.removeFromFavorites : l10n.addToFavorites',refresh)
    def test_router_does_not_remove_feedback_targets(self):
        install=ROUTER.split('final class PlaybackCommandRouter',1)[1].split('func selectionChanged()',1)[0]
        self.assertNotIn('likeCommand',install)
        self.assertNotIn('bookmarkCommand',install)
        self.assertIn('commands.forEach { $0.removeTarget(nil)',install)
if __name__=='__main__': unittest.main()
