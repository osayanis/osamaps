// Évènements routiers multi-sources d'OsaMaps : on agrège des flux OUVERTS (sans compte ni clé),
// on les ramène à un modèle commun, puis on les ANALYSE (fusion des doublons, confiance, gravité,
// impact sur un itinéraire).
//
// Sources (voir SOURCES plus bas : licence, attribution, fréquence, couverture) — toutes publiques :
//   France : Bison Futé (RRN via le module trafic, + DIR Île-de-France, + Côtes-d'Armor), open data
//            de métropoles (chantiers / évènements), ruptures de carburant (prix-carburants),
//            vigilance Météo-France (via MeteoAlarm, crues comprises), accidentalité BAAC (ONISR).
//   Europe : Autobahn GmbH (Allemagne), NDW (Pays-Bas), DGT (Espagne), SCT (Catalogne),
//            CITA (Luxembourg).
//   Communauté OsaMaps : bouchons détectés par le module trafic.
// Waze n'est PAS utilisé (données réservées aux partenaires, sans droit de rediffusion).
//
// Chaque source est téléchargée avec cache, délai, User-Agent identifié, débit modéré, et seulement
// si quelqu'un regarde sa zone (sauf un premier chargement au démarrage, étalé). Une source en panne
// n'empêche rien : on garde ses derniers évènements valides et on réessaie plus tard (recul progressif).
//
// HTTP :  GET  /events?bbox=w,s,e,n[&z=zoom]   → GeoJSON de points (évènements fusionnés)
//         POST /events/route { coords }         → évènements qui touchent l'itinéraire + retard estimé
//         GET  /events/sources                  → état de chaque source (ok / erreur, fraîcheur, nb)
import { gunzipSync } from "node:zlib";
import { HttpError } from "../lib/router.js";
import { trafficShared, parseEvents as parseBisonFute } from "./traffic.js";

const UA = "OsaMaps/0.1 (https://osalabs.fr/maps/)";
const MIN = 60_000, HOUR = 60 * MIN, DAY = 24 * HOUR;
const MAX_BBOX_DEG = 4;
const DEMAND_KEEPALIVE = 30 * MIN;  // une source n'est rafraîchie que si sa zone a été regardée récemment
const TICK_MS = 15_000;
const MAX_PARALLEL = 3;             // téléchargements simultanés (toutes sources confondues)

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
const r6 = (x) => Math.round(x * 1e6) / 1e6;
const isLngLat = (p) => Array.isArray(p) && p.length >= 2 && Number.isFinite(p[0]) && Number.isFinite(p[1])
  && p[0] >= -180 && p[0] <= 180 && p[1] >= -85 && p[1] <= 85 && !(p[0] === 0 && p[1] === 0);
