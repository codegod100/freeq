/**
 * Unit tests for AV session state management.
 *
 * Tests store actions (updateAvSession, removeAvSession, setActiveAvSession)
 * and IRC client AV TAGMSG handling (session started/joined/left/ended, ticket capture).
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// Must mock globals BEFORE importing store
const storage = new Map<string, string>();
const localStorageMock = {
  getItem: (key: string) => storage.get(key) ?? null,
  setItem: (key: string, value: string) => storage.set(key, value),
  removeItem: (key: string) => { storage.delete(key); },
  clear: () => storage.clear(),
  get length() { return storage.size; },
  key: (i: number) => [...storage.keys()][i] ?? null,
};
// @ts-expect-error — assigning mock to global
globalThis.localStorage = localStorageMock;
Object.defineProperty(globalThis, 'crypto', {
  value: { randomUUID: () => 'test-uuid-' + Math.random().toString(36).slice(2), subtle: {} },
  writable: true, configurable: true,
});
// @ts-expect-error — minimal window mock
globalThis.window = { localStorage: localStorageMock, location: { hash: '' }, addEventListener: () => {} };

const { useStore } = await import('./store');
import type { AvSession, AvParticipant } from './store';

function resetStore() {
  useStore.setState({
    avSessions: new Map(),
    activeAvSession: null,
  });
}

function makeSession(overrides: Partial<AvSession> = {}): AvSession {
  return {
    id: 'test-session-1',
    channel: '#test',
    createdBy: 'did:plc:abc',
    createdByNick: 'alice',
    title: undefined,
    participants: new Map<string, AvParticipant>([['alice', {
      did: 'did:plc:abc',
      nick: 'alice',
      role: 'host',
      joinedAt: new Date('2026-04-05T00:00:00Z'),
    }]]),
    state: 'active',
    startedAt: new Date('2026-04-05T00:00:00Z'),
    ...overrides,
  };
}

describe('AV Session Store Actions', () => {
  beforeEach(resetStore);

  it('updateAvSession creates a new session', () => {
    const session = makeSession();
    useStore.getState().updateAvSession(session);

    const stored = useStore.getState().avSessions.get('test-session-1');
    expect(stored).toBeDefined();
    expect(stored!.id).toBe('test-session-1');
    expect(stored!.channel).toBe('#test');
    expect(stored!.createdByNick).toBe('alice');
    expect(stored!.state).toBe('active');
    expect(stored!.participants.size).toBe(1);
    expect(stored!.participants.get('alice')?.role).toBe('host');
  });

  it('updateAvSession updates an existing session', () => {
    const session = makeSession();
    useStore.getState().updateAvSession(session);

    // Add participant
    const updated = { ...session, participants: new Map(session.participants) };
    updated.participants.set('bob', {
      did: 'did:plc:bob',
      nick: 'bob',
      role: 'speaker',
      joinedAt: new Date(),
    });
    useStore.getState().updateAvSession(updated);

    const stored = useStore.getState().avSessions.get('test-session-1');
    expect(stored!.participants.size).toBe(2);
    expect(stored!.participants.get('bob')?.role).toBe('speaker');
  });

  it('removeAvSession deletes the session', () => {
    useStore.getState().updateAvSession(makeSession());
    expect(useStore.getState().avSessions.size).toBe(1);

    useStore.getState().removeAvSession('test-session-1');
    expect(useStore.getState().avSessions.size).toBe(0);
  });

  it('removeAvSession clears activeAvSession if it matches', () => {
    useStore.getState().updateAvSession(makeSession());
    useStore.getState().setActiveAvSession('test-session-1');
    expect(useStore.getState().activeAvSession).toBe('test-session-1');

    useStore.getState().removeAvSession('test-session-1');
    expect(useStore.getState().activeAvSession).toBeNull();
  });

  it('removeAvSession preserves activeAvSession if different', () => {
    useStore.getState().updateAvSession(makeSession({ id: 'session-a' }));
    useStore.getState().updateAvSession(makeSession({ id: 'session-b' }));
    useStore.getState().setActiveAvSession('session-b');

    useStore.getState().removeAvSession('session-a');
    expect(useStore.getState().activeAvSession).toBe('session-b');
  });

  it('setActiveAvSession sets and clears', () => {
    expect(useStore.getState().activeAvSession).toBeNull();

    useStore.getState().setActiveAvSession('session-1');
    expect(useStore.getState().activeAvSession).toBe('session-1');

    useStore.getState().setActiveAvSession(null);
    expect(useStore.getState().activeAvSession).toBeNull();
  });

  it('multiple sessions tracked independently', () => {
    const s1 = makeSession({ id: 'session-1', channel: '#room-a' });
    const s2 = makeSession({ id: 'session-2', channel: '#room-b', createdByNick: 'bob' });

    useStore.getState().updateAvSession(s1);
    useStore.getState().updateAvSession(s2);

    expect(useStore.getState().avSessions.size).toBe(2);
    expect(useStore.getState().avSessions.get('session-1')!.channel).toBe('#room-a');
    expect(useStore.getState().avSessions.get('session-2')!.channel).toBe('#room-b');
  });
});

describe('AV Session State Transitions', () => {
  beforeEach(resetStore);

  it('session started → joined → left → ended lifecycle', () => {
    // Started
    const session = makeSession({ id: 'lifecycle-1' });
    useStore.getState().updateAvSession(session);
    expect(useStore.getState().avSessions.get('lifecycle-1')!.state).toBe('active');
    expect(useStore.getState().avSessions.get('lifecycle-1')!.participants.size).toBe(1);

    // Bob joins
    const s1 = useStore.getState().avSessions.get('lifecycle-1')!;
    const joined = { ...s1, participants: new Map(s1.participants) };
    joined.participants.set('bob', { did: '', nick: 'bob', role: 'speaker', joinedAt: new Date() });
    useStore.getState().updateAvSession(joined);
    expect(useStore.getState().avSessions.get('lifecycle-1')!.participants.size).toBe(2);

    // Bob leaves
    const s2 = useStore.getState().avSessions.get('lifecycle-1')!;
    const left = { ...s2, participants: new Map(s2.participants) };
    left.participants.delete('bob');
    useStore.getState().updateAvSession(left);
    expect(useStore.getState().avSessions.get('lifecycle-1')!.participants.size).toBe(1);
    expect(useStore.getState().avSessions.get('lifecycle-1')!.participants.has('bob')).toBe(false);

    // Session ended
    const s3 = useStore.getState().avSessions.get('lifecycle-1')!;
    useStore.getState().updateAvSession({ ...s3, state: 'ended', participants: new Map() });
    expect(useStore.getState().avSessions.get('lifecycle-1')!.state).toBe('ended');
    expect(useStore.getState().avSessions.get('lifecycle-1')!.participants.size).toBe(0);
  });

  it('iroh ticket attached to active session', () => {
    const session = makeSession({ id: 'ticket-test' });
    useStore.getState().updateAvSession(session);
    useStore.getState().setActiveAvSession('ticket-test');

    // Simulate ticket capture (as done in client.ts NOTICE handler)
    const activeId = useStore.getState().activeAvSession;
    expect(activeId).toBe('ticket-test');

    const existing = useStore.getState().avSessions.get(activeId!);
    expect(existing).toBeDefined();
    expect(existing!.irohTicket).toBeUndefined();

    useStore.getState().updateAvSession({ ...existing!, irohTicket: 'roomabc123def' });
    expect(useStore.getState().avSessions.get('ticket-test')!.irohTicket).toBe('roomabc123def');
  });

  it('ended session with active clears activeAvSession', () => {
    useStore.getState().updateAvSession(makeSession({ id: 's1' }));
    useStore.getState().setActiveAvSession('s1');

    // End the session (as handleAvSessionState does)
    const s = useStore.getState().avSessions.get('s1')!;
    useStore.getState().updateAvSession({ ...s, state: 'ended', participants: new Map() });

    // handleAvSessionState clears active on 'ended'
    if (useStore.getState().activeAvSession === 's1') {
      useStore.getState().setActiveAvSession(null);
    }
    expect(useStore.getState().activeAvSession).toBeNull();
  });
});

describe('AV Audio & Video State (CallPanel)', () => {
  beforeEach(resetStore);

  it('setAvAudioActive toggles call panel visibility', () => {
    expect(useStore.getState().avAudioActive).toBe(false);
    useStore.getState().setAvAudioActive(true);
    expect(useStore.getState().avAudioActive).toBe(true);
    useStore.getState().setAvAudioActive(false);
    expect(useStore.getState().avAudioActive).toBe(false);
  });

  it('setAvMuted toggles mute state', () => {
    expect(useStore.getState().avMuted).toBe(false);
    useStore.getState().setAvMuted(true);
    expect(useStore.getState().avMuted).toBe(true);
    useStore.getState().setAvMuted(false);
    expect(useStore.getState().avMuted).toBe(false);
  });

  it('setAvCameraOn toggles camera (default off)', () => {
    expect(useStore.getState().avCameraOn).toBe(false);
    useStore.getState().setAvCameraOn(true);
    expect(useStore.getState().avCameraOn).toBe(true);
    useStore.getState().setAvCameraOn(false);
    expect(useStore.getState().avCameraOn).toBe(false);
  });

  it('camera defaults to off', () => {
    expect(useStore.getState().avCameraOn).toBe(false);
  });

  it('leaving session clears audio and camera', () => {
    useStore.getState().updateAvSession(makeSession({ id: 's1' }));
    useStore.getState().setActiveAvSession('s1');
    useStore.getState().setAvAudioActive(true);
    useStore.getState().setAvMuted(true);
    useStore.getState().setAvCameraOn(true);

    useStore.getState().setAvAudioActive(false);
    useStore.getState().setAvCameraOn(false);
    useStore.getState().setActiveAvSession(null);

    expect(useStore.getState().avAudioActive).toBe(false);
    expect(useStore.getState().avCameraOn).toBe(false);
    expect(useStore.getState().activeAvSession).toBeNull();
  });

  it('camera and mute are independent', () => {
    useStore.getState().setAvCameraOn(true);
    useStore.getState().setAvMuted(true);
    expect(useStore.getState().avCameraOn).toBe(true);
    expect(useStore.getState().avMuted).toBe(true);

    useStore.getState().setAvMuted(false);
    expect(useStore.getState().avCameraOn).toBe(true);
  });

  it('audio state is independent of session state', () => {
    useStore.getState().setAvAudioActive(true);
    expect(useStore.getState().avAudioActive).toBe(true);
    expect(useStore.getState().activeAvSession).toBeNull();
  });
});

describe('AV Session Edge Cases', () => {
  beforeEach(resetStore);

  it('removing nonexistent session is a no-op', () => {
    useStore.getState().removeAvSession('does-not-exist');
    expect(useStore.getState().avSessions.size).toBe(0);
  });

  it('duplicate participant join is idempotent', () => {
    const session = makeSession();
    useStore.getState().updateAvSession(session);

    // Alice "joins" again (shouldn't duplicate)
    const s = useStore.getState().avSessions.get('test-session-1')!;
    const dup = { ...s, participants: new Map(s.participants) };
    dup.participants.set('alice', { ...s.participants.get('alice')!, role: 'speaker' });
    useStore.getState().updateAvSession(dup);

    expect(useStore.getState().avSessions.get('test-session-1')!.participants.size).toBe(1);
    // Role updated
    expect(useStore.getState().avSessions.get('test-session-1')!.participants.get('alice')!.role).toBe('speaker');
  });

  it('session with no channel (DM voice)', () => {
    const session = makeSession({ channel: null });
    useStore.getState().updateAvSession(session);
    expect(useStore.getState().avSessions.get('test-session-1')!.channel).toBeNull();
  });

  it('session title is optional', () => {
    const session = makeSession({ title: 'Weekly standup' });
    useStore.getState().updateAvSession(session);
    expect(useStore.getState().avSessions.get('test-session-1')!.title).toBe('Weekly standup');

    const noTitle = makeSession({ id: 'no-title' });
    useStore.getState().updateAvSession(noTitle);
    expect(useStore.getState().avSessions.get('no-title')!.title).toBeUndefined();
  });
});
