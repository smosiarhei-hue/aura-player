from pathlib import Path
import subprocess, tempfile, sys, unittest
ROOT=Path(__file__).resolve().parents[2]
class PlaybackContinuationTests(unittest.TestCase):
    def test_queue_lifetime_and_end_recheck(self):
        s=(ROOT/'Sonivo/playercore.swift').read_text()
        self.assertEqual(s.count('let wave = await self.loadQueueContinuation(seed:'),2)
        self.assertEqual(s.count('if let ready = self.peekNext(auto:true)'),2)
        self.assertIn('private var queueContinuationID = UUID()',s)
        refill=s.split('func refillQueueIfNeeded()',1)[1].split('private func flushListeningStats',1)[0]
        self.assertNotIn('playbackRequestID',refill)
        self.assertIn('self.queueContinuationID == queueID',refill)
        self.assertIn('remainingAhead <= (isYandexWavePlayback ? 5 : 0)',refill)
        self.assertIn('if duration > 0, progress >= duration - 0.1 { next(); return }',s)
    def test_compact_graph_and_consistent_limits(self):
        ui=(ROOT/'Sonivo/playerchrome.swift').read_text()
        self.assertIn('CompactEQCurve(gains:',ui)
        self.assertIn('bandRow(selectedBand)',ui)
        self.assertIn('EQGainLimits.range(at:index)',ui)
        self.assertIn('EQPresets.subBassPower',ui)
        limits=(ROOT/'Sonivo/EQGainLimits.swift').read_text()
        self.assertIn('-maximum...maximum',limits)
        self.assertIn('maximum: Float = 15',limits)
    @unittest.skipUnless(sys.platform=='darwin','Swift Foundation concurrency executable runs on macOS CI')
    def test_real_loader_singleflight_retry_and_cancel(self):
        main=r'''
import Foundation
@main struct Checks {
 @MainActor static func main() async throws {
  let loader=PlaybackContinuationLoader<Int,Int>(retryDelay:.milliseconds(1))
  var calls=0
  let first=Task { @MainActor in await loader.load(key:1) { calls += 1;try? await Task.sleep(for:.milliseconds(30));return [7] } }
  try await Task.sleep(for:.milliseconds(3))
  let second=Task { @MainActor in await loader.load(key:1) { calls += 1;return [8] } }
  let a=await first.value,b=await second.value
  precondition(a == [7] && b == [7] && calls == 1)
  var retries=0
  let afterEmpty=await loader.load(key:2) { retries += 1;return retries < 3 ? [] : [9] }
  precondition(retries == 3 && afterEmpty == [9])
  var emptyCalls=0
  let empty=await loader.load(key:3) { emptyCalls += 1;return [] }
  precondition(empty.isEmpty && emptyCalls == 3)
  let old=Task { @MainActor in await loader.load(key:4) { try? await Task.sleep(for:.milliseconds(100));return [4] } }
  try await Task.sleep(for:.milliseconds(2))
  loader.invalidate()
  let fresh=await loader.load(key:5) { [5] }
  let stale=await old.value
  precondition(stale.isEmpty && fresh == [5])
  print("Continuation single-flight, bounded retry, invalidation and stale result checks passed")
 }
}
'''
        with tempfile.TemporaryDirectory() as d:
            p=Path(d);(p/'Checks.swift').write_text(main)
            built=subprocess.run(['swiftc','-swift-version','6',str(ROOT/'Sonivo/PlaybackContinuationLoader.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
            self.assertEqual(built.returncode,0,built.stderr)
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
