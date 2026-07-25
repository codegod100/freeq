/**
 * Roaming favorites: sync the user's favorite channels to the server (per-DID)
 * so they follow the user across devices. The server is the sync point
 * (REST /api/v1/favorites, Bearer-authed); localStorage stays the offline
 * cache. macOS/iOS use the same endpoint.
 */

/**
 * Merge server + local favorites: server order wins, local-only favorites are
 * appended (so no device silently loses a favorite on first sync). Pure +
 * order-stable → unit-testable, and shared conceptually with the native
 * clients' merge.
 */
export function mergeFavorites(server: string[], local: string[]): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const c of [...server, ...local]) {
    const k = c.toLowerCase();
    if (!k || seen.has(k)) continue;
    seen.add(k);
    out.push(k);
  }
  return out;
}

/** Two lists equal as ordered sequences. */
export function favoritesEqual(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

/**
 * Favorites naming a channel we aren't joined to in this session.
 *
 * Favorites roam per-DID, so a favorite set on another device can name a
 * channel absent from this session's list. The sidebar builds both its
 * Favorites and Channels groups by filtering the *joined* channels, so without
 * this such a favorite appears in neither — invisible and unreachable, which
 * reads as "I can't find #freeq, how do I join it?". Callers render these as
 * join-on-click rows.
 *
 * Only `#`/`&` targets are joinable, so DM favorites are excluded.
 * Returns lowercase names, sorted, deduped.
 */
export function unjoinedFavorites(favorites: Iterable<string>, joined: string[]): string[] {
  const joinedLower = new Set(joined.map((c) => c.toLowerCase()));
  const out = new Set<string>();
  for (const f of favorites) {
    const k = f.toLowerCase();
    if (!k.startsWith('#') && !k.startsWith('&')) continue;
    if (joinedLower.has(k)) continue;
    out.add(k);
  }
  return [...out].sort();
}

export async function fetchFavorites(bearer: string): Promise<string[]> {
  const r = await fetch('/api/v1/favorites', {
    headers: { Authorization: `Bearer ${bearer}` },
  });
  if (!r.ok) throw new Error(`favorites GET ${r.status}`);
  const j = await r.json();
  return Array.isArray(j.favorites) ? j.favorites.map(String) : [];
}

export async function pushFavorites(bearer: string, favorites: string[]): Promise<void> {
  const r = await fetch('/api/v1/favorites', {
    method: 'PUT',
    headers: { Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ favorites }),
  });
  if (!r.ok) throw new Error(`favorites PUT ${r.status}`);
}
