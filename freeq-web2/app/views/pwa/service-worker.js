/* freeq-web2 service worker — served at /service-worker (no long-cache).
 * Bump CACHE_VERSION when the offline shell changes. */
const CACHE_VERSION = "freeq-web2-v2";
const SHELL = ["/", "/chat", "/offline.html", "/manifest",
  "/icon-192.png", "/icon-512.png", "/icon-512-maskable.png",
  "/apple-touch-icon.png", "/favicon.png"];

const NO_CACHE_PREFIXES = [
  "/api/", "/auth", "/login", "/logout", "/cable", "/debug/", "/up", "/upload",
];

function shouldBypass(url) {
  if (url.origin !== self.location.origin) return true;
  const path = url.pathname;
  return NO_CACHE_PREFIXES.some(
    (p) => path === p || path.startsWith(p.endsWith("/") ? p : p + "/") || path.startsWith(p)
  );
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_VERSION).then((cache) =>
      Promise.all(SHELL.map((u) => cache.add(u).catch(() => {})))
    ).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_VERSION).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (shouldBypass(url)) return;

  if (url.pathname.startsWith("/assets/")) {
    event.respondWith(cacheFirst(req));
    return;
  }
  if (req.mode === "navigate" || req.destination === "document") {
    event.respondWith(networkFirstNav(req));
    return;
  }
  event.respondWith(staleWhileRevalidate(req));
});

async function cacheFirst(req) {
  const cached = await caches.match(req);
  if (cached) return cached;
  try {
    const resp = await fetch(req);
    if (resp && resp.ok) {
      const cache = await caches.open(CACHE_VERSION);
      cache.put(req, resp.clone());
    }
    return resp;
  } catch (e) {
    return cached || Response.error();
  }
}

async function networkFirstNav(req) {
  try {
    const resp = await fetch(req);
    if (resp && resp.ok) {
      const cache = await caches.open(CACHE_VERSION);
      cache.put("/chat", resp.clone()).catch(() => {});
    }
    return resp;
  } catch (e) {
    return (
      (await caches.match(req)) ||
      (await caches.match("/chat")) ||
      (await caches.match("/offline.html")) ||
      new Response("Offline", { status: 503, statusText: "Offline" })
    );
  }
}

async function staleWhileRevalidate(req) {
  const cache = await caches.open(CACHE_VERSION);
  const cached = await cache.match(req);
  const network = fetch(req)
    .then((resp) => {
      if (resp && resp.ok) cache.put(req, resp.clone());
      return resp;
    })
    .catch(() => cached);
  return cached || network;
}
