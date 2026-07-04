import Foundation

/// What freeq knows about an AT Protocol identity — the bridge between the
/// Bluesky social graph and freeq itself. Resolved from `/api/v1/actors/{did}`.
///
/// The important field is `nick`: if it's present, this person is a freeq user
/// we can actually talk to (DM, see in channels), not just a Bluesky account.
struct FreeqIdentity: Equatable {
    let did: String
    let online: Bool
    let nick: String?
    let handle: String?
    let channels: [String]
    let actorClass: String   // "human" | "agent"

    /// True when this identity is a known freeq participant (has a nick), so
    /// freeq actions (Message, shared channels, presence) are meaningful.
    var isOnFreeq: Bool { nick != nil }
    var isAgent: Bool { actorClass == "agent" }

    static func parse(_ did: String, _ json: [String: Any]) -> FreeqIdentity {
        FreeqIdentity(
            did: did,
            online: json["online"] as? Bool ?? false,
            nick: (json["nick"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            handle: json["handle"] as? String,
            channels: json["channels"] as? [String] ?? [],
            actorClass: json["actor_class"] as? String ?? "human"
        )
    }
}

/// Resolves DIDs to their freeq identity, with a short in-memory cache so a
/// scroll through a follow list doesn't re-hit the server per row.
actor FreeqDirectory {
    static let shared = FreeqDirectory()

    private var cache: [String: (at: Date, value: FreeqIdentity)] = [:]
    private let ttl: TimeInterval = 60

    /// Resolve one DID. Returns nil only on a transport/parse failure (an
    /// unknown-but-reachable DID still returns an identity with `nick == nil`).
    func identity(for did: String) async -> FreeqIdentity? {
        if let hit = cache[did], Date().timeIntervalSince(hit.at) < ttl {
            return hit.value
        }
        let base = ServerConfig.apiBaseUrl
        let encoded = did.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? did
        guard let url = URL(string: "\(base)/api/v1/actors/\(encoded)") else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let identity = FreeqIdentity.parse(did, json)
            cache[did] = (Date(), identity)
            return identity
        } catch {
            return nil
        }
    }

    /// Resolve many DIDs concurrently (bounded), returning a did→identity map
    /// for the ones that resolved.
    func identities(for dids: [String]) async -> [String: FreeqIdentity] {
        var out: [String: FreeqIdentity] = [:]
        // Bounded concurrency so a big follow list doesn't open 200 sockets.
        let chunkSize = 12
        for chunk in stride(from: 0, to: dids.count, by: chunkSize).map({ Array(dids[$0..<min($0 + chunkSize, dids.count)]) }) {
            await withTaskGroup(of: (String, FreeqIdentity?).self) { group in
                for did in chunk {
                    group.addTask { (did, await self.identity(for: did)) }
                }
                for await (did, identity) in group {
                    if let identity { out[did] = identity }
                }
            }
        }
        return out
    }
}
