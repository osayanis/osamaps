// Trafic en direct d'OsaMaps.
//
// 1. Contributions anonymes (socket `traffic:ping`) : de petits segments « position précédente →
//    actuelle + vitesse + cap », avec un jeton éphémère par trajet. Agrégés par cellule (grille de
//    60 m × secteur de cap de 45°), gardés 15 min en mémoire. On compare à la vitesse habituelle de
//    la cellule (agrégats lissés persistés — jamais de traces individuelles) pour classer
//    fluide / ralenti / bouchon, et on repère les bouchons (≥ 3 cellules voisines lentes).
// 2. Données officielles réelles (Bison Futé / DIR, Licence Ouverte) :
//    - vitesses mesurées par les stations de comptage du réseau national (QTV-DIR, toutes les 6 min),
//    - évènements (accidents, travaux, fermetures… en DATEX II, Evenementiel-DIR).
//    Téléchargées à la demande (seulement si quelqu'un regarde) avec cache et requêtes conditionnelles.
//
// HTTP :  GET  /traffic?bbox=w,s,e,n          → GeoJSON de segments colorés (level ok|slow|jam)
//         GET  /traffic/events?bbox=w,s,e,n   → GeoJSON de points (accidents, travaux, fermetures…)
//         GET  /traffic/jams?bbox=w,s,e,n     → bouchons détectés (communauté)
//         POST /traffic/along { coords }       → ralentissements le long d'un tracé + retard estimé
//         GET  /traffic/status                 → état des sources (debug)
// Socket : traffic:ping { t: jeton du trajet, a: [lng,lat], b: [lng,lat], s: m/s, h: cap°, dt: s, ago: s }
//          (client → serveur), traffic:watch { bbox } (abonnement à une zone),
//          traffic:update { features, removed, jams } (serveur → zone, quand ça change).
import { HttpError } from "../lib/router.js";

// ───────────────────────────── réglages ─────────────────────────────
const CELL_M = 60;                        // taille d'une cellule
const DLAT = CELL_M / 111_320;            // pas en latitude
const SECTORS = 8;                        // secteurs de cap (45°)
const WINDOW_MS = 15 * 60_000;            // fenêtre glissante
const HALF_LIFE_MS = 4 * 60_000;          // les observations récentes pèsent plus
const MIN_OBS = 2;                        // une cellule n'est affichée qu'à partir de 2 observations
const JAM_MIN_CELLS = 3;                  // bouchon = au moins 3 cellules voisines lentes
const ZONE_DEG = 0.5;                     // zones de diffusion socket (≈ 55 × 38 km)
const TICK_MS = 10_000;
const MAX_BBOX_DEG = 4;
const USUAL_MAX_CELLS = 400_000;

const QTV_URL = "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/publicationsDIR/QTV-DIR/qtvDir.xml";
const QTV_REF_URL = "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/publicationsDIR/QTV-DIR/refDir.csv";
const EVENTS_URL = "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/publicationsDIR/Evenementiel-DIR/grt/RRN/content.xml";
const QTV_TTL = 6 * 60_000;
const QTV_REF_TTL = 24 * 3600_000;
const EVENTS_TTL = 10 * 60_000;
const DEMAND_KEEPALIVE = 20 * 60_000;     // on ne rafraîchit les sources que si quelqu'un a regardé récemment
const UA = "OsaMaps/0.1 (+https://osalabs.fr/maps/)";

// ───────────────────────────── géométrie ─────────────────────────────
const RAD = Math.PI / 180;
function dist(a, b) {
  const dLat = (b[1] - a[1]) * RAD, dLng = (b[0] - a[0]) * RAD;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371008.8 * Math.asin(Math.sqrt(h));
}
function bearing(a, b) {
  const y = Math.sin((b[0] - a[0]) * RAD) * Math.cos(b[1] * RAD);
  const x = Math.cos(a[1] * RAD) * Math.sin(b[1] * RAD) - Math.sin(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.cos((b[0] - a[0]) * RAD);
  return (Math.atan2(y, x) / RAD + 360) % 360;
}
const angDiff = (a, b) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };
/** Point à `m` mètres de p dans la direction `h` (approximation locale). */
function offsetPoint(p, h, m) {
  const dy = (m * Math.cos(h * RAD)) / 111_320;
  const dx = (m * Math.sin(h * RAD)) / (111_320 * Math.cos(p[1] * RAD));
  return [round6(p[0] + dx), round6(p[1] + dy)];
}
const round6 = (x) => Math.round(x * 1e6) / 1e6;

