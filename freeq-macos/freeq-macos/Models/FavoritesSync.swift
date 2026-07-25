import Foundation

/// Roaming-favorites merge policy (shared with web + iOS): server order wins,
/// local-only favorites are appended so no device silently loses one on first
/// sync. Pure → unit-testable. Networking lives in `AppState`.
enum FavoritesSync {
    static func merge(server: [String], local: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in server + local {
            let k = c.lowercased()
            if k.isEmpty || seen.contains(k) { continue }
            seen.insert(k)
            out.append(k)
        }
        return out
    }

    static func equal(_ a: [String], _ b: [String]) -> Bool {
        a == b
    }

    /// Favorites naming a channel this device isn't joined to.
    ///
    /// Favorites roam per-DID, so a favorite set on another device can name a
    /// channel that isn't in this session's channel list. The sidebar renders
    /// favorites and non-favorites by filtering the *joined* list, so without
    /// this such a favorite appears in neither group — invisible and
    /// unreachable, which reads as "I can't find #freeq, how do I join it?".
    /// Callers surface these as join-on-click rows.
    ///
    /// DMs are excluded (only `#`-prefixed targets can be joined).
    static func unjoined(favorites: Set<String>, joined: [String]) -> [String] {
        let joinedLower = Set(joined.map { $0.lowercased() })
        return favorites
            .filter { $0.hasPrefix("#") && !joinedLower.contains($0.lowercased()) }
            .sorted()
    }
}
