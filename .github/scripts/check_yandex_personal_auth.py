"""Compile the actual OAuth transport and exercise it without any real account."""
from pathlib import Path
import subprocess
import tempfile


def verify_yandex_personal_auth(root):
    code = r'''
import Foundation

nonisolated final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [(Int, String)] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    static func enqueue(_ status: Int, _ json: String) {
        lock.lock(); defer { lock.unlock() }; replies.append((status, json))
    }
    static func recorded() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Checks {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = YandexDeviceAuthClient(session: session, clientID: "test-client", clientSecret: "test-secret")
        let codeJSON = #"{"device_code":"opaque","user_code":"ABCD","verification_url":"https://oauth.yandex.ru/authorize/device","expires_in":300,"interval":5}"#
        StubProtocol.enqueue(200, codeJSON)
        let code = try await client.requestCode()
        precondition(code.user_code == "ABCD" && code.interval == 5 && code.expires_in == 300)
        precondition(code.verificationURL?.host == "oauth.yandex.ru")
        // Actual production response shape: verification_url is https://ya.ru/device.
        StubProtocol.enqueue(200, codeJSON.replacingOccurrences(of: "https://oauth.yandex.ru/authorize/device", with: "https://ya.ru/device"))
        let shortCode = try await client.requestCode()
        precondition(shortCode.verificationURL?.absoluteString == "https://ya.ru/device")
        for address in ["http://oauth.yandex.ru/", "https://oauth.yandex.ru.evil.test/", "https://user@oauth.yandex.ru/", "https://oauth.yandex.ru:443/", "https://evil.test/", "https://ya.ru/", "https://ya.ru/other", "https://ya.ru.evil.test/device", "http://ya.ru/device", "https://user@ya.ru/device", "https://ya.ru:443/device"] {
            let invalid = YandexDeviceCode(device_code: "x", user_code: "U", verification_url: address, expires_in: 300, interval: 5)
            precondition(invalid.verificationURL == nil)
        }
        for (json, expected) in [(#"{"error":"authorization_pending"}"#, YandexAuthError.pending),
                                 (#"{"error":"slow_down"}"#, .slowDown),
                                 (#"{"error":"access_denied","error_description":"DO_NOT_ECHO_SECRET"}"#, .denied),
                                 (#"{"error":"expired_token"}"#, .expired),
                                 (#"{"error":"invalid_grant"}"#, .rejectedToken)] {
            StubProtocol.enqueue(400, json)
            do { _ = try await client.pollToken(code: "opaque"); preconditionFailure("OAuth error was ignored") }
            catch let error as YandexAuthError {
                precondition(error == expected)
                precondition(!(error.errorDescription ?? "").contains("DO_NOT_ECHO_SECRET"))
            }
        }
        StubProtocol.enqueue(200, #"{"access_token":"fixture-token","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"bearer"}"#)
        let token = try await client.pollToken(code: "opaque")
        precondition(token.access_token == "fixture-token" && token.refresh_token == "fixture-refresh")
        let now = Date(timeIntervalSince1970: 1000)
        let stored = YandexCredential(uid: 42, token: token, now: now)
        precondition(!stored.needsRefresh(at: now.addingTimeInterval(3500)))
        precondition(stored.needsRefresh(at: now.addingTimeInterval(3540)))
        let serialized = try JSONEncoder().encode(stored)
        precondition(try JSONDecoder().decode(YandexCredential.self, from: serialized).uid == 42)
        StubProtocol.enqueue(200, #"{"access_token":"rotated","expires_in":7200}"#)
        let refreshed = try await client.refresh("fixture-refresh")
        let replacement = YandexCredential(uid: 42, token: refreshed, now: now, previousRefreshToken: stored.refreshToken)
        precondition(replacement.refreshToken == "fixture-refresh" && replacement.accessToken == "rotated")
        StubProtocol.enqueue(200, #"{"access_token":"","expires_in":3600}"#)
        do { _ = try await client.pollToken(code: "opaque"); preconditionFailure("Empty token accepted") }
        catch let error as YandexAuthError { precondition(error == .invalidResponse) }
        StubProtocol.enqueue(200, codeJSON.replacingOccurrences(of: "https://oauth.yandex.ru/authorize/device", with: "https://evil.test/"))
        do { _ = try await client.requestCode(); preconditionFailure("Untrusted login URL accepted") }
        catch let error as YandexAuthError { precondition(error == .invalidResponse) }
        let cancelled = Task { @MainActor in try await client.requestCode() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled OAuth request ran") }
        catch is CancellationError {}
        let requests = StubProtocol.recorded()
        precondition(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.host == "oauth.yandex.ru" })
        precondition(requests.first?.url?.path == "/device/code")
        precondition(requests[1].url?.path == "/device/code")
        precondition(requests[2].url?.path == "/token")
        let encoded = String(data: YandexOAuthForm.encode(["code": "a+b &=%#", "grant_type": "device_code"]), encoding: .utf8)!
        precondition(encoded == "code=a%2Bb%20%26%3D%25%23&grant_type=device_code")
        session.invalidateAndCancel()
    }
}
'''
    # A throwing expression cannot be evaluated in a precondition autoclosure.
    code = code.replace('precondition(try JSONDecoder().decode(YandexCredential.self, from: serialized).uid == 42)',
                        'let decoded = try JSONDecoder().decode(YandexCredential.self, from: serialized); precondition(decoded.uid == 42)')
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        (directory / 'Checks.swift').write_text(code)
        args = ['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-parse-as-library',
                str(root / 'Sonivo/YandexDeviceAuthClient.swift'), str(root / 'Sonivo/YandexCredentialStore.swift'),
                str(directory / 'Checks.swift'), '-o', str(directory / 'checks')]
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode:
            raise AssertionError(result.stderr)
        result = subprocess.run([str(directory / 'checks')], capture_output=True, text=True, timeout=40)
        if result.returncode:
            raise AssertionError(result.stdout + result.stderr)