/** Lambert-93 (RGF93, EPSG:2154) → [lng, lat] WGS84 (RGF93 ≈ WGS84 au mètre près). */
function lambert93ToWgs84(x, y) {
  const n = 0.7256077650532670, c = 11754255.4261, xs = 700000, ys = 12655612.0499, e = 0.0818191910428158;
  const dx = x - xs, dy = y - ys;
  const R = Math.sqrt(dx * dx + dy * dy);
  const gamma = Math.atan(dx / -dy);
  const lng = 3 + gamma / n / RAD;
  const latIso = -Math.log(Math.abs(R / c)) / n;
  let lat = 2 * Math.atan(Math.exp(latIso)) - Math.PI / 2;
  for (let i = 0; i < 8; i++) {
    const es = e * Math.sin(lat);
    lat = 2 * Math.atan(((1 + es) / (1 - es)) ** (e / 2) * Math.exp(latIso)) - Math.PI / 2;
  }
  return [round6(lng), round6(lat / RAD)];
}

function parseBbox(q) {
  const b = String(q.bbox ?? "").split(",").map(Number);
  if (b.length !== 4 || b.some((x) => !Number.isFinite(x))) throw new HttpError(400, "bbox attendu : ouest,sud,est,nord");
  const [w, s, e, n] = b;
  if (w >= e || s >= n || w < -180 || e > 180 || s < -85 || n > 85) throw new HttpError(400, "bbox invalide");
  if (e - w > MAX_BBOX_DEG || n - s > MAX_BBOX_DEG) throw new HttpError(400, "zone trop grande, zoome un peu");
  return [w, s, e, n];
}
const inBbox = (p, [w, s, e, n]) => p[0] >= w && p[0] <= e && p[1] >= s && p[1] <= n;
const lineInBbox = (coords, bb) => coords.some((p) => inBbox(p, bb));
const isLngLat = (p) => Array.isArray(p) && p.length === 2 && Number.isFinite(p[0]) && Number.isFinite(p[1])
  && p[0] >= -180 && p[0] <= 180 && p[1] >= -85 && p[1] <= 85;

// ───────────────────────────── classement ─────────────────────────────
/**
 * Niveau d'une vitesse v (km/h) par rapport à la vitesse fluide habituelle f (km/h, null si
 * inconnue). Sans historique, on reste prudent : seuils absolus (une rue à 30 n'est pas un bouchon).
 */
function classify(v, f) {
  if (v >= 70) return "ok";
  if (f && f > 0) {
    const r = v / f;
    if (r < 0.3 || (v < 10 && f >= 25)) return "jam";
    if (r < 0.6) return "slow";
    return "ok";
  }
  if (v < 8) return "jam";
  if (v < 18) return "slow";
  return "ok";
}
/**
 * Retard (s) sur une portion de `len` mètres couverte par des morceaux { len, v, ref } qui peuvent
 * se recouvrir : moyennes harmoniques pondérées par la longueur, appliquées à la longueur réelle.
 */
function runDelay(len, parts) {
  let w = 0, inv = 0, invRef = 0;
  for (const p of parts) {
    const v = Math.max(p.v, 3), ref = Math.max(p.ref || 45, v);
    w += p.len; inv += p.len / v; invRef += p.len / ref;
  }
  return w ? Math.max(0, len * 3.6 * (inv - invRef) / w) : 0;
}
/** Retard (s) pour parcourir `len` mètres à v au lieu de la vitesse de référence. */
function delayFor(len, v, ref) {
  const r = Math.max(ref || 45, v);
  return Math.max(0, (len * 3.6) / Math.max(v, 3) - (len * 3.6) / r);
}

// ───────────────────────────── cellules ─────────────────────────────
function cellOf(lng, lat, heading) {
  const row = Math.floor(lat / DLAT);
  const dLng = DLAT / Math.cos((row + 0.5) * DLAT * RAD);
  const col = Math.floor(lng / dLng);
  const sec = Math.floor(((heading + 22.5) % 360) / (360 / SECTORS)) % SECTORS;
  return { key: `${row}:${col}:${sec}`, row, col, sec };
}
const zoneOf = (lng, lat) => `traffic:z:${Math.floor(lng / ZONE_DEG)}:${Math.floor(lat / ZONE_DEG)}`;

// ───────────────────────────── XML léger (DATEX II) ─────────────────────────────
const tagRe = (name) => new RegExp(`<(?:\\w+:)?${name}\\b[^>]*>([\\s\\S]*?)</(?:\\w+:)?${name}>`, "g");
const first = (s, name) => { const m = tagRe(name).exec(s); return m ? m[1] : null; };
const all = (s, name) => [...s.matchAll(tagRe(name))].map((m) => m[1]);
const decode = (s) => s?.replace(/<[^>]+>/g, "").replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"')
  .replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/&amp;/g, "&").trim() ?? null;

async function fetchText(url, prev) {
  const headers = { "User-Agent": UA };
  if (prev?.etag) headers["If-None-Match"] = prev.etag;
  if (prev?.lastModified) headers["If-Modified-Since"] = prev.lastModified;
  const r = await fetch(url, { headers, signal: AbortSignal.timeout(45_000) });
  if (r.status === 304) return { notModified: true };
  if (!r.ok) throw new Error(`${url} → HTTP ${r.status}`);
  return { text: await r.text(), etag: r.headers.get("etag"), lastModified: r.headers.get("last-modified") };
}