const inBbox = (p, [w, s, e, n]) => p[0] >= w && p[0] <= e && p[1] >= s && p[1] <= n;
const bboxOverlap = (a, b) => a[0] <= b[2] && a[2] >= b[0] && a[1] <= b[3] && a[3] >= b[1];
function lineLength(c) { let l = 0; for (let i = 1; i < c.length; i++) l += dist(c[i - 1], c[i]); return l; }
/** Distance (m) d'un point à un segment, approximation locale (suffisante sous quelques km). */
function distToSeg(p, a, b) {
  const k = Math.cos(p[1] * RAD) * 111_320, m = 111_320;
  const ax = (a[0] - p[0]) * k, ay = (a[1] - p[1]) * m, bx = (b[0] - p[0]) * k, by = (b[1] - p[1]) * m;
  const dx = bx - ax, dy = by - ay, l2 = dx * dx + dy * dy;
  const t = l2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / l2)) : 0;
  return Math.hypot(ax + dx * t, ay + dy * t);
}
function distToLine(p, line) {
  if (line.length === 1) return dist(p, line[0]);
  let best = Infinity;
  for (let i = 1; i < line.length; i++) best = Math.min(best, distToSeg(p, line[i - 1], line[i]));
  return best;
}
/** Douglas-Peucker (tolérance en mètres) + plafond de points : les tracés des sources sont parfois énormes. */
function simplify(coords, tol = 15, max = 60) {
  if (coords.length <= 2) return coords;
  const keep = new Uint8Array(coords.length);
  keep[0] = keep[coords.length - 1] = 1;
  const stack = [[0, coords.length - 1]];
  while (stack.length) {
    const [i, j] = stack.pop();
    let md = 0, mi = -1;
    for (let k = i + 1; k < j; k++) { const d = distToSeg(coords[k], coords[i], coords[j]); if (d > md) { md = d; mi = k; } }
    if (mi > 0 && md > tol) { keep[mi] = 1; stack.push([i, mi], [mi, j]); }
  }
  let out = coords.filter((_, i) => keep[i]);
  if (out.length > max) { const step = (out.length - 1) / (max - 1); out = Array.from({ length: max }, (_, i) => out[Math.round(i * step)]); }
  return out.map((p) => [r6(p[0]), r6(p[1])]);
}
function pointInRing(p, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if ((yi > p[1]) !== (yj > p[1]) && p[0] < ((xj - xi) * (p[1] - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}
function pointInGeometry(p, g) {
  const polys = g.type === "Polygon" ? [g.coordinates] : g.type === "MultiPolygon" ? g.coordinates : [];
  return polys.some((poly) => pointInRing(p, poly[0]) && !poly.slice(1).some((hole) => pointInRing(p, hole)));
}
/** Lambert-93 → WGS84 (même formule que le module trafic). */
function lambert93ToWgs84(x, y) {
  const n = 0.7256077650532670, c = 11754255.4261, xs = 700000, ys = 12655612.0499, e = 0.0818191910428158;
  const dx = x - xs, dy = y - ys, R = Math.sqrt(dx * dx + dy * dy), gamma = Math.atan(dx / -dy);
  const latIso = -Math.log(Math.abs(R / c)) / n;
  let lat = 2 * Math.atan(Math.exp(latIso)) - Math.PI / 2;
  for (let i = 0; i < 8; i++) { const es = e * Math.sin(lat); lat = 2 * Math.atan(((1 + es) / (1 - es)) ** (e / 2) * Math.exp(latIso)) - Math.PI / 2; }
  return [r6(3 + gamma / n / RAD), r6(lat / RAD)];
}

function parseBbox(q) {
  const b = String(q.bbox ?? "").split(",").map(Number);
  if (b.length !== 4 || b.some((x) => !Number.isFinite(x))) throw new HttpError(400, "bbox attendu : ouest,sud,est,nord");
  const [w, s, e, n] = b;
  if (w >= e || s >= n || w < -180 || e > 180 || s < -85 || n > 85) throw new HttpError(400, "bbox invalide");
  if (e - w > MAX_BBOX_DEG || n - s > MAX_BBOX_DEG) throw new HttpError(400, "zone trop grande, zoome un peu");
  return [w, s, e, n];
}

// ───────────────────────────── téléchargement ─────────────────────────────
async function fetchRaw(url, { prev, timeout = 45_000, accept } = {}) {
  const headers = { "User-Agent": UA, "Accept-Encoding": "gzip, deflate" };
  if (accept) headers.Accept = accept;
  if (prev?.etag) headers["If-None-Match"] = prev.etag;
  if (prev?.lastModified) headers["If-Modified-Since"] = prev.lastModified;
  const r = await fetch(url, { headers, signal: AbortSignal.timeout(timeout), redirect: "follow" });
  if (r.status === 304) return { notModified: true };
  if (!r.ok) throw new Error(`HTTP ${r.status} (${new URL(url).host})`);
  const buf = Buffer.from(await r.arrayBuffer());
  return { buf, etag: r.headers.get("etag"), lastModified: r.headers.get("last-modified") };
}
async function fetchText(url, opts = {}) {
  const r = await fetchRaw(url, opts);
  if (r.notModified) return r;
  // fichiers .gz servis tels quels (NDW) : on décompresse nous-mêmes
  const buf = r.buf[0] === 0x1f && r.buf[1] === 0x8b ? gunzipSync(r.buf) : r.buf;
  return { ...r, text: buf.toString("utf8") };
}
async function fetchJson(url, opts = {}) {
  const r = await fetchText(url, { accept: "application/json", ...opts });
  return r.notModified ? r : { ...r, json: JSON.parse(r.text) };
}
const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

// ───────────────────────────── XML léger ─────────────────────────────
const reCache = new Map();
const tagRe = (name) => {
  let re = reCache.get(name);
  if (!re) reCache.set(name, (re = new RegExp(`<(?:[\\w-]+:)?${name}\\b[^>]*?(?:/>|>([\\s\\S]*?)</(?:[\\w-]+:)?${name}>)`, "g")));
  re.lastIndex = 0;
  return re;
};
const first = (s, name) => { if (!s) return null; const m = tagRe(name).exec(s); return m ? (m[1] ?? "") : null; };
const all = (s, name) => (s ? [...s.matchAll(tagRe(name))].map((m) => m[1] ?? "") : []);
const decode = (s) => s?.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1").replace(/<[^>]+>/g, " ").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
  .replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&#(\d+);/g, (_, n) => String.fromCharCode(+n)).replace(/&amp;/g, "&")
  .replace(/\s+/g, " ").trim() ?? null;
const num = (s) => { const x = Number(String(s ?? "").replace(",", ".")); return s != null && s !== "" && Number.isFinite(x) ? x : null; };
const iso = (t) => { const d = typeof t === "number" ? t : Date.parse(t ?? ""); return Number.isFinite(d) ? new Date(d).toISOString() : null; };
const clip = (s, n) => (s ? (s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s) : null);
const cap1 = (s) => (s ? s.charAt(0).toUpperCase() + s.slice(1) : s);
/** « A0075 », « a 7 », « N-1 » → « A75 », « A7 », « N1 » (pour comparer des routes entre sources). */
const roadKey = (s) => (s ? String(s).toUpperCase().replace(/[\s._-]/g, "").replace(/^([A-Z]+)0+(\d)/, "$1$2") : null);
const roadLabel = (s) => (s ? String(s).trim().replace(/^([A-Z]+)0+(\d)/, "$1$2") : null);

// ───────────────────────────── modèle commun ─────────────────────────────
/**
 * Un évènement normalisé :
 * { id, source, type, severity (1 info · 2 gêne · 3 forte · 4 critique), title, description,
 *   original?, lang?, road?, direction?, lanes?, point [lng,lat], line? [[lng,lat]…], bearing?,
 *   start?, end?, delay? (s, annoncé par la source), speed? (km/h), blocking?, extra? }
 */
const TYPES = {
  closure: { label: "Route fermée", sev: 3, group: "works", rank: 0 },
  accident: { label: "Accident", sev: 3, group: "incident", rank: 1 },
  jam: { label: "Bouchon", sev: 2, group: "jam", rank: 2 },
  danger: { label: "Danger", sev: 2, group: "incident", rank: 3 },
  flood: { label: "Vigilance crues", sev: 2, group: "flood", rank: 4 },
  weather: { label: "Vigilance météo", sev: 2, group: "weather", rank: 5 },
  lanes: { label: "Voies réduites", sev: 2, group: "works", rank: 6 },
  works: { label: "Travaux", sev: 1, group: "works", rank: 7 },
  fuel: { label: "Rupture de carburant", sev: 1, group: "fuel", rank: 8 },
  hotspot: { label: "Section accidentogène", sev: 1, group: "hotspot", rank: 9 },
};
const DATEX_SEV = { lowest: 1, low: 1, medium: 2, high: 3, highest: 4 };

function makeEvent(src, o) {
  if (!isLngLat(o.point)) return null;
  const t = TYPES[o.type];
  if (!t) return null;
  const line = o.line && o.line.length >= 2 ? simplify(o.line.filter(isLngLat)) : null;
  return {
    id: `${src}:${String(o.id).slice(0, 80)}`,
    source: src,
    type: o.type,
    severity: Math.max(1, Math.min(4, Math.round(o.severity ?? t.sev))),
    title: clip(o.title ?? t.label, 80),
    description: clip(o.description ?? null, 400),
    original: o.original && o.original !== o.description ? clip(o.original, 500) : null,
    lang: o.lang ?? null,
    road: roadLabel(o.road) || null,
    direction: clip(o.direction ?? null, 80),
    lanes: clip(o.lanes ?? null, 80),
    point: [r6(o.point[0]), r6(o.point[1])],
    line: line && line.length >= 2 && lineLength(line) > 20 ? line : null,
    bearing: Number.isFinite(o.bearing) ? Math.round(o.bearing) : null,
    start: iso(o.start),
    end: iso(o.end),
    delay: Number.isFinite(o.delay) && o.delay > 0 ? Math.round(o.delay) : null,
    speed: Number.isFinite(o.speed) && o.speed > 0 ? Math.round(o.speed) : null,
    blocking: !!o.blocking,
    extra: o.extra ?? null,
  };
}

// ───────────────────────────── DATEX II générique (v2 et v3) ─────────────────────────────
const SUB_TITLE = {
  brokenDownVehicle: "Véhicule en panne", vehicleStuck: "Véhicule immobilisé", vehicleOnFire: "Véhicule en feu",
  objectOnTheRoad: "Objet sur la chaussée", obstructionOnTheRoad: "Obstacle sur la chaussée", rockfalls: "Chute de pierres",
  avalanches: "Avalanche", flooding: "Chaussée inondée", fallenTrees: "Arbre sur la chaussée", landslips: "Glissement de terrain",
  subsidence: "Affaissement de chaussée", damagedRoadSurface: "Chaussée dégradée", roadSurfaceInPoorCondition: "Chaussée en mauvais état",
  animalsOnTheRoad: "Animaux sur la chaussée", wildlife: "Animaux sur la chaussée", peopleOnRoadway: "Piétons sur la chaussée",
  vehicleOnWrongCarriageway: "Véhicule à contresens", vehicleWithOverwideLoad: "Convoi exceptionnel",
  queuingTraffic: "Bouchon", stationaryTraffic: "Circulation à l'arrêt", slowTraffic: "Ralentissement", heavyTraffic: "Trafic dense",
  singleAlternateLineTraffic: "Circulation alternée", contraflow: "Basculement de circulation", narrowLanes: "Voies rétrécies",
  laneClosures: "Voies fermées", lanesDeviated: "Voies déviées", carriagewayClosures: "Chaussée fermée", roadClosed: "Route fermée",
  intermittentShortTermClosures: "Fermetures ponctuelles", closedPermanentlyForTheWinter: "Fermé pour l'hiver",
  weightRestrictionInOperation: "Restriction de tonnage", speedRestrictionInOperation: "Vitesse limitée",
  newRoadworksLayout: "Nouvelle configuration de chantier", grassCuttingWork: "Fauchage", resurfacingWork: "Réfection de chaussée",
  roadMarkingWork: "Marquage au sol", repairWork: "Réparations", roadworks: "Travaux", maintenanceWork: "Entretien",
  bridgeOpening: "Pont levant ouvert", rerouting: "Déviation", wrongWayDriving: "Véhicule à contresens",
};
const SUB_TYPE = {
  queuingTraffic: "jam", stationaryTraffic: "jam", slowTraffic: "jam", heavyTraffic: "jam",
  roadClosed: "closure", carriagewayClosures: "closure", closedPermanentlyForTheWinter: "closure",
  laneClosures: "lanes", narrowLanes: "lanes", lanesDeviated: "lanes", singleAlternateLineTraffic: "lanes", contraflow: "lanes",
  intermittentShortTermClosures: "lanes", doNotUseSpecifiedLanesOrCarriageways: "lanes", newRoadworksLayout: "works",
  vehicleOnWrongCarriageway: "danger", wrongWayDriving: "danger",
};
const RECORD_TYPE = {
  Accident: "accident",
  VehicleObstruction: "danger", GeneralObstruction: "danger", EnvironmentalObstruction: "danger", AnimalPresenceObstruction: "danger",
  InfrastructureDamageObstruction: "danger", PoorEnvironmentConditions: "danger", WeatherRelatedRoadConditions: "danger",
  NonWeatherRelatedRoadConditions: "danger", EquipmentOrSystemFault: "danger",
  MaintenanceWorks: "works", ConstructionWorks: "works", Roadworks: "works",
  AbnormalTraffic: "jam",
  ReroutingManagement: "works", SpeedManagement: "works",
};
const CAUSE_TYPE = {
  accident: "accident", roadMaintenance: "works", vehicleObstruction: "danger", obstruction: "danger",
  environmentalObstruction: "danger", infrastructureDamageObstruction: "danger", abnormalTraffic: "jam",
  poorEnvironment: "danger", animalPresence: "danger",
};
const SUB_TAGS = ["roadOrCarriagewayOrLaneManagementType", "abnormalTrafficType", "accidentType", "vehicleObstructionType",
  "obstructionType", "environmentalObstructionType", "infrastructureDamageType", "roadMaintenanceType", "animalPresenceType",
  "nonWeatherRelatedRoadConditionType", "speedManagementType", "reroutingManagementType", "constructionWorkType", "poorEnvironmentType",
  "equipmentOrSystemFaultType"];

/** Lit un flux DATEX II (v2 sans préfixe ou v3 préfixé) : renvoie des évènements normalisés. */
function parseDatex(xml, src, { lang = null, now = Date.now(), sourceName = null } = {}) {
  const out = [];
  for (const sit of xml.split(/<(?:[\w-]+:)?situation\s/).slice(1)) {
    const sitId = /^[^>]*?\bid="([^"]+)"/.exec(sit)?.[1];
    const sitSev = DATEX_SEV[first(sit.slice(0, 2000), "overallSeverity")] ?? null;
    const recs = sit.split(/<(?:[\w-]+:)?situationRecord\s/).slice(1);
    const parsed = [];
    for (const rec of recs) {
      const rtype = /xsi:type="(?:[\w-]+:)?(\w+)"/.exec(rec)?.[1];
      if (!rtype) continue;
      const status = first(rec, "validityStatus");
      if (status === "suspended" || status === "planned") continue;
      if (first(rec, "probabilityOfOccurrence") === "riskOf") continue;
      const start = Date.parse(first(rec, "overallStartTime") ?? "");
      const endRaw = first(rec, "overallEndTime");
      const end = endRaw ? Date.parse(endRaw) : NaN;
      if (Number.isFinite(start) && start > now + 5 * MIN) continue; // pas encore commencé
      if (Number.isFinite(end) && end < now) continue;                // terminé
      let sub = null;
      for (const t of SUB_TAGS) { const v = first(rec, t); if (v) { sub = v; break; } }
      const cause = first(rec, "causeType");
      let type = SUB_TYPE[sub] ?? RECORD_TYPE[rtype] ?? CAUSE_TYPE[cause] ?? null;
      if (rtype === "RoadOrCarriagewayOrLaneManagement" && !SUB_TYPE[sub]) type = sub === "weightRestrictionInOperation" ? "works" : "lanes";
      if (rtype === "Accident") type = "accident";
      if (rtype === "AbnormalTraffic" && sub === "heavyTraffic") type = "jam";
      if (!type) continue;
      if (type === "jam" && first(rec, "trafficTrendType") === "trafficEasing" && sub === "heavyTraffic") continue;
      // géométrie : lignes GML (v3), sinon points de/à, sinon le premier point
      let line = null;
      const posList = first(rec, "posList");
      if (posList) {
        const n = posList.trim().split(/\s+/).map(Number);
        const pts = [];
        for (let i = 0; i + 1 < n.length; i += 2) pts.push([n[i + 1], n[i]]); // « lat lon lat lon… »
        if (pts.length >= 2 && pts.every(isLngLat)) line = pts;
      }
      const ptOf = (block) => block ? [num(first(block, "longitude")), num(first(block, "latitude"))] : null;
      const fromPt = ptOf(first(rec, "from")), toPt = ptOf(first(rec, "to"));
      if (!line && isLngLat(fromPt) && isLngLat(toPt) && dist(fromPt, toPt) > 30) line = [fromPt, toPt];
      const pts = all(rec, "pointCoordinates").map(ptOf).filter(isLngLat);
      const point = line?.[0] ?? (isLngLat(fromPt) ? fromPt : pts[0]);
      if (!isLngLat(point)) continue;
      const comments = all(rec, "generalPublicComment").map((g) => {
        const vals = all(g, "value").map(decode).filter(Boolean);
        return { type: first(g, "commentType"), text: vals[0] ?? decode(g) };
      }).filter((c) => c.text);
      const desc = comments.find((c) => !c.type || c.type === "description")?.text ?? comments[0]?.text ?? null;
      const roadNum = first(rec, "roadNumber") ?? first(rec, "roadName");
      const sev = DATEX_SEV[first(rec, "severity")] ?? sitSev;
      const delaySec = num(first(rec, "delayTimeValue"));
      const speed = num(first(rec, "averageVehicleSpeed") ? first(first(rec, "averageVehicleSpeed"), "speed") : null);
      const restricted = num(first(rec, "numberOfLanesRestricted"));
      const laneUsage = first(rec, "laneUsage");
      const allLanes = /allLanesCompleteCarriageway/.test(rec) || sub === "carriagewayClosures" || sub === "roadClosed";
      if (type === "lanes" && allLanes && /Closures|Closed/i.test(sub ?? "")) type = "closure";
      const dir = first(rec, "tpegDirection") ?? first(rec, "directionRelative") ?? first(rec, "alertCDirectionCoded");
      const brg = num(first(rec, "bearing"));
      const srcName = decode(first(first(rec, "source") ?? "", "value")) ?? decode(first(rec, "sourceIdentification"));
      parsed.push({
        id: /^[^>]*?\bid="([^"]+)"/.exec(rec)?.[1] ?? sitId,
        type, sub, sev, start, end, line, point, desc, roadNum, delaySec, speed, restricted, laneUsage, allLanes, dir, brg, srcName,
      });
    }
    // une situation = un incident : on garde l'enregistrement le plus important, enrichi des autres
    if (!parsed.length) continue;
    parsed.sort((a, b) => TYPES[a.type].rank - TYPES[b.type].rank);
    const p = parsed[0];
    const delay = parsed.map((x) => x.delaySec).find((x) => x > 0) ?? null;
    const line = parsed.map((x) => x.line).find(Boolean) ?? null;
    const lanes = p.type === "closure" ? null
      : p.restricted ? `${p.restricted} voie${p.restricted > 1 ? "s" : ""} fermée${p.restricted > 1 ? "s" : ""}`
      : parsed.some((x) => x.sub === "singleAlternateLineTraffic") ? "Circulation alternée"
      : parsed.some((x) => x.type === "lanes") ? "Voies réduites" : null;
    const title = SUB_TITLE[p.sub] ?? TYPES[p.type].label;
    const sev = p.type === "closure" ? Math.max(3, p.sev ?? 3) : p.sev != null ? Math.min(p.sev, p.type === "works" ? 2 : 4) : null;
    const descFr = [title, p.roadNum ? `sur ${roadLabel(p.roadNum)}` : null].filter(Boolean).join(" ")
      + (lanes && lanes !== title ? ` · ${lanes}` : "") + (delay ? ` · ~${Math.max(1, Math.round(delay / 60))} min de retard` : "");
    out.push({
      id: sitId ?? p.id, type: p.type, severity: sev, title, road: p.roadNum,
      description: lang === "fr" && p.desc ? p.desc : descFr,
      original: lang !== "fr" ? p.desc : null, lang: lang !== "fr" && p.desc ? lang : null,
      lanes, point: p.point, line, bearing: p.brg, start: p.start, end: p.end, delay, speed: p.speed,
      blocking: p.type === "closure",
      extra: sourceName || p.srcName ? { operator: clip(sourceName ?? p.srcName, 60) } : null,
    });
  }
  return out.map((o) => makeEvent(src, o)).filter(Boolean);
}

