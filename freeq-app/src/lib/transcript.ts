import type { Message } from '../store';

/**
 * Clean, paste-friendly plain-text transcript of a run of messages — the web
 * analogue of the macOS `MessageTranscript`. The point is the opposite of what
 * a raw DOM copy gives you: no timestamps, no "(edited)", no reaction tallies,
 * no avatars-as-blank-lines. Just `Name: message`, one per entry.
 *
 * - system lines (empty `from` / isSystem) are skipped (presence noise)
 * - deleted tombstones are skipped
 * - actions render as `* Name text`
 * - `displayName` resolves a wire nick to the shown name (defaults to nick)
 */
export function buildTranscript(
  messages: Message[],
  displayName: (nick: string) => string = (n) => n,
): string {
  const lines: string[] = [];
  for (const m of messages) {
    if (m.deleted) continue;
    if (!m.from || m.isSystem) continue;
    const name = displayName(m.from) || m.from;
    if (m.isAction) {
      lines.push(`* ${name} ${m.text}`);
    } else {
      lines.push(`${name}: ${m.text}`);
    }
  }
  return lines.join('\n');
}
