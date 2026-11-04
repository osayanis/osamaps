// « Sur le trajet » : prix des carburants, bornes de recharge, aires de repos.
// Toutes les données sont publiques et réelles, mises en cache ici pour ménager les services :
//   - carburants : data.economie.gouv.fr (flux instantané v2), export complet rafraîchi toutes les 10 min ;
//   - bornes : base nationale IRVE consolidée (data.gouv), via l'API Opendatasoft d'ODRÉ, 1 fois / 24 h ;
//   - aires : OpenStreetMap (Overpass, highway=rest_area|services) par tuiles de 0,25°, cache 14 jours,
//     complété par les stations-service d'autoroute du flux carburant.
//
//   GET  /along/fuel?bbox=w,s,e,n | ?lat=&lng=&r=        stations (r en m, ≤ 50 km)
//   POST /along/fuel/route { points:[[lng,lat]…], maxDist }  stations à moins de maxDist m du tracé
//   GET  /along/ev?bbox=… | ?lat&lng&r                   bornes de recharge (regroupées par lieu)
//   POST /along/ev/route   { points, maxDist }
//   POST /along/rest/route { points, fromAlong, window }  aires de repos / services devant
//   GET  /along/status                                    fraîcheur des caches
import { HttpError } from "../lib/router.js";

const FUEL_URL = "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/exports/json";
const IRVE_URL = "https://odre.opendatasoft.com/api/explore/v2.1/catalog/datasets/bornes-irve/exports/json";
const OVERPASS = ["https://overpass-api.de/api/interpreter", "https://overpass.private.coffee/api/interpreter"];
const UA = "OsaMaps/0.1 (+https://osalabs.fr/maps/)";

const FUELS = ["gazole", "sp95", "e10", "sp98", "gplc", "e85"];
const FUEL_TTL = 10 * 60_000;
const IRVE_TTL = 24 * 3600_000;
const REST_TTL = 14 * 24 * 3600_000;
const TILE = 0.25;
const IRVE_FORMAT = 2; // à incrémenter si la normalisation des bornes change (invalide le cache disque)

// ---------- géométrie (mêmes formules que web/src/core/geometry.ts) ----------
const R = 6371008.8;
const rad = (d) => (d * Math.PI) / 180;
function distance(a, b) {
  const dLat = rad(b[1] - a[1]), dLng = rad(b[0] - a[0]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[1])) * Math.cos(rad(b[1])) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
/** Projette p sur la polyligne : { offset (m), along (m depuis le début) }. */
function snap(p, coords, cum) {
  const k = Math.cos(rad(p[1]));
  let best = { offset: Infinity, along: 0 };
  for (let i = 1; i < coords.length; i++) {
    const a = coords[i - 1], b = coords[i];
    const ax = (a[0] - p[0]) * k, ay = a[1] - p[1];
    const dx = (b[0] - a[0]) * k, dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    const t = len2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2)) : 0;
    const q = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
    const off = distance(p, q);
    if (off < best.offset) best = { offset: off, along: cum[i - 1] + distance(a, q) };
  }
  return best;
}

// ---------- validation ----------
const num = (v, min, max, name) => {
  const n = Number(v);
  if (!Number.isFinite(n) || n < min || n > max) throw new HttpError(400, `${name} invalide`);
  return n;
};
function parseArea(query) {
  if (query.bbox) {
    const p = String(query.bbox).split(",").map(Number);
    if (p.length !== 4 || p.some((x) => !Number.isFinite(x))) throw new HttpError(400, "bbox invalide");
    const [w, s, e, n] = p;
    if (w >= e || s >= n || e - w > 2 || n - s > 2) throw new HttpError(400, "bbox trop grande (2° max)");
    return { w, s, e, n };
  }
  const lat = num(query.lat, -90, 90, "lat"), lng = num(query.lng, -180, 180, "lng");
  const r = num(query.r ?? 5000, 100, 50_000, "r");
  const dLat = r / 111_320, dLng = r / (111_320 * Math.cos(rad(lat)));
  return { w: lng - dLng, s: lat - dLat, e: lng + dLng, n: lat + dLat, center: [lng, lat], r };
}
function parseLine(body) {
  const pts = body?.points;
  if (!Array.isArray(pts) || pts.length < 2 || pts.length > 600) throw new HttpError(400, "points : 2 à 600 attendus");
  const coords = pts.map((p) => {
    if (!Array.isArray(p) || p.length < 2) throw new HttpError(400, "point invalide");
    return [num(p[0], -180, 180, "lng"), num(p[1], -90, 90, "lat")];
  });
  const cum = [0];
  for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + distance(coords[i - 1], coords[i]));
  if (cum[cum.length - 1] > 2_000_000) throw new HttpError(400, "tracé trop long");
  return { coords, cum };
}
const inArea = (x, a) => x.lng >= a.w && x.lng <= a.e && x.lat >= a.s && x.lat <= a.n
  && (!a.center || distance(a.center, [x.lng, x.lat]) <= a.r);

