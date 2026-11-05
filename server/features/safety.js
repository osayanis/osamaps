// Sécurité routière — zones de danger, ZFE, passages à niveau et écoles.
//
// CADRE LÉGAL (France) : depuis le décret n° 2012-3 du 3 janvier 2012 (art. R413-15 du Code de la
// route), signaler l'emplacement des contrôles routiers est interdit. Les aides à la conduite
// signalent à la place des « zones de danger », sans dire où se trouve l'appareil dans la zone.
// Longueurs d'usage retenues : 300 m en agglomération, 2 km hors agglomération, 4 km sur autoroute.
//
// Ce module télécharge la liste publique des radars fixes (data.gouv.fr, ministère de l'Intérieur),
// la garde EN MÉMOIRE SERVEUR UNIQUEMENT et n'envoie au client que des disques de zone :
//   - rayon = longueur de zone / 2 ;
//   - centre DÉCALÉ de l'appareil (direction et distance pseudo-aléatoires mais STABLES, tirées
//     d'un secret serveur : un décalage qui changerait chaque jour permettrait de retrouver
//     l'appareil en moyennant les centres) ;
//   - identifiant opaque (pas le numéro du radar).
// Le client découpe ensuite ces disques le long de l'itinéraire (zone de longueur réglementaire).
import { createHmac, randomBytes } from "node:crypto";
import { HttpError } from "../lib/router.js";

const DAY = 24 * 3600 * 1000;
const UA = "OsaMaps/0.1 (https://osalabs.fr/maps/)";

// Jeu « Liste des radars fixes en France » (ministère de l'Intérieur), mis à jour ~1 fois par an.
const RADARS_DATASET = "https://www.data.gouv.fr/api/1/datasets/6712583387af110196942793/";
const RADARS_PAGE = "https://www.data.gouv.fr/fr/datasets/liste-des-radars-fixes-en-france/";
// Base nationale consolidée des ZFE (transport.data.gouv.fr).
const ZFE_DATASET = "https://transport.data.gouv.fr/api/datasets/625438b890bf88454b283a55";
const ZFE_PAGE = "https://transport.data.gouv.fr/datasets/base-nationale-consolidee-des-zones-a-faibles-emissions";
const ZFE_NAMES = "https://raw.githubusercontent.com/etalab/transport-site/master/apps/transport/priv/zfe_ids.csv";
// Overpass (OSM) : plusieurs miroirs, essayés à tour de rôle, très peu sollicités (cache par tuile).
const OVERPASS = [
  "https://overpass-api.de/api/interpreter",
  "https://overpass.private.coffee/api/interpreter",
  "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
];
const POI_ZOOM = 12;
const POI_TTL = 30 * DAY;
const POI_MAX_TILES = 6000;

/** Longueur de zone (m) selon la vitesse maximale autorisée et le type d'appareil. */
function zoneKind(type, vma) {
  if (type === "ETFR" || type === "ETPN" || type === "ETU") return "city"; // feux, passages à niveau, urbains
  if (vma != null && vma <= 50) return "city";
  if (vma != null && vma >= 110) return "motorway";
  return "road"; // 70–90 km/h ou inconnue : hors agglomération (zone large = prudente)
}
const ZONE_LENGTH = { city: 300, road: 2000, motorway: 4000 };

async function fetchWithTimeout(url, init = {}, ms = 60000) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    return await fetch(url, { ...init, signal: ctl.signal, headers: { "User-Agent": UA, ...(init.headers || {}) } });
  } finally {
    clearTimeout(t);
  }
}

/** CSV « ; » très simple (pas de champs entre guillemets dans ces fichiers). */
function parseRadarsCsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim());
  const head = lines[0].split(";").map((h) => h.normalize("NFD").replace(/[̀-ͯ]/g, "").trim().toLowerCase());
  const col = (re) => head.findIndex((h) => re.test(h));
  const iId = col(/^num/), iType = col(/^type/), iVma = col(/^vma/), iLat = col(/^lat/), iLng = col(/^lon/);
  if ([iId, iType, iLat, iLng].some((i) => i < 0)) throw new Error("colonnes inattendues : " + head.join("|"));
  const out = [];
  for (const line of lines.slice(1)) {
    const c = line.split(";");
    const lat = Number(c[iLat]), lng = Number(c[iLng]);
    if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) continue;
    const vma = iVma >= 0 && /^\d+$/.test((c[iVma] || "").trim()) ? Number(c[iVma]) : null;
    out.push([String(c[iId]).trim(), String(c[iType]).trim(), vma, lat, lng]);
  }
  return out;
}

