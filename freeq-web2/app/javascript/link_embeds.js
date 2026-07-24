// Link embeds for channel messages — port of freeq-app LinkPreview /
// BlueskyEmbed / YouTube card. Hydrates .msg rows that contain URLs.

const BSKY_POST_RE =
  /https?:\/\/bsky\.app\/profile\/([^/\s]+)\/post\/([a-zA-Z0-9]+)/i;
const YT_RE =
  /(?:youtube\.com\/watch\?v=|youtu\.be\/|youtube\.com\/shorts\/)([a-zA-Z0-9_-]{11})/i;
// Stop at whitespace / common wrappers; cleanUrl trims trailing punct.
const URL_RE = /https?:\/\/[^\s<>\]\)"'{}|\\^`]+/gi;
const IMAGE_URL_RE = /\.(?:jpg|jpeg|png|gif|webp)(?:\?|#|$)/i;
const FREEQ_MEDIA_RE = /\/api\/v1\/media\//i;
const BSKY_CDN_RE = /cdn\.bsky\.app\/img\//i;
// Only skip *real* media file URLs (extension at end / before query), not
// hostnames like codeberg.org or paths that merely contain "ogg" as letters.
const SKIP_PREVIEW_RE =
  /\/api\/v1\/|\.(?:m4a|mp3|mp4|mov|webm|ogg|wav|aac)(?:\?|#|$)/i;

const ogCache = new Map(); // url → { data } | { fail: true, at }
const inflight = new Map();
const FAIL_TTL_MS = 30_000;
// freeq-server rate-limits REST; serialize OG fetches.
let ogQueue = Promise.resolve();

function isImageUrl(url) {
  return (
    IMAGE_URL_RE.test(url) || FREEQ_MEDIA_RE.test(url) || BSKY_CDN_RE.test(url)
  );
}

function cleanUrl(raw) {
  let url = String(raw || "")
    // Zero-width / bidi marks often sneak in on paste.
    .replace(/[\u200B-\u200D\uFEFF\u2060\u00AD]/g, "")
    .trim();
  // Strip wrapping brackets / angles IRC clients sometimes add.
  url = url.replace(/^<+/, "").replace(/>+$/, "");
  while (/[.,;:!?)'"\]]+$/.test(url)) url = url.slice(0, -1);
  return url;
}

function firstEmbeddableUrl(text) {
  if (!text) return null;
  const matches = text.match(URL_RE);
  if (!matches) return null;
  for (const m of matches) {
    const url = cleanUrl(m);
    if (!url) continue;
    if (isImageUrl(url)) continue;
    if (SKIP_PREVIEW_RE.test(url)) continue;
    try {
      const u = new URL(url);
      if (u.protocol !== "http:" && u.protocol !== "https:") continue;
    } catch {
      continue;
    }
    return url;
  }
  return null;
}

function esc(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function domainOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

// Codeberg (and similar) sometimes put CSS in <meta name="description">.
function cleanDescription(desc) {
  let d = String(desc || "").trim();
  if (!d) return "";
  // Drop leading CSS blocks / selectors.
  d = d.replace(/^(?:\.[^{]+\{[^}]*\}\s*)+/g, "").trim();
  d = d.replace(/^(?:[^{]+\{[^}]*\}\s*)+/g, "").trim();
  if (d.length < 8) return "";
  if (/[{};]/.test(d) && d.length < 40) return "";
  return d;
}

function cacheGet(url) {
  const hit = ogCache.get(url);
  if (!hit) return undefined;
  if (hit.fail) {
    if (Date.now() - hit.at < FAIL_TTL_MS) return null;
    ogCache.delete(url);
    return undefined;
  }
  return hit.data;
}

function cacheOk(url, data) {
  ogCache.set(url, { data });
}

function cacheFail(url) {
  ogCache.set(url, { fail: true, at: Date.now() });
}

async function fetchOG(url) {
  const cached = cacheGet(url);
  if (cached !== undefined) return cached;
  if (inflight.has(url)) return inflight.get(url);

  const p = (async () => {
    // Serialize through the queue so a channel full of links doesn't
    // trip freeq-server's REST rate limiter.
    const run = ogQueue.then(() => doFetchOG(url));
    // Don't let one failure stall the queue.
    ogQueue = run.catch(() => {});
    return run;
  })();

  inflight.set(url, p);
  try {
    return await p;
  } finally {
    inflight.delete(url);
  }
}

async function doFetchOG(url) {
  const cached = cacheGet(url);
  if (cached !== undefined) return cached;
  try {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 10_000);
    const resp = await fetch(`/api/v1/og?url=${encodeURIComponent(url)}`, {
      signal: ctrl.signal,
      credentials: "same-origin",
    });
    clearTimeout(timer);
    if (!resp.ok) {
      console.warn("link embed OG", url, "HTTP", resp.status);
      cacheFail(url);
      return null;
    }
    const json = await resp.json();
    const data = {
      title: (json.title && String(json.title).trim()) || undefined,
      description: cleanDescription(json.description),
      image: json.image || undefined,
      siteName: json.site_name || undefined,
    };
    if (data.title || data.description || data.image) {
      cacheOk(url, data);
      return data;
    }
    cacheFail(url);
    return null;
  } catch (e) {
    console.warn("link embed OG", url, e);
    cacheFail(url);
    return null;
  }
}

function makeCard(
  href,
  { image, siteName, title, description, domain, extraClass },
) {
  const a = document.createElement("a");
  a.href = href;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.className = `link-embed${extraClass ? ` ${extraClass}` : ""}`;
  a.dataset.embedUrl = href;

  let html = "";
  if (image) {
    html += `<img class="link-embed-img" src="${esc(image)}" alt="" loading="lazy" referrerpolicy="no-referrer">`;
  }
  html += `<div class="link-embed-body">`;
  if (siteName) {
    html += `<div class="link-embed-site">${esc(siteName)}</div>`;
  }
  if (title) {
    html += `<div class="link-embed-title">${esc(title)}</div>`;
  }
  if (description) {
    html += `<div class="link-embed-desc">${esc(description)}</div>`;
  }
  if (domain) {
    html += `<div class="link-embed-domain">${esc(domain)}</div>`;
  }
  html += `</div>`;
  a.innerHTML = html;

  const img = a.querySelector(".link-embed-img");
  if (img) {
    img.addEventListener("error", () => {
      img.remove();
    });
  }
  return a;
}

function youtubeCard(videoId) {
  const href = `https://youtube.com/watch?v=${videoId}`;
  const a = document.createElement("a");
  a.href = href;
  a.target = "_blank";
  a.rel = "noopener noreferrer";
  a.className = "link-embed yt-embed";
  a.dataset.embedUrl = href;
  a.innerHTML =
    `<img class="link-embed-img yt-thumb" src="https://img.youtube.com/vi/${esc(videoId)}/mqdefault.jpg" alt="YouTube video" loading="lazy">` +
    `<div class="link-embed-body yt-footer"><span class="yt-play">▶</span> YouTube</div>`;
  return a;
}

async function blueskyCard(handle, rkey) {
  const href = `https://bsky.app/profile/${handle}/post/${rkey}`;
  try {
    const uri = `at://${handle}/app.bsky.feed.post/${rkey}`;
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 6000);
    const resp = await fetch(
      `https://public.api.bsky.app/xrpc/app.bsky.feed.getPostThread?uri=${encodeURIComponent(uri)}&depth=0`,
      { signal: ctrl.signal },
    );
    clearTimeout(timer);
    if (!resp.ok) return null;
    const data = await resp.json();
    const p = data.thread?.post;
    if (!p) return null;

    const images =
      p.embed?.images?.map((img) => img.thumb) ||
      p.embed?.media?.images?.map((img) => img.thumb) ||
      [];
    const author = p.author || {};
    const text = p.record?.text || "";
    const display = author.displayName || author.handle || handle;
    const handleLabel = author.handle || handle;
    const likes = p.likeCount || 0;
    const reposts = p.repostCount || 0;
    let time = "";
    if (p.record?.createdAt) {
      time = new Date(p.record.createdAt).toLocaleDateString(undefined, {
        month: "short",
        day: "numeric",
        year: "numeric",
      });
    }

    const a = document.createElement("a");
    a.href = href;
    a.target = "_blank";
    a.rel = "noopener noreferrer";
    a.className = "link-embed bsky-embed";
    a.dataset.embedUrl = href;

    let imgHtml = "";
    if (images.length) {
      imgHtml =
        `<div class="bsky-images">` +
        images
          .slice(0, 4)
          .map(
            (src) =>
              `<img src="${esc(src)}" alt="" loading="lazy" referrerpolicy="no-referrer">`,
          )
          .join("") +
        `</div>`;
    }

    const avatar = author.avatar
      ? `<img class="bsky-avatar" src="${esc(author.avatar)}" alt="" loading="lazy">`
      : `<span class="bsky-avatar bsky-avatar-fallback">${esc(
          (handleLabel[0] || "?").toUpperCase(),
        )}</span>`;

    a.innerHTML =
      `<div class="bsky-author">${avatar}` +
      `<span class="bsky-name">${esc(display)}</span>` +
      `<span class="bsky-handle">@${esc(handleLabel)}</span></div>` +
      `<div class="bsky-text">${esc(text)}</div>` +
      imgHtml +
      `<div class="bsky-footer"><span>♥ ${likes}</span><span>↻ ${reposts}</span>` +
      `<span class="bsky-time">🦋 ${esc(time)}</span></div>`;
    return a;
  } catch {
    return null;
  }
}

function insertCard(row, card) {
  // Prefer after .body so we stay in the message column of the 50px|1fr grid
  // without stuffing block content into an inline span.
  const body = row.querySelector(".body");
  if (body && body.parentElement === row) {
    card.style.gridColumn = "2";
    if (body.nextSibling) row.insertBefore(card, body.nextSibling);
    else row.appendChild(card);
    return;
  }
  const host = body || row;
  const reactions = host.querySelector?.(".reactions");
  if (reactions) host.insertBefore(card, reactions);
  else host.appendChild(card);
}

/** Swap in a new card without an empty frame (avoids clear→await→insert flash). */
function replaceCard(row, card) {
  const old = Array.from(row.querySelectorAll(".link-embed"));
  // Same URL already rendered — keep the live node (images may be decoded).
  if (
    old.length === 1 &&
    old[0].dataset.embedUrl &&
    card.dataset.embedUrl &&
    old[0].dataset.embedUrl === card.dataset.embedUrl
  ) {
    return;
  }
  insertCard(row, card);
  old.forEach((el) => el.remove());
}

/**
 * Scan message rows under root and inject link embeds (YouTube, Bluesky, OG).
 * Safe to call repeatedly — skips rows already claimed for the same URL
 * (in-flight or finished) so concurrent CableReady/MutationObserver passes
 * cannot clear→refetch and flash an already-visible card.
 */
export async function hydrateLinkEmbeds(root) {
  if (!root) return;
  const rows = root.querySelectorAll(".msg[data-text]");
  const jobs = [];

  rows.forEach((row) => {
    // Skip ciphertext still waiting for DM decrypt.
    if (row.dataset.encrypted === "true" && row.dataset.decrypted !== "true") {
      return;
    }
    const text = row.dataset.text || "";
    if (!text || !/https?:\/\//i.test(text)) return;

    const bsky = text.match(BSKY_POST_RE);
    const yt = text.match(YT_RE);
    // freeq-app: skip generic OG when the message already has an inline image.
    const hasInlineImage =
      !!row.querySelector("img.msg-img, a.msg-img-link") ||
      (text.match(URL_RE) || []).some((u) => isImageUrl(cleanUrl(u)));

    let key = null;
    if (bsky) key = `bsky:${bsky[1]}/${bsky[2]}`;
    else if (yt) key = `yt:${yt[1]}`;
    else if (hasInlineImage) return;
    else {
      const url = firstEmbeddableUrl(text);
      if (!url) return;
      key = `og:${url}`;
    }

    // Claimed for this key (pending fetch or already painted) — leave alone.
    // Do NOT clear existing cards before the async work finishes; that was
    // the visible flash when MutationObserver / CableReady re-entered.
    if (row.dataset.embedsUrl === key) return;

    row.dataset.embedsUrl = key;

    jobs.push(
      (async () => {
        let card = null;
        try {
          if (bsky) {
            card = await blueskyCard(bsky[1], bsky[2]);
          } else if (yt) {
            card = youtubeCard(yt[1]);
          } else {
            const url = firstEmbeddableUrl(text);
            if (!url) return;
            const data = await fetchOG(url);
            // Show with title, image, *or* description (Codeberg often has
            // title + garbage description and no og:image).
            if (!data || (!data.title && !data.image && !data.description)) {
              return;
            }
            card = makeCard(url, {
              image: data.image,
              siteName: data.siteName,
              title: data.title,
              description: data.description,
              domain: domainOf(url),
            });
          }
        } catch (e) {
          console.warn("link embed", e);
          return;
        }
        if (!card) {
          // Allow a later hydrate pass to retry (fail cache has TTL).
          if (row.dataset.embedsUrl === key) delete row.dataset.embedsUrl;
          return;
        }
        // Row may have been re-rendered / edited while we awaited.
        if (row.dataset.embedsUrl !== key) return;
        if (!row.isConnected) return;
        replaceCard(row, card);
      })(),
    );
  });

  await Promise.allSettled(jobs);
}
