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
}
