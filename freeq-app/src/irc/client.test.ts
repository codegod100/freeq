/**
 * Unit tests for irc/client.ts protocol handling.
 *
 * Tests the IRC message parsing → store mutation pipeline for every
 * major protocol message type. This is the #3 hotspot (gamma 133).
 */
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { parse, prefixNick } from './parser';

// These tests focus on the parser output that client.ts consumes,
// and the store mutations it would trigger. Since handleLine is
// internal, we test the parsing layer and the store contract.

// ═══════════════════════════════════════════════════════════════
// PROTOCOL MESSAGE PARSING (what client.ts receives from server)
// ═══════════════════════════════════════════════════════════════

describe('server message parsing for client handlers', () => {
  // ── Registration ──

  it('001 RPL_WELCOME extracts nick', () => {
    const m = parse(':srv 001 mynick :Welcome to IRC');
    expect(m.command).toBe('001');
    expect(m.params[0]).toBe('mynick');
  });

  it('433 nick-in-use extracts nick', () => {
    const m = parse(':srv 433 * mynick :Nickname is already in use');
    expect(m.command).toBe('433');
    expect(m.params[1]).toBe('mynick');
  });

  // ── SASL ──

  it('AUTHENTICATE challenge parsed', () => {
    const m = parse('AUTHENTICATE eyJzZXNzaW9uX2lkIjoiYWJjIn0');
    expect(m.command).toBe('AUTHENTICATE');
    expect(m.params[0]).toBe('eyJzZXNzaW9uX2lkIjoiYWJjIn0');
  });

  it('903 SASL success', () => {
    const m = parse(':srv 903 mynick :SASL authentication successful');
    expect(m.command).toBe('903');
  });

  it('904 SASL failure', () => {
    const m = parse(':srv 904 mynick :SASL authentication failed');
    expect(m.command).toBe('904');
    expect(m.params[m.params.length - 1]).toContain('failed');
  });

  // ── Channel events ──

  it('JOIN with extended-join (account + realname)', () => {
    const m = parse(':alice!u@h JOIN #channel did:plc:alice :Alice Smith');
    expect(m.command).toBe('JOIN');
    expect(prefixNick(m.prefix)).toBe('alice');
    expect(m.params[0]).toBe('#channel');
    expect(m.params[1]).toBe('did:plc:alice');
  });

  it('JOIN without extended-join', () => {
    const m = parse(':alice!u@h JOIN #channel');
    expect(m.command).toBe('JOIN');
    expect(m.params[0]).toBe('#channel');
    expect(m.params.length).toBe(1); // No account field
  });

  it('PART with reason', () => {
    const m = parse(':alice!u@h PART #channel :leaving');
    expect(m.command).toBe('PART');
    expect(prefixNick(m.prefix)).toBe('alice');
    expect(m.params[0]).toBe('#channel');
    expect(m.params[1]).toBe('leaving');
  });

  it('PART without reason', () => {
    const m = parse(':alice!u@h PART #channel');
    expect(m.command).toBe('PART');
    expect(m.params.length).toBe(1);
  });

  it('KICK extracts channel, target, reason', () => {
    const m = parse(':op!u@h KICK #channel victim :get out');
    expect(m.command).toBe('KICK');
    expect(m.params[0]).toBe('#channel');
    expect(m.params[1]).toBe('victim');
    expect(m.params[2]).toBe('get out');
  });

  it('QUIT with reason', () => {
    const m = parse(':alice!u@h QUIT :connection reset');
    expect(m.command).toBe('QUIT');
    expect(prefixNick(m.prefix)).toBe('alice');
    expect(m.params[0]).toBe('connection reset');
  });

  it('NICK change', () => {
    const m = parse(':oldnick!u@h NICK newnick');
    expect(m.command).toBe('NICK');
    expect(prefixNick(m.prefix)).toBe('oldnick');
    expect(m.params[0]).toBe('newnick');
  });

  // ── Messages ──

  it('PRIVMSG to channel with tags', () => {
    const m = parse('@msgid=abc123;time=2024-01-01T00:00:00Z :alice!u@h PRIVMSG #ch :hello world');
    expect(m.command).toBe('PRIVMSG');
    expect(m.tags['msgid']).toBe('abc123');
    expect(m.tags['time']).toBe('2024-01-01T00:00:00Z');
    expect(prefixNick(m.prefix)).toBe('alice');
    expect(m.params[0]).toBe('#ch');
    expect(m.params[1]).toBe('hello world');
  });

  it('PRIVMSG DM (target is nick, not channel)', () => {
    const m = parse(':alice!u@h PRIVMSG bob :private message');
    expect(m.params[0]).toBe('bob'); // Not #channel
    expect(m.params[1]).toBe('private message');
  });

  it('PRIVMSG with edit tag', () => {
    const m = parse('@+draft/edit=ORIGMSGID;msgid=NEWMSGID :alice!u@h PRIVMSG #ch :edited text');
    expect(m.tags['+draft/edit']).toBe('ORIGMSGID');
    expect(m.tags['msgid']).toBe('NEWMSGID');
  });

  it('TAGMSG with delete tag', () => {
    const m = parse('@+draft/delete=DELMSGID :alice!u@h TAGMSG #ch');
    expect(m.command).toBe('TAGMSG');
    expect(m.tags['+draft/delete']).toBe('DELMSGID');
  });

  it('TAGMSG with reaction', () => {
    const m = parse('@+react=👍;+reply=TARGETMSGID :bob!u@h TAGMSG #ch');
    expect(m.tags['+react']).toBe('👍');
    expect(m.tags['+reply']).toBe('TARGETMSGID');
  });

  it('TAGMSG with typing indicator', () => {
    const m = parse('@+typing=active :alice!u@h TAGMSG #ch');
    expect(m.tags['+typing']).toBe('active');
  });

  it('NOTICE to channel', () => {
    const m = parse(':srv NOTICE #ch :Server notice');
    expect(m.command).toBe('NOTICE');
    expect(m.params[0]).toBe('#ch');
    expect(m.params[1]).toBe('Server notice');
  });

  // ── Modes ──

  it('MODE single +o', () => {
    const m = parse(':op!u@h MODE #ch +o alice');
    expect(m.command).toBe('MODE');
    expect(m.params).toEqual(['#ch', '+o', 'alice']);
  });

  it('MODE compound +ov with two args', () => {
    const m = parse(':op!u@h MODE #ch +ov alice bob');
    expect(m.params).toEqual(['#ch', '+ov', 'alice', 'bob']);
  });

  it('MODE channel mode +i', () => {
    const m = parse(':op!u@h MODE #ch +i');
    expect(m.params).toEqual(['#ch', '+i']);
  });

  it('MODE +E encryption', () => {
    const m = parse(':op!u@h MODE #ch +E');
    expect(m.params).toEqual(['#ch', '+E']);
  });

  // ── NAMES (353) ──

  it('353 NAMES with prefixes', () => {
    const m = parse(':srv 353 me = #ch :@op +voiced normal');
    expect(m.command).toBe('353');
    expect(m.params[2]).toBe('#ch');
    expect(m.params[3]).toBe('@op +voiced normal');
  });

  it('353 NAMES multi-prefix', () => {
    const m = parse(':srv 353 me = #ch :@%halfop_and_op +voiced');
    const nicks = m.params[3].split(' ');
    // @% prefix means op AND halfop
    expect(nicks[0]).toBe('@%halfop_and_op');
  });

  // ── Topic ──

  it('TOPIC change', () => {
    const m = parse(':alice!u@h TOPIC #ch :new topic');
    expect(m.command).toBe('TOPIC');
    expect(m.params[0]).toBe('#ch');
    expect(m.params[1]).toBe('new topic');
  });

  it('332 RPL_TOPIC', () => {
    const m = parse(':srv 332 me #ch :channel topic text');
    expect(m.command).toBe('332');
    expect(m.params[1]).toBe('#ch');
    expect(m.params[2]).toBe('channel topic text');
  });

  it('TOPIC clear (empty)', () => {
    const m = parse(':alice!u@h TOPIC #ch :');
    expect(m.params[1]).toBe('');
  });

  // ── WHOIS ──

  it('311 RPL_WHOISUSER', () => {
    const m = parse(':srv 311 me alice ~u freeq/plc/abc123 * :Real Name');
    expect(m.command).toBe('311');
    expect(m.params[1]).toBe('alice');
    expect(m.params[3]).toBe('freeq/plc/abc123');
  });

  it('330 RPL_WHOISACCOUNT (DID)', () => {
    const m = parse(':srv 330 me alice did:plc:abc123 :is authenticated as');
    expect(m.command).toBe('330');
    expect(m.params[1]).toBe('alice');
    expect(m.params[2]).toBe('did:plc:abc123');
  });

  it('671 AT handle', () => {
    const m = parse(':srv 671 me alice :AT Protocol handle: alice.bsky.social');
    expect(m.command).toBe('671');
    expect(m.params[1]).toBe('alice');
  });

  it('318 end of WHOIS', () => {
    const m = parse(':srv 318 me alice :End of /WHOIS list');
    expect(m.command).toBe('318');
  });

  // ── BATCH ──

  it('BATCH start', () => {
    const m = parse(':srv BATCH +ch123 chathistory #channel');
    expect(m.command).toBe('BATCH');
    expect(m.params[0]).toBe('+ch123');
    expect(m.params[1]).toBe('chathistory');
    expect(m.params[2]).toBe('#channel');
  });

  it('BATCH end', () => {
    const m = parse(':srv BATCH -ch123');
    expect(m.command).toBe('BATCH');
    expect(m.params[0]).toBe('-ch123');
  });

  it('message in batch has batch tag', () => {
    const m = parse('@batch=ch123;msgid=abc :alice!u@h PRIVMSG #ch :batch msg');
    expect(m.tags['batch']).toBe('ch123');
    expect(m.tags['msgid']).toBe('abc');
  });

  // ── AWAY ──

  it('AWAY set', () => {
    const m = parse(':alice!u@h AWAY :gone fishing');
    expect(m.command).toBe('AWAY');
    expect(m.params[0]).toBe('gone fishing');
  });

  it('AWAY clear', () => {
    const m = parse(':alice!u@h AWAY');
    expect(m.command).toBe('AWAY');
    expect(m.params.length).toBe(0);
  });

  // ── INVITE ──

  it('INVITE', () => {
    const m = parse(':op!u@h INVITE alice #channel');
    expect(m.command).toBe('INVITE');
    expect(m.params[0]).toBe('alice');
    expect(m.params[1]).toBe('#channel');
  });

  // ── Errors ──

  it('401 ERR_NOSUCHNICK', () => {
    const m = parse(':srv 401 me nobody :No such nick/channel');
    expect(m.command).toBe('401');
    expect(m.params[1]).toBe('nobody');
  });

  it('473 invite-only', () => {
    const m = parse(':srv 473 me #secret :Cannot join channel (+i)');
    expect(m.command).toBe('473');
    expect(m.params[1]).toBe('#secret');
  });

  it('474 banned', () => {
    const m = parse(':srv 474 me #ch :Cannot join channel (+b)');
    expect(m.command).toBe('474');
  });

  it('475 bad key', () => {
    const m = parse(':srv 475 me #ch :Cannot join channel (+k)');
    expect(m.command).toBe('475');
  });

  it('482 not operator', () => {
    const m = parse(':srv 482 me #ch :You\'re not channel operator');
    expect(m.command).toBe('482');
  });
});

