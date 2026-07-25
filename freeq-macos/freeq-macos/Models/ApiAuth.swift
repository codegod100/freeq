import Foundation

/// Authorization for the REST API.
///
/// Channel-scoped read endpoints (`/pins`, `/audit`, `/events`, `/sessions`,
/// `/topic`, `/history`, `/export`, and the governance endpoints) enforce the
/// same access rule as history: a mode-restricted channel (+i / +k / encrypted)
/// is refused unless the bearer resolves to a member, op or founder. A request
/// without the bearer therefore works for public channels and 403s for private
/// ones — a failure mode that only shows up for the people who most need privacy.
///
/// Guests have no bearer, and public endpoints don't need one, so absence is
/// normal and must not be treated as an error.
enum ApiAuth {
    /// Header value for a session bearer, or `nil` when there's nothing to send.
    /// Blank/whitespace bearers are treated as absent rather than sent as
    /// `Bearer ` (which a server may reject outright).
    static func headerValue(bearer: String?) -> String? {
        guard let bearer,
              !bearer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return "Bearer \(bearer)"
    }

    /// A GET request for `url`, carrying the bearer when one exists.
    static func request(_ url: URL, bearer: String?) -> URLRequest {
        var req = URLRequest(url: url)
        if let value = headerValue(bearer: bearer) {
            req.setValue(value, forHTTPHeaderField: "Authorization")
        }
        return req
    }
}
