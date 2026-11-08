"""Automatic AutoMix pair selection and transport integration regressions."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLAYER = ROOT / 'Sonivo/playercore.swift'
ANALYSIS = ROOT / 'Sonivo/AutoMixV2AnalysisRuntime.swift'


class AutomaticNextSelectionTests(unittest.TestCase):
    def test_analysis_and_transport_share_selection_and_revalidate(self):
        player, analysis = PLAYER.read_text(), ANALYSIS.read_text()
        refresh = analysis.split('private func refreshPairIfNeeded()', 1)[1]
        self.assertIn('let selection = PlayerCore.shared.automaticNextSelection()', refresh)
        self.assertIn('selectionRevision != observedSelectionRevision', refresh)
        self.assertGreaterEqual(refresh.count('selectionIsCurrent(selectionRevision)'), 3)
        self.assertIn('selectionIsCurrent(observedSelectionRevision)', analysis)
        schedule = player.split('private func scheduleTransitionIfNeeded()', 1)[1].split('private func resolveMashupStyle', 1)[0]
        self.assertIn('isMashupTransitionMode ? automaticNextSelection().track', schedule)
        self.assertIn('guard validatePendingAutomaticTransition()', schedule)
        wait = player.split('private func waitUntilMashupCue(', 1)[1].split('private func mountLiveAutomixNativeDecks', 1)[0]
        self.assertGreaterEqual(wait.count('validatePendingAutomaticTransition()'), 2)
        self.assertIn('transitionRequestID == transitionID', wait)
        self.assertIn('generation == expectedGeneration', wait)
        energy = player.split('private func retargetAutomixFromEnergy(', 1)[1].split('private func mashupProfileMatches', 1)[0]
        self.assertLess(energy.index('transitionRequestID == transitionID'), energy.index('transitionDuration = blend'))
        self.assertIn('self.pendingMashupLiveArm?.transitionID == transitionID', player)
        validate = player.split('private func validatePendingAutomaticTransition()', 1)[1].split('private func peekNext', 1)[0]
        self.assertIn('transitionStartTime == nil', validate)
        self.assertIn('selected.revision == revision', validate)
        self.assertIn('cancelTransition()', validate)
        cancel = player.split('private func cancelTransition()', 1)[1].split('func setOutgoingPlaybackRate', 1)[0]
        self.assertNotIn('automaticNextChoice.reset()', cancel)
        manual = player.split('func next() {', 1)[1].split('func previous()', 1)[0]
        self.assertIn('if let nextTrack = peekNext(auto: false)', manual)
        self.assertIn('if let ready = self.peekNext(auto:true)', manual)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler unavailable')
    def test_real_swift_selection(self):
        source = PLAYER.read_text().split('// BEGIN AutomaticNextChoice', 1)[1].split('// END AutomaticNextChoice', 1)[0]
        main = r'''
import Foundation
let a = UUID(), b = UUID(), c = UUID(), d = UUID()
func context(_ current: UUID = a, shuffle: Bool = false, one: Bool = false,
             all: Bool = false, wave: String? = nil) -> AutomaticNextChoice.Context {
    .init(current: current, shuffle: shuffle, repeatOne: one, repeatAll: all, waveContext: wave)
}
var choice = AutomaticNextChoice()
let first = choice.resolve(context: context(shuffle: true), queue: [a,b,c], excluded: [], choose: { $0.last })
precondition(first.track == c)
let append = choice.resolve(context: context(shuffle: true), queue: [a,b,c,d], excluded: [], choose: { $0.first })
precondition(append.track == c && append.revision == first.revision)
let remove = choice.resolve(context: context(shuffle: true), queue: [a,b,d], excluded: [], choose: { $0.first })
precondition(remove.track == b && remove.revision != first.revision)
let restore = choice.resolve(context: context(shuffle: true), queue: [a,c,d], excluded: [], choose: { $0.first })
precondition(restore.track == c && restore.revision != first.revision)
let ordered = choice.resolve(context: context(), queue: [a,b,c], excluded: [])
precondition(ordered.track == b)
let reorder = choice.resolve(context: context(), queue: [a,c,b], excluded: [])
precondition(reorder.track == c && reorder.revision != ordered.revision)
let end = choice.resolve(context: context(c), queue: [a,b,c], excluded: [])
precondition(end.track == nil)
let wrap = choice.resolve(context: context(c, all: true), queue: [a,b,c], excluded: [])
precondition(wrap.track == a && wrap.revision != end.revision)
let one = choice.resolve(context: context(one: true), queue: [a,b,c], excluded: [])
precondition(one.track == nil)
let wave = choice.resolve(context: context(shuffle: true, one: true, wave: "station"), queue: [a,b,c], excluded: [b])
precondition(wave.track == c)
let excluded = choice.resolve(context: context(shuffle: true, one: true, wave: "station"), queue: [a,b,c], excluded: [b,c])
precondition(excluded.track == nil && excluded.revision != wave.revision)
let refill = choice.resolve(context: context(shuffle: true, one: true, wave: "station"), queue: [a,b,c,d], excluded: [b,c])
precondition(refill.track == d && refill.revision != excluded.revision)
let station = choice.resolve(context: context(shuffle: true, one: true, wave: "other"), queue: [a,b,c,d], excluded: [b,c])
precondition(station.track == d && station.revision != refill.revision)
let absent = choice.resolve(context: context(d, wave: "station"), queue: [a,b,c], excluded: [a])
precondition(absent.track == b)
choice.reset()
let reset = choice.resolve(context: context(d, wave: "station"), queue: [a,b,c], excluded: [a])
precondition(reset.track == b && reset.revision != absent.revision)
let singleOff = choice.resolve(context: context(shuffle: true), queue: [a], excluded: [])
precondition(singleOff.track == nil)
let singleAll = choice.resolve(context: context(shuffle: true, all: true), queue: [a], excluded: [])
precondition(singleAll.track == a)
'''
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path / 'Choice.swift').write_text('import Foundation\n' + source)
            (path / 'main.swift').write_text(main)
            built = subprocess.run(['swiftc', '-swift-version', '6', str(path / 'Choice.swift'),
                                    str(path / 'main.swift'), '-o', str(path / 'checks')],
                                   capture_output=True, text=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stderr)
            run = subprocess.run([str(path / 'checks')], capture_output=True, text=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

if __name__ == '__main__':
    unittest.main()
