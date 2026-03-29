/**
 * Hardcore unit tests for the IRC protocol parser.
 *
 * The parser is the #1 attack surface: every byte from the server passes through it.
 * A parser bug here could enable XSS, state corruption, or identity confusion.
 */
import { describe, it, expect } from 'vitest';
import { parse, prefixNick, format } from './parser';

// ── parse() basic ────────────────────────────────────────────────────

describe('parse() basics', () => {
  it('parses a simple PRIVMSG', () => {
    const m = parse(':nick!user@host PRIVMSG #channel :hello world');
    expect(m.prefix).toBe('nick!user@host');
    expect(m.command).toBe('PRIVMSG');
    expect(m.params).toEqual(['#channel', 'hello world']);
  });

  it('parses a numeric response', () => {
    const m = parse(':server 001 nick :Welcome to IRC');
    expect(m.prefix).toBe('server');
    expect(m.command).toBe('001');
    expect(m.params).toEqual(['nick', 'Welcome to IRC']);
  });

  it('parses PING', () => {
    const m = parse('PING :server123');
    expect(m.command).toBe('PING');
    expect(m.params).toEqual(['server123']);
  });

  it('parses command with no params', () => {
    const m = parse('QUIT');
    expect(m.command).toBe('QUIT');
    expect(m.params).toEqual([]);
  });

  it('strips trailing CRLF', () => {
    const m = parse(':s PRIVMSG #c :text\r\n');
    expect(m.params[1]).toBe('text');
  });

  it('strips trailing LF', () => {
    const m = parse(':s PRIVMSG #c :text\n');
    expect(m.params[1]).toBe('text');
  });
});

// ── parse() tag handling ─────────────────────────────────────────────

describe('parse() IRCv3 tags', () => {
  it('parses simple tags', () => {
    const m = parse('@msgid=abc123 :nick PRIVMSG #c :test');
    expect(m.tags['msgid']).toBe('abc123');
    expect(m.command).toBe('PRIVMSG');
  });

  it('parses multiple tags', () => {
    const m = parse('@msgid=abc;time=2024-01-01T00:00:00Z :n PRIVMSG #c :t');
    expect(m.tags['msgid']).toBe('abc');
    expect(m.tags['time']).toBe('2024-01-01T00:00:00Z');
  });

  it('parses tag with no value', () => {
    const m = parse('@draft/reply :n PRIVMSG #c :t');
    expect(m.tags['draft/reply']).toBe('');
  });

  it('unescapes tag values (space)', () => {
    const m = parse('@key=hello\\sworld :n CMD');
    expect(m.tags['key']).toBe('hello world');
  });

  it('unescapes tag values (semicolon)', () => {
    const m = parse('@key=a\\:b :n CMD');
    expect(m.tags['key']).toBe('a;b');
  });

  it('unescapes tag values (backslash)', () => {
    const m = parse('@key=a\\\\b :n CMD');
    expect(m.tags['key']).toBe('a\\b');
  });

  it('unescapes tag values (CR and LF)', () => {
    const m = parse('@key=a\\rb\\nc :n CMD');
    expect(m.tags['key']).toBe('a\rb\nc');
  });

  it('handles tags with = in value', () => {
    // The first = splits key from value; subsequent = are part of the value
    const m = parse('@key=a=b=c :n CMD');
    expect(m.tags['key']).toBe('a=b=c');
  });

  it('handles empty tag string gracefully', () => {
    // @ followed by space (no tags)
    const m = parse('@ :n CMD');
    // Should not crash — tags object might have empty key
    expect(m.command).toBe('CMD');
  });

  it('handles tag with empty key', () => {
    const m = parse('@=value :n CMD');
    expect(m.tags['']).toBe('value');
  });

  it('handles very long tag value', () => {
    const longVal = 'x'.repeat(10000);
    const m = parse(`@key=${longVal} :n CMD`);
    expect(m.tags['key']).toBe(longVal);
  });
});

// ── parse() edge cases ───────────────────────────────────────────────

describe('parse() edge cases', () => {
  it('handles empty line', () => {
    const m = parse('');
    expect(m.command).toBe('');
    expect(m.params).toEqual([]);
  });

  it('handles line with only spaces', () => {
    const m = parse('   ');
    // Should not crash
    expect(m).toBeDefined();
  });

  it('handles empty prefix (just colon)', () => {
    const m = parse(': PRIVMSG #c :text');
    expect(m.prefix).toBe('');
    expect(m.command).toBe('PRIVMSG');
    expect(m.params).toEqual(['#c', 'text']);
  });

  it('handles multiple spaces between params', () => {
    // IRC spec says parameters are separated by single space
    // Multiple spaces might create empty params
    const m = parse(':n PRIVMSG  #c  :text');
    // The trailing :text should still parse correctly
    expect(m.params.some(p => p === 'text' || p.includes('text'))).toBe(true);
  });

  it('handles trailing colon with empty text', () => {
    const m = parse(':n PRIVMSG #c :');
    expect(m.params[m.params.length - 1]).toBe('');
  });

  it('handles param that starts with colon (trailing)', () => {
    const m = parse(':n PRIVMSG #c ::colons:everywhere:');
    expect(m.params[m.params.length - 1]).toBe(':colons:everywhere:');
  });

  it('command is uppercased', () => {
    const m = parse(':n privmsg #c :test');
    expect(m.command).toBe('PRIVMSG');
  });

  it('preserves param case', () => {
    const m = parse(':n PRIVMSG #Channel :Hello World');
    expect(m.params[0]).toBe('#Channel');
    expect(m.params[1]).toBe('Hello World');
  });

  it('handles message with only tags and command', () => {
    const m = parse('@key=val PING');
    expect(m.tags['key']).toBe('val');
    expect(m.command).toBe('PING');
    expect(m.params).toEqual([]);
  });

  it('handles nick with dots and dashes', () => {
    const m = parse(':user.name-123!~u@host PRIVMSG #c :test');
    expect(m.prefix).toBe('user.name-123!~u@host');
  });
});

