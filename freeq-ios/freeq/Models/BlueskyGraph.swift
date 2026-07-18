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

    /// Viewer-relative relationship between `viewer` and another account.
    struct Relationship {
        let followsMe: Bool   // they follow the viewer
        let iFollow: Bool     // the viewer follows them
        /// at:// URI of the viewer's follow record (needed to unfollow).
        let followingURI: String?
        var isMutual: Bool { followsMe && iFollow }
    }

    /// Resolve how `viewer` relates to each of `others` (batched ≤30 per call —
    /// the endpoint's limit). Public endpoint; no auth needed.
    static func relationships(viewer: String, others: [String]) async -> [String: Relationship] {
        guard !others.isEmpty else { return [:] }
        var out: [String: Relationship] = [:]
        for chunk in stride(from: 0, to: others.count, by: 30)
            .map({ Array(others[$0..<min($0 + 30, others.count)]) }) {
            let othersParam = chunk.map(enc).joined(separator: "&others=")
            let url = "\(base)/app.bsky.graph.getRelationships?actor=\(enc(viewer))&others=\(othersParam)"
            guard let u = URL(string: url) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: u)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rels = json["relationships"] as? [[String: Any]] else { continue }
                for rel in rels {
                    guard let did = rel["did"] as? String else { continue }
                    out[did] = Relationship(
                        followsMe: rel["followedBy"] != nil,
                        iFollow: rel["following"] != nil,
                        followingURI: rel["following"] as? String
                    )
                }
            } catch { continue }
        }
        return out
    }

    // MARK: - Follow / unfollow (broker-delegated writes)

    enum FollowOutcome {
        case done
        /// The deployed broker predates the graph endpoints (404/405) — hide
        /// the affordance instead of erroring.
        case unsupported
        case failed(String)
    }

    /// True once we've seen the broker 404 the graph endpoints this launch.
    private(set) static var followUnsupported = false

    /// Follow `subjectDID` — the broker writes the record to the user's own
    /// PDS with its stored OAuth session (the client never holds the token).
    static func follow(subjectDID: String, brokerToken: String) async -> FollowOutcome {
        await graphWrite(path: "follow", body: ["broker_token": brokerToken, "subject_did": subjectDID])
    }

    /// Unfollow via the at:// URI of the existing follow record.
    static func unfollow(followURI: String, brokerToken: String) async -> FollowOutcome {
        await graphWrite(path: "unfollow", body: ["broker_token": brokerToken, "follow_uri": followURI])
    }

    private static func graphWrite(path: String, body: [String: String]) async -> FollowOutcome {
        guard !followUnsupported else { return .unsupported }
        guard let url = URL(string: "\(ServerConfig.authBrokerBase)/api/graph/\(path)") else {
            return .failed("Bad broker URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200: return .done
            case 404, 405:
                followUnsupported = true
                return .unsupported
            default:
                let text = String(data: data, encoding: .utf8) ?? ""
                return .failed(text.isEmpty ? "HTTP \(code)" : text)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
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
