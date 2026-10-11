import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One server session. No chart/artist fallback and no local reranking.
@MainActor
final class YandexWaveSession<Item: Decodable> {
    nonisolated struct Entry: Decodable { let track: Item? }
    nonisolated struct Batch: Decodable {
        let radioSessionId: String?
        let batchId: String?
        let sequence: [Entry]?
        let unknownSession: Bool?
        let terminated: Bool?
    }
    nonisolated struct Envelope: Decodable { let result: Batch }
    struct Feedback {
        let session: String
        let body: [String: Any]
    }
    enum Failure: Error { case unsupportedSetting(String), badResponse, http(Int), unknownSession, terminated }
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private let identity: (Item) -> String
    private let playable: (Item) -> Bool
    private let log: (String) -> Void
    private(set) var station: String?
    private(set) var serverID: String?
    private(set) var generation = UUID()
    private var issued: [String] = []
    private var batches: [String: String] = [:]
    private var fetching = false
    private var unacknowledged: [Item] = []
    private var feedbacks: [Feedback] = []
    private var draining = false
    private var terminal = false
    var requiresRestart: Bool { terminal && unacknowledged.isEmpty }
    private var playingContexts: [String: (session: String, batch: String)] = [:]

    init(send: @escaping (URLRequest) async throws -> (Data, URLResponse),
         identity: @escaping (Item) -> String, playable: @escaping (Item) -> Bool,
         log: @escaping (String) -> Void = { _ in }) {
        self.send = send; self.identity = identity; self.playable = playable; self.log = log
    }