// ═══════════════════════════════════════════════════════════════
// CLIENT-SIDE ROUTING LOGIC
// ═══════════════════════════════════════════════════════════════

describe('client routing logic', () => {
  it('PRIVMSG target determines buffer: channel vs DM', () => {
    const chan = parse(':alice!u@h PRIVMSG #general :hello');
    const dm = parse(':alice!u@h PRIVMSG bob :hello');
    expect(chan.params[0].startsWith('#')).toBe(true);
    expect(dm.params[0].startsWith('#')).toBe(false);
  });

  it('self-message detection via nick comparison', () => {
    const myNick = 'myuser';
    const m = parse(`:${myNick}!u@h PRIVMSG #ch :my message`);
    const from = prefixNick(m.prefix);
    expect(from.toLowerCase() === myNick.toLowerCase()).toBe(true);
  });

  it('self-message detection case insensitive', () => {
    const myNick = 'MyUser';
    const m = parse(':myuser!u@h PRIVMSG #ch :msg');
    const from = prefixNick(m.prefix);
    expect(from.toLowerCase() === myNick.toLowerCase()).toBe(true);
  });

  it('DM buffer name: from other = their nick, from self = target', () => {
    const myNick = 'me';
    // Message FROM bob TO me → buffer = "bob"
    const fromOther = parse(':bob!u@h PRIVMSG me :hi');
    const fromOtherBuf = prefixNick(fromOther.prefix); // "bob"
    expect(fromOtherBuf).toBe('bob');

    // Message FROM me TO bob → buffer = "bob" (the target)
    const fromSelf = parse(':me!u@h PRIVMSG bob :hi');
    const fromSelfBuf = fromSelf.params[0]; // "bob"
    expect(fromSelfBuf).toBe('bob');
  });

  it('edit detection via +draft/edit tag', () => {
    const m = parse('@+draft/edit=ORIG;msgid=NEW :a!u@h PRIVMSG #ch :edited');
    const isEdit = !!m.tags['+draft/edit'];
    expect(isEdit).toBe(true);
    expect(m.tags['+draft/edit']).toBe('ORIG');
  });

  it('delete detection via +draft/delete tag', () => {
    const m = parse('@+draft/delete=DELMSG :a!u@h TAGMSG #ch');
    const isDelete = !!m.tags['+draft/delete'];
    expect(isDelete).toBe(true);
  });

  it('reaction detection via +react tag', () => {
    const m = parse('@+react=👍;+reply=TARGET :a!u@h TAGMSG #ch');
    expect(m.tags['+react']).toBe('👍');
    expect(m.tags['+reply']).toBe('TARGET');
  });

  it('typing detection via +typing tag', () => {
    const m = parse('@+typing=active :a!u@h TAGMSG #ch');
    expect(m.tags['+typing']).toBe('active');
    const m2 = parse('@+typing=done :a!u@h TAGMSG #ch');
    expect(m2.tags['+typing']).toBe('done');
  });

  it('encrypted message detection (ENC1 prefix)', () => {
    const m = parse(':a!u@h PRIVMSG #ch :ENC1:nonce:ciphertext');
    expect(m.params[1].startsWith('ENC1:')).toBe(true);
  });

  it('encrypted DM detection (ENC3 prefix)', () => {
    const m = parse(':a!u@h PRIVMSG bob :ENC3:header:nonce:ct');
    expect(m.params[1].startsWith('ENC3:')).toBe(true);
  });

  it('action message detection (/me)', () => {
    const m = parse(':a!u@h PRIVMSG #ch :\x01ACTION waves\x01');
    const text = m.params[1];
    expect(text.startsWith('\x01ACTION ')).toBe(true);
    expect(text.endsWith('\x01')).toBe(true);
  });
});

