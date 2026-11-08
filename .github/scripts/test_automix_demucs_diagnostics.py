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
                      'prewarm.cancelled', 'prewarm.failed', 'reason=model-load-refused'):
            self.assertIn(event, bake)
        for event in ('transition.safe-crossfade reason=', 'bake.start blend=',
                      'bake.demucs fallback=', 'bake.ready %@', 'sep=%@'):
            self.assertIn(event, player)

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
