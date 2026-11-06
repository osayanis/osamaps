// Mode camion : aires et parkings poids lourds autour d'un point (OpenStreetMap via Overpass).
//   GET /truck/stops?lat=46.56&lng=3.33&km=30  → { items: [{ id, name, lat, lng, kind, capacity, fuel }], partial }
//   kind : "parking" (parking PL), "services" (aire de services), "rest_area" (aire de repos PL), "fuel" (station PL)
// - cache par tuile de 0,5° sur disque (7 jours), servi même périmé si Overpass ne répond pas ;
// - Overpass est lent (souvent 30-40 s) : on attend au plus ~20 s puis on répond avec ce qu'on a (partial = true),
//   la tuile continue de se charger en arrière-plan pour la requête suivante ;
// - Overpass saturé : on le laisse tranquille 5 minutes ; aucune position n'est conservée (seulement les tuiles).
import { HttpError } from "../lib/router.js";

const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];
const UA = "OsaMaps/1.0 (+https://osalabs.fr/maps/)";
const TILE = 0.5;
const TTL = 7 * 24 * 3600_000;
const WAIT_MS = 20_000;

const num = (v, min, max) => Number.isFinite(v) && v >= min && v <= max;

function distKm(a, b, c, d) {
  const r = Math.PI / 180, x = (d - b) * r * Math.cos(((a + c) / 2) * r), y = (c - a) * r;
  return Math.sqrt(x * x + y * y) * 6371;
}

async function overpass(query) {
  let last;
  for (const url of OVERPASS) {
    try {
      const r = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": UA },
        body: "data=" + encodeURIComponent(query),
        signal: AbortSignal.timeout(55_000),
      });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      return await r.json();
    } catch (e) { last = e; }
  }
  throw last;
}

function tileQuery(s, w, n, e) {
  const b = `(${s},${w},${n},${e})`;
  return `[out:json][timeout:50];(
  nwr["amenity"="parking"]["hgv"~"^(yes|designated|only)$"]${b};
  nwr["amenity"="parking"]["access:hgv"~"^(yes|designated)$"]${b};
  nwr["highway"="services"]${b};
  nwr["highway"="rest_area"]["hgv"~"^(yes|designated)$"]${b};
  nwr["amenity"="fuel"]["hgv"~"^(yes|designated)$"]${b};
);out center tags;`;
}

function parse(d) {
  return (d.elements ?? []).map((el) => {
    const lat = el.lat ?? el.center?.lat, lng = el.lon ?? el.center?.lon;
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
    const t = el.tags ?? {};
    const kind = t.amenity === "fuel" ? "fuel" : t.highway === "services" ? "services" : t.highway === "rest_area" ? "rest_area" : "parking";
    const cap = Number.parseInt(t["capacity:hgv"] ?? (kind === "parking" ? t.capacity : ""), 10);
    return {
      id: `osm-${el.type}-${el.id}`,
      name: String(t.name ?? t.brand ?? t.operator ?? "").slice(0, 80) || null,
      lat: Math.round(lat * 1e6) / 1e6, lng: Math.round(lng * 1e6) / 1e6,
      kind,
      capacity: Number.isFinite(cap) && cap > 0 && cap < 2000 ? cap : null,
      fuel: kind === "fuel" || t.fuel === "yes" || t["fuel:diesel"] === "yes" ? true : undefined,
    };
  }).filter(Boolean);
}

export async function register({ route, store, log }) {
  const disk = await store.collection("truck-stops-tiles", {});
  let busyUntil = 0;
  const inflight = new Map();

  function loadTile(key) {
    if (inflight.has(key)) return inflight.get(key);
    const [x, y] = key.split(",").map(Number);
    const s = y * TILE, w = x * TILE;
    const p = (async () => {
      try {
        const items = parse(await overpass(tileQuery(s, w, s + TILE, w + TILE)));
        disk.data[key] = { at: Date.now(), items };
        disk.save();
        return items;
      } catch (e) {
        busyUntil = Date.now() + 5 * 60_000;
        log(`truck : Overpass indisponible (${e?.message ?? "erreur"})`);
        return null;
      } finally { inflight.delete(key); }
    })();
    inflight.set(key, p);
    return p;
  }

  route.get("/truck/stops", async ({ query }) => {
    const lat = Number(query.lat), lng = Number(query.lng);
    const km = query.km ? Number(query.km) : 30;
    if (!num(lat, 41, 51.5) || !num(lng, -5.5, 10)) throw new HttpError(400, "position hors de France");
    if (!num(km, 1, 60)) throw new HttpError(400, "rayon invalide");
    // tuiles qui couvrent le cercle (au plus 4 avec 60 km et des tuiles de 0,5°)
    const dLat = km / 111, dLng = km / (111 * Math.cos((lat * Math.PI) / 180));
    const keys = new Set();
    for (const a of [lat - dLat, lat + dLat]) for (const b of [lng - dLng, lng + dLng]) keys.add(`${Math.floor(b / TILE)},${Math.floor(a / TILE)}`);
    let partial = false;
    const lists = await Promise.all([...keys].map(async (k) => {
      const t = disk.data[k];
      if (t && Date.now() - t.at < TTL) return t.items;
      if (Date.now() < busyUntil) { partial = true; return t?.items ?? []; }
      const got = await Promise.race([loadTile(k), new Promise((r) => setTimeout(() => r(undefined), WAIT_MS))]);
      if (got === undefined || got === null) { partial = true; return t?.items ?? []; }
      return got;
    }));
    const seen = new Set();
    const items = lists.flat()
      .filter((i) => !seen.has(i.id) && seen.add(i.id))
      .map((i) => ({ ...i, km: Math.round(distKm(lat, lng, i.lat, i.lng) * 10) / 10 }))
      .filter((i) => i.km <= km)
      .sort((a, b) => a.km - b.km)
      .slice(0, 40);
    return { items, partial };
  }, { limit: 20 });

  log("truck : aires poids lourds prêtes");
}