/** Éléments à moins de maxDist du tracé, avec leur position le long (along) et l'écart (offset). */
function nearLine(items, { coords, cum }, maxDist) {
  let w = 180, s = 90, e = -180, n = -90;
  for (const [x, y] of coords) { w = Math.min(w, x); e = Math.max(e, x); s = Math.min(s, y); n = Math.max(n, y); }
  const pad = maxDist / 111_320 * 1.6;
  const out = [];
  for (const it of items) {
    if (it.lng < w - pad || it.lng > e + pad || it.lat < s - pad || it.lat > n + pad) continue;
    const sn = snap([it.lng, it.lat], coords, cum);
    if (sn.offset <= maxDist) out.push({ ...it, along: Math.round(sn.along), offset: Math.round(sn.offset) });
  }
  return out.sort((a, b) => a.along - b.along);
}

// ---------- cache générique « stale-while-revalidate » ----------
function cached(name, ttl, load, log) {
  let value = null, at = 0, pending = null, error = null;
  const refresh = () => {
    pending ??= load()
      .then((v) => { value = v; at = Date.now(); error = null; log(`[along] ${name} : ${v.length} éléments`); })
      .catch((e) => { error = String(e.message || e); log(`[along] ${name} : échec`, error); })
      .finally(() => { pending = null; });
    return pending;
  };
  return {
    async get() {
      if (!value) await refresh();
      else if (Date.now() - at > ttl) refresh(); // on sert l'ancien en attendant
      if (!value) throw new HttpError(503, `${name} indisponible pour le moment`);
      return value;
    },
    seed(v, t) { value = v; at = t; },
    status: () => ({ count: value?.length ?? 0, updatedAt: at || null, loading: !!pending, error }),
  };
}

async function fetchJson(url, init = {}, timeout = 120_000) {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeout);
  try {
    const r = await fetch(url, { ...init, signal: ctrl.signal, headers: { "User-Agent": UA, ...(init.headers ?? {}) } });
    if (!r.ok) throw new Error(`HTTP ${r.status}`);
    return await r.json();
  } finally { clearTimeout(t); }
}

// ---------- carburants ----------
const DAYS = ["Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi", "Dimanche"];
/** horaires (chaîne JSON du flux) → [[["08:00","12:00"],…] × 7 jours] ; [] = fermé, null = inconnu. */
function parseHours(raw) {
  if (!raw) return null;
  try {
    const h = JSON.parse(raw);
    const jours = Array.isArray(h.jour) ? h.jour : [];
    if (!jours.length) return null;
    const week = Array(7).fill(null);
    for (const j of jours) {
      const i = Number(j["@id"]) - 1;
      if (!(i >= 0 && i < 7)) continue;
      const slots = (Array.isArray(j.horaire) ? j.horaire : j.horaire ? [j.horaire] : [])
        .map((s) => [String(s["@ouverture"] ?? "").replace(".", ":"), String(s["@fermeture"] ?? "").replace(".", ":")])
        .filter(([o, f]) => /^\d\d:\d\d$/.test(o) && /^\d\d:\d\d$/.test(f) && o !== f);
      week[i] = j["@ferme"] === "1" ? [] : slots.length ? slots : null;
    }
    return week.every((d) => d === null) ? null : week;
  } catch { return null; }
}

