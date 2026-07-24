import { useEffect, useRef, useState } from 'react';
import { useScrollStableExpand } from '../lib/scrollStableExpand';

interface OGData {
  title?: string;
  description?: string;
  image?: string;
  siteName?: string;
}

// Simple cache to avoid re-fetching
const ogCache = new Map<string, OGData | null>();

async function fetchOG(url: string): Promise<OGData | null> {
  if (ogCache.has(url)) return ogCache.get(url) || null;
  try {
    // Use server-side OG proxy (no privacy leak to third-party services)
    const proxyUrl = `/api/v1/og?url=${encodeURIComponent(url)}`;
    const resp = await fetch(proxyUrl, { signal: AbortSignal.timeout(6000) });
    if (!resp.ok) {
      ogCache.set(url, null);
      return null;
    }
    const json = await resp.json();

    const data: OGData = {
      title: json.title || undefined,
      description: json.description || undefined,
      image: json.image || undefined,
      siteName: json.site_name || undefined,
    };

    // Only cache if we got something useful
    if (data.title || data.description || data.image) {
      ogCache.set(url, data);
      return data;
    }
    ogCache.set(url, null);
    return null;
  } catch {
    ogCache.set(url, null);
    return null;
  }
}

export function LinkPreview({ url }: { url: string }) {
  const cached = ogCache.has(url) ? ogCache.get(url) || null : undefined;
  const [data, setData] = useState<OGData | null>(cached ?? null);
  const [loading, setLoading] = useState(cached === undefined);
  const [inView, setInView] = useState(false);
  const [imgFailed, setImgFailed] = useState(false);
  const [imgLoaded, setImgLoaded] = useState(false);
  const sentinelRef = useRef<HTMLDivElement | null>(null);

  // Gate on inView so cached OG data doesn't expand every history card
  // before the message is near the viewport.
  const show =
    inView &&
    !loading &&
    !!data &&
    !!(data.title || data.image);

  const rootRef = useScrollStableExpand(show);

  // Only fetch when the message is near the viewport — avoids every history
  // URL hammering /api/v1/og and expanding cards all at once on page load.
  useEffect(() => {
    const el = sentinelRef.current;
    if (!el) return;
    if (typeof IntersectionObserver === 'undefined') {
      setInView(true);
      return;
    }
    const io = new IntersectionObserver(
      (entries) => {
        if (entries.some((e) => e.isIntersecting)) {
          setInView(true);
          io.disconnect();
        }
      },
      { root: null, rootMargin: '240px 0px', threshold: 0 }
    );
    io.observe(el);
    return () => io.disconnect();
  }, []);

  useEffect(() => {
    if (!inView) return;
    if (ogCache.has(url)) {
      setData(ogCache.get(url) || null);
      setLoading(false);
      return;
    }
    let cancelled = false;
    setLoading(true);
    fetchOG(url).then((d) => {
      if (!cancelled) {
        setData(d);
        setLoading(false);
      }
    });
    return () => {
      cancelled = true;
    };
  }, [url, inView]);

  // Reset image state when the OG image URL changes
  useEffect(() => {
    setImgFailed(false);
    setImgLoaded(false);
  }, [data?.image]);

  const domain = (() => {
    try {
      return new URL(url).hostname.replace(/^www\./, '');
    } catch {
      return '';
    }
  })();

  return (
    <div ref={rootRef} className="min-h-0">
      {/* 1px sentinel so IntersectionObserver has a real target (0×0 is flaky). */}
      <div ref={sentinelRef} className="h-px w-full opacity-0 pointer-events-none" aria-hidden />
      {show && data && (
        <a
          href={url}
          target="_blank"
          rel="noopener noreferrer"
          className="block mt-1 max-w-md border border-border rounded-lg overflow-hidden hover:border-border-bright transition-colors bg-bg-secondary"
        >
          {data.image && (
            // Fixed h-32 slot reserves space before the image paints so the
            // card doesn't grow again when the bitmap arrives. Keep the slot
            // even on error so a broken OG image doesn't collapse the card.
            <div className="w-full h-32 bg-bg-tertiary relative overflow-hidden">
              {!imgFailed && (
                <img
                  src={data.image}
                  alt=""
                  className={`absolute inset-0 w-full h-full object-cover transition-opacity duration-150 ${
                    imgLoaded ? 'opacity-100' : 'opacity-0'
                  }`}
                  loading="lazy"
                  onLoad={() => setImgLoaded(true)}
                  onError={() => setImgFailed(true)}
                />
              )}
            </div>
          )}
          <div className="px-3 py-2">
            {data.siteName && (
              <div className="text-[10px] text-fg-dim uppercase tracking-wider">
                {data.siteName}
              </div>
            )}
            {data.title && (
              <div className="text-xs font-semibold text-accent truncate">
                {data.title}
              </div>
            )}
            {data.description && (
              <div className="text-[11px] text-fg-muted line-clamp-2 mt-0.5">
                {data.description}
              </div>
            )}
            <div className="text-[10px] text-fg-dim mt-1 truncate">{domain}</div>
          </div>
        </a>
      )}
    </div>
  );
}
