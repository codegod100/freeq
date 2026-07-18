import Foundation

/// Classifies the server's `/api/v1/upload` response into an actionable
/// outcome. Pure (no networking) so the whole decision tree is unit-tested.
///
/// Auth model (freeq-server `api_upload`): a private upload needs the DID to
/// have an active connection (macOS authed users pass automatically). Sharing
/// the blob to the PDS / Bluesky feed needs write scope the default login
/// lacks → the server returns 403 `step_up_required`. Guests have no DID
/// session → 401.
enum UploadResponse {
    enum Failure: Error, Equatable {
        case notAuthenticated
        case stepUpRequired(purpose: String, url: String)
        case tooLarge
        case rateLimited
        case malformed
        case server(message: String)

        /// Actionable, non-protocol message for the compose bar.
        var userMessage: String {
            switch self {
            case .notAuthenticated:
                return "Sign in to upload files."
            case .stepUpRequired:
                return "Sharing to Bluesky needs permission to write to your account. "
                    + "Grant it, then try again."
            case .tooLarge:
                return "That file is too large (max 10 MB)."
            case .rateLimited:
                return "You're uploading too fast — wait a moment and try again."
            case .malformed:
                return "The server returned an unexpected response."
            case .server(let message):
                return message.isEmpty ? "Upload failed." : message
            }
        }
    }

    enum Outcome: Equatable {
        case success(url: String)
        case failure(Failure)
    }

    static func classify(status: Int, body: Data) -> Outcome {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let text = String(data: body, encoding: .utf8) ?? ""

        switch status {
        case 200:
            if let url = json?["url"] as? String {
                return .success(url: url)
            }
            return .failure(.malformed)
        case 401:
            return .failure(.notAuthenticated)
        case 403:
            if let obj = json, (obj["error"] as? String) == "step_up_required" {
                let purpose = obj["purpose"] as? String ?? "blob_upload"
                let url = obj["step_up_url"] as? String ?? "/auth/step-up?purpose=\(purpose)"
                return .failure(.stepUpRequired(purpose: purpose, url: url))
            }
            return .failure(.server(message: text))
        case 413:
            return .failure(.tooLarge)
        case 429:
            return .failure(.rateLimited)
        default:
            return .failure(.server(message: text))
        }
    }
}