/** Numéro de route DATEX (« A0075 », « N0125 ») → « A75 », « N125 ». */
const roadName = (s) => (s ? s.replace(/^([A-Z]+)0*(\d)/, "$1$2") : null);

const EVENT_KINDS = {
  Accident: "accident",
  VehicleObstruction: "obstacle", GeneralObstruction: "obstacle", EnvironmentalObstruction: "obstacle",
  InfrastructureDamageObstruction: "obstacle", AnimalPresenceObstruction: "obstacle", EquipmentOrSystemFault: "obstacle",
  MaintenanceWorks: "works", ConstructionWorks: "works",
  AbnormalTraffic: "slow",
  WeatherRelatedRoadConditions: "conditions", NonWeatherRelatedRoadConditions: "conditions", PoorEnvironmentConditions: "conditions",
};
const KIND_RANK = { closure: 0, accident: 1, slow: 2, obstacle: 3, conditions: 4, works: 5, lanes: 6 };
const KIND_TITLE = {
  closure: "Route fermée", accident: "Accident", slow: "Ralentissement signalé", obstacle: "Obstacle sur la route",
  conditions: "Conditions difficiles", works: "Travaux", lanes: "Voies réduites",
};
const SUBTYPE_TITLE = {
  brokenDownVehicle: "Véhicule en panne", objectOnTheRoad: "Objet sur la chaussée", rockfalls: "Chute de pierres",
  subsidence: "Affaissement de chaussée", queuingTraffic: "Bouchon signalé", slowTraffic: "Ralentissement signalé",
  singleAlternateLineTraffic: "Circulation alternée", contraflow: "Basculement de circulation", narrowLanes: "Voies rétrécies",
  laneClosures: "Voies fermées", roadClosed: "Route fermée", closedPermanentlyForTheWinter: "Fermé pour l'hiver",
  weightRestrictionInOperation: "Restriction de tonnage", grassCuttingWork: "Fauchage", resurfacingWork: "Réfection de chaussée",
  roadMarkingWork: "Marquage au sol", repairWork: "Réparations",
};

function parseEvents(xml, now = Date.now()) {
  const best = new Map(); // situation id → meilleur enregistrement
  for (const sit of xml.split(/<(?:\w+:)?situation\s/).slice(1)) {
    const sitId = /^id="([^"]+)"/.exec(sit)?.[1] ?? Math.random().toString(36);
    const severity = first(sit, "overallSeverity");
    for (const rec of sit.split(/<(?:\w+:)?situationRecord\s/).slice(1)) {
      const type = /xsi:type="(?:\w+:)?(\w+)"/.exec(rec)?.[1];
      if (!type) continue;
      let kind = EVENT_KINDS[type] ?? null;
      let sub = null;
      if (type === "RoadOrCarriagewayOrLaneManagement") {
        sub = first(rec, "roadOrCarriagewayOrLaneManagementType");
        kind = sub === "roadClosed" || sub === "closedPermanentlyForTheWinter" ? "closure" : "lanes";
      }
      if (!kind) continue;
      if (first(rec, "validityStatus") === "suspended") continue;
      const start = Date.parse(first(rec, "overallStartTime") ?? "");
      const endRaw = first(rec, "overallEndTime");
      const end = endRaw ? Date.parse(endRaw) : null;
      if (Number.isFinite(start) && start > now) continue;           // pas encore commencé
      if (end && Number.isFinite(end) && end < now) continue;       // terminé
      const pts = all(rec, "pointCoordinates").map((pc) => [Number(first(pc, "longitude")), Number(first(pc, "latitude"))]).filter(isLngLat);
      if (!pts.length) continue;
      // Linear : <to> est souvent écrit avant <from> ; on prend <from> comme début de zone.
      const fromBlock = first(rec, "from");
      const fromPt = fromBlock ? [Number(first(fromBlock, "longitude")), Number(first(fromBlock, "latitude"))] : null;
      const coord = fromPt && isLngLat(fromPt) ? fromPt : pts[0];
      sub ??= first(rec, "accidentType") ?? first(rec, "vehicleObstructionType") ?? first(rec, "obstructionType")
        ?? first(rec, "environmentalObstructionType") ?? first(rec, "abnormalTrafficType") ?? first(rec, "roadMaintenanceType");
      const comments = all(rec, "generalPublicComment").map((g) => ({ type: first(g, "commentType"), text: decode(first(g, "value")) }));
      const description = comments.find((c) => c.type === "description")?.text ?? null;
      const where = comments.filter((c) => c.type === "locationDescriptor").map((c) => c.text)
        .filter((t) => t && !/^DIR |\/District|\/CEI/.test(t)).slice(0, 2);
      const linkName = all(rec, "name").find((n) => /linkName/.test(n));
      const road = roadName(first(rec, "roadNumber")) ?? (linkName ? decode(first(linkName, "value")) : null);
      const source = decode(first(rec, "sourceIdentification"))?.replace(/^Direction interdépartementale des routes\//, "") ?? null;
      const ev = {
        id: /^[^>]*id="([^"]+)"/.exec(rec)?.[1] ?? sitId,
        kind,
        title: SUBTYPE_TITLE[sub] ?? KIND_TITLE[kind],
        road,
        description: description?.slice(0, 300) ?? null,
        where: where.join(" · ").slice(0, 200) || null,
        source,
        severity,
        end: end && Number.isFinite(end) ? new Date(end).toISOString() : null,
        coord,
      };
      const prev = best.get(sitId);
      if (!prev || KIND_RANK[kind] < KIND_RANK[prev.kind]) best.set(sitId, ev);
    }
  }
  return [...best.values()];
}

