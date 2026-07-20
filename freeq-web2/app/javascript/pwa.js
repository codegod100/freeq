// Register the freeq service worker once per page load (Turbo-safe).
// Prefer /sw.js (static, long-cacheable); fall back to Rails /service-worker.

// Rails route with Cache-Control: no-cache (public/* is year-cached).
const SW_URL = "/service-worker";

function registerServiceWorker() {
  if (!("serviceWorker" in navigator)) return;
  // Local http://localhost is ok; plain LAN http is not installable.
  if (location.protocol !== "https:" && location.hostname !== "localhost") return;

  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register(SW_URL, { scope: "/" })
      .then((reg) => {
        // Check for updates when the tab becomes visible again.
        document.addEventListener("visibilitychange", () => {
          if (document.visibilityState === "visible") reg.update().catch(() => {});
        });
      })
      .catch((err) => {
        console.warn("[pwa] service worker registration failed", err);
      });
  });
}

registerServiceWorker();
