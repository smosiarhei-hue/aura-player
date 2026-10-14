from pathlib import Path
import sys, subprocess, tempfile, unittest
ROOT = Path(__file__).resolve().parents[2]
class SpotifyCatalogTests(unittest.TestCase):
    def test_catalog_does_not_own_playback_or_credentials(self):
        model=(ROOT/'Sonivo/MusicCatalogSource.swift').read_text()
        view=(ROOT/'Sonivo/SpotifyCatalogSearchView.swift').read_text()
        for forbidden in ['PlayerCore','PlaybackCommandRouter','YandexMusicService','AVPlayer','/api/token','Authorization','Keychain','SonivoPlay.']:
            self.assertNotIn(forbidden,model+view)
        for expected in ['URLSessionConfiguration.ephemeral','httpShouldSetCookies = false','httpCookieStorage = nil','timeoutInterval: 12','try Task.checkCancellation()','statusCode == 429','emptyOnNotFound: true','seen.insert($0.id).inserted']:
            self.assertIn(expected,model)
        self.assertIn('.task(id: SearchRequest(query: query, retry: retry))',view)
        self.assertIn('guard !Task.isCancelled else { return }',view)
        self.assertIn('Полное воспроизведение Spotify внутри Sonivo этим API не поддерживается',view)
    def test_default_and_existing_yandex_local_routes_are_preserved(self):
        model=(ROOT/'Sonivo/MusicCatalogSource.swift').read_text()
        root=(ROOT/'Sonivo/sonivoapp.swift').read_text()
        settings=(ROOT/'Sonivo/settingsview.swift').read_text()
        self.assertIn('Self(rawValue: raw) ?? .yandex',model)
        self.assertIn('MusicCatalogSource.resolve(catalogSourceRaw) == .spotifyCatalog',root)
        self.assertIn('if ym.isUserLoggedIn { SearchCatalogView(isActive: tab == .search) } else { SonivoLocalSearchView(isActive: tab == .search) }',root)
        self.assertIn('Picker("Источник поиска", selection: $catalogSourceRaw)',settings)
        self.assertIn('MusicCatalogSource.yandex.rawValue',settings)
    @unittest.skipUnless(sys.platform=='darwin','Executable Foundation client fixture requires macOS Swift')
    def test_production_decode_requests_status_and_url_boundaries(self):
        fixture=r'''
import Foundation
nonisolated final class MockProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.count += 1
        precondition(request.url!.host == "spotify.xwolf.space")
        precondition(request.value(forHTTPHeaderField:"Authorization") == nil)
        precondition(request.value(forHTTPHeaderField:"Cookie") == nil)
        if request.url!.path == "/api/search" {
            let q = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
            precondition(q.first(where:{$0.name == "type"})!.value == "track")
            precondition(q.first(where:{$0.name == "limit"})!.value == "20")
            precondition(q.first(where:{$0.name == "q"})!.value!.count <= 150)
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:Self.status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct Checks {
    static func main() async throws {
        precondition(MusicCatalogSource.resolve("unknown") == .yandex)
        let config=URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies=false;config.httpCookieStorage=nil;config.protocolClasses=[MockProtocol.self]
        let session=URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        let service=WolfSpotifyCatalogClient(session:session)
        let item=#"{"id":"3n3Ppam7vgaVa1iaRUIOKE","title":"Song","artist":"Artist","thumbnail":"https://i.scdn.co/art.jpg","preview_url":"https://p.scdn.co/test.mp3"}"#
        MockProtocol.body=Data((#"{"success":true,"results":["#+item+","+item+"]}").utf8)
        let tracks=try await service.search("  test + & музыка  ")
        precondition(tracks.count == 1 && tracks[0].spotifyURL != nil)
        precondition(tracks[0].previewURL != nil && tracks[0].artworkURLString != nil)
        let before=MockProtocol.count
        let empty=try await service.search(" \n ")
        precondition(empty.isEmpty && MockProtocol.count == before)
        MockProtocol.body=Data((#"{"success":true,"track":"#+item+"}").utf8)
        let detail=try await service.detail(tracks[0]);precondition(detail.id == tracks[0].id)
        for (status,limited) in [(503,false),(429,true)] {
            MockProtocol.status=status
            do { _=try await service.search("test");preconditionFailure("HTTP error accepted") }
            catch let error as SpotifyCatalogError {
                switch error { case .limited:precondition(limited);case .unavailable:precondition(!limited);default:preconditionFailure("Wrong HTTP mapping") }
            }
        }
        MockProtocol.status=404
        let notFound=try await service.search("missing");precondition(notFound.isEmpty)
        MockProtocol.status=200;MockProtocol.body=Data(#"{"success":false}"#.utf8)
        do { _=try await service.search("test");preconditionFailure("API failure accepted") } catch is SpotifyCatalogError {}
        for url in ["https://evil.example/audio.mp3","http://p.scdn.co/audio.mp3","https://p.scdn.co.evil.example/a","https://user:password@p.scdn.co/a"] {
            let data=Data((#"{"id":"3n3Ppam7vgaVa1iaRUIOKE","title":"S","artist":"A","preview_url":""#+url+#""}"#).utf8)
            let bad=try JSONDecoder().decode(SpotifyCatalogTrack.self,from:data)
            precondition(bad.previewURL == nil)
        }
        let invalid=try JSONDecoder().decode(SpotifyCatalogTrack.self,from:Data(#"{"id":"../evil","title":"S","artist":"A"}"#.utf8))
        precondition(invalid.spotifyURL == nil)
        print("Catalog: isolated requests, decoding, deduplication, HTTP failures, safe links and default provider passed")
    }
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp); (p/'Checks.swift').write_text(fixture)
            build=subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete','-parse-as-library',str(ROOT/'Sonivo/MusicCatalogSource.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True,timeout=120)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
if __name__=='__main__':unittest.main()