function parseQtvRef(csv) {
  const lines = csv.trim().split(/\r?\n/);
  const out = new Map();
  for (const line of lines.slice(1)) {
    const r = line.split(";");
    const n = r.length;
    // l'en-tête annonce une colonne « source_2 » absente des lignes : on lit les colonnes par la fin
    const x1 = Number(r[n - 5]), y1 = Number(r[n - 4]), x2 = Number(r[n - 3]), y2 = Number(r[n - 2]);
    if (!r[n - 5] || !r[n - 3] || ![x1, y1, x2, y2].every(Number.isFinite)) continue;
    if (Math.hypot(x2 - x1, y2 - y1) < 50) continue;          // station sans tronçon : rien à dessiner
    const prDeb = r[n - 15] ?? "";
    let a = lambert93ToWgs84(x1, y1), b = lambert93ToWgs84(x2, y2);
    // coordonnées dans le sens des PR croissants : on inverse pour le sens « G » (décroissant)
    if (/G$/.test(prDeb)) [a, b] = [b, a];
    if (!isLngLat(a) || !isLngLat(b)) continue;
    out.set(r[0], { code: r[0], road: r[n - 16] || null, coords: [a, b], len: dist(a, b) });
  }
  return out;
}

function parseQtv(xml) {
  const out = new Map();
  for (const s of xml.split(/<(?:\w+:)?siteMeasurements>/).slice(1)) {
    const id = /measurementSiteReference[^>]*id="([^"]+)"/.exec(s)?.[1];
    const speed = Number(first(s, "speed"));
    const used = Number(/averageVehicleSpeed numberOfInputValuesUsed="(\d+)"/.exec(s)?.[1] ?? 0);
    const flow = Number(first(s, "vehicleFlowRate") ?? 0);
    // vitesse 0 = pas de mesure (capteur absent ou en panne), pas un bouchon
    if (!id || !Number.isFinite(speed) || speed < 3 || speed > 200 || used <= 0 || flow <= 0) continue;
    out.set(id, { speed, flow });
  }
  return out;
}

