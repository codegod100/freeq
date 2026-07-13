const CACHE_NAME = 'freeq-v1';
const SHELL_ASSETS = [
  '/chat',
  '/login',
  '/datastar.js',
  '/manifest.json',
  '/icon-192.png',
  '/icon-512.png'
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k))
      )
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // The Cache API only stores GET/HEAD responses. Don't intercept other methods.
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return;
  }

  // Always go to the network for API, events, and uploads.
  if (
    url.pathname.startsWith('/api/') ||
    url.pathname.startsWith('/chat/') && url.pathname.endsWith('/events') ||
    url.pathname.startsWith('/upload') ||
    url.pathname.startsWith('/auth/')
  ) {
    return;
  }

  // Navigation requests (HTML pages): network first, fall back to cached shell.
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          return response;
        })
        .catch(() => caches.match(request).then((r) => r || caches.match('/chat')))
    );
    return;
  }

  // Static assets: cache first, network fallback, EXCEPT for the WASM client
  // bundle which must always be fresh after deploys.
  if (url.pathname === '/freeq_webui_client.js' || url.pathname === '/freeq_webui_client_bg.wasm') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.status === 200) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
          }
          return response;
        })
        .catch(() => caches.match(request))
    );
    return;
  }

  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached;
      return fetch(request).then((response) => {
        if (response.status === 200) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
        }
        return response;
      });
    })
  );
});