async function loadFuel() {
  const select = ["id", "adresse", "ville", "cp", "geom", "horaires", "horaires_automate_24_24", "pop",
    "carburants_rupture_temporaire", ...FUELS.flatMap((f) => [`${f}_prix`, `${f}_maj`])].join(",");
  const rows = await fetchJson(`${FUEL_URL}?select=${encodeURIComponent(select)}`);
  if (!Array.isArray(rows) || rows.length < 1000) throw new Error("réponse inattendue");
  const out = [];
  for (const r of rows) {
    const g = r.geom;
    if (!g || !Number.isFinite(g.lon) || !Number.isFinite(g.lat)) continue;
    const prices = {};
    for (const f of FUELS) {
      const p = r[`${f}_prix`];
      if (typeof p === "number" && p > 0.3 && p < 5) prices[f] = { p, maj: r[`${f}_maj`] || null };
    }
    if (!Object.keys(prices).length) continue;
    out.push({
      id: String(r.id),
      lng: g.lon, lat: g.lat,
      address: titleCase(String(r.adresse ?? "").trim()),
      city: titleCase(String(r.ville ?? "").trim()),
      cp: String(r.cp ?? ""),
      highway: r.pop === "A",
      h24: r.horaires_automate_24_24 === "Oui",
      hours: parseHours(r.horaires),
      shortage: r.carburants_rupture_temporaire ? String(r.carburants_rupture_temporaire).toLowerCase().split(";").filter(Boolean) : [],
      prices,
    });
  }
  return out;
}
const SMALL = new Set(["de", "du", "des", "la", "le", "les", "et", "d", "l", "à", "au", "aux", "sur", "en"]);
/** « 1 ROUTE DE COSNE » → « 1 Route de Cosne » (le flux est souvent en majuscules). */
const titleCase = (s) => s !== s.toUpperCase() ? s : s.toLowerCase()
  .replace(/(^|[\s'’-])(\p{L}+)/gu, (m, a, w, i) => a + (i > 0 && SMALL.has(w) ? w : w[0].toUpperCase() + w.slice(1)));

// ---------- bornes de recharge (IRVE) ----------
const truthy = (v) => /^(true|1|oui)$/i.test(String(v ?? "").trim());
async function loadIrve() {
  const select = "consolidated_longitude as lng, consolidated_latitude as lat, nom_operateur as op, nom_enseigne as en, "
    + "nom_station as nom, adresse_station as adr, horaires as h, gratuit as g, prise_type_2 as t2, "
    + "prise_type_combo_ccs as ccs, prise_type_chademo as chademo, prise_type_ef as ef, "
    + "max(puissance_nominale) as pmax, count(*) as n";
  const group = "consolidated_longitude, consolidated_latitude, nom_operateur, nom_enseigne, nom_station, adresse_station, "
    + "horaires, gratuit, prise_type_2, prise_type_combo_ccs, prise_type_chademo, prise_type_ef";
  const rows = await fetchJson(`${IRVE_URL}?select=${encodeURIComponent(select)}&group_by=${encodeURIComponent(group)}`, {}, 240_000);
  if (!Array.isArray(rows) || rows.length < 1000) throw new Error("réponse inattendue");
  // un même lieu apparaît sur plusieurs lignes (une par combinaison de prises) : on fusionne
  const byPlace = new Map();
  for (const r of rows) {
    if (!Number.isFinite(r.lng) || !Number.isFinite(r.lat) || Math.abs(r.lat) > 90) continue;
    const op = cleanOperator(r.op || r.en || "");
    const key = `${r.lng.toFixed(4)},${r.lat.toFixed(4)},${op}`;
    let kw = Number(r.pmax) || 0;
    if (kw > 1000) kw /= 1000; // quelques producteurs déclarent en W
    if (kw > 400) kw = 0;      // valeur aberrante → inconnue
    let s = byPlace.get(key);
    if (!s) {
      s = { id: key, lng: +r.lng.toFixed(6), lat: +r.lat.toFixed(6), operator: op, name: cleanName(r.nom, op), address: String(r.adr ?? "").trim().slice(0, 140),
        hours: String(r.h ?? "").trim().slice(0, 60), free: truthy(r.g), kw: 0, points: 0, plugs: [] };
      byPlace.set(key, s);
    }
    s.kw = Math.max(s.kw, Math.round(kw));
    s.points += Number(r.n) || 0;
    for (const [field, label] of [["ccs", "CCS"], ["t2", "Type 2"], ["chademo", "CHAdeMO"], ["ef", "Domestique"]]) {
      if (truthy(r[field]) && !s.plugs.includes(label)) s.plugs.push(label);
    }
  }
  return [...byPlace.values()];
}
const cleanOperator = (s) => String(s).split("|")[0].trim().slice(0, 60);
function cleanName(nom, op) {
  const n = titleCase(String(nom ?? "").trim());
  // beaucoup de noms sont des identifiants techniques (« Opérateur/MBSSYTGNDB ») : on les écarte
  if (!n || /\/[A-Z0-9-]{6,}$/i.test(n) || /^[A-Z0-9*_-]{8,}$/.test(n)) return op || "Borne de recharge";
  // nom réduit à une ville (« MOULINS ») : on précise l'opérateur
  if (op && !n.toLowerCase().includes(op.toLowerCase().split(" ")[0]) && n.length <= 24 && !/\s-\s|\d/.test(n)) return `${op} · ${n}`.slice(0, 80);
  return n.slice(0, 80);
}

// ---------- aires de repos (Overpass, par tuiles) ----------
async function overpass(query) {
  let last;
  for (const url of OVERPASS) {
    try {
      return await fetchJson(url, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: "data=" + encodeURIComponent(query),
      }, 60_000); // Overpass public est souvent lent (30-40 s) : on patiente, c'est en arrière-plan
    } catch (e) { last = e; }
  }
  throw last;
}

export async function register({ route, store, log }) {
  const fuel = cached("carburants", FUEL_TTL, loadFuel, log);

  // les bornes : gros téléchargement (≈ 45 Mo), gardé sur disque pour survivre aux redémarrages
  const irveDisk = await store.collection("along-irve", { at: 0, items: [] });
  const irve = cached("bornes IRVE", IRVE_TTL, async () => {
    const items = await loadIrve();
    irveDisk.data = { v: IRVE_FORMAT, at: Date.now(), items };
    return items;
  }, log);
  if (irveDisk.data.v === IRVE_FORMAT && irveDisk.data.items?.length) irve.seed(irveDisk.data.items, irveDisk.data.at);

  const restDisk = await store.collection("along-rest-tiles", {});
  let overpassBusyUntil = 0;
  let restInFlight = 0;
  const restQueued = new Set();
  async function restTile(key) {
    const t = restDisk.data[key];
    if (t && Date.now() - t.at < REST_TTL) return t.items;
    if (Date.now() < overpassBusyUntil) return t?.items ?? null;
    const [x, y] = key.split(",").map(Number);
    const s = y * TILE, w = x * TILE, n = s + TILE, e = w + TILE;
    try {
      restInFlight++;
      const d = await overpass(`[out:json][timeout:50];nwr[highway~"^(rest_area|services)$"](${s},${w},${n},${e});out center tags;`);
      const items = (d.elements ?? []).map((el) => {
        const lat = el.lat ?? el.center?.lat, lng = el.lon ?? el.center?.lon;
        if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
        const tg = el.tags ?? {};
        return { id: `osm-${el.type}-${el.id}`, lng, lat, kind: tg.highway === "services" ? "services" : "rest_area",
          name: String(tg.name ?? "").slice(0, 80) || null, toilets: tg.toilets === "yes" };
      }).filter(Boolean);
      restDisk.data[key] = { at: Date.now(), items };
      restDisk.save();
      return items;
    } catch (e) {
      overpassBusyUntil = Date.now() + 5 * 60_000; // Overpass saturé : on lui laisse 5 min
      log("[along] Overpass indisponible :", e.message);
      return t?.items ?? null;
    } finally { restInFlight--; }
  }

  // ---- routes ----
  route.get("/along/status", () => ({ fuel: fuel.status(), ev: irve.status(), restTiles: Object.keys(restDisk.data).length, overpassBusy: Date.now() < overpassBusyUntil }));

  route.get("/along/fuel", async ({ query }) => {
    const area = parseArea(query);
    const all = await fuel.get();
    const stations = all.filter((x) => inArea(x, area)).slice(0, 600);
    return { updatedAt: fuel.status().updatedAt, stations };
  });

  route.post("/along/fuel/route", async ({ body }) => {
    const line = parseLine(body);
    const maxDist = num(body.maxDist ?? 1000, 50, 5000, "maxDist");
    const stations = nearLine(await fuel.get(), line, maxDist).slice(0, 800);
    return { updatedAt: fuel.status().updatedAt, stations };
  }, { limit: 30 });

  route.get("/along/ev", async ({ query }) => {
    const area = parseArea(query);
    const all = await irve.get();
    const stations = all.filter((x) => inArea(x, area)).sort((a, b) => b.kw - a.kw).slice(0, 600);
    return { updatedAt: irve.status().updatedAt, stations };
  });

  route.post("/along/ev/route", async ({ body }) => {
    const line = parseLine(body);
    const maxDist = num(body.maxDist ?? 1000, 50, 5000, "maxDist");
    const minKw = num(body.minKw ?? 0, 0, 400, "minKw");
    const stations = nearLine((await irve.get()).filter((x) => x.kw >= minKw), line, maxDist).slice(0, 800);
    return { updatedAt: irve.status().updatedAt, stations };
  }, { limit: 30 });

  // Aires devant le conducteur : on ne regarde qu'une fenêtre du tracé (fromAlong → +window) et on
  // ne demande à Overpass que 4 tuiles manquantes au plus par appel (parcimonie).
  route.post("/along/rest/route", async ({ body }) => {
    const line = parseLine(body);
    const fromAlong = num(body.fromAlong ?? 0, 0, 2_000_000, "fromAlong");
    const win = num(body.window ?? 40_000, 1000, 150_000, "window");
    const maxDist = 600;
    const tiles = new Set();
    for (let i = 0; i < line.coords.length; i++) {
      if (line.cum[i] < fromAlong - 2000 || line.cum[i] > fromAlong + win + 2000) continue;
      const [lng, lat] = line.coords[i];
      tiles.add(`${Math.floor(lng / TILE)},${Math.floor(lat / TILE)}`);
    }
    // on ne fait jamais attendre le client : les tuiles manquantes sont demandées en arrière-plan
    // (4 au plus), il récupère le résultat complet au prochain appel.
    let items = [], queued = 0, missing = 0;
    for (const key of tiles) {
      const t = restDisk.data[key];
      if (t) items.push(...t.items);
      if (!t || Date.now() - t.at > REST_TTL) {
        missing++;
        if (queued < 4 && restInFlight < 2 && !restQueued.has(key)) {
          queued++; restQueued.add(key);
          restTile(key).finally(() => restQueued.delete(key));
        }
      }
    }
    // stations-service d'autoroute du flux carburant (données officielles, toujours dispo)
    try {
      const hw = (await fuel.get()).filter((s) => s.highway)
        .map((s) => ({ id: `fuel-${s.id}`, lng: s.lng, lat: s.lat, kind: "services", name: null, city: s.city, fuel: true }));
      items.push(...hw);
    } catch { /* flux carburant indisponible : tant pis */ }
    const near = nearLine(items, line, maxDist).filter((x) => x.along >= fromAlong && x.along <= fromAlong + win);
    // dédoublonne (aire OSM + station du flux au même endroit)
    const out = [];
    for (const x of near) {
      const dup = out.find((o) => Math.abs(o.along - x.along) < 800);
      if (!dup) out.push(x);
      else if (!dup.name && x.name) Object.assign(dup, { name: x.name, id: x.id, kind: x.kind });
    }
    return { areas: out.slice(0, 30), partial: missing > 0 };
  }, { limit: 20 });

  // préchauffe le cache carburant au démarrage (les bornes : à la première demande)
  fuel.get().catch(() => {});
}