    private func request(_ path: String, body: [String: Any]? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.music.yandex.net" + path)!)
        request.setValue("ru", forHTTPHeaderField: "Accept-Language")
        request.setValue("com.yandex.mobile.music", forHTTPHeaderField: "X-Yandex-Music-Client")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
    private func data(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw Failure.badResponse }
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] != nil {
            throw Failure.badResponse
        }
        return data
    }

    /// Use serializedSeed supplied by Yandex, not invented settings/query fields.
    private func seeds(station: String, settings: [String: String]) async throws -> [String] {
        var components = URLComponents(string: "https://api.music.yandex.net/rotor/wave/settings")!
        components.queryItems = [URLQueryItem(name: "seeds", value: station)]
        var settingsRequest = request("/rotor/wave/settings")
        settingsRequest.url = components.url
        let payload = try await data(settingsRequest)
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let restrictions = result["settingRestrictions"] as? [String: Any] else { throw Failure.badResponse }
        var seeds = [station]
        for field in ["diversity", "language", "moodEnergy"] {
            guard let value = settings[field] else { continue }
            guard let options = restrictions[field] as? [String: Any],
                  let values = options["possibleValues"] as? [[String: Any]],
                  let option = values.first(where: { ($0["value"] as? String) == value }) else {
                throw Failure.unsupportedSetting(field)
            }
            if let seed = option["serializedSeed"] as? String, !seed.isEmpty { seeds.append(seed) }
            else if option["unspecified"] as? Bool != true { throw Failure.unsupportedSetting(field) }
        }
        return seeds
    }

    /// Transactional replacement: failed or stale startup preserves the old session.
    func start(station: String, settings: [String: String], history: [String], seedTrack: String? = nil, canCommit: () -> Bool = { true }) async throws -> [Item] {
        let operation = UUID(); generation = operation
        await flushFeedback()
        guard generation == operation else { throw CancellationError() }
        let seeds = try await seeds(station: station, settings: settings)
        guard generation == operation else { throw CancellationError() }
        var body: [String: Any] = ["seeds": seeds, "queue": Array(history.suffix(1000)),
                                  "includeTracksInResponse": true, "includeWaveModel": true, "interactive": true]
        if let seedTrack { body["trackToStartFrom"] = seedTrack }
        let response = try await data(request("/rotor/session/new", body: body))
        let batch = try JSONDecoder().decode(Envelope.self, from: response).result
        guard generation == operation, canCommit() else { throw CancellationError() }
        guard let id = batch.radioSessionId, !id.isEmpty, batch.terminated != true else { throw Failure.badResponse }
        let items = (batch.sequence ?? []).compactMap(\.track).filter(playable)
        let excluded = Set(history)
        guard items.contains(where: { !excluded.contains(identity($0)) }) else { throw Failure.badResponse }
        self.station = station; serverID = id; terminal = false
        issued = Array(history.suffix(1000)); batches = [:]
        let accepted = accept(batch)
        unacknowledged = accepted
        guard !accepted.isEmpty else { throw Failure.badResponse }
        var event: [String: Any] = ["type": "radioStarted", "timestamp": timestamp()]
        event["trackId"] = nil
        var feedback: [String: Any] = ["event": event, "from": "sonivo-ios"]
        if let batchID = batch.batchId { feedback["batchId"] = batchID }
        feedbacks.append(Feedback(session: id, body: feedback))
        log("Session started; accepted=\(accepted.count)")
        Task { await flushFeedback() }
        return accepted
    }

    func next(excluding: [String] = []) async throws -> [Item] {
        let operation = generation
        while fetching {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
            guard generation == operation else { throw CancellationError() }
        }
        guard let serverID else { return [] }
        let excluded = Set(excluding)
        unacknowledged.removeAll { excluded.contains(identity($0)) || !playable($0) }
        if !unacknowledged.isEmpty { return unacknowledged }
        guard !terminal else { return [] }
        fetching = true
        defer { fetching = false }
        await flushFeedback()
        guard generation == operation else { throw CancellationError() }
        var queue = issued
        for id in excluding where !queue.contains(id) { queue.append(id) }
        let response = try await data(request("/rotor/session/\(serverID)/tracks", body: ["queue": Array(queue.suffix(1000))]))
        let batch = try JSONDecoder().decode(Envelope.self, from: response).result
        guard generation == operation, self.serverID == serverID else { throw CancellationError() }
        if batch.unknownSession == true {
            terminal = true
            feedbacks.removeAll { $0.session == serverID }
            playingContexts = playingContexts.filter { $0.value.session != serverID }
            throw Failure.unknownSession
        }
        let accepted = accept(batch, excluding: excluded)
        unacknowledged = accepted
        if batch.terminated == true {
            terminal = true
            if accepted.isEmpty { throw Failure.terminated }
        }
        log("Next batch; accepted=\(accepted.count)")
        return accepted
    }

    private func accept(_ batch: Batch, excluding: Set<String> = []) -> [Item] {
        var seen = Set(issued).union(excluding)
        var accepted: [Item] = []
        for item in (batch.sequence ?? []).compactMap(\.track) where playable(item) {
            let id = identity(item)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            issued.append(id)
            if let batchID = batch.batchId { batches[id] = batchID }
            accepted.append(item)
        }
        if issued.count > 1000 {
            issued = Array(issued.suffix(1000))
            let retained = Set(issued); batches = batches.filter { retained.contains($0.key) }
        }
        return accepted
    }

    func event(type: String, trackID: String, seconds: Double? = nil) {
        guard feedbacks.count < 256 else { log("Feedback queue full"); return }
        let context: (session: String, batch: String)
        if type == "trackStarted" {
            guard let serverID, let batch = batches[trackID] else { return }
            context = (serverID, batch); playingContexts[trackID] = context
        } else if let playing = playingContexts[trackID] {
            context = playing
        } else {
            guard let serverID, let batch = batches[trackID] else { return }
            context = (serverID, batch)
        }
        var event: [String: Any] = ["type": type, "timestamp": timestamp(), "trackId": trackID]
        if let seconds { event["totalPlayedSeconds"] = max(0, seconds.isFinite ? seconds : 0) }
        feedbacks.append(Feedback(session: context.session, body: ["event": event, "batchId": context.batch]))
        if type == "skip" || type == "trackFinished" { playingContexts.removeValue(forKey: trackID) }
        Task { await flushFeedback() }
    }
    private func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }
    func flushFeedback() async {
        while draining {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        draining = true
        defer { draining = false }
        while let first = feedbacks.first {
            let operation = generation
            do {
                let reply = try await data(request("/rotor/session/\(first.session)/feedback", body: first.body))
                guard let response = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                      response["result"] is [String: Any] else { throw Failure.badResponse }
                // Startup can change generation; reset/logout must not remove a newer event.
                guard let current = feedbacks.first, current.session == first.session,
                      NSDictionary(dictionary: current.body).isEqual(to: first.body) else { return }
                feedbacks.removeFirst()
            } catch Failure.http(404) {
                // A missing server session cannot accept this old event; do not block newer sessions.
                if feedbacks.first?.session == first.session { feedbacks.removeFirst() }
                log("Feedback session no longer exists")
            } catch {
                if generation == operation { log("Feedback pending; will retry before refill") }
                return
            }
        }
    }
    func close() {
        let pending = feedbacks
        reset()
        feedbacks = pending
        Task { await flushFeedback() }
    }
    func reset() {
        generation = UUID(); station = nil; serverID = nil; terminal = false
        issued = []; batches = [:]; feedbacks = []; playingContexts = [:]; unacknowledged = []
    }
}

/// Count positive media advancement only: no seek jumps, pauses or buffering.
nonisolated struct WaveListeningState {
    private(set) var trackID: String?
    private(set) var seconds: Double = 0
    private var lastPosition: Double?
    private var started = false
    private var ended = false
    mutating func sample(trackID: String, position: Double, advancing: Bool) -> Bool {
        if self.trackID != trackID { reset(); self.trackID = trackID }
        guard position.isFinite else { return false }
        defer { lastPosition = position }
        guard !ended, advancing, let previous = lastPosition else { return false }
        let delta = position - previous
        guard delta > 0, delta <= 2 else { return false }
        seconds += delta
        if !started { started = true; return true }
        return false
    }
    mutating func finish(trackID: String) -> Double? {
        guard self.trackID == trackID, started, !ended else { return nil }
        ended = true; return seconds
    }
    mutating func reset() { self = Self() }
}
