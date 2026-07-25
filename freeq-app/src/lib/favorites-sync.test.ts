import { describe, it, expect } from 'vitest';
import { mergeFavorites, favoritesEqual, unjoinedFavorites } from './favorites-sync';

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

describe('unjoinedFavorites', () => {
  it('finds a favorite that is not in the joined list', () => {
    // The reported bug: #freeq favorited (roamed from another device) but not
    // joined here rendered in neither sidebar group.
    expect(unjoinedFavorites(new Set(['#freeq', '#general']), ['#general'])).toEqual(['#freeq']);
  });

  it('is case-insensitive so an already-joined channel never shows a Join row', () => {
    expect(unjoinedFavorites(new Set(['#freeq']), ['#FreeQ'])).toEqual([]);
  });

  it('excludes DMs, keeps & channels, and sorts', () => {
    expect(unjoinedFavorites(new Set(['#b', '&local', '#a', 'alice', 'did:plc:xyz']), [])).toEqual([
      '#a',
      '&local',
      '#b',
    ].sort());
  });

  it('is empty when everything is joined', () => {
    expect(unjoinedFavorites(new Set(['#a', '#b']), ['#a', '#b'])).toEqual([]);
    expect(unjoinedFavorites(new Set<string>(), ['#a'])).toEqual([]);
  });
});
