import AuthenticationServices
import Foundation

/// Drives the freeq server's `/auth/step-up` flow on iOS.
///
/// Default OAuth login asks Bluesky for `atproto` only — proof of identity,
/// no PDS write access. When the user triggers a feature that needs more
/// (image / voice upload to PDS, future Bluesky cross-post), the server's
/// upload endpoint returns 403 with:
///
///   { "error": "step_up_required", "purpose": "blob_upload",
///     "step_up_url": "/auth/step-up?purpose=blob_upload" }
///
/// This helper detects that body, opens an ASWebAuthenticationSession to
/// `<server>/auth/step-up?purpose=…&did=…&mobile=1`, and resumes when the
/// server bounces back to `freeq://step-up?ok=1&purpose=…`. Web parity with
/// `freeq-app/src/lib/oauth-step-up.ts` — same purposes, same shape.
@MainActor
enum StepUpAuth {

    enum Purpose: String, CaseIterable {
        case blobUpload = "blob_upload"
        case blueskyPost = "bluesky_post"

        var humanLabel: String {
            switch self {
            case .blobUpload: return "Image / voice upload"
            case .blueskyPost: return "Posting to Bluesky"
            }
        }
    }

    enum Outcome {
        case granted
        case userCancelled
        case error(String)
    }

    /// If the response is a step_up_required 403, return the purpose;
    /// otherwise nil. Caller decides whether to drive the flow.
    /// Mirrors `detectStepUpRequired` in the web SDK.
    static func detectStepUpRequired(status: Int, body: Data) -> Purpose? {
        guard status == 403 else { return nil }
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let err = json["error"] as? String,
            err == "step_up_required",
            let p = json["purpose"] as? String
        else {
            return nil
        }
        return Purpose(rawValue: p)
    }

    /// Open the step-up flow for `purpose` against the user's `did`. Returns
    /// when the server redirects back to freeq://step-up?ok=1, the user
    /// cancels, or an error occurs.
    static func request(purpose: Purpose, did: String, on appState: AppState) async -> Outcome {
        let base = ServerConfig.apiBaseUrl
        var components = URLComponents(string: "\(base)/auth/step-up")!
        components.queryItems = [
            URLQueryItem(name: "purpose", value: purpose.rawValue),
            URLQueryItem(name: "did", value: did),
            URLQueryItem(name: "mobile", value: "1"),
        ]
        guard let url = components.url else {
            return .error("Invalid step-up URL")
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<Outcome, Never>) in
            let presenter = WebAuthPresenter()
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "freeq"
            ) { callback, error in
                if let nsError = error as? NSError,
                   nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                   nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    cont.resume(returning: .userCancelled)
                    return
                }
                if let error {
                    cont.resume(returning: .error(error.localizedDescription))
                    return
                }
                guard let callback,
                      callback.scheme == "freeq",
                      callback.host == "step-up"
                else {
                    cont.resume(returning: .error("Unexpected callback URL"))
                    return
                }
                let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                let ok = comps?.queryItems?.first(where: { $0.name == "ok" })?.value == "1"
                cont.resume(returning: ok ? .granted : .error("Permission was not granted"))
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = false
            // Hold the presenter alive until the session finishes by
            // capturing it in a side reference the session retains.
            objc_setAssociatedObject(session, &Self.presenterKey, presenter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            session.start()
        }
    }

    private static var presenterKey: UInt8 = 0

    /// Issue an upload `request`. If the server responds 403
    /// `step_up_required`, drive the step-up flow and retry once. Returns
    /// the successful response or surfaces the final error.
    ///
    /// Both iOS upload sites (voice in ComposeView, image in PhotoPicker)
    /// funnel through this so step-up handling lives in one place.
    static func uploadWithStepUp(
        request: URLRequest,
        did: String,
        appState: AppState
    ) async -> (Data, URLResponse)? {
        do {
            let (data, resp) = try await URLSession.shared.data(for: request)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let purpose = detectStepUpRequired(status: status, body: data) else {
                return (data, resp)
            }
            // Server says "you need more permission". Drive the step-up
            // flow once, then retry the original request verbatim.
            let outcome = await Self.request(purpose: purpose, did: did, on: appState)
            switch outcome {
            case .granted:
                let (retryData, retryResp) = try await URLSession.shared.data(for: request)
                return (retryData, retryResp)
            case .userCancelled, .error:
                return (data, resp)
            }
        } catch {
            print("[freeq.upload] error: \(error)")
            return nil
        }
    }
}

/// Provides the presentation anchor for `ASWebAuthenticationSession`.
private final class WebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The first foreground active scene is the right anchor on iOS 15+.
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        return scene?.keyWindow ?? ASPresentationAnchor()
    }
}