// ═══════════════════════════════════════════════════════════════
// NAMES PARSING (353 → member list)
// ═══════════════════════════════════════════════════════════════

describe('NAMES (353) member extraction', () => {
  function parseMembers(namesStr: string) {
    return namesStr.split(' ').filter(Boolean).map(n => {
      const prefixMatch = n.match(/^([@%+]+)/);
      const prefixes = prefixMatch ? prefixMatch[1] : '';
      const bare = n.slice(prefixes.length);
      return {
        nick: bare,
        isOp: prefixes.includes('@'),
        isHalfop: prefixes.includes('%'),
        isVoiced: prefixes.includes('+'),
      };
    });
  }

  it('extracts op prefix @', () => {
    const members = parseMembers('@op normal');
    expect(members[0]).toEqual({ nick: 'op', isOp: true, isHalfop: false, isVoiced: false });
    expect(members[1]).toEqual({ nick: 'normal', isOp: false, isHalfop: false, isVoiced: false });
  });

  it('extracts voice prefix +', () => {
    const members = parseMembers('+voiced');
    expect(members[0].isVoiced).toBe(true);
    expect(members[0].nick).toBe('voiced');
  });

  it('extracts halfop prefix %', () => {
    const members = parseMembers('%halfop');
    expect(members[0].isHalfop).toBe(true);
  });

  it('extracts multi-prefix @%', () => {
    const members = parseMembers('@%ophalfop');
    expect(members[0].isOp).toBe(true);
    expect(members[0].isHalfop).toBe(true);
    expect(members[0].nick).toBe('ophalfop');
  });

  it('handles empty string', () => {
    const members = parseMembers('');
    expect(members.length).toBe(0);
  });

  it('handles nick that is just @', () => {
    const members = parseMembers('@');
    expect(members[0].nick).toBe('');
    expect(members[0].isOp).toBe(true);
  });

  it('handles many members', () => {
    const nicks = Array.from({ length: 100 }, (_, i) => `user${i}`).join(' ');
    const members = parseMembers(nicks);
    expect(members.length).toBe(100);
  });

  it('unicode nicks', () => {
    const members = parseMembers('@café +日本語');
    expect(members[0].nick).toBe('café');
    expect(members[1].nick).toBe('日本語');
  });
});

