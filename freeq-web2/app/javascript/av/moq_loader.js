/**
 * Dynamically loads moq-publish / moq-watch custom elements.
 *
 * Served same-origin via Rails proxy at /av/assets/* (from freeq-server).
 * Loaded on demand when the user first joins a call.
 */

let loaded = false;
let loading = null;

// Hashed asset names match freeq-server/static/av/assets/ (and freeq-app moq-loader).
const SCRIPTS = [
  "/av/assets/publish-Du5ksDQe.js",
  "/av/assets/watch-CTz_Tjt7.js",
];

const PRELOADS = [
  "/av/assets/time-D4Xqna_f.js",
];

export function loadMoqComponents() {
  if (loaded) return Promise.resolve();
  if (loading) return loading;

  loading = new Promise((resolve, reject) => {
    let remaining = SCRIPTS.length;
    let failed = false;

    // Placeholders so auto-init scripts don't throw "missing element".
    if (!document.querySelector("moq-publish")) {
      const placeholder = document.createElement("moq-publish");
      placeholder.style.display = "none";
      placeholder.id = "__moq-placeholder-pub";
      document.body.appendChild(placeholder);
    }
    if (!document.querySelector("moq-watch")) {
      const placeholder = document.createElement("moq-watch");
      placeholder.style.display = "none";
      const canvas = document.createElement("canvas");
      canvas.style.display = "none";
      placeholder.appendChild(canvas);
      placeholder.id = "__moq-placeholder-watch";
      document.body.appendChild(placeholder);
    }

    for (const href of PRELOADS) {
      if (!document.querySelector(`link[href="${href}"]`)) {
        const link = document.createElement("link");
        link.rel = "modulepreload";
        link.crossOrigin = "";
        link.href = href;
        document.head.appendChild(link);
      }
    }

    for (const src of SCRIPTS) {
      if (document.querySelector(`script[src="${src}"]`)) {
        remaining -= 1;
        if (remaining === 0) {
          loaded = true;
          resolve();
        }
        continue;
      }

      const script = document.createElement("script");
      script.type = "module";
      script.crossOrigin = "";
      script.src = src;
      script.onload = () => {
        remaining -= 1;
        if (remaining === 0 && !failed) {
          loaded = true;
          resolve();
        }
      };
      script.onerror = () => {
        if (!failed) {
          failed = true;
          loading = null;
          reject(new Error(`Failed to load MoQ script: ${src}`));
        }
      };
      document.head.appendChild(script);
    }

    if (remaining === 0) {
      loaded = true;
      resolve();
    }
  });

  return loading;
}

export function isMoqLoaded() {
  return (
    loaded &&
    typeof customElements !== "undefined" &&
    !!customElements.get("moq-publish")
  );
}
