// Musique : relais de connexion Spotify pour l'app iOS.
// Spotify n'accepte plus que des Redirect URI en HTTPS (ou http://127.0.0.1) : l'app déclare donc
//   https://osalabs.fr/maps/api/music/spotify-callback
// et ce relais renvoie aussitôt (302) vers osamaps://spotify-callback?<code|error, state>, que la
// session de connexion de l'app (ASWebAuthenticationSession, schéma « osamaps ») récupère.
//
//   GET /maps/api/music/spotify-callback?code=…&state=…   → 302 osamaps://spotify-callback?code=…&state=…
//
// Rien n'est stocké ni journalisé : le code ne sert à rien sans le « code_verifier » PKCE resté dans l'app.
//
// Le mini-routeur (lib/router.js) ne sait répondre qu'en JSON : on intercepte donc cette seule adresse
// avant lui, sur le serveur HTTP de socket.io (io.httpServer), sans toucher au socle.
const PATH = "/maps/api/music/spotify-callback";
const FORWARD = ["code", "state", "error"];
const hits = new Map();

export function register({ io }) {
  const server = io.httpServer;
  if (!server) return;

  server.prependListener("request", (req, res) => {
    const url = new URL(req.url, "http://x");
    if (req.method !== "GET" || url.pathname.replace(/\/$/, "") !== PATH) return;

    // le routeur va aussi recevoir cette requête : ses réponses deviennent sans effet
    const writeHead = res.writeHead.bind(res);
    const end = res.end.bind(res);
    res.writeHead = () => res;
    res.end = () => res;

    // limite de débit simple (30 / minute / IP), en mémoire
    const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").toString().split(",")[0].trim();
    const now = Date.now();
    const h = (hits.get(ip) || []).filter((t) => now - t < 60_000);
    if (h.length >= 30) {
      writeHead(429, { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store" });
      return end("Trop de requêtes.");
    }
    h.push(now); hits.set(ip, h);

    const out = new URLSearchParams();
    for (const k of FORWARD) {
      const v = url.searchParams.get(k);
      if (v && v.length <= 2048 && /^[\w\-.~]+$/.test(v)) out.set(k, v);
    }
    if (!out.has("code") && !out.has("error")) out.set("error", "invalid_request");
    const target = `osamaps://spotify-callback?${out}`;
    writeHead(302, {
      Location: target,
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "Referrer-Policy": "no-referrer",
    });
    end(`<!doctype html><meta charset="utf-8"><title>OsaMaps</title>` +
        `<p style="font-family:system-ui;padding:24px">Retour dans OsaMaps… <a href="${target}">Ouvrir OsaMaps</a></p>`);
  });

  setInterval(() => { const now = Date.now(); for (const [k, v] of hits) if (!v.some((t) => now - t < 60_000)) hits.delete(k); }, 120_000).unref();
}
