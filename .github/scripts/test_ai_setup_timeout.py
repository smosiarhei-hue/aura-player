import pathlib
import unittest
ROOT=pathlib.Path(__file__).resolve().parents[2]
class AISetupTimeoutTests(unittest.TestCase):
    def test_setup_has_longer_and_hard_deadlines(self):
        s=(ROOT/'Sonivo/Dify/DifyService.swift').read_text()
        self.assertIn('seconds: 45, timeoutError: .catalogTimedOut',s)
        self.assertIn('seconds: seconds, timeoutError: .connectionTimedOut',s)
        self.assertIn('defer { group.cancelAll() }',s)
        self.assertIn('network.code == .timedOut',s)
    def test_timeout_does_not_commit_and_ui_explains_wait(self):
        s=(ROOT/'Sonivo/Dify/DifyService.swift').read_text()
        connect=s.split('func connect(',1)[1].split('private func setupData',1)[0]
        self.assertLess(connect.index('probeConnection(provider:'),connect.index('try configure('))
        ui=(ROOT/'Sonivo/Dify/DifySettingsSheet.swift').read_text()
        self.assertIn('ProgressView(connectionProgress)',ui)
        self.assertIn('до 2 минут',ui)
        self.assertIn('Button("Остановить")',ui)
    def test_preserved_choice_and_latency_hints_not_proof(self):
        s=(ROOT/'Sonivo/Dify/AIModelDiscovery.swift').read_text()
        self.assertIn('preserving current',s)
        self.assertIn('automaticRank',s)
        self.assertIn('Size/reasoning names are only latency hints',s)
if __name__=='__main__':unittest.main()
