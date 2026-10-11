"""Execute production curator transport/store/resolver using only fixture responses."""
from pathlib import Path
import subprocess
import tempfile

def verify_ai_curator(root):
    fixtures = r'''
import Foundation
import Combine
nonisolated struct Track: Codable, Sendable, Identifiable { var id = UUID(); var title: String; var artist: String; var coverURL: String? = nil }
@MainActor enum CuratorWebCredentialStore {
    static var token = ""
    static func read() -> String { token }
    static func write(_ value: String) throws { token = value }
}
@MainActor enum AICredentialStore {
    static var keys: [String:String] = [:]
    static func migrate(_ provider: AIProvider, legacyKey: String) {}
    static func read(_ provider: AIProvider) -> String { keys[provider.rawValue] ?? "" }
    static func write(_ key: String, provider: AIProvider) throws { keys[provider.rawValue] = key }
}
@MainActor final class UIPasteboard { static let general = UIPasteboard(); var string: String? }
@MainActor enum Haptics { enum Kind { case medium }; static func tap(_ kind: Kind) {} }
@MainActor enum SonivoDiagnostics { static func log(_ message: String, tag: String) {} }
@MainActor final class PlayerCore { static let shared = PlayerCore(); var currentTrack: Track? }
@MainActor final class PlaybackCommandRouter { static let shared = PlaybackCommandRouter(); func play(_ track: Track, queue: [Track]) {} }
@MainActor final class LibraryStore {
    struct Playlist { let id: UUID; let title: String; var tracks: [Track] }
    static let shared = LibraryStore(); var playlists: [Playlist] = []
    func playlist(byId id: UUID) -> Playlist? { playlists.first { $0.id == id } }
    func tracks(for playlist: Playlist) -> [Track] { playlist.tracks }
    func createPlaylist(title: String, coverURL: String?, initialTracks: [Track]) -> Playlist {
        let p = Playlist(id: UUID(), title: title, tracks: initialTracks); playlists.append(p); return p
    }
    func addTracksToPlaylist(tracks: [Track], playlistId: UUID) {
        if let i = playlists.firstIndex(where: { $0.id == playlistId }) { playlists[i].tracks += tracks }
    }
}
@MainActor final class YandexMusicService {
    struct User { let uid: Int }
    struct Artist: Sendable { let name: String? }
    struct Item: Sendable { let title: String; let artists: [Artist]?; let available: Bool? }
    struct Search { let tracks: [Item] }
    static let shared = YandexMusicService(); var accountGeneration = UUID(); var currentUser: User?
    var isUserLoggedIn: Bool { currentUser != nil }
    var searches = 0
    func searchAllFixed(query: String) async -> Search {
        searches += 1
        return Search(tracks: [Item(title:"Wrong Remix",artists:[Artist(name:"Wrong")],available:true),
                              Item(title:"Song",artists:[Artist(name:"Artist")],available:true)])
    }
    func convertToTrack(_ item: Item) -> Track {
        Track(id: UUID(uuidString:"00000000-0000-0000-0000-000000000001")!,title:item.title,artist:"Artist")
    }
}
nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state: (Int, String) = (200, "")
    nonisolated(unsafe) private static var seen: [URLRequest] = []
    nonisolated(unsafe) private static var queue: [(Int,String)] = []
    static func reply(_ code: Int, _ body: String) { lock.lock(); state = (code,body); queue = []; lock.unlock() }
    static func enqueue(_ code: Int, _ body: String) { lock.lock(); queue.append((code,body)); lock.unlock() }
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let (code,body) = Self.queue.isEmpty ? Self.state : Self.queue.removeFirst(); Self.seen.append(request); Self.lock.unlock()
        if code == -1 { return }
        let response = HTTPURLResponse(url:request.url!, statusCode:code, httpVersion:"HTTP/1.1", headerFields:["Content-Type":"text/event-stream"])!
        client?.urlProtocol(self, didReceive:response, cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self, didLoad:Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
'''
    checks = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        let ai = DifyService(session:session)
        try ai.configure(provider:.nvidia,key:"fixture-only-not-a-real-key",endpoint:"https://fixture.invalid/v1",model:"fixture-model")
        precondition(AICuratorPolicy.matches(artist:" ARTIST ",title:"SONG!",candidateArtist:"Artist",candidateTitle:"Song"))
        precondition(!AICuratorPolicy.matches(artist:"Artist",title:"Song",candidateArtist:"Artist",candidateTitle:"Song Remix"))
        for bad in ["http://fixture.invalid", "https://user:pass@fixture.invalid", "https://fixture.invalid?key=1"] {
            precondition(AICuratorPolicy.endpoint(base:bad,path:"chat") == nil)
        }
        precondition(AICuratorPolicy.context(title:"Song",artist:"Artist",enabled:false).isEmpty)
        let playlist = AIGeneratedPlaylist(playlistTitle:"Fixture",description:"Test",tracks:[AITrackSuggestion(artist:"Artist",title:"Song")])
        let content = "A recommendation.\n```json\n" + String(data:try JSONEncoder().encode(playlist),encoding:.utf8)! + "\n```"
        let chunk = try JSONSerialization.data(withJSONObject:["choices":[["delta":["content":content,"reasoning_content":"PRIVATE REASONING"]]]])
        StubProtocol.reply(200,"data: " + String(data:chunk,encoding:.utf8)! + "\n\ndata: [DONE]\n\n")
        let response = try await ai.sendMessage(query:"test",history:[.init(role:"user",content:"earlier")],onDelta:{ _ in })
        precondition(response.playlist?.tracks.count == 1 && !response.fullText.contains("PRIVATE REASONING"))
        let request = StubProtocol.requests.last!
        precondition(request.url!.absoluteString == "https://fixture.invalid/v1/chat/completions")
        // Guest resolution must not call any catalog endpoint.
        let generator = AIPlaylistGeneratorService.shared
        let guest = await generator.resolveTracks(for:playlist.tracks)
        precondition(guest.isEmpty && YandexMusicService.shared.searches == 0)
        YandexMusicService.shared.currentUser = .init(uid:991)
        let tracks = await generator.resolveTracks(for:playlist.tracks)
        precondition(tracks.count == 1 && tracks[0].title == "Song")
        let store = AIMusicCuratorStore(ai:ai)
        store.clearChat()
        precondition(store.send("test",shareCurrentTrack:false))
        for _ in 0..<100 where store.isBusy { try await Task.sleep(for:.milliseconds(10)) }
        precondition(!store.isBusy && store.messages.last?.resolvedTracks.count == 1)
        let id = store.messages.last!.id
        store.save(id); store.save(id)
        precondition(LibraryStore.shared.playlists.count == 1 && store.messages.last!.savedPlaylistID != nil)
        let savedID = store.messages.last!.savedPlaylistID!
        precondition(LibraryStore.shared.playlist(byId:savedID)!.tracks.count == 1)
        UIPasteboard.general.string = "keep me"
        store.showToast("Notice")
        precondition(UIPasteboard.general.string == "keep me")
        // A clear/cancel while transport is suspended cannot mutate a stale message index.
        StubProtocol.reply(-1, "")
        precondition(store.send("waiting",shareCurrentTrack:false))
        try await Task.sleep(for:.milliseconds(20)); store.clearChat()
        try await Task.sleep(for:.milliseconds(20))
        precondition(store.messages.isEmpty && !store.isBusy)
        YandexMusicService.shared.currentUser = .init(uid:992)
        YandexMusicService.shared.accountGeneration = UUID(); store.switchAccount()
        precondition(store.messages.isEmpty)
        store.clearChat()
        // Errors are surfaced, not retried against another model.
        StubProtocol.reply(401,"data: {}\n\n")
        let before = StubProtocol.requests.count
        do { _ = try await ai.sendMessage(query:"bad",onDelta:{ _ in }); fatalError("Accepted 401") }
        catch DifyError.unauthorized { }
        precondition(StubProtocol.requests.count == before + 1)
        try ai.configure(provider:.dify,key:"fixture-only-not-a-real-key",endpoint:"https://fixture.invalid/v1",model:"")
        StubProtocol.reply(200,"data: {\"event\":\"error\",\"code\":\"fixture\"}\n\n")
        do { _ = try await ai.sendMessage(query:"error",onDelta:{ _ in }); fatalError("Accepted Dify error event") }
        catch DifyError.invalidResponse { }
        StubProtocol.reply(200,"data: {\"event\":\"message\",\"answer\":\"OK\",\"conversation_id\":\"fixture-conversation\"}\n\n")
        _ = try await ai.sendMessage(query:"chat",onDelta:{ _ in })
        precondition(ai.currentConversationId == "fixture-conversation")
        _ = try await ai.sendMessage(query:"video",channel:.video,onDelta:{ _ in })
        precondition(ai.currentConversationId == "fixture-conversation")

        // Structured intent must never turn a clarification/conversation into a playlist.
        let playlistJSON = String(data:try JSONEncoder().encode(playlist),encoding:.utf8)!
        let clarification = "```json\n{\"intent\":\"clarify\",\"summary\":\"Не хватает настроения\",\"question\":\"Спокойно или энергично?\",\"playlist\":" + playlistJSON + "}\n```"
        precondition(AICuratorPrompt.reply(from:clarification)?.intent == .clarify)
        precondition(DifyService.extractPlaylist(from:clarification) == nil)
        let structured = "```json\n{\"intent\":\"playlist\",\"summary\":\"Спокойно и без вокала\",\"question\":null,\"playlist\":" + playlistJSON + "}\n```"
        precondition(DifyService.extractPlaylist(from:structured)?.tracks.count == 1)
        let conversation = "{\"intent\":\"conversation\",\"summary\":\"Обсуждаем артиста\",\"question\":null,\"playlist\":null}"
        precondition(AICuratorPrompt.reply(from:conversation)?.intent == .conversation)
        precondition(DifyService.cleanDisplayText(from:conversation).isEmpty)
        precondition(DifyService.extractPlaylist(from:conversation) == nil)
        precondition(AICuratorPrompt.system(.curator).contains("ОДИН короткий вопрос"))
        precondition(AICuratorPrompt.system(.curator).contains("не создавай плейлист"))
        // Live catalog, duplicate IDs, non-chat exclusions, preserve existing model, staged commit.
        let catalog = "{\"data\":[{\"id\":\"vendor/llama-instruct\"},{\"id\":\"vendor/llama-instruct\"},{\"id\":\"vendor/qwen-embed\"},{\"id\":\"vendor/tts\"},{\"id\":\"vendor/qwen-chat\"}]}"
        let decoded = try AIModelDiscovery.decode(Data(catalog.utf8))
        precondition(decoded.count == 4)
        precondition(AIModelDiscovery.recommended(in:decoded,preserving:"vendor/qwen-chat") == "vendor/qwen-chat")
        precondition(AIModelDiscovery.recommended(in:decoded,preserving:"") == "vendor/llama-instruct")
        StubProtocol.reply(200, catalog)
        let models = try await ai.discoverModels(key:"fixture-only-not-a-real-key",endpoint:"https://fixture.invalid/v1")
        precondition(models == decoded && StubProtocol.requests.last!.url!.path == "/v1/models")
        try ai.configure(provider:.nvidia,key:"old-fixture-key",endpoint:"https://fixture.invalid/v1",model:"old-fixture-model")
        StubProtocol.enqueue(200, catalog)
        StubProtocol.enqueue(200, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"OK\"}}]}")
        let chosen = try await ai.connect(provider:.nvidia,key:"new-fixture-key",endpoint:"https://fixture.invalid/v1",model:nil)
        precondition(chosen == "vendor/llama-instruct" && ai.nvidiaApiKey == "new-fixture-key")
        StubProtocol.enqueue(200, catalog)
        StubProtocol.enqueue(401, "{}")
        do { _ = try await ai.connect(provider:.nvidia,key:"rejected-fixture-key",endpoint:"https://fixture.invalid/v1",model:nil); fatalError("Accepted rejected setup") }
        catch DifyError.unauthorized { }
        precondition(ai.nvidiaApiKey == "new-fixture-key" && ai.nvidiaSelectedModel == chosen)
        // Dify takes its server-side model, and performs no /models request.
        StubProtocol.reply(200, "{\"answer\":\"OK\",\"conversation_id\":\"health-only\"}")
        let requestsBeforeDify = StubProtocol.requests.count
        let difyModel = try await ai.connect(provider:.dify,key:"dify-fixture-key",endpoint:"https://fixture.invalid/v1",model:nil)
        precondition(difyModel.isEmpty && StubProtocol.requests.count == requestsBeforeDify + 1)
        precondition(ai.currentConversationId == nil)
        print("Curator auto setup: live catalog, non-chat exclusions, preserve model, staged commit, rejected key preservation and Dify server model passed")
        print("Curator intent: playlist/clarify/conversation envelope and constraint-priority prompt checks passed")


        // Actual web transport/store integration; no real keys, servers or web requests.
        let suiteName = "curator-web-fixture-" + UUID().uuidString
        let webDefaults = UserDefaults(suiteName:suiteName)!
        defer { webDefaults.removePersistentDomain(forName:suiteName) }
        let web = CuratorWebSearch(session:session,defaults:webDefaults)
        precondition(!web.enabled && !web.isConfigured)
        for invalid in ["http://proxy.example.com/search","https://user:pass@proxy.example.com/search",
                        "https://proxy.example.com/search?token=x","https://api.firecrawl.dev/v2/search"] {
            precondition(CuratorWebSearch.validEndpoint(invalid) == nil)
        }
        try web.configure(endpoint:"https://proxy.example.com/search",token:"proxy-fixture-not-real")
        web.enabled = true
        let sourceJSON = "{\"sources\":[{\"title\":\"Release\",\"url\":\"https://music.example.com/release\",\"excerpt\":\"Artist — Song\"},{\"title\":\"Private\",\"url\":\"https://127.0.0.1/private\",\"excerpt\":\"bad\"}]}"
        StubProtocol.reply(200,sourceJSON)
        let found = try await web.search("jazz")
        precondition(found.sources.count == 1 && found.promptContext.contains("недоверенные данные"))
        let webRequest = StubProtocol.requests.last!
        precondition(webRequest.value(forHTTPHeaderField:"Authorization") == "Bearer proxy-fixture-not-real")
        let webBody = try JSONSerialization.jsonObject(with:webRequest.httpBody!) as! [String:Any]
        precondition(Set(webBody.keys) == ["query"] && webBody["query"] as? String == "jazz")
        StubProtocol.reply(429,"{\"error\":\"quota\"}")
        do { _ = try await web.search("q"); fatalError("Web quota ignored") } catch CuratorWebError.limit { }
        StubProtocol.reply(403,"secret upstream error")
        do { _ = try await web.search("q"); fatalError("Web rejected auth ignored") } catch CuratorWebError.unauthorized { }
        StubProtocol.reply(200,String(repeating:"x",count:64_001))
        do { _ = try await web.search("q"); fatalError("Oversized web accepted") } catch CuratorWebError.invalidResponse { }
        try ai.configure(provider:.nvidia,key:"fixture-only-not-real",endpoint:"https://fixture.invalid/v1",model:"fixture-model")
        let webStore = AIMusicCuratorStore(ai:ai,web:web)
        webStore.clearChat()
        let chatChunk = try JSONSerialization.data(withJSONObject:["choices":[["delta":["content":"Found a recommendation [1].\n```json\n" + String(data:try JSONEncoder().encode(playlist),encoding:.utf8)! + "\n```"]]]])
        let chatSSE = "data: " + String(data:chatChunk,encoding:.utf8)! + "\n\ndata: [DONE]\n\n"
        StubProtocol.enqueue(200,sourceJSON); StubProtocol.enqueue(200,chatSSE)
        precondition(webStore.send("Подбери джаз",shareCurrentTrack:false))
        for _ in 0..<500 { if !webStore.isBusy { break }; try await Task.sleep(for:.milliseconds(10)) }
        precondition(!webStore.isBusy && webStore.messages.last?.webSources?.count == 1)
        precondition(webStore.messages.last?.resolvedTracks.count == 1 && webStore.messages.last?.webFetchedAt != nil)
        let aiWebRequest = StubProtocol.requests.last { $0.url!.path.contains("chat/completions") }!
        let aiWebBody = try JSONSerialization.jsonObject(with:aiWebRequest.httpBody!) as! [String:Any]
        let aiWebMessages = aiWebBody["messages"] as! [[String:Any]]
        precondition((aiWebMessages.last!["content"] as! String).contains("https://music.example.com/release"))
        StubProtocol.enqueue(429,"{}"); StubProtocol.enqueue(200,chatSSE)
        precondition(webStore.send("Ещё джаз",shareCurrentTrack:false))
        for _ in 0..<500 { if !webStore.isBusy { break }; try await Task.sleep(for:.milliseconds(10)) }
        precondition(webStore.messages.last?.error == nil && webStore.messages.last?.webNotice?.contains("без свежих") == true)
        precondition(webStore.messages.last?.webSources == nil)
        // Extensions must not rewrite source numbering for the original answer.
        let originalSources = webStore.messages[1].webSources!
        StubProtocol.enqueue(200,sourceJSON); StubProtocol.enqueue(200,chatSSE)
        webStore.extend(webStore.messages[1].id)
        for _ in 0..<500 { if !webStore.isBusy { break }; try await Task.sleep(for:.milliseconds(10)) }
        precondition(webStore.messages[1].webSources?.first?.url == originalSources.first?.url)
        precondition(webStore.messages[1].extensionWebSources?.count == 1)
        let archived = try JSONEncoder().encode(webStore.messages)
        let reloaded = try JSONDecoder().decode([AIMessage].self,from:archived)
        precondition(reloaded.contains { $0.webSources?.count == 1 })
        let oldArchive = try JSONSerialization.data(withJSONObject:[["id":UUID().uuidString,"role":"assistant","text":"Old reply",
            "timestamp":0,"resolvedTracks":[],"isStreaming":false,"isResolvingTracks":false]])
        let oldDecoded = try JSONDecoder().decode([AIMessage].self,from:oldArchive)
        precondition(oldDecoded[0].webSources == nil && oldDecoded[0].extensionWebSources == nil)
        StubProtocol.reply(-1,"")
        precondition(webStore.send("Cancel web",shareCurrentTrack:false))
        try await Task.sleep(for:.milliseconds(30)); webStore.clearChat()
        try await Task.sleep(for:.milliseconds(30)); precondition(webStore.messages.isEmpty && !webStore.isBusy)
        web.enabled = false
        StubProtocol.reply(200,chatSSE)
        let requestsBeforeDisabled = StubProtocol.requests.count
        precondition(webStore.send("Without web",shareCurrentTrack:false))
        for _ in 0..<500 { if !webStore.isBusy { break }; try await Task.sleep(for:.milliseconds(10)) }
        precondition(StubProtocol.requests.count == requestsBeforeDisabled + 1)
        webStore.clearChat(); try web.removeCredential()
        print("Curator web: opt-in, safe source URLs, bounded transport, auth/quota, AI source context, exact catalog resolution, honest fallback, archive migration, cancellation and disabled zero-web-network passed")

        print("Curator: transport errors, exact matching, guest gating, cancellation/clear, account scope, save ID, clipboard and isolated channels passed")
    }
}
'''
    with tempfile.TemporaryDirectory() as directory:
        p = Path(directory)
        (p/'Fixtures.swift').write_text(fixtures)
        (p/'Checks.swift').write_text(checks)
        (p/'Store.swift').write_text((root/'Sonivo/Dify/AIMusicCuratorStore.swift').read_text().replace('import UIKit', ''))
        files = [root/'Sonivo/Dify'/name for name in ['CuratorWebSearch.swift','AICuratorPolicy.swift','DifyModels.swift','AICuratorPrompt.swift','AIModelDiscovery.swift','DifyService.swift','AIPlaylistGeneratorService.swift']]
        built = subprocess.run(['swiftc','-swift-version','6',*map(str,files),str(p/'Store.swift'),str(p/'Fixtures.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert built.returncode == 0, built.stderr
        ran = subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=60)
        assert ran.returncode == 0, ran.stdout + ran.stderr
        print(ran.stdout.strip())
