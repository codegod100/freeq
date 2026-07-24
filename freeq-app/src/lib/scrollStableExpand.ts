import { useLayoutEffect, useRef, type RefObject } from 'react';

/** Nearest scrollable ancestor (the message list pane in chat). */
export function findScrollParent(el: HTMLElement | null): HTMLElement | null {
  let p = el?.parentElement ?? null;
  while (p) {
    const { overflowY } = getComputedStyle(p);
    if (overflowY === 'auto' || overflowY === 'scroll' || overflowY === 'overlay') {
      return p;
    }
    p = p.parentElement;
  }
  return null;
}

/**
 * Keep the chat scroll position stable when an async embed expands from empty → content.
 *
 * - Near the bottom: re-pin to bottom (page load / live tail).
 * - Embed above the viewport: bump scrollTop by the new height so the reading
 *   position doesn't jump.
 * - Embed in/below the viewport: leave scroll alone.
 */
export function stabilizeScrollAfterExpand(
  el: HTMLElement | null,
  prevHeight: number
): void {
  if (!el) return;
  const root = findScrollParent(el);
  if (!root) return;

  const nextHeight = el.offsetHeight;
  const delta = nextHeight - prevHeight;
  if (delta <= 0) return;

  const distFromBottom =
    root.scrollHeight - root.scrollTop - root.clientHeight;
  // After expand, distance from bottom grows by ~delta if we were stuck.
  if (distFromBottom < delta + 80) {
    root.scrollTop = root.scrollHeight;
    return;
  }

  const rootRect = root.getBoundingClientRect();
  const elRect = el.getBoundingClientRect();
  // Content above the fold grew — keep the visible region fixed.
  if (elRect.bottom <= rootRect.top + 1) {
    root.scrollTop += delta;
  }
}

/**
 * Attach to a wrapper that always mounts. Call when `expanded` flips true
 * (or when measured height grows) to stabilize the parent scroller.
 */
export function useScrollStableExpand(
  expanded: boolean
): RefObject<HTMLDivElement | null> {
  const ref = useRef<HTMLDivElement | null>(null);
  const prevExpanded = useRef(false);
  const prevHeight = useRef(0);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;

    const height = el.offsetHeight;
    const becameExpanded = expanded && !prevExpanded.current;
    prevExpanded.current = expanded;

    if (becameExpanded || (expanded && height > prevHeight.current)) {
      stabilizeScrollAfterExpand(el, prevHeight.current);
    }
    prevHeight.current = height;
  }, [expanded]);

  return ref;
}
