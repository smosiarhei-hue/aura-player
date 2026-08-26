import AuthenticationServices
import Foundation
import SwiftUI

// MARK: - Social Auth (Sign in with Apple) — identity for favorites persistence

final class SocialAuthStore: ObservableObject {
    static let shared = SocialAuthStore()

    @Published var userID: String?
    @Published var displayName: String?

    private let d = UserDefaults.standard

    init() {
        userID = d.string(forKey: "social.userID")
        displayName = d.string(forKey: "social.name")
    }

    var isSignedIn: Bool { userID != nil }

    func handleSuccess(userID: String, name: String?) {
        self.userID = userID
        self.displayName = name
        d.set(userID, forKey: "social.userID")
        d.set(name, forKey: "social.name")
    }

    func signOut() {
        userID = nil
        displayName = nil
        d.removeObject(forKey: "social.userID")
        d.removeObject(forKey: "social.name")
    }
}

struct SignInWithAppleView: View {
    var onSignedIn: (String, String?) -> Void

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            switch result {
            case .success(let authorization):
                if let credential = authorization.credential as? ASAuthorizationAppleIDCredential {
                    let name = [credential.fullName?.givenName, credential.fullName?.familyName]
                        .compactMap { $0 }
                        .joined(separator: " ")
                    onSignedIn(credential.user, name.isEmpty ? nil : name)
                }
            case .failure:
                break
            }
        }
        .frame(height: 44)
        .signInWithAppleButtonStyle(.whiteOutline)
    }
}
