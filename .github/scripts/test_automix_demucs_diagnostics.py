"""Regression checks for privacy-safe HTDemucs session diagnostics."""
import pathlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
BAKE = ROOT / 'Packages/AutoMixV2/Sources/AudioEngineCore/StemSplit/HTDemucsMashupBake.swift'
ANALYSIS = ROOT / 'Sonivo/AutoMixV2AnalysisRuntime.swift'
PLAYER = ROOT / 'Sonivo/playercore.swift'

class DemucsDiagnostics(unittest.TestCase):
    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_cache_hit_respects_slice_start_boundary(self):
        source = BAKE.read_text()
        start = source.index('private struct CachedWindow:')
        end = source.index('\nenum HTDemucsPCM', start)
        program = 'import Foundation\nimport CryptoKit\n' + source[start:end].replace(
            'private struct CachedWindow:', 'struct CachedWindow:', 1
        ) + '''
let rate = 44100.0
let samples = Array(repeating: Float(0), count: Int(4 * rate))
let w = CachedWindow(filePath: "x", fileRevision: nil, startSec: 10, rate: rate, reachesFileEnd: false,
                     dryL: samples, dryR: samples, vocalsL: samples, vocalsR: samples,
                     instL: samples, instR: samples)
precondition(w.covers(startSec: 10, durationSec: 2))
precondition(w.slice(startSec: 10, durationSec: 2) != nil)
precondition(!w.covers(startSec: 9.98, durationSec: 2), "invalid cache hit")
precondition(w.slice(startSec: 9.98, durationSec: 2) == nil)
precondition(w.covers(startSec: 10 - 1 / rate, durationSec: 2))
precondition(w.slice(startSec: 10 - 1 / rate, durationSec: 2) != nil)
precondition(!w.covers(startSec: 12, durationSec: 2.1), "truncated non-EOF cache hit")
var eof = w
eof.reachesFileEnd = true
precondition(eof.covers(startSec: 12, durationSec: 2.1), "EOF tail should remain usable")
let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: file) }
try! Data([1]).write(to: file)
let original = CachedWindow.revision(of: file)
precondition(original != nil && CachedWindow.revision(of: file) == original)
let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: copy) }
try! Data([1]).write(to: copy)
precondition(CachedWindow.revision(of: copy) == original, "identical bytes across caches should reuse stems")
try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123456)], ofItemAtPath: file.path)
precondition(CachedWindow.revision(of: file) == original, "cache access timestamp must not invalidate stems")
try! Data([1, 2, 3]).write(to: file, options: .atomic)
precondition(CachedWindow.revision(of: file) != original, "replaced audio must invalidate cache")
'''
        with tempfile.TemporaryDirectory() as d:
            src = pathlib.Path(d) / 'main.swift'
            src.write_text(program)
            exe = pathlib.Path(d) / 'test'
            subprocess.run(['swiftc', '-swift-version', '6', str(src), '-o', str(exe)],
                           check=True, capture_output=True, text=True, timeout=60)
            subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)

    def test_each_decision_and_outcome_is_visible(self):
        analysis = ANALYSIS.read_text()
        bake = BAKE.read_text()
        player = PLAYER.read_text()
        for event in ('demucs.pair id=', 'demucs.download.start', 'demucs.download.ready',
                      'demucs.download.failed', 'reason=no-next-track', 'reason=analysis-failed',
                      'reason=plan-', 'onDiagnostic:'):
            self.assertIn(event, analysis)
        for event in ('prewarm.start', 'prewarm.package-ready', 'prewarm.model-load-start',
                      'prewarm.outgoing-window', 'prewarm.incoming-window', 'prewarm.ready',
                      'prewarm.cancelled', 'prewarm.failed', 'reason=model-load-refused',
                      'cache.hit role=', 'cache.miss role=', 'cache.busy-hit', 'cache.busy-miss',
                      'separate.ready role='):
            self.assertIn(event, bake)
        for event in ('transition.safe-crossfade reason=', 'bake.start blend=',
                      'bake.demucs fallback=', 'bake.ready %@', 'sep=%@', 'demucs.bake.'):
            self.assertIn(event, player)

    def test_runtime_serializes_prewarm_and_retries_model_load(self):
        bake = BAKE.read_text()
        prewarm = bake.split('    func prewarm(', 1)[1].split('    private func cachedPair(', 1)[0]
        self.assertLess(prewarm.index('while jobs > 0'), prewarm.index('jobs += 1'))
        self.assertIn('try Task.checkCancellation()', prewarm)
        self.assertIn('defer { jobs -= 1 }', prewarm)
        self.assertIn('private var modelLoad:', bake)
        self.assertIn('if let modelLoad', bake)
        self.assertIn('Date().addingTimeInterval(30)', bake)
        self.assertNotIn('private var refusedLoad = false', bake)
        self.assertIn('var digest = SHA256()', bake)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_real_swift_error_classification_omits_sensitive_text(self):
        source = BAKE.read_text()
        start = source.index('    public static func diagnosticError(')
        end = source.index('\n    /// Classify a nil result', start)
        function = source[start:end].replace('public static func', 'func', 1)
        program = '''import Foundation
struct HTDemucsModelError: Error { let description: String; init(_ s: String) { description = s } }
''' + function + '''
assert(diagnosticError(CancellationError()) == "cancelled")
assert(diagnosticError(HTDemucsModelError("мало места на iPhone")) == "insufficient-storage")
assert(diagnosticError(HTDemucsModelError("файл модели 4 байт, ждали 5")) == "model-file-size-mismatch")
assert(diagnosticError(NSError(domain: NSURLErrorDomain, code: -1009)) == "network--1009")
assert(diagnosticError(NSError(domain: "/private/path", code: 42)) == "other-error")
assert(diagnosticError(HTDemucsModelError("/private/path")) == "model-error")
'''
        with tempfile.TemporaryDirectory() as d:
            src = pathlib.Path(d) / 'main.swift'
            src.write_text(program)
            exe = pathlib.Path(d) / 'test'
            subprocess.run(['swiftc', '-swift-version', '6', str(src), '-o', str(exe)],
                           check=True, capture_output=True, text=True, timeout=60)
            subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)

if __name__ == '__main__':
    unittest.main()
