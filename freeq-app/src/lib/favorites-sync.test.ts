import { describe, it, expect } from 'vitest';
import { mergeFavorites, favoritesEqual } from './favorites-sync';

describe('mergeFavorites', () => {
  it('server order wins, local-only appended', () => {
    expect(mergeFavorites(['#a', '#b'], ['#b', '#c'])).toEqual(['#a', '#b', '#c']);
  });
  it('dedups case-insensitively and lowercases', () => {
    expect(mergeFavorites(['#A'], ['#a', '#B'])).toEqual(['#a', '#b']);
  });
  it('empty local → server; empty server → local', () => {
    expect(mergeFavorites(['#x'], [])).toEqual(['#x']);
    expect(mergeFavorites([], ['#y'])).toEqual(['#y']);
    expect(mergeFavorites([], [])).toEqual([]);
  });
  it('no device loses a favorite (union)', () => {
    const merged = mergeFavorites(['#a'], ['#z']);
    expect(merged).toContain('#a');
    expect(merged).toContain('#z');
  });
});

describe('favoritesEqual', () => {
  it('order-sensitive equality', () => {
    expect(favoritesEqual(['#a', '#b'], ['#a', '#b'])).toBe(true);
    expect(favoritesEqual(['#a', '#b'], ['#b', '#a'])).toBe(false);
    expect(favoritesEqual(['#a'], ['#a', '#b'])).toBe(false);
  });
});
