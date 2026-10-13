from pathlib import Path
import base64,hashlib,hmac,json,re,subprocess,sys,tempfile,unittest
R=Path(__file__).resolve().parents[2]
def source(name):return (R/'Sonivo'/name).read_text()
class YandexStreamContractTests(unittest.TestCase):
    def test_signing_fixture_matches_client_and_codec_contract(self):
        fixture=json.loads((R/'docs/yandex-stream-signature-fixture.json').read_text())
        code=source('YandexStreamRequestContract.swift')
        key=re.search(r'private static let signingKey = "([^"]+)"',code).group(1)
        message=f"{fixture['timestamp']}{fixture['track_id']}{fixture['quality']}{''.join(fixture['codecs'])}{fixture['transport']}"
        self.assertEqual(base64.b64encode(hmac.new(key.encode(),message.encode(),hashlib.sha256).digest()).decode()[:-1],fixture['signature'])
        self.assertIn(f'static let desktopClient = "{fixture["client"]}"',code)
        self.assertIn('request.setValue(desktopClient, forHTTPHeaderField: "X-Yandex-Music-Client")',code)
        self.assertIn('static let transport = "raw"',code)
        self.assertIn('"flac-mp4"',code)
    def test_modern_endpoint_keeps_authentication_and_logs_status_not_credentials(self):
        service=source('yandexmusicservice.swift')
        modern=service.split('private func getLosslessFileInfo',1)[1].split('func getStreamInfo',1)[0]
        self.assertIn('YandexStreamRequestContract.request',modern)
        self.assertIn('sessionData(for: request)',modern)
        self.assertIn('if original.url?.path == "/get-file-info" { return result }',service)
        self.assertIn('streamQualityLog.removeAll()',service)
        self.assertIn('HTTP=\\(http.statusCode)',modern)
        self.assertIn('info.transport == "raw"',modern)
        self.assertNotIn('try? await sessionData',modern)
        report=service.split('func streamQualityReport()',1)[1].split('private func getLosslessFileInfo',1)[0]
        for bad in ['token)', 'signature(', 'streamUrlString', 'activeStreamURL']:
            self.assertNotIn(bad,report)
        self.assertIn('Скопировать диагностику качества',source('PlayerScreenV2.swift'))
    def test_requested_lossless_does_not_silently_accept_lossy_cache(self):
        core=source('playercore.swift')
        policy=core.split('private func acceptsCachedPlayback',1)[1].split('/// Migrates',1)[0]
        self.assertIn('audioQuality == .lossless',policy)
        self.assertIn('LocalAudioQualityReader.read(file)',policy)
        self.assertIn('facts.isLossless',policy)
        self.assertIn('acceptsCachedPlayback(file, for: track)',policy)
        self.assertNotIn('removeItem',policy)
        self.assertIn('respectingQuality: false',core)
    @unittest.skipUnless(sys.platform=='darwin','CryptoKit request fixture executes on macOS')
    def test_actual_swift_request_signature_and_headers(self):
        f=json.loads((R/'docs/yandex-stream-signature-fixture.json').read_text())
        checks=f'''
        let request = YandexStreamRequestContract.request(base: "https://api.music.yandex.net", trackID: "{f['track_id']}", timestamp: {f['timestamp']}, quality: "{f['quality']}")!
        precondition(request.value(forHTTPHeaderField: "X-Yandex-Music-Client") == "{f['client']}")
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(items.first(where: {{ $0.name == "sign" }})?.value == "{f['signature']}")
        precondition(items.first(where: {{ $0.name == "transports" }})?.value == "raw")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        '''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'check.swift';p.write_text(source('YandexStreamRequestContract.swift')+'\n'+checks)
            subprocess.run(['swift',str(p)],check=True,capture_output=True,text=True,timeout=120)
if __name__=='__main__':unittest.main()
