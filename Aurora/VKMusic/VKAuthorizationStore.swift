// Path: Aurora/VKMusic/VKAuthorizationStore.swift

import Foundation
import Observation
import VKID
import VKIDCore

@Observable
@MainActor
final class VKAuthorizationStore {
    enum Status: Equatable {
        case configurationMissing
        case ready
        case authorizing
        case authorized(userID: Int)
        case failed
    }

    enum CatalogCheck: Equatable {
        case idle
        case checking
        case available(total: Int, playable: Int)
        case audioAccessDenied
        case tokenExpired
        case failed(code: Int?)
    }

    private let tokenStore: VKTokenStore
    let musicService: VKMusicService

    private(set) var status: Status = .ready
    private(set) var catalogCheck: CatalogCheck = .idle

    init() {
        let tokenStore = VKTokenStore()
        self.tokenStore = tokenStore
        self.musicService = VKMusicService(tokenStore: tokenStore)
        configureSDK()
    }

    func restoreSession() async {
        guard case .ready = status else { return }
        guard let session = VKID.shared.currentAuthorizedSession else { return }
        await accept(session: session)
    }

    func handleAuthResult(_ result: AuthResult) {
        do {
            let session = try result.get()
            Task { await accept(session: session) }
        } catch AuthError.cancelled {
            status = .ready
        } catch {
            status = .failed
        }
    }

    func handle(url: URL) -> Bool {
        VKID.shared.open(url: url)
    }

    func verifyCatalog() async {
        guard case .authorized = status else {
            catalogCheck = .tokenExpired
            return
        }
        catalogCheck = .checking
        do {
            let tracks = try await musicService.popular(count: 50)
            catalogCheck = .available(
                total: tracks.count,
                playable: tracks.filter { !$0.isRestricted }.count
            )
        } catch VKMusicError.accessDenied {
            catalogCheck = .audioAccessDenied
        } catch VKMusicError.tokenExpired {
            catalogCheck = .tokenExpired
            status = .ready
        } catch VKMusicError.api(let code, _) {
            catalogCheck = .failed(code: code)
        } catch {
            catalogCheck = .failed(code: nil)
        }
    }

    func signOut() {
        guard let session = VKID.shared.currentAuthorizedSession else {
            Task { try? await tokenStore.delete() }
            status = .ready
            catalogCheck = .idle
            return
        }
        session.logout { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                try? await self.tokenStore.delete()
                await self.musicService.clearMemoryCache()
                self.status = .ready
                self.catalogCheck = .idle
            }
        }
    }

    private func configureSDK() {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "CLIENT_ID") as? String,
              let clientSecret = Bundle.main.object(forInfoDictionaryKey: "CLIENT_SECRET") as? String,
              !clientID.isEmpty,
              !clientSecret.isEmpty else {
            status = .configurationMissing
            return
        }

        do {
            try VKID.shared.set(
                config: Configuration(
                    appCredentials: AppCredentials(
                        clientId: clientID,
                        clientSecret: clientSecret
                    ),
                    appearance: Appearance(colorScheme: .dark, locale: .ru),
                    loggingEnabled: false,
                    groupSubscriptionsLimit: nil
                )
            )
            status = .ready
        } catch {
            status = .failed
        }
    }

    private func accept(session: UserSession) async {
        let token = session.accessToken
        do {
            try await tokenStore.save(
                VKAccessToken(
                    value: token.value,
                    userID: token.userId.value,
                    expiresAt: token.expirationDate
                )
            )
            status = .authorized(userID: token.userId.value)
            await verifyCatalog()
        } catch {
            status = .failed
        }
    }
}
