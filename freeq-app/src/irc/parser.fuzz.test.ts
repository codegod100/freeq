/**
 * Fuzz / edge-case tests for the IRC parser targeting crashes and
 * malformed input handling.
 */
import { describe, it, expect } from 'vitest';
import { parse, prefixNick, format } from './parser';

describe('parser crash cases', () => {
  // BUG 1: @ with no space — tag parsing reads garbage
  it('handles @ with no space after tags', () => {
    const m = parse('@key=val');
    // Should not crash. Command may be empty or garbled.
    expect(m).toBeDefined();
  });

  it('handles bare @ only', () => {
    const m = parse('@');
    expect(m).toBeDefined();
    expect(m.command).toBeDefined();
  });

  it('handles @tag with no command', () => {
    const m = parse('@key=val ONLY');
    expect(m.command).toBe('ONLY');
    expect(m.tags['key']).toBe('val');
  });

  // BUG 2: prefix with no space/command
  it('handles :prefix with no command', () => {
    const m = parse(':server');
    // Should not crash. Prefix should be extracted, command may be garbled.
    expect(m).toBeDefined();
  });

  it('handles :prefix with trailing space only', () => {
    const m = parse(':server ');
    expect(m.prefix).toBe('server');
    expect(m.command).toBe('');
  });

  // BUG 3: empty string
  it('handles empty string without crash', () => {
    const m = parse('');
    expect(m.command).toBe('');
    expect(m.params).toEqual([]);
  });

  it('handles whitespace only', () => {
    const m = parse('   ');
    expect(m).toBeDefined();
  });

  it('handles just CRLF', () => {
    const m = parse('\r\n');
    expect(m.command).toBe('');
  });

  // Null bytes
  it('handles null bytes in message', () => {
    const m = parse(':n PRIVMSG #c :\x00hello\x00');
    expect(m.command).toBe('PRIVMSG');
    expect(m.params.length).toBe(2);
  });

  // Very long tag value (memory)
  it('handles 1MB tag value without crash', () => {
    const big = 'x'.repeat(1_000_000);
    const m = parse(`@key=${big} :n CMD`);
    expect(m.tags['key'].length).toBe(1_000_000);
  });

  // Tag with empty key
  it('handles tag with empty key (=value)', () => {
    const m = parse('@=value :n CMD');
    expect(m.tags['']).toBe('value');
  });

  // Tag with no = at all
  it('handles tag key with no equals', () => {
    const m = parse('@flagonly :n CMD');
    expect(m.tags['flagonly']).toBe('');
  });

  // Multiple ;; in tags (empty tags)
  it('handles consecutive semicolons in tags', () => {
    const m = parse('@a=1;;b=2 :n CMD');
    expect(m.tags['a']).toBe('1');
    expect(m.tags['b']).toBe('2');
  });

  // Prefix is just ":"
  it('handles lone colon as prefix', () => {
    const m = parse(': CMD param');
    expect(m.prefix).toBe('');
    expect(m.command).toBe('CMD');
  });

  // Double colon prefix
  it('handles double colon prefix', () => {
    const m = parse('::weird CMD');
    expect(m).toBeDefined();
  });

  // Trailing param that is just ":"
  it('handles trailing param that is empty (just colon)', () => {
    const m = parse(':n CMD target :');
    expect(m.params[m.params.length - 1]).toBe('');
  });

  // Command only, no prefix, no params
  it('handles bare command', () => {
    const m = parse('PING');
    expect(m.command).toBe('PING');
    expect(m.params).toEqual([]);
  });

  // Tag escape edge: backslash at end of value
  it('handles trailing backslash in tag value', () => {
    const m = parse('@key=value\\ :n CMD');
    // Trailing backslash should be preserved (no char to escape)
    expect(m.tags['key']).toBeDefined();
  });

  // XSS attempt in tag value
  it('tag value with HTML is just a string', () => {
    const m = parse('@key=<script>alert(1)</script> :n CMD');
    expect(m.tags['key']).toBe('<script>alert(1)</script>');
    // It's just a string — XSS only matters if rendered as HTML (React prevents this)
  });

  // XSS in message text
  it('message text with HTML is just a string', () => {
    const m = parse(':n PRIVMSG #c :<img src=x onerror=alert(1)>');
    expect(m.params[1]).toBe('<img src=x onerror=alert(1)>');
  });

  // Unicode edge cases
  it('handles zero-width characters', () => {
    const m = parse(':n\u200B PRIVMSG #c :text');
    expect(m).toBeDefined();
  });

  it('handles RTL override character', () => {
    const m = parse(':n PRIVMSG #c :\u202Ereversed');
    expect(m.params[1]).toContain('\u202E');
  });
});

describe('format edge cases', () => {
  it('format with empty command', () => {
    const line = format('', []);
    expect(line).toBe('');
  });

  it('format with undefined-like tag values', () => {
    const line = format('CMD', [], { key: '' });
    // Empty value should just be key (no =value)
    expect(line).toContain('key');
  });

  it('roundtrip complex message', () => {
    const original = '@msgid=abc;+freeq.at/sig=xyz :nick!u@h PRIVMSG #channel :hello world with spaces';
    const p = parse(original);
    const f = format(p.command, p.params, p.tags);
    const p2 = parse(f);
    expect(p2.command).toBe(p.command);
    expect(p2.params).toEqual(p.params);
    expect(p2.tags['msgid']).toBe(p.tags['msgid']);
  });
});
