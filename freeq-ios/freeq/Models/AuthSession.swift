import AuthenticationServices
import UIKit

/// In-app OAuth via ASWebAuthenticationSession — the system's purpose-built
/// sign-in sheet. Replaces the Safari bounce (full app-switch, user stranded on
/// failure) with a sheet that stays over freeq, shares Safari's cookies for
/// PDS SSO, and calls back with the same `freeq://auth?...` URL the broker
/// already produces. App Review also strongly prefers this over kicking users
/// to Safari for login.
final class AuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AuthSession()

    private var session: ASWebAuthenticationSession?

    /// Start the broker OAuth flow. `completion` receives the freeq://auth
    /// callback URL on success, or nil if the user cancelled / it failed
    /// (an alert-worthy error string is passed separately).
    func start(loginURL: URL, completion: @escaping (URL?, String?) -> Void) {
        // Cancel any prior in-flight session.
        session?.cancel()

        let s = ASWebAuthenticationSession(url: loginURL, callbackURLScheme: "freeq") { callbackURL, error in
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                completion(nil, nil) // user dismissed — not an error
                return
            }
            if let error {
                completion(nil, error.localizedDescription)
                return
            }
            completion(callbackURL, nil)
        }
        s.presentationContextProvider = self
        // Ephemeral would drop the user's existing bsky.social session cookie
        // and force a full password entry every time — keep shared storage.
        s.prefersEphemeralWebBrowserSession = false
        session = s
        s.start()
    }

    // MARK: ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The key window of the active scene.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
