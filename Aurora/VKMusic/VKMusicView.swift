// Path: Aurora/VKMusic/VKMusicView.swift

import SwiftUI
import UIKit
import VKID
import VKIDCore

struct VKMusicView: View {
    @Environment(VKAuthorizationStore.self) private var authorization
    @State private var query = ""
    @State private var tracks: [VKTrackDTO] = []
    @State private var isSearching = false
    @State private var searchError: VKMusicError?

    var body: some View {
        NavigationStack {
            ZStack {
                SonivoBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        statusCard
                        if case .authorized = authorization.status {
                            catalogContent
                        } else {
                            loginContent
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 90)
                }
            }
            .navigationTitle("vk_music_title")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await authorization.restoreSession()
            }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("vk_connection_status")
                .font(AG.text(.headline, .bold))
                .foregroundStyle(AG.ink)

            switch authorization.status {
            case .configurationMissing:
                Label("vk_configuration_missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .ready:
                Label("vk_not_signed_in", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(AG.inkMuted)
            case .authorizing:
                Label("vk_signing_in", systemImage: "hourglass")
                    .foregroundStyle(AG.inkMuted)
            case .authorized(let userID):
                Label("vk_signed_in", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("ID: \(userID)")
                    .font(AG.text(.caption))
                    .foregroundStyle(AG.inkMuted)
            case .failed:
                Label("vk_auth_failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }

            catalogCheckView
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AG.hairline, lineWidth: 0.8)
        }
    }

    @ViewBuilder
    private var catalogCheckView: some View {
        switch authorization.catalogCheck {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("vk_catalog_checking")
            }
            .font(AG.text(.caption))
            .foregroundStyle(AG.inkMuted)
        case .available(let total, let playable):
            Text("\(String(localized: "vk_catalog_available")): \(playable)/\(total)")
                .font(AG.text(.caption, .semibold))
                .foregroundStyle(.green)
        case .audioAccessDenied:
            Text("vk_audio_access_denied")
                .font(AG.text(.caption, .semibold))
                .foregroundStyle(.orange)
        case .tokenExpired:
            Text("vk_token_expired")
                .font(AG.text(.caption, .semibold))
                .foregroundStyle(.orange)
        case .failed(let code):
            Text(code.map { "\(String(localized: "vk_catalog_failed")) (\($0))" } ?? String(localized: "vk_catalog_failed"))
                .font(AG.text(.caption, .semibold))
                .foregroundStyle(.red)
        }
    }

    private var loginContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("vk_login_explanation")
                .font(AG.text(.footnote))
                .foregroundStyle(AG.inkMuted)

            if authorization.status != .configurationMissing {
                VKOneTapButton(authorization: authorization)
                    .frame(height: 52)
            }
        }
        .padding(.vertical, 8)
    }

    private var catalogContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("vk_search_prompt", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit { search() }

                Button(action: search) {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.blue)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                .accessibilityLabel("vk_search_button")
            }

            HStack {
                Button("vk_check_catalog") {
                    Task { await authorization.verifyCatalog() }
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("vk_sign_out", role: .destructive) {
                    authorization.signOut()
                }
                .buttonStyle(.bordered)
            }

            if isSearching {
                ProgressView("vk_searching")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if let searchError {
                searchErrorView(searchError)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(tracks) { track in
                        VKTrackRow(track: track)
                    }
                }
            }
        }
    }

    private func search() {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isSearching = true
        searchError = nil
        Task {
            do {
                tracks = try await authorization.musicService.search(query: clean, count: 100)
            } catch let error as VKMusicError {
                searchError = error
                tracks = []
            } catch {
                searchError = .invalidResponse
                tracks = []
            }
            isSearching = false
        }
    }

    @ViewBuilder
    private func searchErrorView(_ error: VKMusicError) -> some View {
        switch error {
        case .accessDenied:
            Text("vk_audio_access_denied")
        case .tokenExpired, .unauthorized:
            Text("vk_token_expired")
        case .rateLimited:
            Text("vk_rate_limited")
        default:
            Text("vk_catalog_failed")
        }
    }
}

private struct VKOneTapButton: UIViewRepresentable {
    let authorization: VKAuthorizationStore

    func makeUIView(context: Context) -> UIView {
        let configuration = OneTapButton(
            layout: .regular(height: .large(.h52), cornerRadius: 14),
            presenter: .newUIWindow,
            authConfiguration: AuthConfiguration(
                flow: .publicClientFlow(),
                scope: Scope("audio"),
                forceWebViewFlow: false,
                prompt: .consent
            ),
            onCompleteAuth: { result in
                authorization.handleAuthResult(result)
            }
        )
        return VKID.shared.ui(for: configuration).uiView()
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct VKTrackRow: View {
    let track: VKTrackDTO

    var body: some View {
        HStack(spacing: 12) {
            RemoteArtwork(urlString: track.album?.thumb?.bestURL, corner: 10)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(AG.text(.subheadline, .semibold))
                    .foregroundStyle(AG.ink)
                    .lineLimit(1)
                Text(track.artist)
                    .font(AG.text(.caption))
                    .foregroundStyle(AG.inkMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if track.isRestricted {
                Image(systemName: "lock.fill")
                    .foregroundStyle(AG.inkMuted)
                    .accessibilityLabel("vk_track_unavailable")
            } else {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(Color.blue)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