def _method(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


def verify_yandex_account_transactions(root):
    """Execute actual staging/logout/library methods with controlled profile/storage."""
    service = (root / 'Sonivo/yandexmusicservice.swift').read_text()
    library = (root / 'Sonivo/librarystore.swift').read_text()
    credential = (root / 'Sonivo/YandexCredentialStore.swift').read_text().split('@MainActor\nenum YandexCredentialStore', 1)[0]
    credential = credential.replace('import Security\n', '')
    service_methods = '\n'.join(_method(service, marker) for marker in [
        'func loginWithOAuthToken(', 'func logout()', 'static func isPersonalYandexTrack(',
        'private func stopOldYandexPlayback()'])
    library_methods = '\n'.join(_method(library, marker) for marker in [
        'func clearYandexAccountData()', 'func setFavoritesFromCloud(', 'func setYandexPlaylistsFromCloud('])
    code = r'''
import Foundation
nonisolated struct Track: Equatable {
    var id = UUID()
    var fileName: String
    var isStream: Bool
    var isFavorite = false
}
nonisolated struct Playlist {
    var id = UUID()
    var trackIds: [UUID]
    var cachedTracks: [Track]
}
@MainActor enum YandexCredentialStore {
    static var maySave = true
    static var saved: YandexCredential?
    static func save(_ value: YandexCredential) -> Bool {
        guard maySave else { return false }; saved = value; return true
    }
    static func remove() { saved = nil }
}
@MainActor final class PlayerCore {
    static let shared = PlayerCore()
    var currentTrack: Track?
    var queue: [Track] = []
    var stopped = false
    func stopAndClear() { stopped = true; currentTrack = nil }
}
@MainActor final class LibraryStore {
    static let shared = LibraryStore()
    var tracks: [Track] = []
    var playlists: [Playlist] = []
    LIBRARY_METHODS
}
@MainActor final class YandexMusicService {
    struct Profile: Sendable { let uid: Int }
    var credential: YandexCredential?
    var token = ""
    var isAuthorized = false
    var currentUser: Profile?
    var accountGeneration = UUID()
    var loginAttemptID = UUID()
    var refreshTask: Task<Bool, Never>?
    var resetCount = 0
    var waiters: [String: CheckedContinuation<Profile?, Never>] = [:]
    func profile(for token: String) async -> Profile? {
        if token == "invalid" { return nil }
        if token.hasPrefix("wait") {
            return await withCheckedContinuation { waiters[token] = $0 }
        }
        return Profile(uid: token == "accountB" ? 2 : 1)
    }
    func resolve(_ token: String, uid: Int) { waiters.removeValue(forKey: token)?.resume(returning: Profile(uid: uid)) }
    func installProfile(_ profile: Profile) { currentUser = profile }
    func resetPersonalState() { resetCount += 1 }
    func syncAccountData() async {}
    static func ymId(fromFileName name: String) -> String? {
        guard name.hasPrefix("ym_"), name.hasSuffix(".mp3") else { return nil }
        let core = String(name.dropFirst(3).dropLast(4)); return core.isEmpty ? nil : core
    }
    SERVICE_METHODS
}
@main struct Checks {
    @MainActor static func result(_ token: String) -> YandexOAuthToken {
        YandexOAuthToken(access_token: token, refresh_token: nil, expires_in: nil, token_type: nil)
    }
    @MainActor static func main() async {
        defer { UserDefaults.standard.removeObject(forKey: "ym.imported_playlist_ids") }
        let ym = YandexMusicService()
        let signedIn = await ym.loginWithOAuthToken(result("accountA"))
        precondition(signedIn && ym.currentUser?.uid == 1 && ym.token == "accountA")
        let generation = ym.accountGeneration
        let invalid = await ym.loginWithOAuthToken(result("invalid"))
        precondition(!invalid && ym.token == "accountA" && ym.accountGeneration == generation)
        YandexCredentialStore.maySave = false
        let failedSave = await ym.loginWithOAuthToken(result("accountB"))
        precondition(!failedSave && ym.currentUser?.uid == 1 && YandexCredentialStore.saved?.uid == 1)
        YandexCredentialStore.maySave = true
        let pending = Task { @MainActor in await ym.loginWithOAuthToken(result("wait-cancel")) }
        while ym.waiters["wait-cancel"] == nil { await Task.yield() }
        pending.cancel(); ym.resolve("wait-cancel", uid: 2)
        let cancelled = await pending.value
        precondition(!cancelled && ym.currentUser?.uid == 1)
        let oldAttempt = Task { @MainActor in await ym.loginWithOAuthToken(result("wait-old")) }
        while ym.waiters["wait-old"] == nil { await Task.yield() }
        let newerAttempt = await ym.loginWithOAuthToken(result("accountB"))
        ym.resolve("wait-old", uid: 1)
        let stale = await oldAttempt.value
        precondition(newerAttempt && !stale && ym.currentUser?.uid == 2 && YandexCredentialStore.saved?.uid == 2)
        let late = Task { @MainActor in await ym.loginWithOAuthToken(result("wait-logout")) }
        while ym.waiters["wait-logout"] == nil { await Task.yield() }
        let local = Track(fileName: "12345-local.mp3", isStream: false, isFavorite: true)
        let cloud = Track(fileName: "ym_12345.mp3", isStream: true, isFavorite: true)
        let localNamedLikeCloud = Track(fileName: "ym_54321.mp3", isStream: false, isFavorite: true)
        precondition(!YandexMusicService.isPersonalYandexTrack(local))
        precondition(!YandexMusicService.isPersonalYandexTrack(localNamedLikeCloud))
        let library = LibraryStore.shared
        library.tracks = [local, cloud, localNamedLikeCloud]
        let localPlaylist = Playlist(trackIds: [local.id, cloud.id], cachedTracks: [local, cloud])
        let importedPlaylist = Playlist(trackIds: [cloud.id], cachedTracks: [cloud])
        library.playlists = [localPlaylist]
        library.setYandexPlaylistsFromCloud([importedPlaylist])
        precondition(library.playlists.count == 2)
        PlayerCore.shared.currentTrack = cloud
        PlayerCore.shared.queue = [local, cloud]
        ym.logout()
        ym.resolve("wait-logout", uid: 1)
        let loggedOut = await late.value
        precondition(!loggedOut && ym.token.isEmpty && !ym.isAuthorized && ym.currentUser == nil)
        precondition(YandexCredentialStore.saved == nil)
        precondition(library.tracks == [local, localNamedLikeCloud] && library.tracks.allSatisfy { $0.isFavorite })
        precondition(library.playlists.count == 1 && library.playlists[0].id == localPlaylist.id)
        precondition(library.playlists[0].cachedTracks == [local] && library.playlists[0].trackIds == [local.id])
        precondition(PlayerCore.shared.stopped && PlayerCore.shared.queue == [local])
        PlayerCore.shared.stopped = false
        PlayerCore.shared.currentTrack = local
        ym.logout()
        precondition(!PlayerCore.shared.stopped && PlayerCore.shared.currentTrack == local)
        library.tracks = [local, cloud]
        library.setFavoritesFromCloud([])
        precondition(library.tracks[0].isFavorite && !library.tracks[1].isFavorite)
    }
}
'''
    code = code.replace('LIBRARY_METHODS', library_methods).replace('SERVICE_METHODS', service_methods)
    with tempfile.TemporaryDirectory() as directory:
        directory = Path(directory)
        (directory / 'Credential.swift').write_text(credential)
        (directory / 'Checks.swift').write_text(code)
        args = ['swiftc', '-swift-version', '6', '-default-isolation', 'MainActor', '-strict-concurrency=complete', '-parse-as-library',
                str(root / 'Sonivo/YandexDeviceAuthClient.swift'), str(directory / 'Credential.swift'),
                str(directory / 'Checks.swift'), '-o', str(directory / 'checks')]
        compiled = subprocess.run(args, capture_output=True, text=True)
        if compiled.returncode:
            raise AssertionError(compiled.stderr)
        checked = subprocess.run([str(directory / 'checks')], capture_output=True, text=True, timeout=40)
        if checked.returncode:
            raise AssertionError(checked.stdout + checked.stderr)
