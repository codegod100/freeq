/**
 * REST helper: attach the session bearer to API calls.
 *
 * Channel-scoped read endpoints (`/pins`, `/audit`, `/events`, `/sessions`,
 * `/topic`, `/history`, `/export`, and the governance endpoints) all enforce the
 * same access rule as history: a mode-restricted channel (+i / +k / encrypted)
 * is refused unless the bearer resolves to a member, op or founder. A bare
 * `fetch()` therefore works for public channels and silently 403s for private
 * ones — which is exactly the sort of thing that looks fine in dev and breaks
 * for the people who care most about privacy.
 *
 * The bearer arrives asynchronously (API-BEARER notice, shortly after
 * `registered`), so callers must tolerate its absence: guests never get one, and
 * public endpoints don't need it.
 */
import { getClient } from '../irc/client';

/** Merge `Authorization: Bearer …` into `extra` when a session bearer exists. */
export function authHeaders(extra?: HeadersInit): HeadersInit {
  const bearer = getClient()?.apiBearer;
  if (!bearer) return extra ?? {};
  const h = new Headers(extra ?? {});
  h.set('Authorization', `Bearer ${bearer}`);
  return h;
}

/** `fetch` with the session bearer attached when available. */
export function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
  return fetch(path, { ...init, headers: authHeaders(init.headers) });
}
