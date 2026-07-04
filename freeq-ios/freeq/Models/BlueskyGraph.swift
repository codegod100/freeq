import Foundation

/// A person in the AT Protocol social graph, resolved from the public Bluesky
/// AppView. `did` is the stable, verified identity — the same anchor freeq
/// binds at SASL — so a freeq member and a Bluesky account are the same person
/// when their DIDs match.
struct BskyActor: Identifiable, Equatable, Hashable {
    var id: String { did }
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
    let description: String?

    /// Best human label: display name if set, else the handle.
    var title: String {
        if let d = displayName, !d.trimmingCharacters(in: .whitespaces).isEmpty { return d }
        return handle
    }

    static func parse(_ json: [String: Any]) -> BskyActor? {
        guard let did = json["did"] as? String,
              let handle = json["handle"] as? String else { return nil }
        return BskyActor(
            did: did,
            handle: handle,
            displayName: json["displayName"] as? String,
            avatar: json["avatar"] as? String,
            description: json["description"] as? String
        )
    }
}

/// Read-only client for the AT Protocol social graph via the *public* Bluesky
/// AppView (no auth, no viewer context). This is freeq's differentiator made
/// navigable: search people by verified identity and walk anyone's follow
/// graph. Viewer-relative queries (mutuals, "follows you", follow/unfollow)
/// need the authenticated session and are a separate step.
enum BlueskyGraph {
    private static let base = "https://public.api.bsky.app/xrpc"

    /// Search people by name or handle. Empty query → [].
    static func searchActors(_ query: String, limit: Int = 25) async -> [BskyActor] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let url = "\(base)/app.bsky.actor.searchActors?limit=\(limit)&q=\(enc(q))"
        return await fetchActors(url, key: "actors")
    }

    /// Accounts that follow `actor` (a DID or handle).
    static func followers(of actor: String, limit: Int = 60) async -> [BskyActor] {
        let url = "\(base)/app.bsky.graph.getFollowers?limit=\(limit)&actor=\(enc(actor))"
        return await fetchActors(url, key: "followers")
    }

    /// Accounts `actor` follows (a DID or handle).
    static func follows(of actor: String, limit: Int = 60) async -> [BskyActor] {
        let url = "\(base)/app.bsky.graph.getFollows?limit=\(limit)&actor=\(enc(actor))"
        return await fetchActors(url, key: "follows")
    }

    // MARK: - Plumbing

    private static func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
    }

    private static func fetchActors(_ urlStr: String, key: String) async -> [BskyActor] {
        guard let url = URL(string: urlStr) else { return [] }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = json[key] as? [[String: Any]] else { return [] }
            return arr.compactMap(BskyActor.parse)
        } catch {
            return []
        }
    }
}