// ── prefixNick() ─────────────────────────────────────────────────────

describe('prefixNick()', () => {
  it('extracts nick from full prefix', () => {
    expect(prefixNick('nick!user@host')).toBe('nick');
  });

  it('returns full string if no !', () => {
    expect(prefixNick('servername')).toBe('servername');
  });

  it('handles empty string', () => {
    expect(prefixNick('')).toBe('');
  });

  it('handles ! at start (empty nick)', () => {
    // ! at index 0 — i > 0 is false, returns full string
    expect(prefixNick('!user@host')).toBe('!user@host');
  });

  it('handles multiple !', () => {
    expect(prefixNick('nick!user!extra@host')).toBe('nick');
  });
});

// ── format() ─────────────────────────────────────────────────────────

describe('format()', () => {
  it('formats simple command', () => {
    expect(format('PRIVMSG', ['#channel', 'hello world'])).toBe('PRIVMSG #channel :hello world');
  });

  it('formats command with no params', () => {
    expect(format('QUIT', [])).toBe('QUIT');
  });

  it('formats with tags', () => {
    const line = format('PRIVMSG', ['#c', 'hello world'], { msgid: 'abc' });
    expect(line).toBe('@msgid=abc PRIVMSG #c :hello world');
  });

  it('colon-prefixes last param only when needed', () => {
    expect(format('JOIN', ['#channel'])).toBe('JOIN #channel');
    expect(format('PRIVMSG', ['#c', 'no spaces'])).toBe('PRIVMSG #c :no spaces');
  });

  it('colon-prefixes last param if it starts with colon', () => {
    expect(format('PRIVMSG', ['#c', ':starts with colon'])).toBe('PRIVMSG #c ::starts with colon');
  });

  it('escapes tag values', () => {
    const line = format('CMD', [], { key: 'a b' });
    expect(line).toContain('key=a\\sb');
  });

  it('escapes semicolons in tag values', () => {
    const line = format('CMD', [], { key: 'a;b' });
    expect(line).toContain('key=a\\:b');
  });

  it('escapes backslashes in tag values', () => {
    const line = format('CMD', [], { key: 'a\\b' });
    expect(line).toContain('key=a\\\\b');
  });

  it('empty tags object omits tag prefix', () => {
    const line = format('CMD', [], {});
    expect(line).toBe('CMD');
  });

  it('roundtrips parse → format → parse', () => {
    const original = '@msgid=test123;+reply=abc :nick!u@h PRIVMSG #channel :hello world';
    const parsed = parse(original);
    const formatted = format(parsed.command, parsed.params, parsed.tags);
    const reparsed = parse(formatted);
    expect(reparsed.command).toBe(parsed.command);
    expect(reparsed.params).toEqual(parsed.params);
    expect(reparsed.tags['msgid']).toBe(parsed.tags['msgid']);
  });
});

// ── Adversarial inputs ───────────────────────────────────────────────

describe('adversarial inputs', () => {
  it('handles null bytes in message text', () => {
    const m = parse(':n PRIVMSG #c :hello\x00world');
    expect(m.params[1]).toContain('hello');
    // Should not crash
  });

  it('handles control characters in prefix', () => {
    const m = parse(':\x01\x02nick\x03 PRIVMSG #c :test');
    expect(m.command).toBe('PRIVMSG');
    // Should parse without crash
  });

  it('handles extremely long line', () => {
    const longText = 'x'.repeat(100000);
    const m = parse(`:n PRIVMSG #c :${longText}`);
    expect(m.params[1].length).toBe(100000);
  });

  it('handles unicode in all positions', () => {
    const m = parse(':caf\u00e9!u@h PRIVMSG #\u00e9lite :\u{1F600} emoji');
    expect(prefixNick(m.prefix)).toBe('caf\u00e9');
    expect(m.params[0]).toBe('#\u00e9lite');
    expect(m.params[1]).toContain('\u{1F600}');
  });

  it('handles just @ (tags prefix with no content)', () => {
    // This is malformed — @ with no space after
    const m = parse('@');
    // Should not crash
    expect(m).toBeDefined();
  });

  it('handles message that is just a colon', () => {
    const m = parse(':');
    // Malformed — prefix with no command
    expect(m.command).toBe('');
  });

  it('handles tag value with all escaped characters', () => {
    const m = parse('@key=\\s\\:\\\\\\r\\n :n CMD');
    expect(m.tags['key']).toBe(' ;\\\r\n');
  });

  it('format escapes then parse unescapes (roundtrip)', () => {
    const original = ' ;\\\r\n';
    const formatted = format('CMD', [], { key: original });
    const parsed = parse(formatted);
    expect(parsed.tags['key']).toBe(original);
  });
});