// ───────────────────────────── fonctionnalité ─────────────────────────────
export async function register({ io, route, store, log }) {
  /** Vitesse habituelle par cellule (agrégats seulement) : clé → [moyenne, fluide, n]. */
  const usual = await store.collection("traffic-usual", {});
  /** Vitesse fluide apprise par station officielle : code → [fluide, n]. */
  const dirUsual = await store.collection("traffic-dir-usual", {});

  /** Cellules vivantes : clé → { row, col, sec, obs: [{ t, v, tok, lng, lat, h }] } */
  const cells = new Map();
  /** Dernier état calculé par cellule (clé → { level, v, f, delay, center, h, tokens }) */
  let states = new Map();
  let jams = [];
  /** Signature diffusée par id de feature (pour n'envoyer que les changements). */
  const sent = new Map();
  let lastDemand = 0;
  const stats = { pings: 0, rejected: 0 };

  // ── sources officielles ──
  const qtv = { ref: null, refAt: 0, refMeta: null, data: new Map(), at: 0, meta: null, features: new Map(), busy: false, error: null, published: null };
  const events = { list: [], at: 0, meta: null, busy: false, error: null };

  async function refreshQtv(force = false) {
    if (qtv.busy || (!force && Date.now() - qtv.at < QTV_TTL)) return;
    qtv.busy = true;
    try {
      if (!qtv.ref || Date.now() - qtv.refAt > QTV_REF_TTL) {
        const r = await fetchText(QTV_REF_URL, qtv.refMeta);
        if (!r.notModified) { qtv.ref = parseQtvRef(r.text); qtv.refMeta = r; delete qtv.refMeta.text; }
        qtv.refAt = Date.now();
      }
      const r = await fetchText(QTV_URL, qtv.meta);
      qtv.at = Date.now();
      if (r.notModified) return;
      qtv.meta = { etag: r.etag, lastModified: r.lastModified };
      qtv.published = first(r.text.slice(0, 4000), "publicationTime");
      qtv.data = parseQtv(r.text);
      const features = new Map();
      for (const [code, m] of qtv.data) {
        const st = qtv.ref?.get(code);
        if (!st) continue;
        const u = (dirUsual.data[code] ??= [/^A/.test(st.road ?? "") ? 100 : 80, 0]);
        // vitesse fluide : monte vite, descend très lentement (un bouchon ne la fait pas baisser)
        u[0] = Math.round((m.speed > u[0] ? u[0] + 0.2 * (m.speed - u[0]) : u[0] + 0.01 * (m.speed - u[0])) * 10) / 10;
        u[1] = Math.min(u[1] + 1, 1e6);
        const level = classify(m.speed, u[0]);
        features.set(`dir-${code}`, {
          type: "Feature",
          geometry: { type: "LineString", coordinates: st.coords },
          properties: { id: `dir-${code}`, src: "dir", level, speed: Math.round(m.speed), usual: Math.round(u[0]), road: st.road,
            delay: Math.round(delayFor(st.len, m.speed, u[0])), len: Math.round(st.len) },
        });
      }
      dirUsual.save();
      qtv.features = features;
      qtv.error = null;
      log(`trafic : ${features.size} tronçons mesurés (Bison Futé QTV, ${qtv.published ?? "?"})`);
      broadcastChanges();
    } catch (e) {
      qtv.error = String(e.message ?? e);
      qtv.at = Date.now() - QTV_TTL + 60_000; // on retente dans 1 min
      log("trafic : QTV indisponible —", qtv.error);
    } finally {
      qtv.busy = false;
    }
  }

  async function refreshEvents(force = false) {
    if (events.busy || (!force && Date.now() - events.at < EVENTS_TTL)) return;
    events.busy = true;
    try {
      const r = await fetchText(EVENTS_URL, events.meta);
      events.at = Date.now();
      if (!r.notModified) {
        events.meta = { etag: r.etag, lastModified: r.lastModified };
        events.list = parseEvents(r.text);
        log(`trafic : ${events.list.length} évènements en cours (Bison Futé)`);
      } else {
        // les validités dépendent de l'heure : on refiltre les fins dépassées
        events.list = events.list.filter((e) => !e.end || Date.parse(e.end) >= Date.now());
      }
      events.error = null;
    } catch (e) {
      events.error = String(e.message ?? e);
      events.at = Date.now() - EVENTS_TTL + 60_000;
      log("trafic : évènements indisponibles —", events.error);
    } finally {
      events.busy = false;
    }
  }

  /** Quelqu'un regarde le trafic : on garde les sources à jour (sans bloquer la réponse). */
  function demand() {
    lastDemand = Date.now();
    refreshQtv();
    refreshEvents();
  }

  // ── contributions ──
  function addObservation(lng, lat, h, v, tok, now) {
    const c = cellOf(lng, lat, h);
    let cell = cells.get(c.key);
    if (!cell) cells.set(c.key, (cell = { ...c, obs: [] }));
    const firstFromTok = !cell.obs.some((o) => o.tok === tok);
    cell.obs.push({ t: now, v, tok, lng, lat, h });
    if (cell.obs.length > 200) cell.obs.splice(0, cell.obs.length - 200);
    // vitesse habituelle : une seule contribution par trajet et par cellule
    if (firstFromTok) {
      const u = (usual.data[c.key] ??= [v, v, 0]);
      const a = Math.max(1 / (u[2] + 1), 0.02);
      u[0] = Math.round((u[0] + a * (v - u[0])) * 10) / 10;
      u[1] = Math.round((v > u[1] ? u[1] + Math.max(a, 0.25) * (v - u[1]) : u[1] + Math.min(a, 0.03) * (v - u[1])) * 10) / 10;
      u[2] = Math.min(u[2] + 1, 1e6);
      usual.save();
    }
  }

  function handlePing(p, now) {
    if (!p || typeof p !== "object") return false;
    const { t: tok, a, b, s, h, dt, ago = 0 } = p;
    if (typeof tok !== "string" || !/^[A-Za-z0-9_-]{8,40}$/.test(tok)) return false;
    if (!isLngLat(a) || !isLngLat(b)) return false;
    if (typeof dt !== "number" || !(dt >= 1 && dt <= 30)) return false;
    if (s != null && (typeof s !== "number" || !(s >= 0 && s <= 70))) return false;
    if (h != null && (typeof h !== "number" || !(h >= 0 && h < 360))) return false;
    // `ago` : le client retient ses segments jusqu'à s'être éloigné de 300 m (vie privée) → âge en s
    if (typeof ago !== "number" || !(ago >= 0 && ago <= WINDOW_MS / 1000)) return false;
    const tObs = now - ago * 1000;
    const d = dist(a, b);
    if (d > 70 * dt + 30) return false;                          // téléportation
    const vSeg = d / dt;
    if (s != null && d > 20 && Math.abs(vSeg - s) > 15) return false; // incohérent
    const v = (s ?? vSeg) * 3.6;
    const heading = d > 5 ? bearing(a, b) : h;
    if (heading == null) return false;                           // à l'arrêt sans cap : inutilisable
    // on « pixellise » le segment : une observation par cellule traversée
    const steps = Math.max(1, Math.ceil(d / (CELL_M / 2)));
    const seen = new Set();
    for (let i = 0; i < steps; i++) {
      const f = steps === 1 ? 1 : (i + 0.5) / steps;
      const lng = a[0] + (b[0] - a[0]) * f, lat = a[1] + (b[1] - a[1]) * f;
      const k = cellOf(lng, lat, heading).key;
      if (seen.has(k)) continue;
      seen.add(k);
      addObservation(lng, lat, heading, v, tok, tObs);
    }
    return true;
  }

  // ── calcul des états + bouchons ──
  function computeState(cell, now) {
    cell.obs = cell.obs.filter((o) => now - o.t < WINDOW_MS);
    if (cell.obs.length < MIN_OBS) return null;
    let sw = 0, swInv = 0, sl = 0, sa = 0, hx = 0, hy = 0;
    const toks = new Set();
    for (const o of cell.obs) {
      const w = 0.5 ** ((now - o.t) / HALF_LIFE_MS);
      sw += w; swInv += w / Math.max(o.v, 2);
      sl += w * o.lng; sa += w * o.lat;
      hx += w * Math.cos(o.h * RAD); hy += w * Math.sin(o.h * RAD);
      toks.add(o.tok);
    }
    const v = sw / swInv; // moyenne harmonique : c'est elle qui donne le temps de parcours
    const u = usual.data[`${cell.row}:${cell.col}:${cell.sec}`];
    const f = u && u[2] >= 8 ? u[1] : null;
    const level = classify(v, f);
    const h = (Math.atan2(hy, hx) / RAD + 360) % 360;
    return { key: `${cell.row}:${cell.col}:${cell.sec}`, row: cell.row, col: cell.col, sec: cell.sec, level, v, f, h,
      center: [sl / sw, sa / sw], tokens: toks.size, delay: delayFor(CELL_M, v, f) };
  }

  function cellFeature(st) {
    const a = offsetPoint(st.center, st.h, -CELL_M * 0.55), b = offsetPoint(st.center, st.h, CELL_M * 0.55);
    return {
      type: "Feature",
      geometry: { type: "LineString", coordinates: [a, b] },
      properties: { id: st.key, src: "osa", level: st.level, speed: Math.round(st.v), usual: st.f ? Math.round(st.f) : null,
        delay: Math.round(st.delay), n: st.tokens },
    };
  }

  function detectJams(map) {
    const byRc = new Map();
    for (const st of map.values()) {
      if (st.level === "ok") continue;
      const k = `${st.row}:${st.col}`;
      (byRc.get(k) ?? byRc.set(k, []).get(k)).push(st);
    }
    const done = new Set();
    const out = [];
    for (const list of byRc.values()) for (const start of list) {
      if (done.has(start.key)) continue;
      const comp = [];
      const queue = [start];
      done.add(start.key);
      while (queue.length) {
        const c = queue.pop();
        comp.push(c);
        for (let dr = -1; dr <= 1; dr++) for (let dc = -1; dc <= 1; dc++) {
          for (const nb of byRc.get(`${c.row + dr}:${c.col + dc}`) ?? []) {
            if (done.has(nb.key)) continue;
            const ds = Math.min((nb.sec - c.sec + SECTORS) % SECTORS, (c.sec - nb.sec + SECTORS) % SECTORS);
            if (ds > 1) continue;
            done.add(nb.key);
            queue.push(nb);
          }
        }
      }
      if (comp.length < JAM_MIN_CELLS) continue;
      // ordonne les cellules le long du cap moyen
      let hx = 0, hy = 0;
      for (const c of comp) { hx += Math.cos(c.h * RAD); hy += Math.sin(c.h * RAD); }
      const h = (Math.atan2(hy, hx) / RAD + 360) % 360;
      const ux = Math.sin(h * RAD), uy = Math.cos(h * RAD);
      const k = Math.cos(comp[0].center[1] * RAD);
      comp.sort((p, q) => (p.center[0] * k * ux + p.center[1] * uy) - (q.center[0] * k * ux + q.center[1] * uy));
      const jamCells = comp.filter((c) => c.level === "jam").length;
      const tokens = Math.max(...comp.map((c) => c.tokens));
      let length = CELL_M;
      for (let i = 1; i < comp.length; i++) length += Math.min(dist(comp[i - 1].center, comp[i].center), CELL_M * 2);
      out.push({
        id: `j-${comp[0].key}`,
        level: jamCells * 3 >= comp.length ? "jam" : "slow",
        cells: comp.length,
        length: Math.round(length),
        delay: Math.round(runDelay(length, comp.map((c) => ({ len: CELL_M, v: c.v, ref: c.f })))),
        speed: Math.round(Math.min(...comp.map((c) => c.v))),
        heading: Math.round(h),
        start: comp[0].center.map(round6),
        end: comp[comp.length - 1].center.map(round6),
        contributors: tokens,
      });
    }
    return out;
  }

  function recompute(now = Date.now()) {
    const next = new Map();
    for (const [key, cell] of cells) {
      const st = computeState(cell, now);
      if (!cell.obs.length) { cells.delete(key); continue; }
      if (st) next.set(key, st);
    }
    states = next;
    jams = detectJams(states);
  }

  function liveFeatures() {
    const out = new Map(qtv.features);
    for (const st of states.values()) out.set(st.key, cellFeature(st));
    return out;
  }

  /** Envoie à chaque zone les features qui ont changé depuis la dernière diffusion. */
  function broadcastChanges() {
    const feats = liveFeatures();
    const byZone = new Map();
    const push = (zone, kind, item) => {
      let z = byZone.get(zone);
      if (!z) byZone.set(zone, (z = { features: [], removed: [] }));
      z[kind].push(item);
    };
    for (const [id, f] of feats) {
      const p = f.properties;
      const sig = `${p.level}|${Math.round(p.speed / 5)}`;
      if (sent.get(id)?.sig === sig) continue;
      const c = f.geometry.coordinates[0];
      sent.set(id, { sig, zone: zoneOf(c[0], c[1]) });
      push(zoneOf(c[0], c[1]), "features", f);
    }
    for (const [id, s] of sent) {
      if (feats.has(id)) continue;
      sent.delete(id);
      push(s.zone, "removed", id);
    }
    const rooms = io.of("/").adapter.rooms;
    for (const [zone, z] of byZone) {
      if (!rooms.has(zone)) continue;
      const zj = jams.filter((j) => zoneOf(j.start[0], j.start[1]) === zone);
      io.to(zone).emit("traffic:update", { ...z, jams: zj });
    }
  }

  const timer = setInterval(() => {
    recompute();
    broadcastChanges();
    if (Date.now() - lastDemand < DEMAND_KEEPALIVE) { refreshQtv(); refreshEvents(); }
  }, TICK_MS);
  timer.unref?.();

  // ── socket ──
  io.on("connection", (socket) => {
    let lastPing = 0;
    const tokens = [];
    socket.on("traffic:ping", (p) => {
      const now = Date.now();
      if (now - lastPing < 3000) { stats.rejected++; return; }      // ≤ 1 ping / 3 s par connexion
      // une connexion ne peut pas se faire passer pour beaucoup de voitures
      if (p && typeof p.t === "string" && !tokens.includes(p.t)) {
        tokens.push(p.t);
        if (tokens.length > 6) { stats.rejected++; return; }
      }
      lastPing = now;
      if (handlePing(p, now)) stats.pings++; else stats.rejected++;
    });
    socket.on("traffic:watch", (p) => {
      for (const room of socket.rooms) if (room.startsWith("traffic:z:")) socket.leave(room);
      const b = p?.bbox;
      if (!Array.isArray(b) || b.length !== 4 || !b.every(Number.isFinite)) return;
      let [w, s, e, n] = b;
      if (w >= e || s >= n) return;
      // zone trop grande : on se limite au centre (≤ 5 × 5 zones)
      const cx = (w + e) / 2, cy = (s + n) / 2, half = ZONE_DEG * 2.5;
      w = Math.max(w, cx - half); e = Math.min(e, cx + half); s = Math.max(s, cy - half); n = Math.min(n, cy + half);
      for (let x = Math.floor(w / ZONE_DEG); x <= Math.floor(e / ZONE_DEG); x++)
        for (let y = Math.floor(s / ZONE_DEG); y <= Math.floor(n / ZONE_DEG); y++) socket.join(`traffic:z:${x}:${y}`);
      demand();
    });
  });

  // ── HTTP ──
  route.get("/traffic", ({ query }) => {
    const bb = parseBbox(query);
    demand();
    const features = [];
    for (const f of liveFeatures().values()) if (lineInBbox(f.geometry.coordinates, bb)) features.push(f);
    return {
      type: "FeatureCollection",
      features: features.slice(0, 8000),
      jams: jams.filter((j) => inBbox(j.start, bb) || inBbox(j.end, bb)),
      sources: { dir: qtv.published, community: states.size },
    };
  }, { limit: 120 });

  route.get("/traffic/events", ({ query }) => {
    const bb = parseBbox(query);
    demand();
    return {
      type: "FeatureCollection",
      features: events.list.filter((e) => inBbox(e.coord, bb)).slice(0, 2000).map((e) => ({
        type: "Feature",
        geometry: { type: "Point", coordinates: e.coord },
        properties: { ...e, coord: undefined },
      })),
    };
  }, { limit: 120 });

  route.get("/traffic/jams", ({ query }) => {
    const bb = parseBbox(query);
    return { jams: jams.filter((j) => inBbox(j.start, bb) || inBbox(j.end, bb)) };
  });

  route.post("/traffic/along", ({ body }) => {
    const coords = body?.coords;
    if (!Array.isArray(coords) || coords.length < 2 || coords.length > 2000 || !coords.every(isLngLat)) {
      throw new HttpError(400, "coords : 2 à 2000 points [lng, lat]");
    }
    demand();
    return along(coords);
  }, { limit: 40 });

  route.get("/traffic/status", () => ({
    community: { cells: cells.size, shown: states.size, jams: jams.length, usualCells: Object.keys(usual.data).length, ...stats },
    dir: { stations: qtv.ref?.size ?? 0, measured: qtv.features.size, published: qtv.published, fetchedAt: qtv.at || null, error: qtv.error },
    events: { count: events.list.length, fetchedAt: events.at || null, error: events.error },
  }));

  /**
   * Ralentissements le long d'un tracé (le début du tracé = position actuelle). Pour chaque
   * cellule lente / tronçon officiel lent proche du tracé ET dans le même sens, on calcule sa
   * distance depuis le début, puis on regroupe en « portions ».
   */
  function along(coords) {
    const cum = [0];
    for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + dist(coords[i - 1], coords[i]));
    // index spatial des segments du tracé (tuiles de 0,01°)
    const T = 0.01, grid = new Map();
    for (let i = 1; i < coords.length; i++) {
      const a = coords[i - 1], b = coords[i];
      for (let x = Math.floor(Math.min(a[0], b[0]) / T); x <= Math.floor(Math.max(a[0], b[0]) / T); x++)
        for (let y = Math.floor(Math.min(a[1], b[1]) / T); y <= Math.floor(Math.max(a[1], b[1]) / T); y++) {
          const k = `${x}:${y}`;
          (grid.get(k) ?? grid.set(k, []).get(k)).push(i);
        }
    }
    function snap(p) {
      const k = Math.cos(p[1] * RAD);
      let best = null;
      const cand = new Set();
      const gx = Math.floor(p[0] / T), gy = Math.floor(p[1] / T);
      for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) for (const i of grid.get(`${gx + dx}:${gy + dy}`) ?? []) cand.add(i);
      for (const i of cand) {
        const a = coords[i - 1], b = coords[i];
        const ax = (a[0] - p[0]) * k, ay = a[1] - p[1], bx = (b[0] - p[0]) * k, by = b[1] - p[1];
        const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
        const t = len2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2)) : 0;
        const q = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
        const off = dist(p, q);
        if (!best || off < best.off) best = { off, along: cum[i - 1] + dist(a, q), brg: bearing(a, b) };
      }
      return best;
    }
    const items = [];
    for (const st of states.values()) {
      if (st.level === "ok") continue;
      const s = snap(st.center);
      if (!s || s.off > 35 || angDiff(s.brg, st.h) > 60) continue;
      items.push({ from: s.along - CELL_M / 2, to: s.along + CELL_M / 2, level: st.level, v: st.v, ref: st.f, src: "osa" });
    }
    for (const f of qtv.features.values()) {
      const p = f.properties;
      if (p.level === "ok") continue;
      const [a, b] = f.geometry.coordinates;
      const sa = snap(a), sb = snap(b);
      if (!sa || !sb || sa.off > 80 || sb.off > 80 || sb.along <= sa.along) continue; // pas sur le tracé / sens inverse
      items.push({ from: sa.along, to: sb.along, level: p.level, v: p.speed, ref: p.usual, src: "dir" });
    }
    items.sort((p, q) => p.from - q.from);
    const runs = [];
    for (const it of items) {
      const last = runs[runs.length - 1];
      const part = { len: it.to - it.from, v: it.v, ref: it.ref };
      if (last && it.from - last.to < 200) {
        // longueur couverte (union des intervalles, les cellules se recouvrent)
        last.covered += Math.max(0, it.to - Math.max(it.from, last.to));
        last.to = Math.max(last.to, it.to);
        last.parts.push(part);
        if (it.level === "jam") last.jamLen += part.len;
        last.srcs.add(it.src);
      } else {
        runs.push({ from: it.from, to: it.to, covered: part.len, parts: [part], jamLen: it.level === "jam" ? part.len : 0, srcs: new Set([it.src]) });
      }
    }
    const out = runs
      .map((r) => ({
        from: Math.max(0, Math.round(r.from)),
        to: Math.round(r.to),
        level: r.jamLen >= Math.max(120, r.parts.reduce((s, p) => s + p.len, 0) * 0.3) ? "jam" : "slow",
        delay: Math.round(runDelay(r.covered, r.parts)),
        speed: Math.round(Math.min(...r.parts.map((p) => p.v))),
        sources: [...r.srcs],
      }))
      .filter((r) => r.to > 0 && (r.level === "jam" || r.delay >= 20));
    return { runs: out, totalDelay: out.reduce((s, r) => s + r.delay, 0), length: Math.round(cum[cum.length - 1]), at: Date.now() };
  }
}