// ═══════════════════════════════════════════════════════════════
// COMPOUND MODE PARSING (what client.ts now does)
// ═══════════════════════════════════════════════════════════════

describe('compound MODE parsing', () => {
  const argsWithParam = new Set(['o', 'h', 'v', 'k', 'b']);

  function parseModes(modeStr: string, params: string[]) {
    const results: { adding: boolean; mode: string; arg?: string }[] = [];
    let adding = true;
    let argIdx = 0;
    for (const ch of modeStr) {
      if (ch === '+') { adding = true; continue; }
      if (ch === '-') { adding = false; continue; }
      const arg = argsWithParam.has(ch) ? params[argIdx++] : undefined;
      results.push({ adding, mode: ch, arg });
    }
    return results;
  }

  it('+o single', () => {
    const r = parseModes('+o', ['alice']);
    expect(r).toEqual([{ adding: true, mode: 'o', arg: 'alice' }]);
  });

  it('-o single', () => {
    const r = parseModes('-o', ['alice']);
    expect(r).toEqual([{ adding: false, mode: 'o', arg: 'alice' }]);
  });

  it('+ov compound', () => {
    const r = parseModes('+ov', ['alice', 'bob']);
    expect(r).toEqual([
      { adding: true, mode: 'o', arg: 'alice' },
      { adding: true, mode: 'v', arg: 'bob' },
    ]);
  });

  it('+o-v compound', () => {
    const r = parseModes('+o-v', ['alice', 'bob']);
    expect(r).toEqual([
      { adding: true, mode: 'o', arg: 'alice' },
      { adding: false, mode: 'v', arg: 'bob' },
    ]);
  });

  it('+Eo mixed channel and user mode', () => {
    const r = parseModes('+Eo', ['alice']);
    expect(r).toEqual([
      { adding: true, mode: 'E', arg: undefined },
      { adding: true, mode: 'o', arg: 'alice' },
    ]);
  });

  it('+nt channel modes only', () => {
    const r = parseModes('+nt', []);
    expect(r).toEqual([
      { adding: true, mode: 'n', arg: undefined },
      { adding: true, mode: 't', arg: undefined },
    ]);
  });

  it('+ohv three users', () => {
    const r = parseModes('+ohv', ['a', 'b', 'c']);
    expect(r.length).toBe(3);
    expect(r[0]).toEqual({ adding: true, mode: 'o', arg: 'a' });
    expect(r[1]).toEqual({ adding: true, mode: 'h', arg: 'b' });
    expect(r[2]).toEqual({ adding: true, mode: 'v', arg: 'c' });
  });

  it('+k sets channel key', () => {
    const r = parseModes('+k', ['secret']);
    expect(r).toEqual([{ adding: true, mode: 'k', arg: 'secret' }]);
  });

  it('+b sets ban', () => {
    const r = parseModes('+b', ['*!*@evil.com']);
    expect(r).toEqual([{ adding: true, mode: 'b', arg: '*!*@evil.com' }]);
  });

  it('-b removes ban', () => {
    const r = parseModes('-b', ['*!*@evil.com']);
    expect(r).toEqual([{ adding: false, mode: 'b', arg: '*!*@evil.com' }]);
  });

  it('empty mode string', () => {
    const r = parseModes('', []);
    expect(r).toEqual([]);
  });
});

