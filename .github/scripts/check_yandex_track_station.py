"""Compile and execute the actual API-only Swift methods against a stub transport.
No tokens, live API requests or audio downloads are needed. Runs in macOS CI.
"""
from pathlib import Path
import subprocess
import tempfile

def verify_yandex_track_station(root):
    service=(root/'Sonivo/yandexmusicservice.swift').read_text()
    methods=service[service.index('    private func requestTrackStationQueue'):service.index('    func getStationTracks')]
    begin=service[service.index('    func beginStationSession'):service.index('    /// Явный сигнал')]
    playable=service[service.index('    static func playable'):service.index('    /// Детерминированный UUID')]
    stub=r'''
import Foundation
struct Track { let fileName: String }
@MainActor final class PlayerCore {
    static let shared = PlayerCore()
    var playbackRequestID = 0
    var queue = [Track(fileName: "ym_1.mp3")]
}
@MainActor final class WaveSettingsStore {
    static let shared = WaveSettingsStore()
    struct Value { let rotorValue: String }
    let diversity = Value(rotorValue: "default")
    let language = Value(rotorValue: "any")
    let moodEnergy = Value(rotorValue: "all")
}
@MainActor final class StubTransport {
    var fixtures: [(String, Int)] = []
    var requests: [URLRequest] = []
    var hook: (() async -> Void)?
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !fixtures.isEmpty else { throw URLError(.notConnectedToInternet) }
        let fixture = fixtures.removeFirst()
        let callback = hook; hook = nil
        if let callback { await callback() }
        return (Data(fixture.0.utf8), HTTPURLResponse(url: request.url!, statusCode: fixture.1, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor enum URLSession { static let shared = StubTransport() }
@MainActor final class YandexMusicService {
    static let apiBase = "https://api.music.yandex.net"
    struct YMTrackItem: Decodable { let id: String; let available: Bool? }
    var activeStationId: String?
    private var lastBatchId: String?
    private(set) var rotorSessionID = UUID()
    private var trackStationRequestID = UUID()
    func authorizedRequest(url: URL) -> URLRequest { URLRequest(url: url) }
    func convertToTrack(_ item: YMTrackItem) -> Track { Track(fileName: "ym_\(item.id).mp3") }
    static func ymId(fromFileName name: String) -> String? {
        guard name.hasPrefix("ym_"), name.hasSuffix(".mp3") else { return nil }
        return String(name.dropFirst(3).dropLast(4))
    }
    func sendRotorFeedback(stationId: String, type: String) async {}
'''
    main=r'''
}
@main struct Checks {
    @MainActor static func main() async {
        func check(_ passed: Bool, _ message: String) { precondition(passed, message) }
        let transport = URLSession.shared
        func fixture(_ ids: [String]) -> (String,Int) {
            let entries=ids.map { "{\"track\":{\"id\":\"\($0)\",\"available\":true}}" }.joined(separator: ",")
            return ("{\"result\":{\"batchId\":\"b1\",\"sequence\":[\(entries)]}}",200)
        }
        func setup(_ fixtures: [(String,Int)]) -> YandexMusicService {
            transport.fixtures=fixtures; transport.requests=[]; transport.hook=nil
            PlayerCore.shared.playbackRequestID=0
            return YandexMusicService()
        }
        let service=setup([fixture(["1","3","2","3"]),fixture(["2","4"])])
        let tracks=await service.startYandexTrackStation(seedID: "1",target: 3)
        check(tracks.map(\.fileName)==["ym_3.mp3","ym_2.mp3","ym_4.mp3"],"Server order/dedup changed")
        check(service.activeStationId=="track:1","Track station not activated")
        check(transport.requests.count==2,"Unexpected request count")
        let query=URLComponents(url: transport.requests[1].url!,resolvingAgainstBaseURL: false)!.queryItems!
        check(query.first { $0.name=="queue" }?.value=="1,3,2","Server queue context lost")
        check(transport.requests.allSatisfy { $0.url!.path=="/rotor/station/track:1/tracks" },"Non-track source requested")
        let failed=setup([("{}",403)])
        failed.beginStationSession("user:onyourwave")
        check(await failed.startYandexTrackStation(seedID: "1",target: 3).isEmpty,"HTTP error substituted tracks")
        check(failed.activeStationId=="user:onyourwave","Failed fetch replaced station")
        let empty=setup([fixture([])])
        check(await empty.startYandexTrackStation(seedID: "1",target: 3).isEmpty,"Empty result substituted tracks")
        check(empty.activeStationId==nil,"Empty result created a station")
        let stale=setup([fixture(["2"])])
        transport.hook={ PlayerCore.shared.playbackRequestID += 1 }
        check(await stale.startYandexTrackStation(seedID: "1",target: 1).isEmpty,"Old playback result applied")
        let changed=setup([fixture(["2"])])
        transport.hook={ changed.beginStationSession("user:other") }
        check(await changed.startYandexTrackStation(seedID: "1",target: 1).isEmpty,"Changed station overwritten")
        check(changed.activeStationId=="user:other","Station rollback")
        let concurrent=setup([fixture(["2"]),fixture(["8"])])
        transport.hook={
            let newer=await concurrent.startYandexTrackStation(seedID: "7",target: 1)
            check(newer.map(\.fileName)==["ym_8.mp3"],"Newer wave missing")
        }
        check(await concurrent.startYandexTrackStation(seedID: "1",target: 1).isEmpty,"Old request won")
        check(concurrent.activeStationId=="track:7","Older request replaced newer station")
        let refill=setup([fixture(["1","5","6"])])
        refill.beginStationSession("track:1")
        let more=await refill.refillYandexTrackWave(target: 2)
        check(more.map(\.fileName)==["ym_5.mp3","ym_6.mp3"],"Refill changed server order")
        let invalidRefill=setup([fixture(["5"])])
        invalidRefill.beginStationSession("track:1")
        transport.hook={ invalidRefill.beginStationSession("user:other") }
        check(await invalidRefill.refillYandexTrackWave(target: 1).isEmpty,"Stale refill appended")
        let cancelled=setup([fixture(["2"])])
        let task=Task { @MainActor in await cancelled.startYandexTrackStation(seedID: "1",target: 1) }
        task.cancel()
        check(await task.value.isEmpty,"Cancelled wave committed")
        check(cancelled.activeStationId==nil,"Cancellation changed station")
        print("Yandex track-station Swift checks passed: order, dedup, queue context, HTTP/empty, playback/session races, concurrent requests, refill, cancellation")
    }
}
'''
    with tempfile.TemporaryDirectory() as directory:
        p=Path(directory); (p/'Checks.swift').write_text(stub+methods+begin+playable+main)
        compiled=subprocess.run(['swiftc','-swift-version','6','-default-isolation','MainActor','-strict-concurrency=complete','-parse-as-library',str(p/'Checks.swift'),'-o',str(p/'checks')],capture_output=True,text=True)
        assert compiled.returncode==0,compiled.stderr[:6000]
        checked=subprocess.run([str(p/'checks')],capture_output=True,text=True)
        assert checked.returncode==0,checked.stdout+checked.stderr
        print(checked.stdout.strip())
