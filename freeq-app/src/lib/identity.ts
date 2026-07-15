/** Identity display for DM thread keys and message authors.
 *
 * With DIDs as the load-bearing identity, a DM thread is keyed by the peer's
 * DID (see the SDK's `address.ts`), so the buffer name reaching the UI can be
 * a raw `did:plc:…` / `did:key:…` string. These helpers turn that into a human
 * name, resolving against data the client already holds and falling back to a
 * compact form only when nothing resolves. Display-only — the raw DID stays
 * the identity the app operates on (DMs, blocks, reports).
 */

/** A syntactic DID: `did:<method>:<id>`. No network, no `id` validation. */
export function isDid(s: string): boolean {
  return /^did:[a-z0-9]+:.+/i.test(s);
}

/** Compact a DID for display: `did:plc:k2n3…t5j7`. Non-DIDs pass through. */
export function shortenDid(s: string): string {
  if (!isDid(s)) return s;
  const [, method, ...idParts] = s.split(':');
  const id = idParts.join(':');
  if (id.length <= 12) return `${method}:${id}`;
  return `${method}:${id.slice(0, 4)}…${id.slice(-4)}`;
}

/**
 * Human name for a DM thread key or author identifier that may be a raw DID.
 * A non-DID (an ordinary nick) is returned unchanged. A DID is resolved
 * through the provided sources in order — the SDK's learned nick↔DID map, then
 * a cached AT profile handle/display name — and only compacted with
 * `shortenDid` when every source misses. Sources that themselves return a DID
 * (or nothing) are skipped, so we never present one DID in place of another.
 */
export function resolveIdentityName(
  id: string,
  sources: {
    nickForDid?: (did: string) => string | undefined | null;
    nameForDid?: (did: string) => string | undefined | null;
  } = {},
): string {
  if (!isDid(id)) return id;
  for (const src of [sources.nickForDid, sources.nameForDid]) {
    const v = src?.(id);
    if (v && !isDid(v)) return v;
  }
  return shortenDid(id);
}
