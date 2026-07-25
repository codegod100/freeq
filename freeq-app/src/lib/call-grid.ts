/**
 * Expanded-call grid math — the web port of the macOS `CallGridLayout`.
 * Picks the column count that maximizes 16:9 tile area for `count` tiles in a
 * container, then the exact tile size that fits every tile with no scrolling
 * or clipping (Meet/Zoom-style). Kept byte-for-byte in behavior with the
 * macOS/iOS policy so all clients arrange a call the same way.
 */
export const TILE_ASPECT = 16 / 9;

export function gridColumns(count: number, width: number, height: number): number {
  if (count <= 1) return 1;
  const w = Math.max(width, 1);
  const h = Math.max(height, 1);
  let bestCols = 1;
  let bestArea = 0;
  for (let cols = 1; cols <= count; cols++) {
    const rows = Math.ceil(count / cols);
    const tileW = Math.min(w / cols, (h / rows) * TILE_ASPECT);
    const tileH = tileW / TILE_ASPECT;
    const area = tileW * tileH;
    // >= : on equal area prefer more columns (video grids read better wide).
    if (area >= bestArea) {
      bestArea = area;
      bestCols = cols;
    }
  }
  return bestCols;
}

export interface TileSize { width: number; height: number; }

/**
 * The exact 16:9 tile size that fits `count` tiles into the container at the
 * optimal column count, bounded by BOTH column width and row height (minus
 * inter-tile spacing). Returns 0×0 for a degenerate container.
 */
export function gridTileSize(
  count: number,
  width: number,
  height: number,
  spacing = 8,
): TileSize {
  if (count <= 0 || width <= 0 || height <= 0) return { width: 0, height: 0 };
  const cols = Math.max(1, gridColumns(count, width, height));
  const rows = Math.ceil(count / cols);
  const availW = Math.max(1, width - spacing * Math.max(0, cols - 1));
  const availH = Math.max(1, height - spacing * Math.max(0, rows - 1));
  const tileW = Math.min(availW / cols, (availH / rows) * TILE_ASPECT);
  const w = Math.max(1, tileW);
  return { width: w, height: w / TILE_ASPECT };
}
