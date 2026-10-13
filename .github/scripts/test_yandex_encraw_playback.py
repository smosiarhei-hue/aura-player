from pathlib import Path
import base64, json, subprocess, sys, tempfile, unittest
ROOT=Path(__file__).resolve().parents[2]
def source(name): return (ROOT/'Sonivo'/name).read_text()
class YandexEncrawPlaybackTests(unittest.TestCase):
    def test_transport_is_signed_and_encoded_as_part_of_contract(self):
        code=source('YandexStreamRequestContract.swift')
        self.assertIn('["raw", "encraw"].contains(transport)',code)
        self.assertIn('codecs: codecs, transport: transport',code)
        self.assertIn('components.percentEncodedQuery?.replacingOccurrences',code)
    def test_only_actual_flac_encraw_is_materialized(self):
        s=source('yandexmusicservice.swift')
        b=s.split('private func getLosslessFileInfo',1)[1].split('func getStreamInfo',1)[0]
        self.assertIn('["flac", "flac-mp4"].contains(codec.lowercased())',b)
        self.assertIn('let key = info.key',b)
        self.assertIn('losslessAssets.materialize',b)
        self.assertIn('accountGeneration == generation',b)
        self.assertIn('transport == "encraw" ? ["flac", "flac-mp4"]',b)
        self.assertIn('info.quality',b)
        self.assertNotIn('print(',b)
    def test_decode_is_chunked_bounded_and_never_persists_keys(self):
        c=source('YandexEncrawDecryptor.swift');a=source('YandexLosslessAssetStore.swift')
        for t in ['kCCModeCTR','kCCModeOptionCTR_BE','CCOperation(kCCDecrypt)','Data(repeating: 0','65_537','CCCryptorRelease','Task.checkCancellation()']: self.assertIn(t,c)
        for t in ['maximumFileBytes','capacityBytes','downloads >= 2','http.url?.scheme == "https"','validateDecodedAudio','protected.union([decoded])','account.uuidString','removeStaleTemporaryDirectories']: self.assertIn(t,a)
        for t in ['Authorization','UserDefaults','SonivoDiagnostics','print(']:self.assertNotIn(t,a+c)
    def test_native_and_offline_paths_preserve_container(self):
        for name in ['librarystore.swift','playercore.swift']:
            self.assertIn('isFileURL',source(name))
        self.assertIn('\\(fileExtension)',source('librarystore.swift'))
        self.assertIn('YandexLosslessAssetStore.temporaryDirectories',source('MediaCacheManager.swift'))
        self.assertIn('protectedPlaybackURLs',source('playercore.swift'))
        self.assertIn('isPreferred(',source('yandexmusicservice.swift'))
    @unittest.skipUnless(sys.platform=='darwin','CommonCrypto/AVFoundation fixtures run on macOS CI')
    def test_real_swift_decrypt_native_flac_and_cache_isolation(self):
        fixture=json.loads((ROOT/'docs/yandex-encraw-test-fixture.json').read_text())
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'fixture.enc').write_bytes(base64.b64decode(fixture['encraw_base64']));(root/'fixture.flac').write_bytes(base64.b64decode(fixture['plain_base64']))
            (root/'long.plain').write_bytes(bytes(range(256))*1025+b'partial block')
            subprocess.run(['openssl','enc','-aes-128-ctr','-K',fixture['public_test_key_hex'],'-iv',fixture['zero_counter_hex'],'-nosalt','-in',str(root/'long.plain'),'-out',str(root/'long.enc')],check=True,capture_output=True)
            checks=r'''
import Foundation
import AVFoundation
actor FixtureDownload {
    let file: URL; var count = 0
    init(_ file: URL) { self.file = file }
    func download(_ url: URL) throws -> (URL, URLResponse) {
        count += 1
        let temporary = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: file, to: temporary)
        return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
@main struct Checks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let key = "000102030405060708090a0b0c0d0e0f"
        for invalid in ["", "00", String(repeating: "g", count: 32), String(repeating: "0", count: 64)] {
            do { _ = try YandexEncrawDecryptor.keyBytes(invalid); preconditionFailure("invalid key accepted") }
            catch YandexEncrawDecryptor.Failure.invalidKey {}
        }
        let bytes = try YandexEncrawDecryptor.keyBytes(key)
        precondition(bytes == Data((0..<16).map { UInt8($0) }))
        for stem in ["fixture", "long"] {
            let result = root.appendingPathComponent(stem + ".decoded")
            try YandexEncrawDecryptor.decryptFile(root.appendingPathComponent(stem + ".enc"), to: result, keyHex: key)
            let expected = try Data(contentsOf: root.appendingPathComponent(stem == "fixture" ? "fixture.flac" : "long.plain"))
            let actual = try Data(contentsOf: result)
            precondition(actual == expected, "AES zero-counter / cross-chunk mismatch")
        }
        let sparse = root.appendingPathComponent("oversize.enc")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(YandexEncrawDecryptor.maximumFileBytes + 1)); try handle.close()
        do { try YandexEncrawDecryptor.decryptFile(sparse, to: root.appendingPathComponent("reject"), keyHex: key); preconditionFailure("oversize accepted") }
        catch YandexEncrawDecryptor.Failure.invalidSize {}
        let flac = root.appendingPathComponent("fixture.flac")
        try await YandexLosslessAssetStore.validateDecodedAudio(flac, codec: "flac")
        let native = try AVAudioFile(forReading: flac)
        precondition(native.length > 0 && native.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatFLAC)
        let pcm = AVAudioPCMBuffer(pcmFormat: native.processingFormat, frameCapacity: 128)!
        try native.read(into: pcm, frameCount: 128); precondition(pcm.frameLength == 128)
        let engine = AVAudioEngine(); let node = AVAudioPlayerNode()
        engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: pcm.format)
        try engine.enableManualRenderingMode(.offline, format: pcm.format, maximumFrameCount: 128)
        try engine.start(); node.scheduleBuffer(pcm, completionHandler: nil); node.play()
        let rendered = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: 128)!
        let renderStatus = try engine.renderOffline(128, to: rendered)
        precondition(renderStatus == .success && rendered.frameLength == 128)
        engine.stop(); node.stop()
        let mp3 = PlaybackQualityFacts(codec: "mp3", bitrate: 192)
        let aac = PlaybackQualityFacts(codec: "aac-mp4", bitrate: 192)
        let lossless = PlaybackQualityFacts(codec: "flac-mp4", bitrate: 0)
        precondition(aac.isPreferred(over: mp3) && !mp3.isPreferred(over: aac))
        precondition(lossless.isPreferred(over: PlaybackQualityFacts(codec: "mp3", bitrate: 320)))
        let backend = FixtureDownload(root.appendingPathComponent("fixture.enc"))
        let store = YandexLosslessAssetStore(directory: root.appendingPathComponent("decoded-cache"), downloadOverride: { try await backend.download($0) })
        let url = URL(string: "https://catalog.test/authorized-encraw")!; let account = UUID()
        let one = try await store.materialize(url: url, keyHex: key, codec: "flac", trackID: "1", account: account, protectedURLs: { [] })
        let two = try await store.materialize(url: url, keyHex: key, codec: "flac", trackID: "1", account: account, protectedURLs: { [one] })
        let calls = await backend.count; precondition(one == two && calls == 1)
        let other = try await store.materialize(url: url, keyHex: key, codec: "flac", trackID: "1", account: UUID(), protectedURLs: { [one] })
        precondition(one != other)
        do { _ = try await store.materialize(url: url, keyHex: String(repeating: "f", count: 32), codec: "flac", trackID: "wrong-key", account: account, protectedURLs: { [one] }); preconditionFailure("wrong-key media accepted") } catch {}
        do { _ = try await store.materialize(url: URL(string: "http://catalog.test/encraw")!, keyHex: key, codec: "flac", trackID: "1", account: account, protectedURLs: { [] }); preconditionFailure("http accepted") }
        catch YandexLosslessAssetStore.Failure.invalidURL {}
        do { _ = try await store.materialize(url: url, keyHex: key, codec: "mp3", trackID: "1", account: account, protectedURLs: { [] }); preconditionFailure("encrypted lossy accepted") }
        catch YandexLosslessAssetStore.Failure.invalidAudio {}
        let cancelled = Task { try await store.materialize(url: url, keyHex: key, codec: "flac", trackID: "cancelled", account: account, protectedURLs: { [] }) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancelled decode accepted") } catch is CancellationError {}
        print("encraw AES / native FLAC / source selection / account-scoped cache fixtures passed")
    }
}
'''
            (root/'Checks.swift').write_text(checks)
            cmd=['swiftc','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete','-parse-as-library',str(ROOT/'Sonivo/YandexEncrawDecryptor.swift'),str(ROOT/'Sonivo/YandexLosslessAssetStore.swift'),str(ROOT/'Sonivo/PlaybackQualityFacts.swift'),str(root/'Checks.swift'),'-o',str(root/'checks')]
            compiled=subprocess.run(cmd,capture_output=True,text=True,timeout=120)
            self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
            result=subprocess.run([str(root/'checks'),str(root)],capture_output=True,text=True,timeout=120)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__':unittest.main()
