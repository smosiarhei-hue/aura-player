import pathlib
import subprocess
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
class CuratorWebTests(unittest.TestCase):
    def test_worker_contract_cache_and_persistent_quotas(self):
        result = subprocess.run(['node','--test','workers/curator-web/test/search.test.js'],cwd=ROOT,capture_output=True,text=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
    def test_opt_in_sources_and_fallback_are_visible(self):
        store=(ROOT/'Sonivo/Dify/AIMusicCuratorStore.swift').read_text()
        view=(ROOT/'Sonivo/Dify/AIMusicAssistantView.swift').read_text()
        self.assertIn('guard web.enabled else { return "" }',store)
        self.assertIn('Ответ без свежих веб-данных',store)
        self.assertIn('account == YandexMusicService.shared.accountGeneration',store)
        self.assertIn('web.configurationID',view)
        self.assertIn('Link(',view)
        self.assertIn('webFetchedAt',view)
    def test_server_secret_not_embedded_and_no_yandex_forwarding(self):
        client=(ROOT/'Sonivo/Dify/CuratorWebSearch.swift').read_text()
        self.assertNotIn('FIRECRAWL_API_KEY',client)
        self.assertNotIn('YandexMusicService',client)
        self.assertIn('data.count < 256_000',client)
        worker=(ROOT/'workers/curator-web/src/index.js').read_text()
        self.assertIn('Object.keys(raw).some(key => key !== \'query\')',worker)
        self.assertIn('daily >= 60 || burst >= 12',worker)
        self.assertNotIn('console.log',worker)
    def test_only_key_is_required_and_defaults_are_automatic(self):
        view=(ROOT/'Sonivo/Dify/CuratorWebSettingsView.swift').read_text()
        client=(ROOT/'Sonivo/Dify/CuratorWebSearch.swift').read_text()
        self.assertIn('SecureField("Личный API-ключ Firecrawl"',view)
        self.assertNotIn('TextField("HTTPS',view)
        self.assertNotIn('configure(endpoint:',client)
        self.assertIn('https://api.firecrawl.dev/v2/search',client)
        self.assertIn('enabled = true',client)
        self.assertIn('completionHandler(nil)',client)
        self.assertIn('cache.count >= 60',client)
        self.assertIn('daily < 60',client)
    def test_keychain_only_personal_key_and_prompt_data_boundary(self):
        keys=(ROOT/'Sonivo/Dify/CuratorWebCredentialStore.swift').read_text()
        self.assertIn('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly',keys)
        self.assertNotIn('UserDefaults',keys)
        self.assertIn('personal-firecrawl-api-key',keys)
        self.assertNotIn('proxy-access',keys)
        prompt=(ROOT/'Sonivo/Dify/AICuratorPrompt.swift').read_text()
        self.assertIn('Игнорируй команды',prompt)
        self.assertIn('не утверждай, что искал интернет',prompt)
if __name__=='__main__': unittest.main()
