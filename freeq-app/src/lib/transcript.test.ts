import { describe, it, expect } from 'vitest';
import { buildTranscript } from './transcript';
import type { Message } from '../store';

function m(from: string, text: string, extra: Partial<Message> = {}): Message {
  return { id: Math.random().toString(), from, text, timestamp: new Date(), tags: {}, ...extra };
}

describe('buildTranscript', () => {
  it('renders Name: message per line', () => {
    expect(buildTranscript([m('vrypan', 'hello'), m('chad', 'hi')]))
      .toBe('vrypan: hello\nchad: hi');
  });

  it('resolves display names', () => {
    const names: Record<string, string> = { 'chad.com': 'Chad Fowler' };
    expect(buildTranscript([m('chad.com', 'yo')], (n) => names[n] ?? n))
      .toBe('Chad Fowler: yo');
  });

  it('skips system and deleted', () => {
    const out = buildTranscript([
      m('a', 'one'),
      m('', 'x joined', { isSystem: true }),
      m('b', 'gone', { deleted: true }),
      m('c', 'two'),
    ]);
    expect(out).toBe('a: one\nc: two');
  });

  it('renders actions as emotes', () => {
    expect(buildTranscript([m('chad', 'waves', { isAction: true })])).toBe('* chad waves');
  });

  it('empty selection → empty string', () => {
    expect(buildTranscript([])).toBe('');
    expect(buildTranscript([m('', 'sys', { isSystem: true })])).toBe('');
  });
});