// ───────────────────────────── Autobahn (Allemagne) ─────────────────────────────
const AB = "https://verkehr.autobahn.de/o/autobahn";
/** « 15.11.26 um 20:00 » / « 16.11.26 05:00 » (heure allemande) → ms. */
function deDate(s) {
  const m = /(\d{2})\.(\d{2})\.(\d{2,4})(?:\s*(?:um)?\s*(\d{1,2}):(\d{2}))?/.exec(s ?? "");
  if (!m) return NaN;
  const y = m[3].length === 2 ? 2000 + +m[3] : +m[3];
  // heure locale de Berlin ≈ UTC+1 (hiver) / +2 (été) : on prend +1, l'erreur maximale est d'une heure
  return Date.UTC(y, +m[2] - 1, +m[1], (+(m[4] ?? 23)) - 1, +(m[5] ?? 59));
}
function autobahnItem(x, kind) {
  if (x.future) return null;
  const desc = (x.description ?? []).filter(Boolean);
  const text = desc.join(" ");
  const pt = x.coordinate ? [num(x.coordinate.long), num(x.coordinate.lat)] : null;
  const line = x.geometry?.type === "LineString" ? x.geometry.coordinates : null;
  const road = /^\s*(A\s?\d+)/.exec(x.title ?? "")?.[1]?.replace(/\s/g, "");
  const where = (x.title ?? "").split("|")[1]?.trim().replace(/^Verkehrsmeldung$/i, "") || null;
  const dirTxt = x.subtitle?.trim() || null;
  const symbols = x.impact?.symbols ?? [];
  const closedLanes = symbols.filter((s) => s === "CLOSED").length;
  const openLanes = symbols.filter((s) => /^ARROW/.test(s)).length;
  let type, title, sev, lanes = null, blocking = false, delay = null, speed = null, end = null;
  if (kind === "warning") {
    delay = num(x.delayTimeValue) != null ? num(x.delayTimeValue) * 60 : null;
    speed = num(x.averageSpeed);
    if (/Unfall/i.test(text)) { type = "accident"; title = "Accident"; sev = 3; }
    else if (/Falschfahrer|Geisterfahrer/i.test(text)) { type = "danger"; title = "Véhicule à contresens"; sev = 4; }
    else if (/Vollsperrung|gesperrt/i.test(text)) { type = "closure"; title = "Route fermée"; sev = 4; blocking = true; }
    else if (/Gefahr|Gegenstände|Tiere|Personen auf der Fahrbahn|Pannenfahrzeug|liegengebliebenes/i.test(text)) {
      type = "danger"; sev = 2;
      title = /Pannenfahrzeug|liegengebliebenes/i.test(text) ? "Véhicule en panne" : /Gegenstände/i.test(text) ? "Objet sur la chaussée"
        : /Tiere/i.test(text) ? "Animaux sur la chaussée" : /Personen/i.test(text) ? "Piétons sur la chaussée" : "Danger";
    } else if (x.abnormalTrafficType || delay) {
      type = "jam"; sev = (delay ?? 0) >= 15 * 60 || /Stillstand|STATIONARY/i.test(text + x.abnormalTrafficType) ? 3 : 2;
      title = SUB_TITLE[{ QUEUING_TRAFFIC: "queuingTraffic", STATIONARY_TRAFFIC: "stationaryTraffic", SLOW_TRAFFIC: "slowTraffic", HEAVY_TRAFFIC: "heavyTraffic" }[x.abnormalTrafficType]] ?? "Ralentissement";
      if (x.abnormalTrafficType === "HEAVY_TRAFFIC" && !delay) return null; // simple « trafic dense » sans retard
    } else return null;
  } else if (kind === "closure") {
    if (x.display_type === "CLOSURE_ENTRY_EXIT") { type = "lanes"; title = "Bretelle fermée"; sev = 1; lanes = "Entrée ou sortie fermée"; }
    else { type = "closure"; title = "Route fermée"; sev = 3; blocking = true; }
    end = deDate(/bis(?: zum)?\s+([\d.]+\s*(?:um\s*)?[\d:]*)/i.exec(text)?.[1]);
  } else {
    end = deDate(/Ende:\s*([\d.]+\s*(?:um\s*)?[\d:]*)/i.exec(text)?.[1] ?? /bis(?: zum)?\s+([\d.]+\s*(?:um\s*)?[\d:]*)/i.exec(text)?.[1]);
    if (closedLanes && !openLanes) { type = "closure"; title = "Chaussée fermée"; sev = 3; blocking = true; }
    else if (closedLanes) { type = "lanes"; title = x.display_type === "SHORT_TERM_ROADWORKS" ? "Chantier mobile" : "Travaux"; sev = 2; lanes = `${closedLanes} voie${closedLanes > 1 ? "s" : ""} fermée${closedLanes > 1 ? "s" : ""}`; }
    else { type = "works"; title = x.display_type === "SHORT_TERM_ROADWORKS" ? "Chantier mobile" : "Travaux"; sev = 1; }
  }
  if (Number.isFinite(end) && end < Date.now()) return null;
  return {
    id: x.identifier, type, severity: sev, title, road, lanes, blocking, delay, speed,
    direction: dirTxt ? dirTxt.replace(/\s*->\s*/, " → ") : null,
    description: [title, road ? `sur l'${road}` : null, where ? `(${where})` : null].filter(Boolean).join(" ")
      + (lanes && lanes !== title ? ` · ${lanes}` : "") + (delay ? ` · ~${Math.round(delay / 60)} min de retard` : "")
      + (speed && type === "jam" ? ` · ${speed} km/h` : ""),
    original: desc.join("\n"), lang: "de",
    point: line?.[0] ?? pt, line, start: x.startTimestamp, end: Number.isFinite(end) ? end : null,
  };
}

// ───────────────────────────── sources ─────────────────────────────
const FR = [-5.5, 41.2, 9.8, 51.2];
const BF = "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/publicationsDIR/Evenementiel-DIR/grt";

/**
 * Registre des sources. `fetch(ctx)` renvoie la liste complète des évènements valides de la source
 * (ou `null` si rien n'a changé : on garde la liste précédente). `weight` = fiabilité (0..1).
 */
const SOURCES = [
  {
    id: "bf-rrn", name: "Bison Futé (réseau national)", country: "FR", bbox: FR, ttl: 10 * MIN, weight: 0.9,
    kinds: ["accident", "closure", "works", "lanes", "danger", "jam"],
    licence: "Licence Ouverte Etalab 2.0", attribution: "Bison Futé / DIR (ministère chargé des transports)",
    url: "https://tipi.bison-fute.gouv.fr/bison-fute-ouvert/", frequency: "≈ 6 min",
    // déjà téléchargé par le module trafic : on lit sa copie (pas de double téléchargement)
    async fetch() {
      trafficShared.demand();
      const err = trafficShared.eventsError();
      if (err && !trafficShared.events().length) throw new Error(err);
      if (!trafficShared.eventsAt()) throw new Error("premier téléchargement en cours (module trafic)");
      return trafficShared.events().map((e) => bisonFuteEvent("bf-rrn", e)).filter(Boolean);
    },
  },
  {
    id: "bf-dirif", name: "Bison Futé (DIR Île-de-France)", country: "FR", bbox: [1.4, 48.1, 3.6, 49.3], ttl: 10 * MIN, weight: 0.9,
    kinds: ["accident", "closure", "works", "lanes", "danger"],
    licence: "Licence Ouverte Etalab 2.0", attribution: "Bison Futé / DIR Île-de-France",
    url: `${BF}/DIRIF/content.xml`, frequency: "≈ 5 min",
    async fetch(ctx) { return bisonFuteFeed(ctx, `${BF}/DIRIF/content.xml`, "bf-dirif"); },
  },
  {
    id: "bf-cd22", name: "Bison Futé (Côtes-d'Armor)", country: "FR", bbox: [-3.7, 48.0, -1.9, 48.95], ttl: 15 * MIN, weight: 0.85,
    kinds: ["works", "closure", "lanes", "danger"],
    licence: "Licence Ouverte Etalab 2.0", attribution: "Bison Futé / Département des Côtes-d'Armor",
    url: `${BF}/CD22/content.xml`, frequency: "≈ 15 min",
    async fetch(ctx) { return bisonFuteFeed(ctx, `${BF}/CD22/content.xml`, "bf-cd22"); },
  },
  {
    id: "autobahn", name: "Autobahn GmbH (Allemagne)", country: "DE", bbox: [5.8, 47.2, 15.1, 55.1], ttl: 15 * MIN, weight: 0.9,
    kinds: ["jam", "accident", "danger", "closure", "lanes", "works"],
    licence: "API publique sans clé (Autobahn GmbH des Bundes) — réutilisation libre avec mention de la source",
    attribution: "Die Autobahn GmbH des Bundes", url: "https://autobahn.api.bund.dev/", frequency: "alertes 15 min, chantiers 2 h",
    async fetch(ctx) {
      // ≈ 110 autoroutes × 3 services : séquentiel, 250 ms entre deux requêtes. Les chantiers (lourds,
      // lents à changer) ne sont rechargés que toutes les 2 h ; alertes et fermetures à chaque passage.
      const st = ctx.state;
      if (!st.roads || Date.now() - st.roadsAt > DAY) {
        const r = await fetchJson(`${AB}/`, { timeout: 20_000 });
        st.roads = (r.json.roads ?? []).filter((x) => /^A\d+$/.test(x.trim())).map((x) => x.trim());
        st.roadsAt = Date.now();
      }
      const doWorks = !st.worksAt || Date.now() - st.worksAt > 2 * HOUR;
      const prevWorks = st.works ?? [];
      const out = [], works = [];
      let errors = 0, streak = 0;
      for (const road of st.roads) {
        for (const svc of doWorks ? ["warning", "closure", "roadworks"] : ["warning", "closure"]) {
          try {
            const r = await fetchJson(`${AB}/${road}/services/${svc}`, { timeout: 20_000 });
            for (const x of r.json[svc] ?? []) {
              const e = makeEvent("autobahn", autobahnItem(x, svc) ?? {});
              if (e) (svc === "roadworks" ? works : out).push(e);
            }
            streak = 0;
          } catch (e) {
            errors++;
            // le service ne répond plus : inutile d'enchaîner 300 délais d'attente
            if (++streak >= 5) throw new Error(`service injoignable (${e?.message ?? e})`);
          }
          await sleep(250);
        }
      }
      if (errors > st.roads.length) throw new Error(`${errors} requêtes en échec`);
      if (doWorks) { st.works = works; st.worksAt = Date.now(); }
      const seen = new Set();
      return [...out, ...(doWorks ? works : prevWorks.filter((e) => !e.end || Date.parse(e.end) > Date.now()))]
        .filter((e) => !seen.has(e.id) && seen.add(e.id));
    },
  },
  {
    id: "ndw", name: "NDW (Pays-Bas)", country: "NL", bbox: [3.2, 50.7, 7.3, 53.7], ttl: 5 * MIN, weight: 0.9,
    kinds: ["accident", "danger", "jam", "closure", "lanes", "works"],
    licence: "NDW open data — libre réutilisation (conditions d'utilisation NDW)", attribution: "Nationaal Dataportaal Wegverkeer (NDW)",
    url: "https://opendata.ndw.nu/", frequency: "1 min",
    async fetch(ctx) {
      // « actueel beeld » (situation actuelle : travaux, fermetures, incidents) + messages de sécurité (SRTI)
      const a = await fetchText("https://opendata.ndw.nu/actueel_beeld.xml.gz", { prev: ctx.state.metaA, timeout: 60_000 });
      const b = await fetchText("https://opendata.ndw.nu/veiligheidsgerelateerde_informatie_srti.xml.gz", { prev: ctx.state.metaB, timeout: 60_000 });
      if (a.notModified && b.notModified) return null;
      if (!a.notModified) { ctx.state.metaA = { etag: a.etag, lastModified: a.lastModified }; ctx.state.listA = parseDatex(a.text, "ndw", { lang: "nl" }); }
      if (!b.notModified) { ctx.state.metaB = { etag: b.etag, lastModified: b.lastModified }; ctx.state.listB = parseDatex(b.text, "ndw", { lang: "nl" }); }
      return [...(ctx.state.listA ?? []), ...(ctx.state.listB ?? [])];
    },
  },
  {
    id: "dgt", name: "DGT (Espagne)", country: "ES", bbox: [-9.5, 35.9, 4.4, 43.9], ttl: 10 * MIN, weight: 0.85,
    kinds: ["works", "lanes", "closure", "danger", "accident", "jam"],
    licence: "Données ouvertes DGT (NAP espagnol), réutilisation libre avec mention", attribution: "Dirección General de Tráfico (DGT)",
    url: "https://nap.dgt.es/", frequency: "≈ 5 min",
    async fetch(ctx) {
      // l'URL « v36 » redirige vers la dernière version du profil (v37 en nov. 2026)
      const r = await fetchText("https://nap.dgt.es/datex2/v3/dgt/SituationPublication/datex2_v36.xml", { prev: ctx.state.meta, timeout: 90_000 });
      if (r.notModified) return null;
      ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
      return parseDatex(r.text, "dgt", { lang: "es" });
    },
  },
  {
    id: "sct", name: "Servei Català de Trànsit (Catalogne)", country: "ES", bbox: [0.1, 40.5, 3.4, 42.9], ttl: 5 * MIN, weight: 0.85,
    kinds: ["jam", "accident", "works", "closure", "danger", "weather"],
    licence: "Llicència oberta d'ús d'informació – Catalunya (mention de la source)", attribution: "Servei Català de Trànsit, Generalitat de Catalunya",
    url: "https://www.gencat.cat/transit/opendata/incidenciesGML.xml", frequency: "≈ 5 min",
    async fetch(ctx) {
      const r = await fetchText("https://www.gencat.cat/transit/opendata/incidenciesGML.xml", { prev: ctx.state.meta, timeout: 30_000 });
      if (r.notModified) return null;
      ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
      return all(r.text, "featureMember").map(sctItem).map((o) => o && makeEvent("sct", o)).filter(Boolean);
    },
  },
  {
    id: "cita", name: "CITA (Luxembourg)", country: "LU", bbox: [5.7, 49.4, 6.55, 50.2], ttl: 5 * MIN, weight: 0.9,
    kinds: ["accident", "works", "danger", "closure", "lanes"],
    licence: "CC0 (data.public.lu)", attribution: "Administration des ponts et chaussées — CITA",
    url: "https://data.public.lu/fr/datasets/cita-evenements-trafic-en-datex-ii-v3-6/", frequency: "temps réel",
    async fetch(ctx) {
      const r = await fetchText("https://cita.lu/info_trafic/datex/situationrecord36", { prev: ctx.state.meta, timeout: 30_000 });
      if (r.notModified) return null;
      ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
      return parseDatex(r.text, "cita", { lang: "fr" });
    },
  },
  {
    id: "meteoalarm", name: "Vigilance Météo-France (MeteoAlarm)", country: "FR", bbox: FR, ttl: 15 * MIN, weight: 0.95,
    kinds: ["weather", "flood"],
    licence: "MeteoAlarm — réutilisation libre avec attribution (CC BY 4.0)", attribution: "Météo-France via MeteoAlarm (EUMETNET)",
    url: "https://feeds.meteoalarm.org/", frequency: "à chaque bulletin (≥ 2 / jour)",
    async fetch(ctx) { return meteoalarm(ctx); },
  },
  {
    id: "carburants", name: "Ruptures de carburant (prix-carburants)", country: "FR", bbox: FR, ttl: 30 * MIN, weight: 0.7,
    kinds: ["fuel"],
    licence: "Licence Ouverte Etalab 2.0", attribution: "Ministère de l'Économie — prix-carburants.gouv.fr",
    url: "https://data.economie.gouv.fr/explore/dataset/prix-des-carburants-en-france-flux-instantane-v2/", frequency: "10 min",
    async fetch() { return fuelShortages(); },
  },
  {
    id: "baac", name: "Accidentalité (BAAC, ONISR)", country: "FR", bbox: FR, ttl: 30 * DAY, weight: 1, static: true,
    kinds: ["hotspot"],
    licence: "Licence Ouverte Etalab 2.0", attribution: "ONISR — Bases de données annuelles des accidents corporels (data.gouv.fr)",
    url: "https://www.data.gouv.fr/fr/datasets/53698f4ca3a729239d2036df/", frequency: "annuelle (3 dernières années)",
    async fetch(ctx) { return baacHotspots(ctx); },
  },
];