/** Simplification Douglas-Peucker (degrés), pour alléger les périmètres ZFE. */
function simplify(ring, tol) {
  if (ring.length <= 4) return ring;
  const keep = new Uint8Array(ring.length);
  keep[0] = keep[ring.length - 1] = 1;
  const stack = [[0, ring.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    let best = -1, bestD = tol;
    const [x1, y1] = ring[a], [x2, y2] = ring[b];
    const dx = x2 - x1, dy = y2 - y1, len2 = dx * dx + dy * dy;
    for (let i = a + 1; i < b; i++) {
      const [x, y] = ring[i];
      let t = len2 ? ((x - x1) * dx + (y - y1) * dy) / len2 : 0;
      t = Math.max(0, Math.min(1, t));
      const d = Math.hypot(x - (x1 + t * dx), y - (y1 + t * dy));
      if (d > bestD) { bestD = d; best = i; }
    }
    if (best > 0) { keep[best] = 1; stack.push([a, best], [best, b]); }
  }
  const out = ring.filter((_, i) => keep[i]).map(([x, y]) => [Math.round(x * 1e5) / 1e5, Math.round(y * 1e5) / 1e5]);
  return out.length >= 4 ? out : ring;
}

function tileBBox(z, x, y) {
  const n = 2 ** z;
  const lng = (xx) => (xx / n) * 360 - 180;
  const lat = (yy) => (Math.atan(Math.sinh(Math.PI * (1 - (2 * yy) / n))) * 180) / Math.PI;
  return { w: lng(x), e: lng(x + 1), n: lat(y), s: lat(y + 1) };
}

export async function register({ route, store, log }) {
  const secretCol = await store.collection("safety-secret", null);
  if (!secretCol.data) secretCol.data = { key: randomBytes(32).toString("hex") };
  const hmac = (s) => createHmac("sha256", secretCol.data.key).update(s).digest();

  // ---------------------------------------------------------------- radars → zones
  const radarsCol = await store.collection("safety-radars", { fetchedAt: 0, checkedAt: 0, resource: null, radars: [] });
  let zones = [];
  let radarsError = null;

  function buildZones() {
    zones = radarsCol.data.radars.map(([id, type, vma, lat, lng]) => {
      const kind = zoneKind(type, vma);
      const r = ZONE_LENGTH[kind] / 2;
      const h = hmac("offset:" + id);
      const u = h.readUInt32BE(0) / 2 ** 32, v = h.readUInt32BE(4) / 2 ** 32;
      // décalage uniforme dans une couronne de rayons 0,3·r/2 à r/2 : l'appareil reste DANS la zone,
      // et le centre n'est jamais (par hasard) posé sur l'appareil
      const dist = 0.5 * r * Math.sqrt(0.09 + 0.91 * v), ang = 2 * Math.PI * u;
      const dLat = (dist * Math.cos(ang)) / 111320;
      const dLng = (dist * Math.sin(ang)) / (111320 * Math.cos((lat * Math.PI) / 180));
      return {
        id: hmac("id:" + id).toString("hex").slice(0, 12),
        lng: Math.round((lng + dLng) * 1e5) / 1e5,
        lat: Math.round((lat + dLat) * 1e5) / 1e5,
        r,
        kind,
      };
    });
  }

  async function refreshRadars() {
    try {
      const meta = await (await fetchWithTimeout(RADARS_DATASET)).json();
      const csv = (meta.resources || [])
        .filter((r) => String(r.format).toLowerCase() === "csv")
        .sort((a, b) => String(b.last_modified).localeCompare(String(a.last_modified)))[0];
      if (!csv) throw new Error("aucune ressource CSV dans le jeu de données");
      radarsCol.data.checkedAt = Date.now();
      if (radarsCol.data.resource?.url === csv.url && radarsCol.data.radars.length) {
        radarsCol.save();
        radarsError = null;
        return;
      }
      const res = await fetchWithTimeout(csv.url, {}, 120000);
      if (!res.ok) throw new Error(`CSV ${res.status}`);
      const text = new TextDecoder("latin1").decode(await res.arrayBuffer()); // fichier en ISO-8859-1
      const radars = parseRadarsCsv(text);
      if (radars.length < 500) throw new Error(`seulement ${radars.length} lignes valides`);
      radarsCol.data = { fetchedAt: Date.now(), checkedAt: Date.now(), resource: { url: csv.url, updated: csv.last_modified, title: csv.title }, radars };
      buildZones();
      radarsError = null;
      log(`safety : ${radars.length} radars fixes → ${zones.length} zones de danger (${csv.title})`);
    } catch (e) {
      radarsError = String(e.message || e);
      log("safety : radars indisponibles —", radarsError);
    }
  }

  // ---------------------------------------------------------------- ZFE
  const zfeCol = await store.collection("safety-zfe", { fetchedAt: 0, resource: null, features: [] });
  let zfeError = null;

  async function refreshZfe() {
    try {
      const meta = await (await fetchWithTimeout(ZFE_DATASET)).json();
      const res = (meta.resources || []).find((r) => /aires/i.test(r.title || "") && /geojson/i.test(r.format || ""));
      if (!res) throw new Error("ressource aires.geojson introuvable");
      const names = new Map();
      const codes = []; // [code ville sans accents, nom] pour deviner depuis l'URL quand l'identifiant est mal saisi
      try {
        const csv = await (await fetchWithTimeout(ZFE_NAMES)).text();
        for (const line of csv.split(/\r?\n/).slice(1)) {
          const [siren, code, epci, autres] = line.split(";");
          if (!siren) continue;
          names.set(siren, epci);
          for (const s of (autres || "").split(",").map((x) => x.trim()).filter(Boolean)) names.set(s, epci);
          const c = String(code || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().split(/[\s-]/)[0];
          if (c.length >= 4) codes.push([c, epci]);
        }
      } catch { /* noms facultatifs */ }
      const nameOf = (siren, url) =>
        names.get(siren) || names.get(siren.slice(0, 9)) || codes.find(([c]) => String(url || "").toLowerCase().includes(c))?.[1] || "Zone à faibles émissions";
      const gj = await (await fetchWithTimeout(res.url, {}, 120000)).json();
      const features = [];
      for (const f of gj.features || []) {
        const p = f.properties || {};
        const g = f.geometry;
        if (!g || !["Polygon", "MultiPolygon"].includes(g.type)) continue;
        const polys = g.type === "Polygon" ? [g.coordinates] : g.coordinates;
        const coordinates = polys.map((poly) => poly.map((ring) => simplify(ring, 0.00015)));
        const id = String(p.id || "");
        const siren = id.split("-")[0];
        const url = p.url_site_information || p.url_site || p.url_site_informations || null;
        features.push({
          type: "Feature",
          geometry: { type: "MultiPolygon", coordinates },
          properties: {
            id,
            name: nameOf(siren, url),
            vp: p.vp_critair ?? null,
            hours: p.vp_horaires && p.vp_horaires !== "NC" ? p.vp_horaires : null,
            from: p.date_debut ?? null,
            to: p.date_fin ?? p.date_fin_init ?? null,
            url,
          },
        });
      }
      if (!features.length) throw new Error("aucun périmètre");
      zfeCol.data = { fetchedAt: Date.now(), resource: { url: res.url, updated: res.updated }, features };
      zfeError = null;
      log(`safety : ${features.length} périmètres ZFE chargés`);
    } catch (e) {
      zfeError = String(e.message || e);
      log("safety : ZFE indisponibles —", zfeError);
    }
  }

  /** Règles ZFE en vigueur aujourd'hui (une par agglomération et par périmètre : la plus récente). */
  function activeZfe() {
    const today = new Date().toISOString().slice(0, 10);
    const byKey = new Map();
    for (const f of zfeCol.data.features) {
      const p = f.properties;
      if (p.from && p.from > today) continue;
      if (p.to && p.to < today) continue;
      const ring = f.geometry.coordinates[0]?.[0] || [];
      const key = `${p.id.split("-")[0]}|${ring.length}|${ring[0]?.join(",")}`;
      const prev = byKey.get(key);
      if (!prev || String(p.from) > String(prev.properties.from)) byKey.set(key, f);
    }
    return [...byKey.values()];
  }

  // ---------------------------------------------------------------- démarrage + rafraîchissement quotidien
  if (radarsCol.data.radars.length) buildZones();
  const refreshAll = async () => {
    if (Date.now() - radarsCol.data.checkedAt > DAY - 60000 || !radarsCol.data.radars.length) await refreshRadars();
    if (Date.now() - zfeCol.data.fetchedAt > DAY - 60000 || !zfeCol.data.features.length) await refreshZfe();
  };
  refreshAll(); // en arrière-plan : le serveur démarre sans attendre
  setInterval(refreshAll, 3600 * 1000).unref(); // vérifie toutes les heures, télécharge au plus 1×/jour

  // ---------------------------------------------------------------- API
  const parseBBox = (s) => {
    const b = String(s || "").split(",").map(Number);
    if (b.length !== 4 || b.some((x) => !Number.isFinite(x))) throw new HttpError(400, "bbox attendue : ouest,sud,est,nord");
    const [w, so, e, n] = b;
    if (w >= e || so >= n || e - w > 14 || n - so > 14 || Math.abs(so) > 90 || Math.abs(n) > 90) throw new HttpError(400, "bbox invalide ou trop grande");
    return [w, so, e, n];
  };

  route.get("/safety/zones", ({ query }) => {
    const [w, s, e, n] = parseBBox(query.bbox);
    const pad = 0.05; // ~4 km : les disques qui débordent dans la vue
    const list = zones.filter((z) => z.lng >= w - pad && z.lng <= e + pad && z.lat >= s - pad && z.lat <= n + pad).slice(0, 6000);
    return {
      available: zones.length > 0,
      error: zones.length ? null : radarsError || "chargement en cours",
      source: { name: "Liste des radars fixes en France (ministère de l'Intérieur)", page: RADARS_PAGE, updated: radarsCol.data.resource?.updated ?? null },
      lengths: ZONE_LENGTH,
      zones: list,
    };
  }, { limit: 120 });

  // Toutes les zones de France d'un coup (≈ 3 500 disques, mis à jour ~1×/an) : la carte les affiche
  // à tous les niveaux de zoom. Mêmes disques décalés que /safety/zones, jamais la position d'un radar.
  route.get("/safety/zones/all", () => ({
    available: zones.length > 0,
    error: zones.length ? null : radarsError || "chargement en cours",
    source: { name: "Liste des radars fixes en France (ministère de l'Intérieur)", page: RADARS_PAGE, updated: radarsCol.data.resource?.updated ?? null },
    lengths: ZONE_LENGTH,
    zones,
  }), { limit: 20 });

  route.get("/safety/zfe", () => {
    const features = activeZfe();
    return {
      available: zfeCol.data.features.length > 0,
      error: zfeCol.data.features.length ? null : zfeError || "chargement en cours",
      source: { name: "Base nationale consolidée des ZFE (transport.data.gouv.fr)", page: ZFE_PAGE, updated: zfeCol.data.resource?.updated ?? null },
      type: "FeatureCollection",
      features,
    };
  }, { limit: 30 });

  route.get("/safety/status", () => ({
    radars: { count: radarsCol.data.radars.length, zones: zones.length, checkedAt: radarsCol.data.checkedAt, resource: radarsCol.data.resource, error: radarsError },
    zfe: { features: zfeCol.data.features.length, active: activeZfe().length, fetchedAt: zfeCol.data.fetchedAt, error: zfeError },
    pois: { tiles: Object.keys(poisCol.data.tiles).length, overpassPausedUntil: pausedUntil },
  }), { limit: 30 });

  // ---------------------------------------------------------------- passages à niveau + écoles (Overpass)
  const poisCol = await store.collection("safety-pois", { tiles: {} });
  let mirror = 0;
  let pausedUntil = 0; // pause après des échecs répétés (miroirs saturés)
  let failures = 0;
  let chain = Promise.resolve(); // une seule requête Overpass à la fois
  const inflight = new Map();

  async function overpassTiles(keys) {
    const boxes = keys.map((k) => { const [z, x, y] = k.split("/").map(Number); return tileBBox(z, x, y); });
    const parts = boxes.flatMap((b) => {
      const bb = `${b.s.toFixed(5)},${b.w.toFixed(5)},${b.n.toFixed(5)},${b.e.toFixed(5)}`;
      return [`node["railway"="level_crossing"](${bb});`, `nwr["amenity"="school"](${bb});`];
    });
    const q = `[out:json][timeout:40];(${parts.join("")});out center tags;`;
    let lastErr;
    for (let attempt = 0; attempt < OVERPASS.length; attempt++) {
      const url = OVERPASS[(mirror + attempt) % OVERPASS.length];
      try {
        const res = await fetchWithTimeout(url, { method: "POST", body: new URLSearchParams({ data: q }), headers: { "Content-Type": "application/x-www-form-urlencoded" } }, 50000);
        if (!res.ok) throw new Error(`${res.status}`);
        const json = await res.json();
        mirror = (mirror + attempt) % OVERPASS.length;
        failures = 0;
        const out = Object.fromEntries(keys.map((k) => [k, { t: Date.now(), lc: [], sc: [] }]));
        for (const el of json.elements || []) {
          const lat = el.lat ?? el.center?.lat, lng = el.lon ?? el.center?.lon;
          if (lat == null || lng == null) continue;
          const i = boxes.findIndex((b) => lng >= b.w && lng < b.e && lat >= b.s && lat < b.n);
          if (i < 0) continue;
          const pt = [Math.round(lng * 1e5) / 1e5, Math.round(lat * 1e5) / 1e5];
          if (el.tags?.railway === "level_crossing") out[keys[i]].lc.push(pt);
          else if (el.tags?.amenity === "school") out[keys[i]].sc.push(pt);
        }
        return out;
      } catch (e) {
        lastErr = e;
      }
    }
    failures++;
    pausedUntil = Date.now() + Math.min(15 * 60000, 30000 * 2 ** Math.min(failures, 5));
    throw new Error(`Overpass indisponible (${lastErr?.message || lastErr})`);
  }

  function prune() {
    const entries = Object.entries(poisCol.data.tiles);
    if (entries.length <= POI_MAX_TILES) return;
    entries.sort((a, b) => a[1].t - b[1].t);
    for (const [k] of entries.slice(0, entries.length - POI_MAX_TILES)) delete poisCol.data.tiles[k];
  }

  function fetchTiles(keys) {
    const todo = keys.filter((k) => !inflight.has(k));
    if (todo.length) {
      const p = (chain = chain.then(async () => {
        if (Date.now() < pausedUntil) throw new Error("Overpass en pause");
        const got = await overpassTiles(todo);
        Object.assign(poisCol.data.tiles, got);
        prune();
        poisCol.save();
        await new Promise((r) => setTimeout(r, 1500)); // politesse envers les serveurs publics
      }).finally(() => todo.forEach((k) => inflight.delete(k))));
      chain = p.catch(() => {});
      todo.forEach((k) => inflight.set(k, p));
    }
    return Promise.allSettled(keys.map((k) => inflight.get(k)));
  }

  route.post("/safety/pois", async ({ body }) => {
    const tiles = Array.isArray(body?.tiles) ? body.tiles : null;
    if (!tiles || tiles.length > 40) throw new HttpError(400, "tiles : liste de 1 à 40 tuiles z/x/y");
    const keys = [...new Set(tiles.map(String))].filter((k) => {
      const m = /^(\d+)\/(\d+)\/(\d+)$/.exec(k);
      return m && Number(m[1]) === POI_ZOOM && Number(m[2]) < 2 ** POI_ZOOM && Number(m[3]) < 2 ** POI_ZOOM;
    });
    if (keys.length !== tiles.length) throw new HttpError(400, `tuiles invalides (zoom ${POI_ZOOM} attendu)`);
    const now = Date.now();
    const missing = keys.filter((k) => !poisCol.data.tiles[k] || now - poisCol.data.tiles[k].t > POI_TTL);
    // au plus 4 nouvelles tuiles par appel (une seule requête Overpass groupée)
    const batch = missing.slice(0, 4);
    if (batch.length && now >= pausedUntil) {
      await Promise.race([fetchTiles(batch), new Promise((r) => setTimeout(r, 45000))]);
    }
    const out = {};
    for (const k of keys) if (poisCol.data.tiles[k]) out[k] = { lc: poisCol.data.tiles[k].lc, sc: poisCol.data.tiles[k].sc };
    return { zoom: POI_ZOOM, tiles: out, pending: keys.filter((k) => !out[k]), retryAfter: pausedUntil > Date.now() ? Math.ceil((pausedUntil - Date.now()) / 1000) : 0 };
  }, { limit: 30 });
}
