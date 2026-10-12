"""Execute the production session client and production next-track selector with a stub transport."""
from pathlib import Path
import subprocess
import tempfile

def verify_yandex_track_station(root):
    core = (root/'Sonivo/playercore.swift').read_text()
    selector = core[core.index('    private func peekNext(auto: Bool)'):core.index('    private func liveProgress()')].replace('private func peekNext', 'func peekNext')
    fixture = r'''
import Foundation
nonisolated struct Item: Decodable, Sendable { let id: String; let available: Bool? }
@MainActor final class Transport {
    var responses: [(String, Int)] = []
    var requests: [URLRequest] = []
    var hook: (() async -> Void)?
    var failFeedback = false
    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        if path.contains("feedback") {
            if failFeedback { throw URLError(.notConnectedToInternet) }
            return response(request, "{\"result\":{}}", 200)
        }
        if path == "/rotor/wave/settings" {
            let options: [String: Any] = ["result": ["settingRestrictions": [
                "diversity": ["possibleValues": [["value":"default", "serializedSeed":"settingDiversity:default"], ["value":"discover", "serializedSeed":"settingDiversity:discover"]]],
                "language": ["possibleValues": [["value":"any", "unspecified":true]]],
                "moodEnergy": ["possibleValues": [["value":"all", "unspecified":true]]]]]]
            return (try JSONSerialization.data(withJSONObject: options), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        guard !responses.isEmpty else { throw URLError(.notConnectedToInternet) }
        let first = responses.removeFirst()
        let callback = hook; hook = nil
        if let callback { await callback() }
        return response(request, first.0, first.1)
    }
    func response(_ request: URLRequest, _ body: String, _ status: Int) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
    }
}
nonisolated struct Track: Equatable { let id: Int; var fileName: String { "ym_\(id)" } }
nonisolated enum RepeatMode { case off, all, one }
@MainActor final class YandexMusicService {
    static let shared = YandexMusicService()
    var activeStationId: String?
    var isUserLoggedIn = true
    static func ymId(fromFileName: String) -> String? { fromFileName.hasPrefix("ym_") ? String(fromFileName.dropFirst(3)) : nil }
}
@MainActor final class Selector {
    var queue = [Track(id:1),Track(id:2),Track(id:3),Track(id:4),Track(id:5)]
    var currentTrack: Track? = Track(id:5)
    var shuffle = false
    var repeatMode: RepeatMode = .off
    func effectiveQueue() -> [Track] { queue }
    SELECTOR
}
@main struct Checks {
    @MainActor static func main() async throws {
        func batch(_ session: String? = nil, _ batch: String, _ ids: [String]) -> (String, Int) {
            var body: [String:Any] = ["batchId":batch,"sequence":ids.map { ["track":["id":$0,"available":true]] }]
            if let session { body["radioSessionId"] = session }
            return (String(data:try! JSONSerialization.data(withJSONObject:["result":body]),encoding:.utf8)!,200)
        }
        func body(_ request: URLRequest) -> [String:Any] { try! JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any] }
        let settings = ["diversity":"default","language":"any","moodEnergy":"all"]
        let transport = Transport()
        let client = YandexWaveSession<Item>(send: { try await transport.send($0) }, identity: { $0.id }, playable: { $0.available != false })
        transport.responses = [batch("session-A","batch-A",["1","3","2","3"]),batch(nil,"batch-B",["2","4","5"]),batch(nil,"batch-C",["1","2","3","4","5"])]
        let first = try await client.start(station:"track:1",settings:settings,history:["1"],seedTrack:"1")
        precondition(first.map(\.id) == ["3","2"])
        let startRequest = transport.requests.first { $0.url!.path == "/rotor/session/new" }!
        precondition(startRequest.httpMethod == "POST")
        precondition(body(startRequest)["queue"] as! [String] == ["1"])
        precondition(body(startRequest)["seeds"] as! [String] == ["track:1","settingDiversity:default"])
        let more = try await client.next(excluding:["1","3","2"])
        precondition(more.map(\.id) == ["4","5"])
        precondition(client.serverID == "session-A")
        let refill = transport.requests.last { $0.url!.path.hasSuffix("/tracks") }!
        precondition(refill.url!.path == "/rotor/session/session-A/tracks")
        precondition(body(refill)["queue"] as! [String] == ["1","3","2"])
        let duplicate = try await client.next(excluding:["1","2","3","4","5"])
        precondition(duplicate.isEmpty)
        precondition(transport.requests.filter { $0.url!.path == "/rotor/session/new" }.count == 1)
        client.event(type:"trackStarted",trackID:"3")
        await client.flushFeedback()
        // A new batch must not change the old track's feedback context.
        client.event(type:"skip",trackID:"3",seconds:7.25)
        await client.flushFeedback()
        let skip = transport.requests.last { (body($0)["event"] as? [String:Any])?["type"] as? String == "skip" }!
        precondition(body(skip)["batchId"] as? String == "batch-A")
        precondition((body(skip)["event"] as! [String:Any])["totalPlayedSeconds"] as? Double == 7.25)
        // Failed starts leave the previous session intact.
        transport.responses = [("{}",403)]
        do { _ = try await client.start(station:"genre:rock",settings:settings,history:[]); preconditionFailure("403 accepted") } catch {}
        precondition(client.serverID == "session-A")
        transport.responses = [batch("stale","bad",["9"])]
        do { _ = try await client.start(station:"genre:rock",settings:settings,history:[],canCommit:{false}); preconditionFailure("Stale playback accepted") } catch {}
        precondition(client.serverID == "session-A")
        var unsupported = settings; unsupported["language"] = "without-words"
        do { _ = try await client.start(station:"user:onyourwave",settings:unsupported,history:[]); preconditionFailure("Invented setting accepted") } catch {}
        // Offline feedback remains in the outbox and keeps its original party.
        transport.failFeedback = true
        client.event(type:"trackStarted",trackID:"4")
        await client.flushFeedback()
        let before = transport.requests.count
        transport.failFeedback = false
        await client.flushFeedback()
        precondition(transport.requests.count > before)
        // A reset during a response invalidates it (logout/changed account).
        transport.responses = [batch(nil,"old",["8"])]
        transport.hook = { client.reset() }
        do { _ = try await client.next(excluding:["1","2","3","4","5"]); preconditionFailure("Stale refill accepted") } catch {}
        precondition(client.serverID == nil)
        transport.responses = [batch("new","b",["6"])]
        _ = try await client.start(station:"user:onyourwave",settings:settings,history:[])
        transport.responses = [("{\"result\":{\"unknownSession\":true}}",200)]
        do { _ = try await client.next(excluding:["6"]); preconditionFailure("Unknown session accepted") } catch {}
        let count = transport.requests.count
        let empty = try await client.next()
        precondition(empty.isEmpty && transport.requests.count == count)
        precondition(client.requiresRestart)
        transport.responses = [batch("renewed","renewed-batch",["6","7","8"])]
        let renewed = try await client.start(station:"user:onyourwave",settings:settings,history:["6"])
        precondition(renewed.map(\.id) == ["7","8"] && !client.requiresRestart)
        // Buffer is redelivered until the app acknowledges it, without a second HTTP fetch.
        let beforeBuffer = transport.requests.count
        let tracksBeforeBuffer = transport.requests.filter { $0.url!.path.hasSuffix("/tracks") }.count
        let buffered = try await client.next(excluding:["6"])
        precondition(buffered.map(\.id) == ["7","8"])
        precondition(transport.requests.filter { $0.url!.path.hasSuffix("/tracks") }.count == tracksBeforeBuffer)
        client.event(type:"trackStarted",trackID:"7")
        client.event(type:"trackFinished",trackID:"7",seconds:2)
        client.close()
        await client.flushFeedback()
        precondition(client.serverID == nil)
        precondition(transport.requests.count > beforeBuffer)
        let cancelled = Task { @MainActor in try await client.start(station:"track:7",settings:settings,history:[]) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled startup accepted") } catch {}
        // Actual production selector: five songs never wrap in radio, even with global shuffle/repeat.
        let selector = Selector()
        YandexMusicService.shared.activeStationId = "user:onyourwave"
        for mode in [RepeatMode.off, .all, .one] {
            selector.repeatMode = mode
            for shuffle in [false,true] {
                selector.shuffle = shuffle
                precondition(selector.peekNext(auto:false) == nil)
                precondition(selector.peekNext(auto:true) == nil)
                selector.currentTrack = Track(id:3)
                precondition(selector.peekNext(auto:true)?.id == 4)
                selector.currentTrack = Track(id:5)
            }
        }
        YandexMusicService.shared.activeStationId = nil
        selector.shuffle = false; selector.repeatMode = .off
        precondition(selector.peekNext(auto:false) == nil) // signed-in catalog playlist requests continuation
        YandexMusicService.shared.isUserLoggedIn = false
        precondition(selector.peekNext(auto:false)?.id == 1) // local/guest manual wrap remains
        YandexMusicService.shared.isUserLoggedIn = true
        selector.repeatMode = .all
        precondition(selector.peekNext(auto:true)?.id == 1) // explicit whole-playlist repeat remains
        // Media accounting: buffering, pause, backward/forward seek and duplicate end events.
        var listening = WaveListeningState()
        precondition(!listening.sample(trackID:"1",position:0,advancing:true))
        precondition(listening.sample(trackID:"1",position:0.5,advancing:true))
        precondition(!listening.sample(trackID:"1",position:1,advancing:true))
        _ = listening.sample(trackID:"1",position:60,advancing:false)
        _ = listening.sample(trackID:"1",position:60,advancing:false)
        _ = listening.sample(trackID:"1",position:60.5,advancing:true)
        precondition(listening.finish(trackID:"1") == 1.5)
        precondition(listening.finish(trackID:"1") == nil)
        precondition(!listening.sample(trackID:"1",position:61,advancing:true))
        print("Session continuation, order, dedup, HTTP/settings/stale/cancel, feedback parties/retry, real queue selector and listened time OK")
    }
}
'''.replace('SELECTOR', selector)
    with tempfile.TemporaryDirectory() as directory:
        p=Path(directory);(p/'Checks.swift').write_text(fixture)
        result=subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete',
            '-parse-as-library',str(root/'Sonivo/YandexWaveSession.swift'),str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True,timeout=90)
        assert result.returncode == 0, result.stderr[:8000]
        result=subprocess.run([str(p/'checks')],capture_output=True,text=True,timeout=30)
        assert result.returncode == 0,result.stdout+result.stderr[:8000]
        print(result.stdout.strip())
