import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// The helper reads the bearer off the singleton SDK client, so stub that module.
const mockClient: { apiBearer: string | null } = { apiBearer: null };
vi.mock('../irc/client', () => ({
  getClient: () => mockClient,
}));

import { authHeaders, apiFetch } from './api';

describe('authHeaders', () => {
  beforeEach(() => {
    mockClient.apiBearer = null;
  });

  it('omits Authorization when there is no session bearer (guests)', () => {
    const h = new Headers(authHeaders());
    expect(h.has('Authorization')).toBe(false);
  });

  it('attaches the bearer when a session exists', () => {
    mockClient.apiBearer = 'sess-abc';
    const h = new Headers(authHeaders());
    expect(h.get('Authorization')).toBe('Bearer sess-abc');
  });

  it('preserves caller-supplied headers', () => {
    mockClient.apiBearer = 'sess-abc';
    const h = new Headers(authHeaders({ 'Content-Type': 'application/json' }));
    expect(h.get('Content-Type')).toBe('application/json');
    expect(h.get('Authorization')).toBe('Bearer sess-abc');
  });

  it('does not let a caller-supplied Authorization shadow the session bearer', () => {
    mockClient.apiBearer = 'sess-real';
    const h = new Headers(authHeaders({ Authorization: 'Bearer stale' }));
    expect(h.get('Authorization')).toBe('Bearer sess-real');
  });
});

describe('apiFetch', () => {
  const realFetch = globalThis.fetch;
  beforeEach(() => {
    mockClient.apiBearer = null;
    globalThis.fetch = vi.fn(async () => new Response('{}', { status: 200 })) as never;
  });
  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  it('sends the bearer so private-channel endpoints do not 403', async () => {
    mockClient.apiBearer = 'sess-xyz';
    await apiFetch('/api/v1/channels/%23secret/pins');
    const [, init] = (globalThis.fetch as unknown as { mock: { calls: [string, RequestInit][] } })
      .mock.calls[0];
    expect(new Headers(init.headers).get('Authorization')).toBe('Bearer sess-xyz');
  });

  it('keeps the caller’s method and body intact', async () => {
    mockClient.apiBearer = 'sess-xyz';
    await apiFetch('/api/v1/favorites', { method: 'PUT', body: '{"favorites":[]}' });
    const [, init] = (globalThis.fetch as unknown as { mock: { calls: [string, RequestInit][] } })
      .mock.calls[0];
    expect(init.method).toBe('PUT');
    expect(init.body).toBe('{"favorites":[]}');
  });
});
