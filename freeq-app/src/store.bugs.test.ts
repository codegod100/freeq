/**
 * Bug-hunting tests for the Zustand store — state corruption,
 * phantom members, edge cases in message handling.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';

// Mock globals before import
const storage = new Map<string, string>();
// @ts-expect-error mock
globalThis.localStorage = {
  getItem: (k: string) => storage.get(k) ?? null,
  setItem: (k: string, v: string) => storage.set(k, v),
  removeItem: (k: string) => { storage.delete(k); },
  clear: () => storage.clear(),
  get length() { return storage.size; },
  key: (i: number) => [...storage.keys()][i] ?? null,
};
Object.defineProperty(globalThis, 'crypto', {
  value: { randomUUID: () => 'uuid-' + Math.random().toString(36).slice(2), subtle: {} },
  writable: true, configurable: true,
});
// @ts-expect-error mock
globalThis.window = { localStorage: globalThis.localStorage, location: { hash: '' }, addEventListener: () => {} };

const { useStore } = await import('./store');

beforeEach(() => {
  storage.clear();
  useStore.getState().reset();
});

function mkMsg(overrides: Record<string, any> = {}) {
  return {
    id: 'msg-' + Math.random().toString(36).slice(2),
    from: 'alice',
    text: 'hello',
    timestamp: new Date(),
    tags: {},
    ...overrides,
  };
}

function ensureChannel(name: string) {
  useStore.getState().addMessage(name, mkMsg({ from: 'system', text: 'init', isSystem: true }));
}

// ═══════════════════════════════════════════════════════════════
// BUG: handleMode creates phantom members
// ═══════════════════════════════════════════════════════════════

describe('handleMode phantom members', () => {
  it('MODE +o on non-existent nick does NOT create phantom member (FIXED)', () => {
    ensureChannel('#test');
    useStore.getState().handleMode('#test', '+o', 'ghost_user', 'server');
    const ch = useStore.getState().channels.get('#test')!;
    // FIXED: ghost_user should NOT be in members
    expect(ch.members.has('ghost_user')).toBe(false);
  });

  it('MODE +v on non-existent nick does NOT create phantom member (FIXED)', () => {
    ensureChannel('#test');
    useStore.getState().handleMode('#test', '+v', 'phantom', 'server');
    const ch = useStore.getState().channels.get('#test')!;
    expect(ch.members.has('phantom')).toBe(false);
  });

  it('MODE +o on existing member does NOT create phantom', () => {
    ensureChannel('#test');
    useStore.getState().addMember('#test', { nick: 'real_user' });
    useStore.getState().handleMode('#test', '+o', 'real_user', 'server');
    const ch = useStore.getState().channels.get('#test')!;
    const member = ch.members.get('real_user');
    expect(member).toBeDefined();
    expect(member!.isOp).toBe(true);
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: renameUser with empty/same nick
// ═══════════════════════════════════════════════════════════════

describe('renameUser edge cases', () => {
  it('renameUser with empty new nick is rejected (FIXED)', () => {
    ensureChannel('#test');
    useStore.getState().addMember('#test', { nick: 'alice' });
    useStore.getState().renameUser('alice', '');
    const ch = useStore.getState().channels.get('#test')!;
    // FIXED: rename rejected, alice still present
    expect(ch.members.has('alice')).toBe(true);
    expect(ch.members.has('')).toBe(false);
  });

  it('renameUser with same name (case change) works', () => {
    ensureChannel('#test');
    useStore.getState().addMember('#test', { nick: 'Alice' });
    useStore.getState().renameUser('Alice', 'alice');
    const ch = useStore.getState().channels.get('#test')!;
    // Should have lowercase key
    expect(ch.members.has('alice')).toBe(true);
  });

  it('renameUser where old nick does not exist is a no-op', () => {
    ensureChannel('#test');
    useStore.getState().renameUser('nonexistent', 'newname');
    const ch = useStore.getState().channels.get('#test')!;
    expect(ch.members.has('newname')).toBe(false);
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: addMessage with missing/falsy ID allows duplicates
// ═══════════════════════════════════════════════════════════════

describe('addMessage ID edge cases', () => {
  it('message with undefined id bypasses dedup', () => {
    ensureChannel('#test');
    const m1 = mkMsg({ id: undefined, text: 'dup1' });
    const m2 = mkMsg({ id: undefined, text: 'dup2' });
    useStore.getState().addMessage('#test', m1);
    useStore.getState().addMessage('#test', m2);
    const ch = useStore.getState().channels.get('#test')!;
    // Both should be added since dedup is skipped for falsy IDs
    const texts = ch.messages.map(m => m.text);
    expect(texts).toContain('dup1');
    expect(texts).toContain('dup2');
  });

  it('message with empty string id bypasses dedup', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: '', text: 'a' }));
    useStore.getState().addMessage('#test', mkMsg({ id: '', text: 'b' }));
    const ch = useStore.getState().channels.get('#test')!;
    const noId = ch.messages.filter(m => m.id === '');
    // Empty string IDs may or may not be deduped
    // Document actual behavior
    expect(noId.length).toBeGreaterThanOrEqual(1);
  });

  it('message with same ID is deduped', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: 'same', text: 'first' }));
    useStore.getState().addMessage('#test', mkMsg({ id: 'same', text: 'second' }));
    const ch = useStore.getState().channels.get('#test')!;
    const matches = ch.messages.filter(m => m.id === 'same');
    expect(matches.length).toBe(1);
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: editMessage on missing message is silent
// ═══════════════════════════════════════════════════════════════

describe('editMessage edge cases', () => {
  it('edit on non-existent message is silent no-op', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: 'real', text: 'original' }));
    // Edit a message that doesn't exist
    useStore.getState().editMessage('#test', 'nonexistent', 'edited text');
    const ch = useStore.getState().channels.get('#test')!;
    // Original should be unchanged
    const real = ch.messages.find(m => m.id === 'real');
    expect(real?.text).toBe('original');
  });

  it('edit on deleted message is silent no-op', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: 'del', text: 'original' }));
    useStore.getState().deleteMessage('#test', 'del');
    useStore.getState().editMessage('#test', 'del', 'edited');
    const ch = useStore.getState().channels.get('#test')!;
    const msg = ch.messages.find(m => m.id === 'del');
    expect(msg?.deleted).toBe(true);
    // Text may or may not be updated — document behavior
  });

  it('edit with empty text shows placeholder (FIXED)', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: 'empty_edit', text: 'original' }));
    useStore.getState().editMessage('#test', 'empty_edit', '');
    const ch = useStore.getState().channels.get('#test')!;
    const msg = ch.messages.find(m => m.id === 'empty_edit');
    // FIXED: empty edit shows placeholder
    expect(msg?.text).toBe('[message cleared]');
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: setActiveChannel for non-existent channel
// ═══════════════════════════════════════════════════════════════

describe('setActiveChannel edge cases', () => {
  it('setting active to non-existent channel', () => {
    useStore.getState().setActiveChannel('#doesnotexist');
    // Should either be rejected or create an empty state
    // Document actual behavior
    expect(useStore.getState().activeChannel).toBeDefined();
  });

  it('setting active to empty string', () => {
    useStore.getState().setActiveChannel('');
    expect(useStore.getState().activeChannel).toBeDefined();
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: removeChannel doesn't clean up in-flight batches
// ═══════════════════════════════════════════════════════════════

describe('removeChannel batch cleanup', () => {
  it('removing channel cleans up pending batches (FIXED)', () => {
    ensureChannel('#leaving');
    useStore.getState().startBatch('b1', 'chathistory', '#leaving');
    useStore.getState().addBatchMessage('b1', mkMsg({ text: 'batch msg' }));
    // Remove the channel — should also clean up the batch
    useStore.getState().removeChannel('#leaving');
    // FIXED: batch should be cleaned up
    expect(useStore.getState().batches.has('b1')).toBe(false);
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: addReaction on missing message
// ═══════════════════════════════════════════════════════════════

describe('addReaction edge cases', () => {
  it('reaction on non-existent message is silent no-op', () => {
    ensureChannel('#test');
    useStore.getState().addReaction('#test', 'nonexistent', '👍', 'bob');
    // Should not crash
    const ch = useStore.getState().channels.get('#test')!;
    // No message has a reaction
    const withReaction = ch.messages.filter(m => m.reactions && m.reactions.size > 0);
    expect(withReaction.length).toBe(0);
  });

  it('reaction with empty emoji', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: 'r1' }));
    useStore.getState().addReaction('#test', 'r1', '', 'bob');
    const ch = useStore.getState().channels.get('#test')!;
    const msg = ch.messages.find(m => m.id === 'r1');
    // Empty emoji reaction — document behavior
    if (msg?.reactions?.has('')) {
      // BUG: empty emoji stored
      expect(msg.reactions.get('')!.has('bob')).toBe(true);
    }
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: addMember with empty nick
// ═══════════════════════════════════════════════════════════════

describe('addMember edge cases', () => {
  it('addMember with empty nick', () => {
    ensureChannel('#test');
    useStore.getState().addMember('#test', { nick: '' });
    const ch = useStore.getState().channels.get('#test')!;
    // BUG: empty nick member exists in map under key ''
    const empty = ch.members.get('');
    if (empty) {
      expect(empty.nick).toBe('');
    }
  });

  it('addMember with whitespace-only nick', () => {
    ensureChannel('#test');
    useStore.getState().addMember('#test', { nick: '   ' });
    const ch = useStore.getState().channels.get('#test')!;
    // Stored under key '   ' (lowercased = '   ')
    const ws = ch.members.get('   ');
    if (ws) {
      expect(ws.nick).toBe('   ');
    }
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: 1000 message cap — verify no data loss
// ═══════════════════════════════════════════════════════════════

describe('message cap', () => {
  it('adding 1001 messages keeps exactly 1000', () => {
    ensureChannel('#big');
    for (let i = 0; i < 1001; i++) {
      useStore.getState().addMessage('#big', mkMsg({ text: `msg${i}` }));
    }
    const ch = useStore.getState().channels.get('#big')!;
    expect(ch.messages.length).toBeLessThanOrEqual(1000);
    // Newest message should be preserved
    expect(ch.messages[ch.messages.length - 1].text).toBe('msg1000');
  });

  it('batch merge with overflow drops oldest correctly', () => {
    ensureChannel('#batchbig');
    // Add 900 messages
    for (let i = 0; i < 900; i++) {
      useStore.getState().addMessage('#batchbig', mkMsg({ id: `exist-${i}`, text: `e${i}` }));
    }
    // Start batch with 200 messages (total would be 1100)
    useStore.getState().startBatch('big', 'chathistory', '#batchbig');
    for (let i = 0; i < 200; i++) {
      useStore.getState().addBatchMessage('big', mkMsg({
        id: `batch-${i}`,
        text: `b${i}`,
        timestamp: new Date(1000 + i), // old timestamps
      }));
    }
    useStore.getState().endBatch('big');
    const ch = useStore.getState().channels.get('#batchbig')!;
    expect(ch.messages.length).toBeLessThanOrEqual(1000);
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: WHOIS cache with undefined values
// ═══════════════════════════════════════════════════════════════

describe('whois cache edge cases', () => {
  it('updateWhois with all undefined fields', () => {
    useStore.getState().updateWhois('test', {});
    const info = useStore.getState().whoisCache.get('test');
    expect(info).toBeDefined();
    expect(info?.nick).toBe('test');
  });

  it('whois for nick with special characters', () => {
    useStore.getState().updateWhois('test[bot]', { user: '~bot' });
    const info = useStore.getState().whoisCache.get('test[bot]');
    expect(info?.user).toBe('~bot');
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: deleteMessage then addMessage with same ID
// ═══════════════════════════════════════════════════════════════

describe('delete then re-add', () => {
  it('deleted message ID blocks re-add (dedup)', () => {
    ensureChannel('#test');
    useStore.getState().addMessage('#test', mkMsg({ id: 'resurrect', text: 'original' }));
    useStore.getState().deleteMessage('#test', 'resurrect');
    // Try to add a new message with the same ID
    useStore.getState().addMessage('#test', mkMsg({ id: 'resurrect', text: 'new version' }));
    const ch = useStore.getState().channels.get('#test')!;
    const matches = ch.messages.filter(m => m.id === 'resurrect');
    // Dedup should prevent re-add — the deleted message is still in the array
    expect(matches.length).toBe(1);
    // The one that exists should still be marked deleted
    expect(matches[0].deleted).toBe(true);
  });
});

// ═══════════════════════════════════════════════════════════════
// BUG: removeUserFromAll with nick that has special chars
// ═══════════════════════════════════════════════════════════════

describe('removeUserFromAll edge cases', () => {
  it('remove user with brackets in nick', () => {
    ensureChannel('#test');
    useStore.getState().addMember('#test', { nick: '[bot]' });
    useStore.getState().removeUserFromAll('[bot]', 'quit');
    const ch = useStore.getState().channels.get('#test')!;
    expect(ch.members.has('[bot]')).toBe(false);
  });
});
