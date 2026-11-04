// Itinéraires : petit proxy vers Valhalla (FOSSGIS) pour le ménager.
//   POST /routing/route  { locations, costing_options?, alternates?, date_time? }  → réponse Valhalla brute
//   POST /routing/trace  { encoded_polyline }                                      → { edges: [{ b, e, kmh }] }
// - valide et reconstruit chaque requête (rien du client n'est transmis tel quel) ;
// - cache mémoire (mêmes requêtes = zéro appel) ;
// - file d'attente globale : au plus 1 appel sortant par seconde, User-Agent générique ;
// - ne garde aucune position : le cache est en mémoire, court, et indexé par empreinte.
import { createHash } from "node:crypto";
import { HttpError } from "../lib/router.js";

const VALHALLA = process.env.VALHALLA_URL || "https://valhalla1.openstreetmap.de";
const UA = "OsaMaps/1.0 (+https://osalabs.fr/maps/)";
const MIN_GAP_MS = 1000;
const MAX_QUEUE = 40;
const ROUTE_TTL = 5 * 60_000;
const TRACE_TTL = 60 * 60_000;
const CACHE_MAX = 300;

const cache = new Map(); // clé → { at, ttl, data }
function cacheGet(key) {
  const hit = cache.get(key);
  if (!hit) return null;
  if (Date.now() - hit.at > hit.ttl) { cache.delete(key); return null; }
  cache.delete(key); cache.set(key, hit); // LRU : remis en fin
  return hit.data;
}
function cachePut(key, data, ttl) {
  cache.set(key, { at: Date.now(), ttl, data });
  while (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value);
}

// file d'attente : un appel sortant à la fois, espacés d'au moins MIN_GAP_MS
let chain = Promise.resolve();
let waiting = 0;
let lastCall = 0;
function queued(fn) {
  if (waiting >= MAX_QUEUE) throw new HttpError(503, "service d'itinéraire saturé, réessaie dans un instant");
  waiting++;
  const run = chain.then(async () => {
    const wait = lastCall + MIN_GAP_MS - Date.now();
    if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    lastCall = Date.now();
    try { return await fn(); } finally { waiting--; }
  });
  chain = run.catch(() => {});
  return run;
}

let logFn = () => {};
async function valhalla(endpoint, body) {
  let r;
  try {
    r = await fetch(`${VALHALLA}/${endpoint}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "User-Agent": UA },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(25_000),
    });
  } catch (e) {
    logFn(`routing : ${endpoint} injoignable (${e?.name ?? "erreur"})`);
    throw new HttpError(502, "service d'itinéraire injoignable");
  }
  const data = await r.json().catch(() => null);
  if (r.ok && data) return data;
  // 400 de Valhalla = pas d'itinéraire possible (point hors réseau, trop loin…) : on relaie le message
  if (r.status === 400 && data) throw new HttpError(422, String(data.error || "aucun itinéraire trouvé").slice(0, 200));
  logFn(`routing : ${endpoint} a répondu ${r.status} ${String(data?.error ?? "").slice(0, 120)}`);
  throw new HttpError(502, `service d'itinéraire indisponible (${r.status})`);
}

const num = (v, min, max) => typeof v === "number" && Number.isFinite(v) && v >= min && v <= max;
const key = (o) => createHash("sha1").update(JSON.stringify(o)).digest("hex");

function cleanRoute(body) {
  if (!body || typeof body !== "object") throw new HttpError(400, "requête invalide");
  const locs = body.locations;
  if (!Array.isArray(locs) || locs.length < 2 || locs.length > 10) throw new HttpError(400, "2 à 10 points");
  const locations = locs.map((l) => {
    if (!l || !num(l.lat, -90, 90) || !num(l.lon, -180, 180)) throw new HttpError(400, "point invalide");
    // 5 décimales (~1 m) : suffisant et améliore le cache
    const out = { lat: Math.round(l.lat * 1e5) / 1e5, lon: Math.round(l.lon * 1e5) / 1e5, type: l.type === "via" ? "via" : "break" };
    if (num(l.heading, 0, 360)) { out.heading = Math.round(l.heading); out.heading_tolerance = 45; }
    return out;
  });
  const auto = {};
  const co = body.costing_options?.auto ?? {};
  for (const k of ["use_tolls", "use_highways", "use_ferry"]) if (num(co[k], 0, 1)) auto[k] = co[k];
  const req = {
    locations,
    costing: "auto",
    costing_options: { auto },
    language: "fr-FR",
    directions_options: { units: "kilometers" },
    alternates: num(body.alternates, 0, 2) ? Math.round(body.alternates) : 0,
  };
  const dt = body.date_time;
  if (dt && (dt.type === 1 || dt.type === 2) && typeof dt.value === "string" && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(dt.value)) {
    req.date_time = { type: dt.type, value: dt.value };
  }
  return req;
}

export async function register({ route, log }) {
  logFn = log;
  route.post("/routing/route", async ({ body }) => {
    const req = cleanRoute(body);
    const k = "r" + key(req);
    const hit = cacheGet(k);
    if (hit) return hit;
    const data = await queued(() => valhalla("route", req));
    cachePut(k, data, ROUTE_TTL);
    return data;
  }, { limit: 30 });

  route.post("/routing/trace", async ({ body }) => {
    const poly = body?.encoded_polyline;
    if (typeof poly !== "string" || poly.length < 4 || poly.length > 60_000 || !/^[\x3f-\x7e]+$/.test(poly)) {
      throw new HttpError(400, "tracé invalide");
    }
    const k = "t" + key(poly);
    const hit = cacheGet(k);
    if (hit) return hit;
    const data = await queued(() => valhalla("trace_attributes", {
      encoded_polyline: poly,
      shape_match: "edge_walk",
      costing: "auto",
      filters: { attributes: ["edge.speed_limit", "edge.begin_shape_index", "edge.end_shape_index"], action: "include" },
    }));
    // réponse compacte : seulement ce qui sert (limite par portion du tracé)
    const out = {
      edges: (data.edges || []).map((e) => ({
        b: e.begin_shape_index,
        e: e.end_shape_index,
        kmh: typeof e.speed_limit === "number" && e.speed_limit > 0 && e.speed_limit < 200 ? e.speed_limit : null,
      })),
    };
    cachePut(k, out, TRACE_TTL);
    return out;
  }, { limit: 60 });

  log("routing : proxy Valhalla prêt");
}
