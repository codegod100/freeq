import { describe, it, expect } from 'vitest';
import { gridColumns, gridTileSize, TILE_ASPECT } from './call-grid';

// Mirrors the macOS CallGridLayoutTests so all clients agree on layout.
describe('gridColumns', () => {
  const W = 1600, H = 900;

  it('0 or 1 tile → 1 column', () => {
    expect(gridColumns(0, W, H)).toBe(1);
    expect(gridColumns(1, W, H)).toBe(1);
  });
  it('2 tiles side-by-side in landscape', () => {
    expect(gridColumns(2, W, H)).toBe(2);
  });
  it('4 → 2×2, 9 → 3×3, 12 → 4 cols', () => {
    expect(gridColumns(4, W, H)).toBe(2);
    expect(gridColumns(9, W, H)).toBe(3);
    expect(gridColumns(12, W, H)).toBe(4);
  });
  it('tall container prefers fewer columns', () => {
    expect(gridColumns(4, 500, 1200)).toBeLessThanOrEqual(gridColumns(4, W, H));
  });
  it('columns never exceed tile count', () => {
    for (let n = 1; n <= 20; n++) expect(gridColumns(n, W, H)).toBeLessThanOrEqual(n);
  });
  it('columns grow monotonically with tile count', () => {
    let prev = 1;
    for (let n = 1; n <= 30; n++) {
      const c = gridColumns(n, W, H);
      expect(c).toBeGreaterThanOrEqual(prev);
      prev = c;
    }
  });
  it('degenerate container never crashes / stays in range', () => {
    for (const [w, h] of [[0, 0], [-5, 100], [100, -5]] as const) {
      const c = gridColumns(6, w, h);
      expect(c).toBeGreaterThanOrEqual(1);
      expect(c).toBeLessThanOrEqual(6);
    }
  });
});

describe('gridTileSize', () => {
  it('is 16:9 and fits the container for a range of counts', () => {
    for (let n = 1; n <= 30; n++) {
      const t = gridTileSize(n, 1600, 900, 8);
      expect(t.width / t.height).toBeCloseTo(TILE_ASPECT, 3);
      const cols = gridColumns(n, 1600, 900);
      const rows = Math.ceil(n / cols);
      expect(t.width * cols).toBeLessThanOrEqual(1600 + cols * 8 + 1);
      expect(t.height * rows).toBeLessThanOrEqual(900 + rows * 8 + 1);
    }
  });
  it('degenerate container → 0×0', () => {
    expect(gridTileSize(4, 0, 0)).toEqual({ width: 0, height: 0 });
    expect(gridTileSize(0, 100, 100)).toEqual({ width: 0, height: 0 });
  });
  it('more tiles never grow the tile', () => {
    let prev = Infinity;
    for (let n = 1; n <= 20; n++) {
      const w = gridTileSize(n, 1600, 900).width;
      expect(w).toBeLessThanOrEqual(prev + 0.01);
      prev = w;
    }
  });
});