// ── open data des collectivités françaises (chantiers, fermetures, arrêtés) ──
/** Point représentatif + ligne éventuelle d'une géométrie GeoJSON quelconque. */
function geoRep(g) {
  if (!g) return { point: null, line: null };
  switch (g.type) {
    case "Point": return { point: g.coordinates, line: null };
    case "MultiPoint": return { point: g.coordinates[0], line: null };
    case "LineString": return { point: g.coordinates[0], line: g.coordinates };
    case "MultiLineString": {
      const best = [...g.coordinates].sort((a, b) => lineLength(b) - lineLength(a))[0];
      return { point: best?.[0], line: best };
    }
    case "Polygon": case "MultiPolygon": {
      const ring = g.type === "Polygon" ? g.coordinates[0] : [...g.coordinates].sort((a, b) => b[0].length - a[0].length)[0][0];
      let x = 0, y = 0;
      for (const p of ring) { x += p[0]; y += p[1]; }
      return { point: [x / ring.length, y / ring.length], line: null };
    }
    case "GeometryCollection": return geoRep(g.geometries?.[0]);
    default: return { point: null, line: null };
  }
}
/** Classe un texte libre de chantier (« Route barrée », « Alternat »…) en type OsaMaps. */
function worksKind(text) {
  const t = String(text ?? "");
  if (/route barr|circulation interdite|barrage total|fermeture (?:de la |à la )?(?:route|voie|circulation)|ferm[ée]e?\b|mise en impasse|impasse|d[ée]viation/i.test(t)) return "closure";
  if (/altern|neutralisation|r[ée]tr[ée]ci|r[ée]duite|restreinte|1 file|une file|voie fermée|sens unique|basculement|perturb/i.test(t)) return "lanes";
  return "works";
}
const KIND_TITLE_FR = { closure: "Route barrée", lanes: "Circulation perturbée", works: "Travaux" };
const frDate = (s) => { // « 19/10/2026 08h30 » / « 2026-11-10 00:00:00.0 »
  const m = /(\d{2})\/(\d{2})\/(\d{4})(?:\s*(\d{1,2})[h:](\d{2})?)?/.exec(s ?? "");
  if (m) return new Date(+m[3], +m[2] - 1, +m[1], +(m[4] ?? 23), +(m[5] ?? (m[4] ? 0 : 59))).getTime();
  const d = Date.parse(String(s ?? "").replace(" ", "T").replace(/\.0$/, ""));
  return Number.isFinite(d) ? d : NaN;
};
/** Date de fin d'un chantier donnée en jour seul (« 2026-11-06 ») : jusqu'à la fin de ce jour. */
const endOfDay = (s) => (/^\d{4}-\d{2}-\d{2}$/.test(s ?? "") ? Date.parse(`${s}T23:59:00`) : frDate(s));

/**
 * Fabrique une source GeoJSON/JSON simple. `map(props, geometry)` renvoie un objet pour makeEvent
 * (sans id de source) ou null. Les évènements finis ou qui commencent dans plus de 24 h sont ignorés,
 * et les doublons exacts (même type, même point) d'une même source sont fusionnés.
 */
function cityGeoSource(def) {
  return {
    ttl: 3 * HOUR, weight: 0.75, country: "FR", kinds: ["works", "lanes", "closure"], ...def,
    async fetch(ctx) {
      const r = await fetchJson(def.fetchUrl ?? def.url, { prev: ctx.state.meta, timeout: 90_000 });
      if (r.notModified) return null;
      ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
      const feats = def.features ? def.features(r.json) : (r.json.features ?? []);
      const now = Date.now(), out = [], seen = new Set();
      for (const f of feats) {
        let o;
        try { o = def.map(f.properties ?? f, f.geometry ?? null); } catch { o = null; }
        if (!o) continue;
        const end = typeof o.end === "number" ? o.end : endOfDay(o.end);
        const start = typeof o.start === "number" ? o.start : Date.parse(o.start ?? "");
        if (Number.isFinite(end) && end < now) continue;
        if (Number.isFinite(start) && start > now + DAY) continue;
        if (!o.point) Object.assign(o, geoRep(f.geometry), { point: o.point ?? geoRep(f.geometry).point, line: o.line ?? geoRep(f.geometry).line });
        const e = makeEvent(def.id, { ...o, end: Number.isFinite(end) ? end : null, start: Number.isFinite(start) ? start : null });
        if (!e) continue;
        const k = `${e.type}:${e.point[0].toFixed(4)}:${e.point[1].toFixed(4)}`;
        if (seen.has(k)) continue;
        seen.add(k);
        out.push(e);
      }
      return out;
    },
  };
}
const ods = (host, id, where) => `https://${host}/api/explore/v2.1/catalog/datasets/${id}/exports/geojson${where ? `?where=${encodeURIComponent(where)}` : ""}`;
const worksEvent = (kind, { id, title, road, where, detail, start, end, point, line, severity }) => ({
  id, type: kind, title: title ?? KIND_TITLE_FR[kind], road,
  severity: severity ?? (kind === "closure" ? 2 : kind === "lanes" ? 2 : 1), blocking: kind === "closure",
  lanes: kind === "lanes" ? clip(detail, 80) : null,
  description: [where, detail].filter(Boolean).join(" — ") || KIND_TITLE_FR[kind], start, end, point, line,
});

