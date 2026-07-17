/** Wired identity display — the standard resolution sources in one place.
 *
 * `resolveIdentityName` in `./identity` stays pure (and unit-tested); this is
 * the app-wired convenience that plugs in the two sources every surface uses:
 * the SDK's learned nick↔DID map, then the cached AT profile. Use it anywhere
 * a conversation/thread key is shown to a human, so a DID-keyed DM never
 * renders as a raw `did:plc:…` / `did:key:…` string.
 */
import { getClient } from '../irc/client';
import { getCachedProfile } from './profiles';
import { resolveIdentityName } from './identity';

/** Human label for a thread key or identifier that may be a raw DID. */
export function displayNameForKey(key: string): string {
  return resolveIdentityName(key, {
    nickForDid: (did) => getClient()?.getNickForDid(did),
    nameForDid: (did) => {
      const p = getCachedProfile(did);
      return p?.handle || p?.displayName;
    },
  });
}
