/**
 * Pure sound-design policy for notifications — no DOM/AudioContext, so it's
 * unit-testable and importable anywhere. `notifications.ts` consumes it.
 */
export type NotifyKind = 'mention' | 'dm' | 'message';

/**
 * Note frequencies (Hz) for each notification kind. A DM is a direct ping
 * (3-note rising, brighter); a mention is the classic two-tone chime; a
 * generic message is a single soft tone.
 */
export function soundRecipe(kind: NotifyKind): number[] {
  switch (kind) {
    case 'dm': return [659.25, 783.99, 1046.5]; // E5 → G5 → C6
    case 'mention': return [523.25, 659.25];    // C5 → E5
    case 'message': return [587.33];            // D5
  }
}