const CITY_SOURCES = [
  cityGeoSource({
    id: "paris-evt", name: "Ville de Paris (PC Lutèce)", bbox: [2.22, 48.81, 2.47, 48.91], ttl: 15 * MIN, weight: 0.8,
    licence: "Licence Ouverte Etalab", attribution: "Ville de Paris — circulation_evenement", frequency: "5 min",
    url: "https://opendata.paris.fr/api/explore/v2.1/catalog/datasets/circulation_evenement/exports/json",
    features: (j) => j,
    map(p) {
      const n = String(p.polyline ?? "").trim().split(/\s+/).map(Number);
      const line = [];
      for (let i = 0; i + 1 < n.length; i += 2) line.push([n[i + 1], n[i]]); // « lat lon »
      if (!line.length) return null;
      const kind = p.type === "ROAD_CLOSED" ? "closure" : p.type === "CONSTRUCTION" ? worksKind(p.description) : null;
      if (!kind) return null;
      return worksEvent(kind, { id: p.id, title: kind === "closure" ? "Voie fermée" : undefined, where: String(p.street ?? "").replace(/_/g, " "),
        detail: p.description, start: p.starttime, end: p.endtime, point: line[0], line: line.length > 1 ? line : null });
    },
  }),
  cityGeoSource({
    id: "paris-chantiers", name: "Ville de Paris (chantiers perturbants)", bbox: [2.22, 48.81, 2.47, 48.91], weight: 0.75,
    licence: "ODbL", attribution: "Ville de Paris — Direction de la Voirie et des Déplacements", frequency: "quotidienne",
    url: ods("opendata.paris.fr", "chantiers-perturbants"),
    map(p, g) {
      const imp = p.impact_circulation;
      const kind = imp === "BARRAGE_TOTAL" || imp === "IMPASSE" ? "closure" : imp === "RESTREINTE" || imp === "SENS_UNIQUE" ? "lanes" : "works";
      return worksEvent(kind, { id: p.identifiant, where: p.voie, detail: p.impact_circulation_detail ?? p.description,
        start: p.date_debut, end: p.date_fin, ...geoRep(g), severity: p.niveau_perturbation === "Très perturbant" ? 2 : undefined });
    },
  }),
  cityGeoSource({
    id: "lyon", name: "Métropole de Lyon (chantiers perturbants)", bbox: [4.6, 45.55, 5.2, 46.0], weight: 0.75,
    licence: "Licence Ouverte 2.0", attribution: "Métropole de Lyon", frequency: "quotidienne",
    url: "https://data.grandlyon.com/geoserver/metropole-de-lyon/ows?SERVICE=WFS&VERSION=2.0.0&request=GetFeature&typename=metropole-de-lyon:pvo_patrimoine_voirie.pvochantierperturbant&outputFormat=application/json&SRSNAME=EPSG:4326",
    map(p, g) {
      const kind = worksKind(p.typeperturbation);
      return worksEvent(kind, { id: p.gid ?? `${p.nom}-${p.debutchantier}`, where: [p.nom?.trim(), p.commune1].filter(Boolean).join(", "),
        detail: [p.typeperturbation, p.nomchantier?.trim(), p.descripchantierinternet].filter(Boolean).join(" · "),
        start: p.debutchantier, end: p.finchantier, ...geoRep(g), severity: /très/i.test(p.importance ?? "") ? 2 : undefined });
    },
  }),
  cityGeoSource({
    id: "rennes", name: "Rennes Métropole (travaux)", bbox: [-1.95, 47.95, -1.45, 48.3], weight: 0.75,
    licence: "ODbL", attribution: "Rennes Métropole", frequency: "continue",
    url: ods("data.rennesmetropole.fr", "travaux_1_jour"),
    map(p, g) {
      const kind = worksKind(p.type);
      return worksEvent(kind, { id: p.id_evt, where: [p.localisation, String(p.commune ?? "").replace(/^\d+ - /, "")].filter(Boolean).join(", "),
        detail: [p.type, p.libelle].filter(Boolean).join(" : "), start: p.date_deb, end: p.date_fin, ...geoRep(g),
        severity: p.niv_perturbation === "Secteur à éviter" ? 3 : p.niv_perturbation === "Circulation difficile" ? 2 : kind === "works" ? 1 : undefined });
    },
  }),
  cityGeoSource({
    id: "bordeaux", name: "Bordeaux Métropole (chantiers)", bbox: [-0.85, 44.7, -0.4, 45.05], weight: 0.75,
    licence: "Licence Ouverte", attribution: "Bordeaux Métropole", frequency: "quotidienne",
    url: ods("opendata.bordeaux-metropole.fr", "ci_chantier"),
    map(p, g) {
      const kind = worksKind(p.libelle);
      return worksEvent(kind, { id: p.ident ?? p.gid, where: String(p.localisation ?? "").replace(/\s*situé en agglomération/i, ""),
        detail: String(p.libelle ?? "").split(/[;/]/).map((x) => x.trim()).filter(Boolean).slice(0, 3).join(", ") || p.alias_nature_n1,
        start: p.date_debut, end: p.date_fin, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "toulouse", name: "Toulouse Métropole (chantiers)", bbox: [1.15, 43.45, 1.65, 43.8], weight: 0.75,
    licence: "Licence Ouverte 2.0", attribution: "Toulouse Métropole", frequency: "quotidienne",
    get url() { return ods("data.toulouse-metropole.fr", "chantiers-en-cours", "datefin>=now()"); },
    map(p, g) {
      const kind = worksKind(p.circulation);
      const voie = [...new Set(String(p.voie ?? "").split("|").map((x) => x.trim()))].slice(0, 2).join(", ");
      return worksEvent(kind, { id: p.numero, where: [voie, p.commune].filter(Boolean).join(", "),
        detail: String(p.circulation ?? "").split(" - ").slice(0, 3).join(", ") || p.libelle, start: p.datedebut, end: p.datefin, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "lille", name: "Métropole Européenne de Lille (travaux)", bbox: [2.75, 50.45, 3.3, 50.8], weight: 0.7, kinds: ["works"],
    licence: "Licence Ouverte 2.0", attribution: "Métropole Européenne de Lille", frequency: "quotidienne",
    url: "https://data.lillemetropole.fr/geoserver/wfs?SERVICE=WFS&VERSION=2.0.0&REQUEST=GetFeature&typeNames=mel_espacepublic:operation_melmap_sig_tro&outputFormat=application/json&srsName=EPSG:4326",
    map(p, g) {
      return worksEvent(worksKind(p.description_ope), { id: p.numero_phenix_ope ?? p.objectid, where: [p.libelle_ope, cap1(String(p.commune ?? "").toLowerCase())].filter(Boolean).join(", "),
        detail: p.description_ope, start: p.date_demarrage, end: p.date_fin, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "loire-atlantique", name: "Loire-Atlantique (info-route)", bbox: [-2.6, 46.85, -0.9, 47.85], ttl: 10 * MIN, weight: 0.8,
    kinds: ["works", "closure", "jam"], licence: "Licence Ouverte", attribution: "Département de Loire-Atlantique", frequency: "temps réel",
    url: ods("data.loire-atlantique.fr", "224400028_info-route-departementale"),
    map(p, g) {
      const nat = String(p.nature ?? "");
      const lines = [p.ligne3, p.ligne5].filter((x) => typeof x === "string" && x.trim());
      const end = /au\s+(\d{2}\/\d{2}\/\d{4}(?:\s*\d{1,2}h\d{0,2})?)/i.exec(p.ligne4 ?? "")?.[1];
      const start = /du\s+(\d{2}\/\d{2}\/\d{4}(?:\s*\d{1,2}h\d{0,2})?)/i.exec(p.ligne4 ?? "")?.[1];
      let kind;
      if (/bouchon/i.test(nat)) kind = "jam"; else if (/d[ée]viation/i.test(nat)) kind = "closure"; else if (/chantier/i.test(nat)) kind = worksKind(lines.join(" "));
      else return null; // bacs de Loire, etc.
      const o = worksEvent(kind === "jam" ? "works" : kind, { id: `${nat}-${p.ligne3}-${p.ligne4}`, where: p.ligne3, detail: p.ligne5 ?? p.ligne4,
        start: start ? frDate(start) : null, end: end ? frDate(end) : null, ...geoRep(g) });
      if (kind === "jam") Object.assign(o, { type: "jam", title: "Bouchon", severity: 2, blocking: false, lanes: null });
      if (kind === "closure") o.title = "Route barrée (déviation)";
      return o;
    },
  }),
  cityGeoSource({
    id: "cd22-arretes", name: "Côtes-d'Armor (arrêtés de chantiers)", bbox: [-3.7, 48.0, -1.9, 48.95], weight: 0.8,
    licence: "Licence Ouverte", attribution: "Département des Côtes-d'Armor", frequency: "quotidienne",
    get url() { return `https://datarmor.cotesdarmor.fr/data-fair/api/v1/datasets/cd22arreteschantiers/lines?size=1000&format=geojson&DATEFIN_gte=${new Date().toISOString().slice(0, 10)}`; },
    map(p, g) {
      const kind = worksKind(p.CIRCULATION);
      return worksEvent(kind, { id: p.NUMDOSSIER, road: p.ROUTE, where: [p.ROUTE, p.COMMUNE].filter(Boolean).join(", "),
        detail: [p.CIRCULATION, p.TRAVAUX, p.JOURSETHORAIRES1].filter(Boolean).join(" · "), start: frDate(p.DATEDEBUT),
        end: Number.isFinite(frDate(p.DATEFIN)) ? frDate(p.DATEFIN) + DAY - MIN : null, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "mayenne", name: "Mayenne (routes barrées)", bbox: [-1.25, 47.7, -0.05, 48.6], weight: 0.8,
    licence: "Licence Ouverte 2.0", attribution: "Département de la Mayenne", frequency: "continue",
    url: ods("data.lamayenne.fr", "225300011_waze_road-closures"),
    map(p, g) {
      const kind = p.type === "ROAD_CLOSED" ? "closure" : worksKind(p.descriptio);
      return worksEvent(kind, { id: p.objectid, road: String(p.street ?? "").split("/")[0], where: [p.street, p.locdesc].filter(Boolean).join(", "),
        detail: [p.descriptio, p.timestart && p.timeend ? `de ${p.timestart} à ${p.timeend}` : null].filter(Boolean).join(" · "),
        start: p.starttime, end: p.endtime, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "sarthe", name: "Sarthe (chantiers routiers)", bbox: [-0.5, 47.55, 0.95, 48.5], weight: 0.8,
    licence: "Licence Ouverte 2.0", attribution: "Département de la Sarthe", frequency: "quotidienne",
    url: ods("data.sarthe.fr", "227200029_chantiers_routiers"),
    map(p, g) {
      const kind = worksKind(p.mode_exp);
      return worksEvent(kind, { id: p.objectid, road: /RD\s*0*(\d+)/.exec(p.loc_txt ?? "") ? `D${/RD\s*0*(\d+)/.exec(p.loc_txt)[1]}` : null,
        where: p.loc_txt, detail: [p.mode_exp, p.nature_trvx].filter(Boolean).join(" · "), start: p.date_debut, end: p.date_fin, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "tours", name: "Tours Métropole (travaux)", bbox: [0.5, 47.25, 0.9, 47.5], weight: 0.7,
    licence: "Licence Ouverte 2.0", attribution: "Tours Métropole Val de Loire", frequency: "2 fois par semaine",
    get url() { return ods("data.tours-metropole.fr", "travaux_lineaire_tmvl", "date_previsionnelle_de_fin_des_travaux>=now()"); },
    map(p, g) {
      const imp = p.impact_des_travaux_sur_la_circulation;
      const kind = /ferm/i.test(imp ?? "") ? "closure" : worksKind(imp);
      return worksEvent(kind, { id: `${p.nom_de_la_voie ?? p.adresse}-${p.date_previsionnelle_de_debut_des_travaux}`,
        where: [p.nom_de_la_voie ?? p.adresse, p.commune].filter(Boolean).join(", "), detail: [imp, p.type_de_travaux].filter(Boolean).join(" · "),
        start: p.date_previsionnelle_de_debut_des_travaux, end: p.date_previsionnelle_de_fin_des_travaux, ...geoRep(g) });
    },
  }),
  cityGeoSource({
    id: "angers", name: "Angers Loire Métropole (info travaux)", bbox: [-0.75, 47.35, -0.4, 47.6], weight: 0.7,
    licence: "ODbL", attribution: "Angers Loire Métropole", frequency: "quotidienne",
    get url() { return ods("data.angers.fr", "info-travaux", "endat>=now()"); },
    map(p, g) {
      if (p.traffic === "normal") return null;
      const kind = p.traffic === "deviated" ? "closure" : p.traffic === "slow" ? "lanes" : worksKind(p.description);
      return worksEvent(kind, { id: p.id, where: p.address ?? p.title, detail: p.description ?? p.title, start: p.startat, end: p.endat, ...geoRep(g) });
    },
  }),
];

/** DiaLog : arrêtés de circulation temporaires (DATEX II v3, TrafficRegulationPublication). */
const DIALOG = {
  id: "dialog", name: "DiaLog (arrêtés de circulation)", country: "FR", bbox: FR, ttl: 6 * HOUR, weight: 0.8,
  kinds: ["closure", "lanes"], licence: "Licence Ouverte 2.0", attribution: "DiaLog (beta.gouv.fr) — arrêtés des collectivités",
  url: "https://dialog.beta.gouv.fr/api/regulations/datex", frequency: "continue",
  async fetch(ctx) {
    // ≈ 13 Mo générés à la volée et servis lentement (jusqu'à 15 min mesurées) : délai long, rafraîchi toutes les 6 h
    const r = await fetchText("https://dialog.beta.gouv.fr/api/regulations/datex", { prev: ctx.state.meta, timeout: 25 * MIN });
    if (r.notModified) return null;
    ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
    const now = Date.now(), out = [];
    for (const order of r.text.split(/<(?:[\w-]+:)?trafficRegulationOrder\b/).slice(1)) {
      const id = /^[^>]*?\bid="([^"]+)"/.exec(order)?.[1];
      const head = order.slice(0, 3000);
      const end = Date.parse(first(head, "overallEndTime") ?? ""), start = Date.parse(first(head, "overallStartTime") ?? "");
      if (!Number.isFinite(end) || end < now || (Number.isFinite(start) && start > now + DAY)) continue; // permanents et finis : non
      const desc = decode(first(first(order, "description"), "value"));
      const auth = decode(first(first(order, "issuingAuthority"), "value"));
      let n = 0;
      for (const reg of order.split(/<(?:[\w-]+:)?trafficRegulation>/).slice(1)) {
        const t = /typeOfRegulation xsi:type="(?:[\w-]+:)?(\w+)"/.exec(reg)?.[1];
        let kind = null;
        if (t === "AccessRestriction" && first(reg, "accessRestrictionType") === "noEntry") kind = "closure";
        else if (t === "RoadOrCarriagewayOrLaneManagement") kind = "lanes";
        if (!kind) continue;
        // restriction réservée à certains véhicules (poids lourds, gabarit…) : pas une fermeture pour tous
        if (/VehicleCondition|vehicleCharacteristics/.test(reg)) continue;
        for (const gj of all(reg, "geoJsonGeometry").slice(0, 4)) {
          let g;
          try { g = JSON.parse(decode(gj)); } catch { continue; }
          const rep = geoRep(g);
          const road = decode(first(reg, "roadName"));
          const sub = first(reg, "roadOrCarriagewayOrLaneManagementType");
          const e = makeEvent("dialog", worksEvent(kind, {
            id: `${id}-${n++}`, title: kind === "closure" ? "Route barrée" : SUB_TITLE[sub] ?? "Circulation perturbée",
            where: [road, auth].filter(Boolean).join(", "), detail: desc, start, end, ...rep,
          }));
          if (e) out.push(e);
        }
      }
    }
    return out;
  },
};
SOURCES.push(...CITY_SOURCES, DIALOG);

// ───────────────────────── importance à l'écran ─────────────────────────
// Carte « comme Waze » : en vue ville, seulement ce qui compte pour un conducteur (accidents, fermetures
// et bouchons des grands axes, dangers, évènements graves ou confirmés par plusieurs sources).
// Les chantiers de rue et arrêtés locaux n'apparaissent que de près ; les points noirs BAAC servent
// surtout aux alertes de conduite (pastille discrète seulement tout près).
const LOCAL_SOURCES = new Set([...CITY_SOURCES.map((s) => s.id), DIALOG.id]);
/** 2 = grand axe (autoroute, nationale, métropolitaine, européenne), 1 = départementale, 0 = rue / inconnue. */
function roadClass(road) {
  const k = roadKey(road);
  if (!k) return 0;
  if (/^(A|AP|E|M|N|RN|RCEA)\d/.test(k)) return 2;
  if (/^(D|RD|C|CV|GI|B|L)\d/.test(k)) return 1;
  return 0;
}
function minZoomOf(e) {
  const rc = roadClass(e.road);
  const local = LOCAL_SOURCES.has(e.source);
  const main = rc === 2 || (!local && rc === 0); // sources nationales (Bison Futé, Autobahn, NDW…) = grands axes
  const multi = (e.sources?.length ?? 1) >= 2;
  const sev = e.severity;
  let z;
  switch (e.type) {
    case "weather": case "flood": return 0;
    case "hotspot": return 15;
    case "fuel": return 14;
    case "accident": z = main ? (sev >= 3 ? 0 : 9) : rc === 1 ? 10 : 12; break;
    case "jam": z = main ? (sev >= 3 ? 0 : 9) : 11; break;
    case "danger": z = main ? (sev >= 3 ? 0 : 10) : 12; break;
    case "closure": z = main ? (sev >= 3 ? 0 : 9) : rc === 1 ? 11 : sev >= 4 ? 12 : 14; break;
    case "lanes": z = main ? (sev >= 3 ? 10 : 11) : rc === 1 ? 13 : 15; break;
    case "works": z = main ? (sev >= 3 ? 11 : 12) : rc === 1 ? 14 : 15; break;
    default: z = 12;
  }
  if (multi && e.type !== "works") z = Math.min(z, main ? 9 : 12);
  return z;
}

function bisonFuteEvent(src, e) {
  const map = { closure: "closure", accident: "accident", slow: "jam", obstacle: "danger", conditions: "danger", works: "works", lanes: "lanes" };
  const type = map[e.kind];
  if (!type) return null;
  const sev = DATEX_SEV[e.severity] ?? null;
  return makeEvent(src, {
    id: e.id, type, title: e.title, road: e.road, point: e.coord, line: e.line ?? null,
    severity: type === "closure" ? Math.max(3, sev ?? 3) : type === "works" ? Math.min(sev ?? 1, 2) : sev,
    description: [e.where, e.description].filter(Boolean).join(" — ") || `${e.title}${e.road ? ` sur ${e.road}` : ""}`,
    lang: null, start: e.start, end: e.end, blocking: type === "closure",
    extra: e.source ? { operator: e.source } : null,
  });
}
async function bisonFuteFeed(ctx, url, src) {
  const r = await fetchText(url, { prev: ctx.state.meta, timeout: 45_000 });
  if (r.notModified) return null;
  ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
  return parseBisonFute(r.text).map((e) => bisonFuteEvent(src, e)).filter(Boolean);
}

/** Catalogne : GML (WFS 1.0) avec un point par incident. */
function sctItem(fm) {
  const c = first(fm, "coordinates")?.split(",").map(Number);
  if (!c || !isLngLat(c)) return null;
  const typ = decode(first(fm, "descripcio_tipus")) ?? "";
  const cause = decode(first(fm, "causa")) ?? "";
  const desc = decode(first(fm, "descripcio")) ?? "";
  const all3 = `${typ} ${cause} ${desc}`;
  const level = num(first(fm, "nivell")) ?? 1;
  let type, title;
  if (/accident/i.test(all3)) { type = "accident"; title = "Accident"; }
  else if (/tallad|tancad|tall total/i.test(all3)) { type = "closure"; title = "Route fermée"; }
  else if (/obres|manteniment/i.test(all3)) { type = /carril|calçada/i.test(all3) ? "lanes" : "works"; title = "Travaux"; }
  else if (/retenci|congesti|circulació lenta|intensa/i.test(all3)) { type = "jam"; title = /aturad/i.test(all3) ? "Circulation à l'arrêt" : "Bouchon"; }
  else if (/neu|gel|boira|meteo|pluja|vent/i.test(all3)) { type = "danger"; title = "Conditions difficiles"; }
  else if (/avaria|obstacle|objecte|animal|incendi/i.test(all3)) { type = "danger"; title = /avaria/i.test(all3) ? "Véhicule en panne" : "Obstacle sur la chaussée"; }
  else return null;
  const road = decode(first(fm, "carretera"));
  const towards = decode(first(fm, "cap_a"));
  return {
    id: decode(first(fm, "identificador")) ?? `${c[0]},${c[1]}`, type, title, road,
    severity: type === "closure" ? 3 : type === "works" ? 1 : level >= 4 ? 3 : 2,
    direction: towards ? `vers ${cap1(towards.toLowerCase())}` : null,
    description: `${title}${road ? ` sur ${road}` : ""}${towards ? `, direction ${cap1(towards.toLowerCase())}` : ""}`,
    original: [typ, desc].filter(Boolean).join(" — "), lang: "ca",
    point: c, start: decode(first(fm, "data")), blocking: type === "closure",
  };
}

// ── vigilance météo (MeteoAlarm, flux France, en français) ──
const MA_HAZARD = {
  1: ["Vent violent", "weather"], 2: ["Neige-verglas", "weather"], 3: ["Orages", "weather"], 4: ["Brouillard", "weather"],
  5: ["Canicule", "weather"], 6: ["Grand froid", "weather"], 7: ["Vagues-submersion", "weather"], 8: ["Feux de forêt", "weather"],
  9: ["Avalanches", "weather"], 10: ["Pluie-inondation", "flood"], 12: ["Crues", "flood"], 13: ["Pluie-inondation", "flood"],
};
const MA_LEVEL = { 2: ["jaune", 2], 3: ["orange", 3], 4: ["rouge", 4] };
const normName = (s) => String(s ?? "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z]/g, "");
let depts = null; // { byName: Map, list: [{code, nom, geometry, bbox, center}] }
const DEPTS_URL = "https://raw.githubusercontent.com/gregoiredavid/france-geojson/master/departements-version-simplifiee.geojson";
async function loadDepts(store) {
  if (depts) return depts;
  const disk = await store.collection("events-depts", { at: 0, fc: null });
  if (!disk.data.fc || Date.now() - disk.data.at > 180 * DAY) {
    const r = await fetchJson(DEPTS_URL, { timeout: 60_000 });
    disk.data.fc = r.json; disk.data.at = Date.now(); disk.save();
  }
  const list = [];
  for (const f of disk.data.fc.features ?? []) {
    const polys = f.geometry.type === "Polygon" ? [f.geometry.coordinates] : f.geometry.coordinates;
    let w = 180, s = 90, e = -180, n = -90, best = null, bestArea = -1;
    for (const poly of polys) {
      let area = 0;
      for (const [x, y] of poly[0]) { w = Math.min(w, x); e = Math.max(e, x); s = Math.min(s, y); n = Math.max(n, y); }
      for (let i = 0, j = poly[0].length - 1; i < poly[0].length; j = i++) area += poly[0][j][0] * poly[0][i][1] - poly[0][i][0] * poly[0][j][1];
      if (Math.abs(area) > bestArea) { bestArea = Math.abs(area); best = poly[0]; }
    }
    // point d'ancrage : centroïde du plus grand anneau (ramené dedans s'il tombe dehors)
    let cx = 0, cy = 0, a = 0;
    for (let i = 0, j = best.length - 1; i < best.length; j = i++) {
      const k = best[j][0] * best[i][1] - best[i][0] * best[j][1];
      a += k; cx += (best[j][0] + best[i][0]) * k; cy += (best[j][1] + best[i][1]) * k;
    }
    let center = a ? [cx / (3 * a), cy / (3 * a)] : [(w + e) / 2, (s + n) / 2];
    if (!pointInGeometry(center, f.geometry)) center = best[Math.floor(best.length / 2)];
    list.push({ code: f.properties.code, nom: f.properties.nom, geometry: f.geometry, bbox: [w, s, e, n], center: center.map(r6) });
  }
  depts = { list, byName: new Map(list.map((d) => [normName(d.nom), d])) };
  return depts;
}
async function meteoalarm(ctx) {
  const d = await loadDepts(ctx.store);
  const r = await fetchJson("https://feeds.meteoalarm.org/api/v1/warnings/feeds-france", { prev: ctx.state.meta, timeout: 30_000 });
  if (r.notModified) return null;
  ctx.state.meta = { etag: r.etag, lastModified: r.lastModified };
  const now = Date.now();
  const best = new Map(); // département + phénomène → avertissement le plus fort en cours
  for (const w of r.json.warnings ?? []) {
    const al = w.alert;
    if (!al || al.msgType === "Cancel" || al.status !== "Actual") continue;
    const info = (al.info ?? []).find((i) => /^fr/i.test(i.language)) ?? al.info?.[0];
    if (!info || (info.responseType ?? []).includes("AllClear")) continue;
    const p = Object.fromEntries((info.parameter ?? []).map((x) => [x.valueName, x.value]));
    const lvl = parseInt(p.awareness_level, 10), haz = parseInt(p.awareness_type, 10);
    if (!MA_LEVEL[lvl] || !MA_HAZARD[haz]) continue;
    const onset = Date.parse(info.onset ?? info.effective ?? ""), exp = Date.parse(info.expires ?? "");
    if (Number.isFinite(exp) && exp < now) continue;
    if (Number.isFinite(onset) && onset > now + 12 * HOUR) continue; // vigilance pour demain : pas encore
    for (const area of info.area ?? []) {
      const dep = d.byName.get(normName(area.areaDesc));
      if (!dep) continue;
      const key = `${dep.code}:${haz}`;
      const prev = best.get(key);
      if (prev && prev.lvl >= lvl) continue;
      best.set(key, { dep, lvl, haz, onset, exp, info, id: w.uuid ?? al.identifier });
    }
  }
  return [...best.values()].map(({ dep, lvl, haz, onset, exp, info }) => {
    const [hz, type] = MA_HAZARD[haz];
    const [color, sev] = MA_LEVEL[lvl];
    return makeEvent("meteoalarm", {
      id: `${dep.code}-${haz}`, type, severity: sev,
      title: `Vigilance ${color} ${hz.toLowerCase()}`,
      description: `${dep.nom} (${dep.code}) — ${clip(info.description ?? "", 300)}`,
      original: info.instruction ?? null, lang: null,
      point: dep.center, start: Number.isFinite(onset) ? onset : null, end: Number.isFinite(exp) ? exp : null,
      extra: { area: dep.code, areaName: dep.nom, level: color, hazard: hz },
    });
  }).filter(Boolean);
}

// ── ruptures de carburant (flux instantané v2) ──
async function fuelShortages() {
  const base = "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/exports/json";
  const fuels = ["gazole", "sp95", "e10", "sp98", "e85", "gplc"];
  const q = new URLSearchParams({
    select: ["id", "ville", "adresse", "geom", "carburants_rupture_temporaire", "carburants_disponibles", ...fuels.map((f) => `${f}_rupture_debut`)].join(","),
    where: "carburants_rupture_temporaire is not null",
  });
  const r = await fetchJson(`${base}?${q}`, { timeout: 60_000 });
  const now = Date.now();
  const names = { gazole: "Gazole", sp95: "SP95", e10: "SP95-E10", sp98: "SP98", e85: "E85", gplc: "GPL" };
  const out = [];
  for (const s of r.json ?? []) {
    const p = s.geom ? [s.geom.lon, s.geom.lat] : null;
    // une rupture « temporaire » ouverte depuis plus de 7 jours n'est plus une information fiable
    const out7 = fuels.filter((f) => { const t = Date.parse(s[`${f}_rupture_debut`] ?? ""); return Number.isFinite(t) && now - t < 7 * DAY; });
    if (!out7.length) continue;
    const dry = !(s.carburants_disponibles ?? []).length;
    const since = Math.max(...out7.map((f) => Date.parse(s[`${f}_rupture_debut`])));
    out.push(makeEvent("carburants", {
      id: s.id, type: "fuel", severity: dry ? 2 : 1,
      title: dry ? "Station à sec" : `Rupture : ${out7.map((f) => names[f]).join(", ")}`,
      description: `${cap1(String(s.adresse ?? "").toLowerCase())}, ${s.ville ?? ""}`.trim().replace(/^,\s*/, ""),
      point: p, start: since,
      extra: { missing: out7.map((f) => names[f]), available: s.carburants_disponibles ?? [] },
    }));
  }
  return out.filter(Boolean);
}

// ── accidentalité (BAAC) : sections accidentogènes des 3 dernières années ──
const BAAC_DATASET = "https://www.data.gouv.fr/api/1/datasets/53698f4ca3a729239d2036df/";
function csvRows(text) {
  const lines = text.split(/\r?\n/);
  const sep = lines[0].includes(";") ? ";" : ",";
  const head = lines[0].split(sep).map((h) => h.replace(/^﻿/, "").replace(/"/g, "").trim());
  const out = [];
  for (let i = 1; i < lines.length; i++) {
    if (!lines[i]) continue;
    const c = lines[i].split(sep).map((x) => x.replace(/^"|"$/g, "").trim());
    const o = {};
    for (let k = 0; k < head.length; k++) o[head[k]] = c[k];
    out.push(o);
  }
  return out;
}
async function baacHotspots(ctx) {
  const disk = await ctx.store.collection("events-baac", { at: 0, years: [], hotspots: [] });
  ctx.state.disk = disk;
  if (disk.data.hotspots.length && Date.now() - disk.data.at < 30 * DAY) {
    if (ctx.state.loaded) return null;
    ctx.state.loaded = true;
    return disk.data.hotspots.map((h) => hotspotEvent(h, disk.data.years)).filter(Boolean);
  }
  const ds = (await fetchJson(BAAC_DATASET, { timeout: 30_000 })).json;
  const years = new Map();
  for (const r of ds.resources ?? []) {
    const m = /^(caract|usagers)[-_](\d{4})\.csv$/i.exec(r.title ?? "");
    if (!m) continue;
    const y = +m[2];
    (years.get(y) ?? years.set(y, {}).get(y))[m[1].toLowerCase()] = r.url;
  }
  const chosen = [...years.entries()].filter(([, v]) => v.caract && v.usagers).sort((a, b) => b[0] - a[0]).slice(0, 3);
  if (!chosen.length) throw new Error("ressources BAAC introuvables");
  // grille de ~150 m : on compte accidents, blessés hospitalisés et tués par case
  const G = 0.00135;
  const cells = new Map();
  for (const [, v] of chosen) {
    const grav = new Map(); // Num_Acc → { killed, hosp }
    const us = await fetchText(v.usagers, { timeout: 180_000 });
    for (const u of csvRows(us.text)) {
      const g = u.grav;
      if (g !== "2" && g !== "3") continue;
      const k = grav.get(u.Num_Acc) ?? { killed: 0, hosp: 0 };
      if (g === "2") k.killed++; else k.hosp++;
      grav.set(u.Num_Acc, k);
    }
    await sleep(1000);
    const ca = await fetchText(v.caract, { timeout: 180_000 });
    for (const a of csvRows(ca.text)) {
      const lat = num(a.lat), lng = num(a.long);
      if (!isLngLat([lng, lat]) || lat < 41 || lat > 51.5 || lng < -5.5 || lng > 10) continue; // métropole
      const key = `${Math.floor(lat / G)}:${Math.floor(lng / (G * 1.45))}`;
      const c = cells.get(key) ?? { n: 0, killed: 0, hosp: 0, sx: 0, sy: 0, agg: 0 };
      const k = grav.get(a.Num_Acc ?? a.Accident_Id);
      c.n++; c.sx += lng; c.sy += lat;
      if (k) { c.killed += k.killed; c.hosp += k.hosp; }
      if (a.agg === "2") c.agg++;
      cells.set(key, c);
    }
    await sleep(1000);
  }
  // une case est « accidentogène » avec ≥ 4 accidents corporels en 3 ans dont au moins un grave
  const hot = [];
  for (const [key, c] of cells) {
    if (c.n < 4 || c.killed + c.hosp < 1) continue;
    const score = c.n + 3 * c.hosp + 10 * c.killed;
    hot.push({ k: key, p: [r6(c.sx / c.n), r6(c.sy / c.n)], n: c.n, killed: c.killed, hosp: c.hosp, urban: c.agg * 2 >= c.n ? 1 : 0, score });
  }
  hot.sort((a, b) => b.score - a.score);
  disk.data = { at: Date.now(), years: chosen.map(([y]) => y), hotspots: hot.slice(0, 20000) };
  disk.save();
  ctx.state.loaded = true;
  return disk.data.hotspots.map((h) => hotspotEvent(h, disk.data.years)).filter(Boolean);
}
function hotspotEvent(h, years) {
  const span = years.length ? `${Math.min(...years)}–${Math.max(...years)}` : "";
  const sev = h.score >= 40 ? 3 : h.score >= 18 ? 2 : 1;
  const parts = [`${h.n} accidents corporels`];
  if (h.killed) parts.push(`${h.killed} tué${h.killed > 1 ? "s" : ""}`);
  if (h.hosp) parts.push(`${h.hosp} blessé${h.hosp > 1 ? "s" : ""} hospitalisé${h.hosp > 1 ? "s" : ""}`);
  return makeEvent("baac", {
    id: h.k, type: "hotspot", severity: sev, title: "Section accidentogène",
    description: `${parts.join(", ")} sur ${span}${h.urban ? " (en agglomération)" : ""}. Prudence.`,
    point: h.p, extra: { accidents: h.n, killed: h.killed, hospitalized: h.hosp, urban: !!h.urban, years: span },
  });
}

// ───────────────────────────── analyse ─────────────────────────────
/**
 * Fusion : deux évènements parlent du même incident s'ils sont du même groupe (incident, travaux,
 * bouchon…), proches (distance point↔géométrie), compatibles dans le temps et sur la même route
 * quand les deux la donnent. Union-find sur une grille spatiale.
 */
const MERGE_DIST = { incident: 400, jam: 600, works: 300, weather: 1, flood: 1, fuel: 30, hotspot: 1 };
function compatible(a, b) {
  const ga = TYPES[a.type].group, gb = TYPES[b.type].group;
  if (ga !== gb || a.source === b.source && !(a.source === "osa")) return false;
  if (ga === "weather" || ga === "flood" || ga === "hotspot") return false;
  const ra = roadKey(a.road), rb = roadKey(b.road);
  if (ra && rb && ra !== rb) return false;
  const lim = MERGE_DIST[ga] ?? 300;
  const d = Math.min(
    a.line ? distToLine(b.point, a.line) : Infinity,
    b.line ? distToLine(a.point, b.line) : Infinity,
    dist(a.point, b.point),
  );
  if (d > lim) return false;
  // sens opposés sur une même route (bearing connu ou ligne orientée) : deux évènements distincts
  const ha = a.bearing ?? (a.line ? bearing(a.line[0], a.line[a.line.length - 1]) : null);
  const hb = b.bearing ?? (b.line ? bearing(b.line[0], b.line[b.line.length - 1]) : null);
  if (ha != null && hb != null && angDiff(ha, hb) > 120 && (a.line && lineLength(a.line) > 200 || a.bearing != null) && (b.line && lineLength(b.line) > 200 || b.bearing != null)) return false;
  if (ga === "incident" || ga === "jam") {
    const sa = Date.parse(a.start ?? ""), sb = Date.parse(b.start ?? "");
    if (Number.isFinite(sa) && Number.isFinite(sb) && Math.abs(sa - sb) > 4 * HOUR) return false;
  } else if (ga === "works") {
    const ea = Date.parse(a.end ?? "") || Infinity, eb = Date.parse(b.end ?? "") || Infinity;
    const sa = Date.parse(a.start ?? "") || 0, sb = Date.parse(b.start ?? "") || 0;
    if (sa > eb || sb > ea) return false;
  }
  return true;
}

function analyze(list, weights, names, now = Date.now()) {
  const n = list.length;
  const parent = Int32Array.from({ length: n }, (_, i) => i);
  const find = (i) => { while (parent[i] !== i) { parent[i] = parent[parent[i]]; i = parent[i]; } return i; };
  const G = 0.01; // ≈ 1,1 km
  const grid = new Map();
  list.forEach((e, i) => {
    const pts = e.line ? [e.point, e.line[e.line.length - 1], e.line[Math.floor(e.line.length / 2)]] : [e.point];
    const keys = new Set(pts.map((p) => `${Math.floor(p[0] / G)}:${Math.floor(p[1] / G)}`));
    for (const k of keys) (grid.get(k) ?? grid.set(k, []).get(k)).push(i);
  });
  for (const [k, idx] of grid) {
    const [gx, gy] = k.split(":").map(Number);
    const near = [];
    for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) near.push(...(grid.get(`${gx + dx}:${gy + dy}`) ?? []));
    for (const i of idx) for (const j of near) {
      if (j <= i || find(i) === find(j)) continue;
      if (compatible(list[i], list[j])) parent[find(i)] = find(j);
    }
  }
  const clusters = new Map();
  list.forEach((e, i) => { const r = find(i); (clusters.get(r) ?? clusters.set(r, []).get(r)).push(e); });

  const out = [];
  for (const members of clusters.values()) {
    // évènement principal : type le plus important, puis source la plus fiable, puis le plus détaillé
    members.sort((a, b) => TYPES[a.type].rank - TYPES[b.type].rank || (weights[b.source] ?? 0.5) - (weights[a.source] ?? 0.5)
      || (b.line ? 1 : 0) - (a.line ? 1 : 0));
    const p = members[0];
    const srcs = [...new Set(members.map((m) => m.source))];
    let conf = 1 - srcs.reduce((acc, s) => acc * (1 - (weights[s] ?? 0.5)), 1);
    // un incident ancien, sans fin annoncée et vu par une seule source devient douteux
    const startMs = Math.min(...members.map((m) => Date.parse(m.start ?? "") || Infinity));
    const age = Number.isFinite(startMs) ? now - startMs : null;
    if ((p.type === "accident" || p.type === "danger") && age != null && !p.end && srcs.length === 1) {
      if (age > 12 * HOUR) conf *= 0.6; else if (age > 4 * HOUR) conf *= 0.8;
    }
    const ends = members.map((m) => Date.parse(m.end ?? "")).filter(Number.isFinite);
    out.push({
      ...p,
      id: members.length > 1 ? `m:${p.id}` : p.id,
      severity: Math.max(...members.map((m) => m.severity)),
      line: p.line ?? members.find((m) => m.line)?.line ?? null,
      road: p.road ?? members.find((m) => m.road)?.road ?? null,
      lanes: p.lanes ?? members.find((m) => m.lanes)?.lanes ?? null,
      delay: Math.max(0, ...members.map((m) => m.delay ?? 0)) || null,
      speed: members.map((m) => m.speed).filter(Boolean).sort((a, b) => a - b)[0] ?? null,
      blocking: members.some((m) => m.blocking),
      start: Number.isFinite(startMs) ? new Date(startMs).toISOString() : null,
      end: ends.length ? new Date(Math.max(...ends)).toISOString() : null,
      sources: srcs.map((s) => ({ id: s, name: names[s] ?? s })),
      merged: members.length,
      members: members.length > 1 ? members.map((m) => m.id).slice(0, 12) : undefined,
      confidence: Math.round(Math.min(0.99, conf) * 100) / 100,
    });
  }
  // corroboration croisée : un bouchon (mesuré ou communautaire) juste en aval d'un accident / danger
  // confirme celui-ci et lui donne un retard
  const jamsList = out.filter((e) => e.type === "jam");
  if (jamsList.length) {
    const jg = new Map();
    for (const j of jamsList) { const k = `${Math.floor(j.point[0] / 0.02)}:${Math.floor(j.point[1] / 0.02)}`; (jg.get(k) ?? jg.set(k, []).get(k)).push(j); }
    for (const e of out) {
      if (e.type !== "accident" && e.type !== "danger" && e.type !== "closure") continue;
      const gx = Math.floor(e.point[0] / 0.02), gy = Math.floor(e.point[1] / 0.02);
      let best = null;
      for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) for (const j of jg.get(`${gx + dx}:${gy + dy}`) ?? []) {
        const d = j.line ? distToLine(e.point, j.line) : dist(e.point, j.point);
        if (d < 2500 && (!roadKey(e.road) || !roadKey(j.road) || roadKey(e.road) === roadKey(j.road)) && (!best || d < best.d)) best = { d, j };
      }
      if (!best) continue;
      e.relatedJam = { id: best.j.id, delay: best.j.delay, speed: best.j.speed, distance: Math.round(best.d) };
      const extra = best.j.sources.filter((s) => !e.sources.some((x) => x.id === s.id));
      if (extra.length) e.confidence = Math.round(Math.min(0.99, 1 - (1 - e.confidence) * (1 - 0.5 * Math.max(...extra.map((s) => weights[s.id] ?? 0.5)))) * 100) / 100;
      if (!e.delay && best.j.delay) e.delay = best.j.delay;
    }
  }
  return out;
}

/** Retard (s) estimé pour un évènement qui touche l'itinéraire sur `len` mètres. */
function estimateDelay(e, len, byLine = true) {
  if (e.delay) return e.delay;
  const kmh = (l, v, ref) => Math.max(0, (l * 3.6) / v - (l * 3.6) / ref);
  const major = /^(A|N|E|M|AP|AG|BAB|RN)\d/i.test(e.road ?? "");
  switch (e.type) {
    // fermeture : il faudra contourner. Grand axe confirmé par le tracé → long détour ; rue → court détour.
    case "closure": return major && byLine ? 15 * 60 : byLine ? 5 * 60 : 3 * 60;
    case "jam": return Math.min(30 * 60, kmh(Math.max(len, 500), e.speed ?? 15, 80));
    case "accident": return e.severity >= 4 ? 10 * 60 : e.severity >= 3 ? 5 * 60 : 2 * 60;
    case "lanes": if (e.severity <= 1) return 0; return Math.min(5 * 60, (e.lanes === "Circulation alternée" ? 120 : 30) + kmh(Math.max(len, 300), 50, 90));
    case "works": return Math.min(2 * 60, kmh(Math.max(len, 200), 70, 90));
    case "danger": return e.severity >= 3 ? 60 : 20;
    default: return 0;
  }
}

// ───────────────────────────── fonctionnalité ─────────────────────────────
export async function register({ route, store, log }) {
  const weights = Object.fromEntries(SOURCES.map((s) => [s.id, s.weight]));
  weights.osa = 0.6;
  const names = Object.fromEntries(SOURCES.map((s) => [s.id, s.name]));
  names.osa = "Communauté OsaMaps";
  const state = new Map(SOURCES.map((s) => [s.id, {
    events: [], at: 0, okAt: 0, error: null, fails: 0, busy: false, ms: null, demandAt: 0, nextAt: 0, ctx: { state: {}, store },
  }]));
  let analyzed = [];
  let dirty = true;
  let running = 0;

  /** Évènements « vivants » : on refiltre les fins dépassées à chaque analyse. */
  function rebuild() {
    const now = Date.now();
    const list = [];
    const seen = new Set();
    for (const s of SOURCES) for (const e of state.get(s.id).events) {
      if (seen.has(e.id) || (e.end && Date.parse(e.end) <= now)) continue;
      seen.add(e.id);
      list.push(e);
    }
    // bouchons communautaires du module trafic
    for (const j of trafficShared.jams()) {
      const e = makeEvent("osa", {
        id: j.id, type: "jam", severity: j.level === "jam" ? 3 : 2, title: j.level === "jam" ? "Bouchon" : "Ralentissement",
        description: `${j.level === "jam" ? "Bouchon" : "Ralentissement"} détecté par ${j.contributors} conducteur${j.contributors > 1 ? "s" : ""} OsaMaps, ${j.speed} km/h`,
        point: j.start, line: [j.start, j.end], bearing: j.heading, delay: j.delay, speed: j.speed, start: now,
      });
      if (e) list.push(e);
    }
    const t0 = Date.now();
    analyzed = analyze(list, weights, names, now);
    for (const e of analyzed) e.minZoom = minZoomOf(e);
    dirty = false;
    lastAnalysis = { at: now, input: list.length, output: analyzed.length, merged: list.length - analyzed.length, ms: Date.now() - t0 };
  }
  let lastAnalysis = null;

  async function refresh(src) {
    const st = state.get(src.id);
    st.busy = true; running++;
    const t0 = Date.now();
    try {
      const list = await src.fetch(st.ctx);
      st.at = Date.now();
      if (list) { st.events = list; dirty = true; }
      st.okAt = st.at; st.error = null; st.fails = 0;
      st.nextAt = st.at + src.ttl;
      if (list) log(`évènements : ${src.id} → ${list.length} (${Date.now() - t0} ms)`);
    } catch (e) {
      st.at = Date.now();
      st.fails++;
      st.error = String(e?.message ?? e).slice(0, 200);
      // recul progressif : 2, 4, 8… min, plafonné au TTL (et 30 min)
      st.nextAt = st.at + Math.min(src.ttl, 30 * MIN, 2 * MIN * 2 ** (st.fails - 1));
      log(`évènements : ${src.id} indisponible — ${st.error}`);
    } finally {
      st.ms = Date.now() - t0;
      st.busy = false; running--;
    }
  }

  function tick() {
    const now = Date.now();
    // les plus en retard d'abord (sinon une source en échec qui réessaie souvent affame les suivantes)
    const due = SOURCES.filter((s) => { const st = state.get(s.id); return !st.busy && now >= st.nextAt; })
      .sort((a, b) => state.get(a.id).nextAt - state.get(b.id).nextAt);
    for (const src of due) {
      if (running >= MAX_PARALLEL) break;
      const st = state.get(src.id);
      // jamais chargée → on charge (premier passage étalé) ; sinon seulement si la zone est regardée
      if (st.okAt && !src.static && now - st.demandAt > DEMAND_KEEPALIVE) continue;
      refresh(src);
    }
    if (dirty) rebuild();
  }
  // premier chargement étalé (un nouveau départ toutes les 20 s au plus via MAX_PARALLEL et le tick)
  SOURCES.forEach((s, i) => { state.get(s.id).nextAt = Date.now() + 3000 + i * 4000; });
  const timer = setInterval(tick, TICK_MS);
  timer.unref?.();
  setTimeout(tick, 3500).unref?.();
  // les bouchons communautaires changent sans cesse : réanalyse légère toutes les minutes
  setInterval(() => { dirty = true; }, MIN).unref?.();

  function demand(bb) {
    const now = Date.now();
    for (const s of SOURCES) if (bboxOverlap(s.bbox, bb)) state.get(s.id).demandAt = now;
    if (bboxOverlap(FR, bb)) trafficShared.demand();
    // une source regardée après une longue pause : on la rafraîchit tout de suite (au prochain tick)
    if (dirty) rebuild();
  }

  const toFeature = (e) => ({
    type: "Feature",
    geometry: { type: "Point", coordinates: e.point },
    properties: {
      id: e.id, type: e.type, severity: e.severity, title: e.title, description: e.description, original: e.original, lang: e.lang,
      road: e.road, direction: e.direction, lanes: e.lanes, start: e.start, end: e.end, delay: e.delay, speed: e.speed,
      blocking: e.blocking, confidence: e.confidence, sources: e.sources, merged: e.merged, relatedJam: e.relatedJam ?? null,
      line: e.line, extra: e.extra, minZoom: e.minZoom ?? 0,
    },
  });

  route.get("/events", ({ query }) => {
    const bb = parseBbox(query);
    const z = Number(query.z);
    demand(bb);
    const zoom = Number.isFinite(z) ? z : 12;
    const pad = 0.02;
    const box = [bb[0] - pad, bb[1] - pad, bb[2] + pad, bb[3] + pad];
    const feats = [];
    for (const e of analyzed) {
      if (!inBbox(e.point, box) && !(e.line && e.line.some((p) => inBbox(p, box)))) continue;
      // densité selon le zoom (voir minZoomOf) ; un cran d'avance pour que le zoom suivant soit déjà là
      if ((e.minZoom ?? 0) > zoom + 1) continue;
      feats.push(e);
    }
    feats.sort((a, b) => b.severity - a.severity || TYPES[a.type].rank - TYPES[b.type].rank);
    return {
      type: "FeatureCollection",
      features: feats.slice(0, 3000).map(toFeature),
      truncated: feats.length > 3000,
      at: lastAnalysis?.at ?? null,
    };
  }, { limit: 120 });

  route.post("/events/route", ({ body }) => {
    const coords = body?.coords;
    if (!Array.isArray(coords) || coords.length < 2 || coords.length > 2000 || !coords.every(isLngLat)) {
      throw new HttpError(400, "coords : 2 à 2000 points [lng, lat]");
    }
    let w = 180, s = 90, e = -180, n = -90;
    for (const p of coords) { w = Math.min(w, p[0]); e = Math.max(e, p[0]); s = Math.min(s, p[1]); n = Math.max(n, p[1]); }
    demand([w, s, e, n]);
    return onRoute(coords, [w - 0.05, s - 0.05, e + 0.05, n + 0.05]);
  }, { limit: 40 });

  route.get("/events/sources", () => ({
    at: Date.now(),
    analysis: lastAnalysis,
    sources: SOURCES.map((s) => {
      const st = state.get(s.id);
      return {
        id: s.id, name: s.name, country: s.country, kinds: s.kinds, licence: s.licence, attribution: s.attribution, url: s.url,
        frequency: s.frequency, weight: s.weight,
        status: st.busy && !st.okAt ? "loading" : st.error ? "error" : st.okAt ? "ok" : "pending",
        events: st.events.length, lastRefresh: st.at ? new Date(st.at).toISOString() : null,
        lastOk: st.okAt ? new Date(st.okAt).toISOString() : null, error: st.error, durationMs: st.ms,
        watched: Date.now() - st.demandAt < DEMAND_KEEPALIVE,
        nextRefresh: st.nextAt ? new Date(st.nextAt).toISOString() : null,
      };
    }).concat([{
      id: "osa", name: names.osa, country: "—", kinds: ["jam"], licence: "OsaMaps", attribution: "Contributions anonymes OsaMaps",
      status: "ok", events: trafficShared.jams().length, weight: weights.osa,
    }]),
  }));

  /**
   * Évènements qui touchent un tracé (le début = position actuelle) : on accroche chaque évènement
   * proche au tracé, on vérifie le sens (lignes orientées, cap), on estime le retard, et on ne compte
   * pas deux fois un retard déjà mesuré par le module trafic (portions ralenties du même endroit).
   */
  function onRoute(coords, box) {
    const cum = [0];
    for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + dist(coords[i - 1], coords[i]));
    const T = 0.01, grid = new Map();
    for (let i = 1; i < coords.length; i++) {
      const a = coords[i - 1], b = coords[i];
      for (let x = Math.floor(Math.min(a[0], b[0]) / T); x <= Math.floor(Math.max(a[0], b[0]) / T); x++)
        for (let y = Math.floor(Math.min(a[1], b[1]) / T); y <= Math.floor(Math.max(a[1], b[1]) / T); y++)
          (grid.get(`${x}:${y}`) ?? grid.set(`${x}:${y}`, []).get(`${x}:${y}`)).push(i);
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
    const measured = (() => { try { return trafficShared.along(coords).runs ?? []; } catch { return []; } })();
    const hits = [];
    // vigilances : le tracé traverse-t-il le département ? (échantillon tous les ~2 km)
    const samples = [];
    { let last = -Infinity; for (let i = 0; i < coords.length; i++) if (cum[i] - last >= 2000 || i === coords.length - 1) { samples.push(i); last = cum[i]; } }
    for (const ev of analyzed) {
      if (ev.type === "weather" || ev.type === "flood") {
        const dep = depts?.list.find((d) => d.code === ev.extra?.area);
        if (!dep || !bboxOverlap(dep.bbox, box)) continue;
        const i = samples.find((i) => inBbox(coords[i], dep.bbox) && pointInGeometry(coords[i], dep.geometry));
        if (i == null) continue;
        hits.push({ ev, at: Math.round(cum[i]), len: 0, delay: 0, measured: false });
        continue;
      }
      if (!inBbox(ev.point, box) && !(ev.line && ev.line.some((p) => inBbox(p, box)))) continue;
      if (ev.type === "fuel") continue; // une station n'est pas « sur » la route : c'est le module along qui les propose
      // tolérance d'accrochage : les sources nationales placent l'évènement sur l'axe (70 m) ; les
      // collectivités donnent souvent le centre d'un polygone de chantier (25 m, sinon on accroche la rue voisine)
      const cityPoint = !ev.line && (weights[ev.source] ?? 0.8) <= 0.8 && ev.source !== "osa";
      const tol = ev.type === "hotspot" ? 40 : ev.source === "osa" ? 40 : cityPoint ? 25 : 70;
      let at, len = 0, byLine = false;
      if (ev.line && lineLength(ev.line) > 80) {
        // ligne : on l'échantillonne ; au moins la moitié des points doit coller au tracé, dans le bon sens
        const pts = [];
        for (let i = 1; i < ev.line.length; i++) {
          const a = ev.line[i - 1], b = ev.line[i], d = dist(a, b), steps = Math.max(1, Math.ceil(d / 150));
          for (let k = 0; k < steps; k++) pts.push([a[0] + (b[0] - a[0]) * k / steps, a[1] + (b[1] - a[1]) * k / steps]);
        }
        pts.push(ev.line[ev.line.length - 1]);
        const sn = pts.map(snap).filter((x) => x && x.off <= tol);
        if (sn.length < Math.max(2, pts.length * 0.5)) continue;
        const first = sn[0].along, last = sn[sn.length - 1].along;
        if (last < first - 50) continue; // sens inverse
        at = first; len = Math.max(0, last - first); byLine = true;
      } else {
        const s = snap(ev.point);
        if (!s || s.off > tol) continue;
        if (ev.bearing != null && angDiff(ev.bearing, s.brg) > 75) continue;
        at = s.along;
      }
      if (at + len < 0) continue;
      const overlap = measured.some((r) => r.from - 300 < at + Math.max(len, 100) && r.to + 300 > at);
      const delay = ev.type === "hotspot" || ev.type === "weather" ? 0 : overlap && ev.type !== "closure" ? 0 : Math.round(estimateDelay(ev, len, byLine));
      hits.push({ ev, at: Math.round(at), len: Math.round(len), delay, measured: overlap });
    }
    hits.sort((a, b) => a.at - b.at);
    const events = hits.slice(0, 200).map((h) => ({ ...toFeature(h.ev).properties, point: h.ev.point, at: h.at, length: h.len, routeDelay: h.delay, alreadyMeasured: h.measured }));
    return {
      events,
      totalDelay: events.reduce((s, e) => s + e.routeDelay, 0),
      blocking: events.filter((e) => e.blocking).map((e) => ({ id: e.id, at: e.at })),
      length: Math.round(cum[cum.length - 1]),
      at: Date.now(),
    };
  }
}

/** Pour les tests hors ligne (scripts) : rien d'autre ne doit s'en servir. */
export const _internals = { SOURCES, parseDatex, analyze, estimateDelay, makeEvent, minZoomOf, roadClass };
