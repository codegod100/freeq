import { describe, it, expect } from 'vitest';
import { soundRecipe } from './notification-sound';

describe('soundRecipe', () => {
  it('gives each kind a distinct tone sequence', () => {
    expect(soundRecipe('dm')).not.toEqual(soundRecipe('mention'));
    expect(soundRecipe('mention')).not.toEqual(soundRecipe('message'));
    expect(soundRecipe('dm')).not.toEqual(soundRecipe('message'));
  });
  it('a DM is the most attention-grabbing (3 rising notes)', () => {
    const dm = soundRecipe('dm');
    expect(dm.length).toBe(3);
    expect(dm[0]).toBeLessThan(dm[1]);
    expect(dm[1]).toBeLessThan(dm[2]);
  });
  it('a generic message is a single soft tone', () => {
    expect(soundRecipe('message')).toHaveLength(1);
  });
  it('all frequencies are audible', () => {
    for (const k of ['dm', 'mention', 'message'] as const)
      for (const f of soundRecipe(k)) expect(f).toBeGreaterThan(100);
  });
});