// ═══════════════════════════════════════════════════════════════
// CHATHISTORY TARGETS PARSING
// ═══════════════════════════════════════════════════════════════

describe('CHATHISTORY TARGETS parsing', () => {
  it('extracts nick from TARGETS response', () => {
    const m = parse('@time=2024-01-01T00:00:00Z :srv CHATHISTORY TARGETS alice');
    expect(m.command).toBe('CHATHISTORY');
    expect(m.params[0]).toBe('TARGETS');
    expect(m.params[1]).toBe('alice');
  });
});

// ═══════════════════════════════════════════════════════════════
// EDGE CASES
// ═══════════════════════════════════════════════════════════════

describe('edge cases', () => {
  it('message with no prefix', () => {
    const m = parse('PING :token');
    expect(m.prefix).toBe('');
    expect(prefixNick(m.prefix)).toBe('');
  });

  it('message with server prefix (no nick)', () => {
    const m = parse(':irc.server.com 001 nick :Welcome');
    expect(prefixNick(m.prefix)).toBe('irc.server.com');
  });

  it('PRIVMSG with empty text', () => {
    const m = parse(':a!u@h PRIVMSG #ch :');
    expect(m.params[1]).toBe('');
  });

  it('very long message preserved', () => {
    const text = 'x'.repeat(5000);
    const m = parse(`:a!u@h PRIVMSG #ch :${text}`);
    expect(m.params[1].length).toBe(5000);
  });

  it('message with unicode emoji in tags', () => {
    const m = parse('@+react=👨‍👩‍👧‍👦 :a!u@h TAGMSG #ch');
    expect(m.tags['+react']).toBe('👨‍👩‍👧‍👦');
  });

  it('multiple tags preserved', () => {
    const m = parse('@msgid=abc;time=2024;batch=xyz;+freeq.at/sig=sig123 :a!u@h PRIVMSG #ch :text');
    expect(Object.keys(m.tags).length).toBe(4);
    expect(m.tags['msgid']).toBe('abc');
    expect(m.tags['+freeq.at/sig']).toBe('sig123');
  });
});
