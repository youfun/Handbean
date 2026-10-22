/* Only the generic offline document is cached. Conversations, settings, assets,
   API responses, and workspace content always come from the Handbean server. */
const OFFLINE_CACHE_PREFIX = "handbean-offline-";
// Bump when offline.html changes so activate can discard the previous fallback.
const OFFLINE_CACHE = `${OFFLINE_CACHE_PREFIX}v1`;
const OFFLINE_URL = "/offline.html";
const DEFAULT_URL = "/settings?tab=ui";

function allowedNotificationURL(value) {
  try {
    if (typeof value !== "string" || /[\\\\\u0000-\u0020\u007f-\u009f]/.test(value)) return null;
    // Inspect the original path before URL normalizes dot segments away.
    const path = value.match(/^(?:https?:\/\/[^/?#]+)?(\/[^?#]*)/i)?.[1];
    if (!path) return null;
    const segments = path.slice(1).split("/").map(decodeURIComponent);
    if (segments.some((part) => !part || part === "." || part === ".." ||
      /[/\\\\%\u0000-\u001f\u007f-\u009f]/.test(part))) return null;
    const url = new URL(value, self.location.origin);
    const conversation = (segments.length === 2 && segments[0] === "c") ||
      (segments.length === 4 && segments[0] === "w" && segments[2] === "c");
    const settings = segments.length === 1 && segments[0] === "settings" && url.search === "?tab=ui";
    if (url.origin === self.location.origin && !url.username && !url.password &&
        !url.hash && ((conversation && !url.search) || settings)) {
      url.pathname = `/${segments.map(encodeURIComponent).join("/")}`;
      return url.href;
    }
  } catch (_) {}
  return null;
}

function notificationURL(value) {
  return allowedNotificationURL(value) || new URL(DEFAULT_URL, self.location.origin).href;
}

self.addEventListener("install", (event) => {
  event.waitUntil(Promise.all([
    caches.open(OFFLINE_CACHE).then((cache) => cache.add(OFFLINE_URL)),
    self.skipWaiting()
  ]));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(Promise.all([
    caches.keys().then((names) => Promise.all(names
      .filter((name) => name.startsWith(OFFLINE_CACHE_PREFIX) && name !== OFFLINE_CACHE)
      .map((name) => caches.delete(name)))),
    self.clients.claim()
  ]));
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET" || event.request.mode !== "navigate") return;
  event.respondWith(fetch(event.request, {cache: "no-store"}).catch(async () =>
    (await caches.match(OFFLINE_URL)) || Response.error()));
});

self.addEventListener("push", (event) => {
  let payload = {};
  try {
    const data = event.data?.json();
    if (data && typeof data === "object") payload = data;
  } catch (_) {}
  const text = (value, fallback) => typeof value === "string" && value.trim() ? value : fallback;
  // userVisibleOnly requires a visible notification for every received push,
  // including while an app tab is focused.
  event.waitUntil(self.registration.showNotification(text(payload.title, "Handbean"), {
    body: text(payload.body, "Handbean has an update for you."),
    icon: "/images/pwa-192.png",
    badge: "/images/pwa-192.png",
    tag: text(payload.tag, "handbean-update"),
    data: {url: notificationURL(payload.url)}
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = notificationURL(event.notification.data?.url);
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: "window", includeUncontrolled: true});
    const sameOrigin = windows.filter((client) => {
      try { return new URL(client.url).origin === self.location.origin; } catch (_) { return false; }
    });
    const matching = sameOrigin.find((client) => allowedNotificationURL(client.url) === url);
    if (matching) {
      try { await matching.focus(); return; } catch (_) {}
    }
    // Prefer an existing app window, while leaving unrelated same-origin pages alone.
    const app = sameOrigin.find((client) => {
      const path = new URL(client.url).pathname;
      return path === "/" || path === "/settings" || /^\/(?:c|w)\//.test(path);
    });
    if (app) {
      try {
        const navigated = await app.navigate(url);
        if (navigated) { await navigated.focus(); return; }
      } catch (_) {}
    }
    await self.clients.openWindow(url);
  })());
});

// pushsubscriptionchange cannot safely obtain the page's CSRF token. The next
// foreground page reconciles the browser's current subscription through the
// authenticated API; an absent subscription requires an explicit enable click.
