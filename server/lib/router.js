// Mini routeur HTTP sans dépendance. Les handlers renvoient un objet (JSON) ou lèvent HttpError.
//   route.get("/reports", ({ query }) => …)    route.post("/reports", ({ body, ip }) => …)
// Limite de débit simple par IP (60 requêtes / minute / route par défaut).
export class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function createRouter(prefix) {
  const routes = [];
  const hits = new Map();

  const add = (method) => (path, handler, opts = {}) => {
    const keys = [];
    const re = new RegExp("^" + path.replace(/:(\w+)/g, (_, k) => { keys.push(k); return "([^/]+)"; }) + "/?$");
    routes.push({ method, re, keys, handler, limit: opts.limit ?? 60 });
  };

  async function handle(req, res) {
    const url = new URL(req.url, "http://x");
    const send = (status, data) => {
      res.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" });
      res.end(JSON.stringify(data));
    };
    if (!url.pathname.startsWith(prefix)) return send(404, { error: "introuvable" });
    const path = url.pathname.slice(prefix.length) || "/";
    const r = routes.find((r) => r.method === req.method && r.re.test(path));
    if (!r) return send(404, { error: "introuvable" });
    const ip = (req.headers["x-forwarded-for"] || req.socket.remoteAddress || "").toString().split(",")[0].trim();
    const key = `${ip}|${r.method}|${r.re}`;
    const now = Date.now();
    const h = (hits.get(key) || []).filter((t) => now - t < 60_000);
    if (h.length >= r.limit) return send(429, { error: "trop de requêtes" });
    h.push(now); hits.set(key, h);
    try {
      let body = null;
      if (req.method !== "GET") {
        let raw = "";
        for await (const chunk of req) { raw += chunk; if (raw.length > 64 * 1024) throw new HttpError(413, "trop gros"); }
        body = raw ? JSON.parse(raw) : null;
      }
      const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(path.match(r.re)[i + 1])]));
      const out = await r.handler({ query: Object.fromEntries(url.searchParams), body, params, ip, req });
      send(200, out ?? { ok: true });
    } catch (e) {
      send(e.status || 500, { error: e.status ? e.message : "erreur serveur" });
      if (!e.status) console.error(e);
    }
  }

  // ménage de la table de débit
  setInterval(() => { const now = Date.now(); for (const [k, v] of hits) if (!v.some((t) => now - t < 60_000)) hits.delete(k); }, 120_000).unref();

  return { get: add("GET"), post: add("POST"), put: add("PUT"), delete: add("DELETE"), handle };
}
