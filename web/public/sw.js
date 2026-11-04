/*
 * Service worker d'OsaMaps (écrit à la main, sans dépendance).
 *
 * Ce qu'il met en cache : UNIQUEMENT le shell de l'app (index.html, fichiers /assets/ de Vite,
 * manifest, icônes). Jamais l'API (/maps/api/), jamais socket.io, jamais les tuiles ni les
 * services externes (requêtes d'une autre origine : non interceptées).
 *
 *   page (navigation)  stale-while-revalidate : réponse immédiate depuis le cache, puis
 *                      téléchargement de la version en ligne ; si elle a changé, elle remplace
 *                      le cache, ses fichiers sont préchargés et la page reçoit
 *                      { type: "osamaps:update" } → toast « Nouvelle version — Recharger ».
 *   /assets/…          cache d'abord (noms avec empreinte : un fichier ne change jamais).
 *   le reste du scope  stale-while-revalidate (manifest, icônes, favicon).
 *
 * Changer VERSION seulement quand la logique de ce fichier change (les mises à jour de l'app
 * passent par la revalidation de index.html, pas par ce numéro).
 */
const VERSION = 1;
const CACHE = `osamaps-shell-v${VERSION}`;
const SCOPE = self.registration.scope; // ex. https://osalabs.fr/maps/
const SCOPE_PATH = new URL(SCOPE).pathname;
const STATIC = ["manifest.webmanifest", "favicon.svg", "icons/icon-192.png", "icons/icon-512.png"];
const MAX_ENTRIES = 80;

let updatePending = false;

/** Fichiers référencés par index.html (script, css, préchargements) dans le scope. */
function assetsOf(html) {
  const out = new Set();
  for (const m of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    const u = new URL(m[1], SCOPE);
    if (u.origin === location.origin && u.pathname.startsWith(`${SCOPE_PATH}assets/`)) out.add(u.href);
  }
  return [...out];
}

async function precacheIndex(cache, html) {
  await Promise.all(assetsOf(html).map(async (u) => {
    if (await cache.match(u)) return;
    const r = await fetch(u).catch(() => null);
    if (r && r.ok) await cache.put(u, r);
  }));
}

async function trim(cache) {
  const keys = await cache.keys();
  const assets = keys.filter((k) => new URL(k.url).pathname.startsWith(`${SCOPE_PATH}assets/`));
  // les plus anciens d'abord (ordre d'insertion)
  for (const k of assets.slice(0, Math.max(0, keys.length - MAX_ENTRIES))) await cache.delete(k);
}

self.addEventListener("install", (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    const r = await fetch(SCOPE, { cache: "no-cache" }).catch(() => null);
    if (r && r.ok) {
      const html = await r.clone().text();
      await cache.put(SCOPE, r);
      await precacheIndex(cache, html);
    }
    await Promise.all(STATIC.map((p) => cache.add(SCOPE + p).catch(() => {})));
    // pas d'attente : ce fichier ne contient que la stratégie de cache
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter((n) => n.startsWith("osamaps-shell-") && n !== CACHE).map((n) => caches.delete(n)));
    await self.clients.claim();
  })());
});

async function notifyUpdate() {
  updatePending = true;
  const clients = await self.clients.matchAll({ type: "window" });
  clients.forEach((c) => c.postMessage({ type: "osamaps:update" }));
}

self.addEventListener("message", (event) => {
  // la page demande au démarrage si une nouvelle version a été trouvée avant qu'elle n'écoute
  if (event.data?.type === "osamaps:hello" && updatePending) event.source?.postMessage({ type: "osamaps:update" });
});

async function handleNavigate(event) {
  const cache = await caches.open(CACHE);
  const cached = await cache.match(SCOPE); // une seule page (SPA), quelle que soit la query (?sim=…)
  const network = (async () => {
    const r = await fetch(event.request, { cache: "no-cache" });
    if (!r.ok || !(r.headers.get("content-type") || "").includes("text/html")) return r;
    const html = await r.clone().text();
    const before = cached ? await cached.clone().text() : null;
    if (before !== html) {
      await cache.put(SCOPE, r.clone());
      await precacheIndex(cache, html);
      await trim(cache);
      if (before != null) await notifyUpdate();
    }
    return r;
  })();
  event.waitUntil(network.catch(() => {}));
  if (cached) return cached;
  try {
    return await network;
  } catch {
    return new Response(
      '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<title>OsaMaps</title><body style="margin:0;height:100vh;display:grid;place-items:center;background:#0a0a0f;color:#fff;font:600 16px system-ui">' +
      "<p>Pas de réseau. OsaMaps s’ouvrira dès que la connexion revient.</p></body>",
      { headers: { "Content-Type": "text/html; charset=utf-8" } },
    );
  }
}

async function cacheFirst(event) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(event.request);
  if (hit) return hit;
  const r = await fetch(event.request);
  if (r.ok) event.waitUntil(cache.put(event.request, r.clone()));
  return r;
}

async function staleWhileRevalidate(event) {
  const cache = await caches.open(CACHE);
  const hit = await cache.match(event.request, { ignoreSearch: true });
  const network = fetch(event.request).then((r) => {
    if (r.ok) return cache.put(event.request, r.clone()).then(() => r);
    return r;
  });
  event.waitUntil(network.catch(() => {}));
  return hit || network;
}

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== location.origin || !url.pathname.startsWith(SCOPE_PATH)) return;
  const path = url.pathname.slice(SCOPE_PATH.length);
  // jamais l'API ni le temps réel
  if (path.startsWith("api/") || path.startsWith("socket.io")) return;
  // ni les fichiers de dev de Vite (au cas où un service worker traînerait en dev)
  if (path.startsWith("@") || path.startsWith("src/") || path.startsWith("node_modules/")) return;
  if (req.mode === "navigate") event.respondWith(handleNavigate(event));
  else if (path.startsWith("assets/")) event.respondWith(cacheFirst(event));
  else event.respondWith(staleWhileRevalidate(event));
});
