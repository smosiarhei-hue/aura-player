"""HTDemucs status is passive, actionable and independent of verbose logging."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

def read(name): return (ROOT / 'Sonivo' / name).read_text(encoding='utf-8')

class HTDemucsDiagnosticUITests(unittest.TestCase):
    def test_accessible_from_playback_settings(self):
        self.assertIn('HTDemucsDiagnosticView()', read('settingsview.swift'))
        self.assertIn('settings.htdemucs.diagnostics', read('settingsview.swift'))

    def test_passive_and_clear_about_evidence(self):
        view = read('HTDemucsDiagnosticView.swift')
        self.assertIn('HTDemucsMashupBake.unavailableReason()', view)
        self.assertIn('работоспособность не проверена отдельно', view)
        self.assertIn('не запускает тестовое разделение', view)
        self.assertIn('не доказывают конфликт', view)
        self.assertIn('не включает и не выключает HTDemucs', view)
        self.assertNotIn('.prewarm(', view)
        self.assertNotIn('.stemPair(', view)
        event = read('AutoMixSessionLog.swift').split('func event(_ message:',1)[1].split('func fault(',1)[0]
        self.assertLess(event.index('HTDemucsDiagnostics.shared.record(message)'), event.index('guard isEnabled'))

    def test_pair_evidence_is_anonymous_and_bounded(self):
        analysis = read('AutoMixV2AnalysisRuntime.swift')
        self.assertIn('demucs.plan id=%@ type=%@ cause=%@ bpmA=%.2f bpmB=%.2f', analysis)
        state = read('HTDemucsDiagnostics.swift')
        self.assertIn('value.isFinite, range.contains(value)', state)
        self.assertIn('lastPlanType == "crossfade"', state)
        self.assertIn('выполнение ещё не подтверждено', state)

    @unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
    def test_real_diagnostic_state_tracks_pair_preparation_and_playback(self):
        source = read('HTDemucsDiagnostics.swift').split('@Observable @MainActor', 1)[0]
        source = source.replace('import Observation\n', '')
        harness = r'''
var s = HTDemucsDiagnosticState()
s.record("demucs.pair id=OLD A=11 B=22")
s.record("demucs.plan id=OLD type=crossfade cause=tempo bpmA=91.00 bpmB=120.00 bpmConfA=0.90 bpmConfB=0.80 downConfA=0.88 downConfB=0.75")
precondition(s.pairStatus.contains("кроссфейд") && s.pairStatus.contains("темпы"))
precondition(s.pairStatus.contains("91.0") && s.pairStatus.contains("120.0"))
let previousEntries = s.entries.count
s.record("demucs.prewarm.skipped id=OLD reason=plan-crossfade")
precondition(s.entries.count == previousEntries && s.pairStatus.contains("91.0"), "duplicate must not erase useful evidence")
s.record("transition.safe-crossfade reason=private")
precondition(s.lastTransition.contains("Запланирован") && s.lastTransition.contains("не подтверждено"))
s.record("demucs.pair id=NEW A=22 B=33")
s.record("demucs.prewarm.failed reason=model-load-refused id=OLD")
precondition(s.pairStatus.contains("ожидается анализ"), "stale pair must not override current")
s.record("demucs.plan id=OLD type=crossfade cause=key bpmA=110.00 bpmB=120.00")
precondition(s.pairStatus.contains("ожидается анализ"), "stale plan must be ignored")
s.record("demucs.plan id=NEW type=crossfade cause=key bpmA=nan bpmB=120.00 bpmConfA=500 bpmConfB=0.80")
precondition(s.pairStatus.contains("тональности") && !s.pairStatus.contains("nan") && !s.pairStatus.contains("500"))
s.record("demucs.prewarm.start id=NEW")
precondition(s.pairStatus.contains("запущена"))
s.record("demucs.prewarm.ready id=NEW")
precondition(s.pairStatus.contains("ещё не подтверждено"))
s.record("bake.ready automix sep=htdemucs")
precondition(s.lastTransition.contains("применён"))
s.record("bake.demucs fallback=window-not-ready")
precondition(s.lastTransition.contains("не готово"))
s.record("demucs.prewarm.failed reason=insufficient-storage id=NEW")
precondition(s.pairStatus.contains("недостаточно свободного места"))
s.record("demucs.prewarm.failed reason=/private/secret id=NEW")
precondition(!s.pairStatus.contains("/private/secret"))
for _ in 0..<60 { s.record("demucs.prewarm.start id=NEW") }
precondition(s.entries.count == 50)
'''
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / 'main.swift'; src.write_text(source + harness)
            exe = Path(d) / 'diag'
            subprocess.run(['swiftc', '-swift-version', '6', str(src), '-o', str(exe)], check=True, capture_output=True, text=True, timeout=60)
            subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)

if __name__ == '__main__': unittest.main()
