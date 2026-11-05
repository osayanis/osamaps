// Sécurité routière — zones de danger, ZFE, passages à niveau et écoles.
//
// CADRE LÉGAL (France) : depuis le décret n° 2012-3 du 3 janvier 2012 (art. R413-15 du Code de la
// route), signaler l'emplacement des contrôles routiers est interdit. Les aides à la conduite
// signalent à la place des « zones de danger », sans dire où se trouve l'appareil dans la zone.
// Longueurs d'usage retenues : 300 m en agglomération, 2 km hors agglomération, 4 km sur autoroute.
//
// Ce module télécharge la liste publique des radars fixes (data.gouv.fr, ministère de l'Intérieur),
// la garde CÔTÉ SERVEUR UNIQUEMENT, et calcule une fois pour toutes (la liste change ~1×/an) un
// TRONÇON DE ROUTE par appareil, d'après OpenStreetMap (Overpass) :
//   - la vraie chaussée, de longueur réglementaire (les deux chaussées d'une route à chaussées séparées) ;
//   - l'appareil est à une fraction pseudo-aléatoire mais STABLE du tronçon (HMAC d'un secret serveur :
//     un tirage qui changerait permettrait de le retrouver en recoupant), entre 15 et 85 %, jamais au
//     milieu ; aucun sommet du tronçon n'est à son emplacement ;
//   - identifiant opaque (pas le numéro du radar) ; l'icône est au MILIEU du tronçon (pas sur l'appareil).
// Résultat persistant (data/safety-segments.json), recalculé seulement si le jeu de données change.
// Tant qu'un tronçon n'est pas calculé (ou si aucune route ne convient), la zone reste un disque au
// centre décalé de l'appareil (l'ancien format), que le client sait aussi traiter.
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
  "https://overpass.openstreetmap.fr/api/interpreter",
];
// Tronçons (gros calcul ponctuel, France uniquement) : d'abord l'instance d'OpenStreetMap France.
const OVERPASS_ROADS = ["https://overpass.openstreetmap.fr/api/interpreter", ...OVERPASS.slice(0, 3)];
const SEG_BATCH = 15; // radars par requête Overpass
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

// ---------------------------------------------------------------- tronçons de route (fonctions pures)
//
// Chaque radar devient un TRONÇON de route (la vraie chaussée, d'après OpenStreetMap) de longueur
// réglementaire. L'appareil est placé à une fraction pseudo-aléatoire STABLE du tronçon (HMAC du secret
// serveur), entre 15 % et 85 % et jamais près du milieu ; le tronçon n'a aucun sommet à l'emplacement de
// l'appareil (seulement les nœuds OSM de la route et deux extrémités interpolées).
export const SEG_ALGO = 1; // à incrémenter si le calcul change : tout est recalculé
export const SEG_ZOOM = 8; // tuiles servies au client (≈ 1,4° × 1°)
const ROADS_ALL = "motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|road|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link";
const ROADS_MAIN = "motorway|trunk|primary|secondary|tertiary|unclassified|road|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link";
const ROADS_FAST = "motorway|trunk|primary|motorway_link|trunk_link|primary_link";
const SNAP_NEAR = 130; // m : toutes les routes autour de l'appareil, pour l'accrochage
const M_PER_DEG = 111320;

/** Requête Overpass groupée : pour chaque radar, les routes utiles dans le rayon de marche. */
export function roadQuery(radars) {
  const parts = radars.flatMap(({ lat, lng, kind }) => {
    const c = `${lat.toFixed(5)},${lng.toFixed(5)}`;
    const far = Math.round(0.85 * ZONE_LENGTH[kind] + 60);
    if (kind === "city") return [`way[highway~"^(${ROADS_ALL})$"](around:${Math.max(far, SNAP_NEAR)},${c});`];
    return [
      `way[highway~"^(${kind === "motorway" ? ROADS_FAST : ROADS_MAIN})$"](around:${far},${c});`,
      `way[highway~"^(${ROADS_ALL})$"](around:${SNAP_NEAR},${c});`,
    ];
  });
  return `[out:json][timeout:180];(${parts.join("")});out body geom;`;
}

/** Graphe routier : ways (géométrie [lng, lat], sens unique, ref/nom) + index nœud → (way, position). */
export function roadGraph(elements) {
  const ways = [];
  const byNode = new Map();
  for (const el of elements) {
    if (el.type !== "way" || !el.nodes || !el.geometry || el.nodes.length < 2 || el.geometry.length !== el.nodes.length) continue;
    if (el.geometry.some((g) => !g || !Number.isFinite(g.lat) || !Number.isFinite(g.lon))) continue;
    const t = el.tags || {};
    const hw = String(t.highway || "");
    const pts = el.geometry.map((g) => [g.lon, g.lat]);
    let w = 180, s = 90, e = -180, n = -90;
    for (const [x, y] of pts) { if (x < w) w = x; if (x > e) e = x; if (y < s) s = y; if (y > n) n = y; }
    const round = t.junction === "roundabout" || t.junction === "circular";
    let ow = 0;
    if (t.oneway === "yes" || t.oneway === "1" || t.oneway === "true") ow = 1;
    else if (t.oneway === "-1" || t.oneway === "reverse") ow = -1;
    else if (t.oneway !== "no" && (round || hw === "motorway" || hw === "motorway_link")) ow = 1;
    const k = ways.push({ id: el.id, nodes: el.nodes, pts, hw, ref: String(t.ref || ""), name: String(t.name || ""), ow, round, link: hw.endsWith("_link"), bbox: [w, s, e, n] }) - 1;
    el.nodes.forEach((nd, j) => {
      let l = byNode.get(nd);
      if (!l) byNode.set(nd, (l = []));
      l.push([k, j]);
    });
  }
  return { ways, byNode };
}

const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
const dist = (a, b, kx) => Math.hypot((b[0] - a[0]) * kx, (b[1] - a[1]) * M_PER_DEG);
const heading = (a, b, kx) => (Math.atan2((b[0] - a[0]) * kx, (b[1] - a[1]) * M_PER_DEG) * 180) / Math.PI;
const angDiff = (a, b) => Math.abs(((b - a + 540) % 360) - 180);
const sameRoad = (a, b) => (a.ref && a.ref === b.ref) || (!a.ref && a.name && a.name === b.name);

// Pénalité (m) selon la catégorie de route : un radar « autoroute » s'accroche d'abord à l'autoroute…
const SNAP_PENALTY = {
  motorway: (w) => (w.hw === "motorway" || w.hw === "trunk" ? 0 : w.hw === "primary" ? 25 : w.link ? 45 : 70),
  road: (w) => (w.link ? 30 : w.hw === "residential" || w.hw === "living_street" ? 35 : w.hw === "motorway" ? 25 : 0),
  city: (w) => (w.link ? 25 : w.hw === "motorway" ? 50 : 0),
};

/** Point de route le plus proche (avec la pénalité de catégorie) : { k, i, t, d }. */
export function snapToRoad(g, lat, lng, kind, maxDist, filter) {
  const kx = M_PER_DEG * Math.cos((lat * Math.PI) / 180);
  const pLat = maxDist / M_PER_DEG, pLng = maxDist / kx;
  const pen = SNAP_PENALTY[kind] || SNAP_PENALTY.road;
  let best = null;
  g.ways.forEach((w, k) => {
    const [bw, bs, be, bn] = w.bbox;
    if (lng < bw - pLng || lng > be + pLng || lat < bs - pLat || lat > bn + pLat) return;
    if (filter && !filter(w)) return;
    for (let i = 0; i < w.pts.length - 1; i++) {
      const ax = (w.pts[i][0] - lng) * kx, ay = (w.pts[i][1] - lat) * M_PER_DEG;
      const dx = (w.pts[i + 1][0] - lng) * kx - ax, dy = (w.pts[i + 1][1] - lat) * M_PER_DEG - ay;
      const l2 = dx * dx + dy * dy;
      const t = l2 > 0 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / l2)) : 0;
      const d = Math.hypot(ax + t * dx, ay + t * dy);
      if (d > maxDist) continue;
      const score = d + pen(w);
      if (!best || score < best.score) best = { k, i, t, d, score };
    }
  });
  return best;
}

/** Peut-on parcourir le way w dans le sens d (+1 : ordre des nœuds) ? travel : true = dans le sens de
 *  circulation, false = à contre-sens (on remonte la file), null = tronçon à double sens (pas de contrainte). */
const canGo = (w, d, travel) => travel == null || w.ow === 0 || (w.ow * d > 0) === travel;

/**
 * Marche le long de la route depuis `start` ({ k, i, t } : way, segment, fraction) dans le sens `dir`,
 * jusqu'à `max` mètres, en enchaînant les ways connectés (même ref / nom, sinon le plus dans l'axe ;
 * traverse les ronds-points par la sortie de la même route ou la plus en face).
 * Renvoie { pts (sans le point de départ), dist }.
 */
export function walkRoad(g, start, dir, travel, max, kx) {
  const out = [];
  let walked = 0;
  let k = start.k, w = g.ways[k];
  let prev = lerp(w.pts[start.i], w.pts[start.i + 1], start.t);
  let j = dir > 0 ? start.i + 1 : start.i;
  let road = w; // dernière route « normale » (hors rond-point) : pour reconnaître la suite
  const seen = new Set([k]);
  const push = (p) => {
    const d = dist(prev, p, kx);
    if (walked + d >= max) {
      out.push(lerp(prev, p, d > 0 ? (max - walked) / d : 0));
      walked = max;
      return true;
    }
    if (d > 0) out.push(p);
    walked += d;
    prev = p;
    return false;
  };
  for (let guard = 0; guard < 20000; guard++) {
    if (push(w.pts[j])) break;
    if (dir > 0 ? j < w.pts.length - 1 : j > 0) { j += dir; continue; }
    // fin du way : la suite
    const hin = heading(w.pts[j - dir], w.pts[j], kx);
    const next = nextWay(g, w.nodes[j], hin, road, w, seen, travel, kx);
    if (!next) break;
    if (next.round) {
      // rond-point : on en fait le tour (dans son sens) jusqu'à la sortie choisie
      const r = throughRoundabout(g, next, hin, road, seen, travel, kx);
      if (!r) break;
      let stop = false;
      for (const p of r.path) if ((stop = push(p))) break;
      if (stop) break;
      ({ k, j, dir } = r.exit);
      w = g.ways[k];
      seen.add(k);
      road = w;
      j += dir;
      continue;
    }
    k = next.k; w = g.ways[k]; dir = next.d; j = next.j + dir;
    seen.add(k);
    road = w;
  }
  return { pts: out, dist: walked };
}

/** Way suivant au nœud nd (arrivée avec le cap hin). */
function nextWay(g, nd, hin, road, cur, seen, travel, kx) {
  let best = null;
  for (const [k2, j2] of g.byNode.get(nd) || []) {
    if (seen.has(k2)) continue;
    const w2 = g.ways[k2];
    for (const d2 of [1, -1]) {
      if (d2 > 0 ? j2 >= w2.pts.length - 1 : j2 <= 0) continue;
      if (w2.round) {
        // entrée de rond-point : on le suit dans son sens de circulation (ou à rebours si on remonte la file)
        const d = travel === false ? -w2.ow || -1 : w2.ow || 1;
        if (d !== d2) continue;
        const score = 30; // moins bien qu'une route qui continue tout droit
        if (!best || score < best.score) best = { k: k2, j: j2, d: d2, round: true, score };
        continue;
      }
      if (!canGo(w2, d2, travel)) continue;
      const turn = angDiff(hin, heading(w2.pts[j2], w2.pts[j2 + d2], kx));
      const same = sameRoad(road, w2);
      if (turn > (same ? 100 : 60)) continue;
      const score = turn - (same ? 100 : 0) - (w2.hw === cur.hw ? 15 : 0) + (w2.link && !cur.link ? 40 : 0);
      if (!best || score < best.score) best = { k: k2, j: j2, d: d2, round: false, score };
    }
  }
  return best;
}

/** Tour d'un rond-point (un ou plusieurs ways) depuis l'entrée : sortie de la même route, sinon la plus
 *  en face du cap d'arrivée (écart < 60°). Renvoie { path, exit: { k, j, dir } } ou null. */
function throughRoundabout(g, entry, hin, road, seen, travel, kx) {
  const path = [];
  const exits = [];
  let k = entry.k, j = entry.j, d = entry.d;
  const visited = new Set();
  let len = 0, prev = g.ways[k].pts[j];
  for (let guard = 0; guard < 400 && len < 500; guard++) {
    const w = g.ways[k];
    j += d;
    if (j < 0 || j >= w.pts.length) break;
    const p = w.pts[j];
    len += dist(prev, p, kx);
    prev = p;
    path.push(p);
    const nd = w.nodes[j];
    if (visited.has(nd)) break; // tour complet
    visited.add(nd);
    let cont = null;
    for (const [k2, j2] of g.byNode.get(nd) || []) {
      const w2 = g.ways[k2];
      if (k2 === k) continue;
      if (w2.round) {
        if (!seen.has(k2) && (d > 0 ? j === w.pts.length - 1 : j === 0)) {
          const d2 = j2 === 0 ? 1 : j2 === w2.pts.length - 1 ? -1 : (travel === false ? -w2.ow || -1 : w2.ow || 1);
          cont = { k: k2, j: j2, d: d2 };
        }
        continue;
      }
      if (seen.has(k2)) continue;
      for (const d2 of [1, -1]) {
        if (d2 > 0 ? j2 >= w2.pts.length - 1 : j2 <= 0) continue;
        if (!canGo(w2, d2, travel)) continue;
        exits.push({ k: k2, j: j2, dir: d2, at: path.length, same: sameRoad(road, w2), off: angDiff(hin, heading(w2.pts[j2], w2.pts[j2 + d2], kx)) });
      }
    }
    if (d > 0 ? j === w.pts.length - 1 : j === 0) {
      if (w.pts[0][0] === w.pts[w.pts.length - 1][0] && w.pts[0][1] === w.pts[w.pts.length - 1][1]) {
        j = d > 0 ? 0 : w.pts.length - 1; // way fermé : on continue le tour
      } else if (cont) {
        seen.add(cont.k);
        k = cont.k; j = cont.j; d = cont.d;
      } else break;
    }
  }
  // jamais de demi-tour (la chaussée opposée de la même route repart en arrière)
  const pick = exits.find((e) => e.same && e.off < 110) || exits.filter((e) => e.off < 60).sort((a, b) => a.off - b.off)[0];
  if (!pick) return null;
  return { path: path.slice(0, pick.at), exit: { k: pick.k, j: pick.j, dir: pick.dir } };
}

/** Longueurs (m) avant / après l'appareil, compte tenu de la route disponible de chaque côté : la fraction
 *  de l'appareil reste dans [0,15 ; 0,85] et hors de [0,45 ; 0,55]. null si le tronçon serait trop court. */
export function cutLengths(f, L, availBack, availFwd) {
  let back = f * L, fwd = (1 - f) * L;
  if (fwd > availFwd) { fwd = availFwd; back = Math.min(availBack, L - fwd); }
  if (back > availBack) { back = availBack; fwd = Math.min(availFwd, L - back); }
  if (back / (back + fwd) > 0.85) back = (fwd * 0.85) / 0.15;
  if (fwd / (back + fwd) > 0.85) fwd = (back * 0.85) / 0.15;
  const r = back / (back + fwd);
  if (Math.abs(r - 0.5) < 0.05) {
    if (f < 0.5) back = (fwd * 0.44) / 0.56;
    else fwd = (back * 0.44) / 0.56;
  }
  if (!(back + fwd >= Math.min(120, 0.4 * L))) return null;
  return { back, fwd };
}

/** Douglas-Peucker en mètres (repère local), puis arrondi à 1e-5°. */
function simplifyLine(line, kx, tol = 2) {
  if (line.length <= 2) return line.map(round5);
  const keep = new Uint8Array(line.length);
  keep[0] = keep[line.length - 1] = 1;
  const stack = [[0, line.length - 1]];
  while (stack.length) {
    const [a, b] = stack.pop();
    const ax = line[a][0] * kx, ay = line[a][1] * M_PER_DEG, dx = line[b][0] * kx - ax, dy = line[b][1] * M_PER_DEG - ay;
    const l2 = dx * dx + dy * dy;
    let best = -1, bestD = tol;
    for (let i = a + 1; i < b; i++) {
      const px = line[i][0] * kx - ax, py = line[i][1] * M_PER_DEG - ay;
      const t = l2 ? Math.max(0, Math.min(1, (px * dx + py * dy) / l2)) : 0;
      const d = Math.hypot(px - t * dx, py - t * dy);
      if (d > bestD) { bestD = d; best = i; }
    }
    if (best > 0) { keep[best] = 1; stack.push([a, best], [best, b]); }
  }
  const out = [];
  for (let i = 0; i < line.length; i++) {
    if (!keep[i]) continue;
    const p = round5(line[i]);
    const q = out[out.length - 1];
    if (!q || q[0] !== p[0] || q[1] !== p[1]) out.push(p);
  }
  return out;
}
const round5 = ([x, y]) => [Math.round(x * 1e5) / 1e5, Math.round(y * 1e5) / 1e5];

function lineLength(line, kx) {
  let l = 0;
  for (let i = 1; i < line.length; i++) l += dist(line[i - 1], line[i], kx);
  return l;
}
function pointAlong(line, d, kx) {
  let acc = 0;
  for (let i = 1; i < line.length; i++) {
    const s = dist(line[i - 1], line[i], kx);
    if (acc + s >= d) return lerp(line[i - 1], line[i], s > 0 ? (d - acc) / s : 0);
    acc += s;
  }
  return line[line.length - 1];
}

/** Chaussée opposée d'une route à chaussées séparées : way à sens unique de même famille, à moins de
 *  70 m du point d'accrochage, de sens contraire. */
function oppositeCarriageway(g, snap, kx) {
  const a = g.ways[snap.k];
  const P = lerp(a.pts[snap.i], a.pts[snap.i + 1], snap.t);
  const hA = heading(a.pts[snap.i], a.pts[snap.i + 1], kx) + (a.ow < 0 ? 180 : 0);
  const family = (w) => (w.hw === "motorway" || w.hw === "trunk" ? "fast" : w.hw);
  const s = snapToRoad(g, P[1], P[0], "road", 70, (w) =>
    w !== a && w.ow !== 0 && !w.link && !w.round && family(w) === family(a) && (!a.ref || !w.ref || w.ref === a.ref));
  if (!s) return null;
  const b = g.ways[s.k];
  const hB = heading(b.pts[s.i], b.pts[s.i + 1], kx) + (b.ow < 0 ? 180 : 0);
  return angDiff(hA, hB) > 140 ? s : null;
}

function buildLine(g, snap, fdir, oneway, back, fwd, kx) {
  const f = walkRoad(g, snap, fdir, oneway ? true : null, fwd, kx);
  const b = walkRoad(g, snap, -fdir, oneway ? false : null, back, kx);
  return [...b.pts.reverse(), ...f.pts];
}

/**
 * Tronçon d'un radar : { a, b?, o, m, len } — a (et b, la chaussée opposée) en [lng, lat] dans le sens de
 * circulation si o = 1 (à double sens sinon), m = milieu de a (emplacement de l'icône), len = longueur de a.
 * f = fraction de l'appareil depuis le début du tronçon. null si aucune route ne convient.
 */
export function computeSegment(g, r, f) {
  const L = ZONE_LENGTH[r.kind];
  const kx = M_PER_DEG * Math.cos((r.lat * Math.PI) / 180);
  const snap = snapToRoad(g, r.lat, r.lng, r.kind, r.kind === "motorway" ? 100 : 75) || snapToRoad(g, r.lat, r.lng, r.kind, SNAP_NEAR);
  if (!snap) return null;
  const w = g.ways[snap.k];
  const oneway = w.ow !== 0;
  const fdir = w.ow < 0 ? -1 : 1; // sens de circulation (ordre des nœuds si double sens)
  const far = 0.85 * L;
  const availF = walkRoad(g, snap, fdir, oneway ? true : null, far, kx).dist;
  const availB = walkRoad(g, snap, -fdir, oneway ? false : null, far, kx).dist;
  const cut = cutLengths(f, L, availB, availF);
  if (!cut) return null;
  const aRaw = buildLine(g, snap, fdir, oneway, cut.back, cut.fwd, kx);
  if (aRaw.length < 2) return null;
  const a = simplifyLine(aRaw, kx);
  const len = lineLength(aRaw, kx);
  const out = { o: oneway ? 1 : 0, m: round5(pointAlong(aRaw, len / 2, kx)), len: Math.round(len), a };
  if (oneway) {
    // chaussée opposée : même étendue (l'appareil peut flasher dans l'autre sens, on ne le sait pas)
    const s = oppositeCarriageway(g, snap, kx);
    if (s) {
      const wb = g.ways[s.k];
      const bdir = wb.ow < 0 ? -1 : 1;
      const bF = walkRoad(g, s, bdir, true, cut.back, kx).dist, bB = walkRoad(g, s, -bdir, false, cut.fwd, kx).dist;
      const cb = cutLengths(1 - f, cut.back + cut.fwd, bB, bF);
      if (cb) {
        const bRaw = buildLine(g, s, bdir, true, cb.back, cb.fwd, kx);
        if (bRaw.length >= 2) out.b = simplifyLine(bRaw, kx);
      }
    }
  }
  return out;
}

/** Fraction de l'appareil dans le tronçon : uniforme sur [0,15 ; 0,44] ∪ [0,56 ; 0,85], stable. */
export function radarFraction(h) {
  const x = (h.readUInt32BE(0) / 2 ** 32) * 0.58;
  return x < 0.29 ? 0.15 + x : 0.56 + (x - 0.29);
}

/** Polyline encodée (précision 5, format Google). */
export function encodePolyline(pts) {
  let lat0 = 0, lng0 = 0, out = "";
  const enc = (v) => {
    v = v < 0 ? ~(v << 1) : v << 1;
    let s = "";
    while (v >= 0x20) { s += String.fromCharCode((0x20 | (v & 0x1f)) + 63); v >>= 5; }
    return s + String.fromCharCode(v + 63);
  };
  for (const [lng, lat] of pts) {
    const la = Math.round(lat * 1e5), ln = Math.round(lng * 1e5);
    out += enc(la - lat0) + enc(ln - lng0);
    lat0 = la; lng0 = ln;
  }
  return out;
}

export function tileOf(lng, lat, z = SEG_ZOOM) {
  const n = 2 ** z;
  const x = Math.floor(((lng + 180) / 360) * n);
  const r = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n);
  return `${z}/${x}/${y}`;
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
  // items[n° radar] = { k, a, b?, o, m, len } (tronçon) ou { fail: 1 } (aucune route : disque)
  const segCol = await store.collection("safety-segments", { resource: null, algo: 0, items: {} });
  let zones = []; // disques (ancien format, pour les anciens clients) : { id, lng, lat, r, kind }
  let tiles = new Map(); // "8/x/y" → zones compactes (tronçons ou disques) dont le milieu est dans la tuile
  let segStats = { segments: 0, fallback: 0, pending: 0, twoWay: 0, dual: 0 };
  let radarsError = null;

  const zoneId = (id) => hmac("id:" + id).toString("hex").slice(0, 12);

  /** Disque au centre décalé de l'appareil (direction et distance stables, tirées du secret serveur). */
  function disk(id, lat, lng, kind) {
    const r = ZONE_LENGTH[kind] / 2;
    const h = hmac("offset:" + id);
    const u = h.readUInt32BE(0) / 2 ** 32, v = h.readUInt32BE(4) / 2 ** 32;
    // décalage uniforme dans une couronne de rayons 0,3·r/2 à r/2 : l'appareil reste DANS la zone,
    // et le centre n'est jamais (par hasard) posé sur l'appareil
    const dist = 0.5 * r * Math.sqrt(0.09 + 0.91 * v), ang = 2 * Math.PI * u;
    const dLat = (dist * Math.cos(ang)) / 111320;
    const dLng = (dist * Math.sin(ang)) / (111320 * Math.cos((lat * Math.PI) / 180));
    return { lng: Math.round((lng + dLng) * 1e5) / 1e5, lat: Math.round((lat + dLat) * 1e5) / 1e5, r };
  }

  /** Index servi au client, reconstruit après chaque lot calculé (rapide : quelques ms). */
  function buildZones() {
    const nextTiles = new Map();
    const nextZones = [];
    const stats = { segments: 0, fallback: 0, pending: 0, twoWay: 0, dual: 0 };
    for (const [id, type, vma, lat, lng] of radarsCol.data.radars) {
      const kind = zoneKind(type, vma);
      const i = zoneId(id);
      const seg = segCol.data.items[id];
      let z;
      if (seg && !seg.fail) {
        stats.segments++;
        if (seg.b) stats.dual++;
        if (!seg.o) stats.twoWay++;
        z = { i, k: kind, m: seg.m, o: seg.o, p: seg.b ? [encodePolyline(seg.a), encodePolyline(seg.b)] : [encodePolyline(seg.a)] };
        // ancien format : disque centré sur le milieu du tronçon (n'apprend rien de plus que le tronçon)
        nextZones.push({ id: i, lng: seg.m[0], lat: seg.m[1], r: Math.max(150, seg.len / 2), kind });
      } else {
        if (seg?.fail) stats.fallback++;
        else stats.pending++;
        const d = disk(id, lat, lng, kind);
        z = { i, k: kind, m: [d.lng, d.lat], r: d.r };
        nextZones.push({ id: i, lng: d.lng, lat: d.lat, r: d.r, kind });
      }
      const key = tileOf(z.m[0], z.m[1]);
      let list = nextTiles.get(key);
      if (!list) nextTiles.set(key, (list = []));
      list.push(z);
    }
    tiles = nextTiles;
    zones = nextZones;
    segStats = stats;
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
      log(`safety : ${radars.length} radars fixes (${csv.title})`);
    } catch (e) {
      radarsError = String(e.message || e);
      log("safety : radars indisponibles —", radarsError);
    }
  }

  // ---------------------------------------------------------------- calcul des tronçons (arrière-plan)
  // Une requête Overpass à la fois, groupée par secteur (SEG_BATCH radars), pause entre deux, reprise
  // automatique (les résultats sont enregistrés au fil de l'eau). Variables d'environnement :
  //   SAFETY_SEGMENTS=off              pas de calcul (disques uniquement)
  //   SAFETY_SEGMENTS_BBOX=o,s,e,n     ne calcule que les radars de ce rectangle (tests)
  let segRunning = false;
  let segError = null;

  async function overpassRoads(q) {
    let lastErr;
    for (const url of OVERPASS_ROADS) {
      try {
        const res = await fetchWithTimeout(url, { method: "POST", body: new URLSearchParams({ data: q }), headers: { "Content-Type": "application/x-www-form-urlencoded" } }, 200000);
        if (!res.ok) throw new Error(`${new URL(url).host} ${res.status}`);
        const json = await res.json();
        if (json.remark && /error|timed out|out of memory/i.test(json.remark)) throw new Error(`${new URL(url).host} : ${json.remark.slice(0, 120)}`);
        return json;
      } catch (e) {
        lastErr = e;
      }
    }
    throw lastErr;
  }

  async function computeSegments() {
    if (segRunning || process.env.SAFETY_SEGMENTS === "off" || !radarsCol.data.radars.length) return;
    segRunning = true;
    try {
      const resource = radarsCol.data.resource?.url || null;
      if (segCol.data.resource !== resource || segCol.data.algo !== SEG_ALGO) {
        segCol.data = { resource, algo: SEG_ALGO, items: {} };
        buildZones();
      }
      const only = (process.env.SAFETY_SEGMENTS_BBOX || "").split(",").map(Number);
      const inside = only.length === 4 && only.every(Number.isFinite)
        ? (lat, lng) => lng >= only[0] && lng <= only[2] && lat >= only[1] && lat <= only[3]
        : () => true;
      // groupés par secteur de ~0,3° : les routes d'un lot se recouvrent
      const todo = radarsCol.data.radars
        .filter(([id, , , lat, lng]) => !segCol.data.items[id] && inside(lat, lng))
        .map(([id, type, vma, lat, lng]) => ({ id, lat, lng, kind: zoneKind(type, vma), cell: `${Math.floor(lat / 0.3)}:${Math.floor(lng / 0.3)}` }))
        .sort((a, b) => a.cell.localeCompare(b.cell) || a.lat - b.lat);
      if (!todo.length) return;
      log(`safety : calcul de ${todo.length} tronçons de route (OpenStreetMap)…`);
      let size = SEG_BATCH, failures = 0;
      for (let i = 0; i < todo.length; ) {
        if (segCol.data.resource !== resource) return; // le jeu de données a changé entre-temps
        const batch = todo.slice(i, i + size);
        let json;
        try {
          json = await overpassRoads(roadQuery(batch));
        } catch (e) {
          failures++;
          segError = String(e.message || e);
          size = Math.max(3, Math.floor(size / 2)); // lot plus petit : requête plus légère
          const wait = Math.min(15 * 60000, 30000 * 2 ** Math.min(failures - 1, 5));
          log(`safety : Overpass indisponible (${segError}), nouvel essai dans ${Math.round(wait / 1000)} s`);
          await new Promise((r) => setTimeout(r, wait));
          continue;
        }
        failures = 0;
        segError = null;
        const g = roadGraph(json.elements || []);
        for (const r of batch) {
          let seg = null;
          try { seg = computeSegment(g, r, radarFraction(hmac("seg:" + r.id))); } catch (e) { log("safety : tronçon", r.id, e.message); }
          segCol.data.items[r.id] = seg || { fail: 1 };
        }
        segCol.save();
        buildZones();
        i += batch.length;
        if (size < SEG_BATCH) size = Math.min(SEG_BATCH, size + 2);
        log(`safety : tronçons ${segStats.segments + segStats.fallback}/${radarsCol.data.radars.length} (${segStats.fallback} replis en disque)`);
        await new Promise((r) => setTimeout(r, 3000)); // politesse envers les serveurs publics
      }
      log(`safety : tronçons calculés — ${segStats.segments} tronçons, ${segStats.fallback} replis en disque`);
    } finally {
      segRunning = false;
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
    computeSegments().catch((e) => log("safety : calcul des tronçons interrompu —", e.message)); // sans attendre
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

  const source = () => ({ name: "Liste des radars fixes en France (ministère de l'Intérieur)", page: RADARS_PAGE, updated: radarsCol.data.resource?.updated ?? null });

  // Zones de danger par tuiles (zoom 8, ≈ 1,4° × 1°) : la carte ne demande que ce qui est visible,
  // l'analyse d'itinéraire les tuiles traversées. Une zone = { i (opaque), k (city|road|motorway),
  // m [lng, lat] (milieu du tronçon : l'icône), p [polylines encodées, précision 5] (une par chaussée),
  // o (1 : polylines dans le sens de circulation, 0 : double sens) } ou, en repli, un disque { i, k, m, r }.
  route.get("/safety/segments", ({ query }) => {
    const keys = [...new Set(String(query.tiles || "").split(",").filter(Boolean))];
    if (!keys.length || keys.length > 32) throw new HttpError(400, "tiles : 1 à 32 tuiles z/x/y");
    for (const k of keys) {
      const m = /^(\d+)\/(\d+)\/(\d+)$/.exec(k);
      if (!m || Number(m[1]) !== SEG_ZOOM || Number(m[2]) >= 2 ** SEG_ZOOM || Number(m[3]) >= 2 ** SEG_ZOOM) throw new HttpError(400, `tuiles invalides (zoom ${SEG_ZOOM} attendu)`);
    }
    return {
      available: zones.length > 0,
      error: zones.length ? null : radarsError || "chargement en cours",
      complete: zones.length > 0 && segStats.pending === 0,
      zoom: SEG_ZOOM,
      source: source(),
      lengths: ZONE_LENGTH,
      tiles: Object.fromEntries(keys.map((k) => [k, tiles.get(k) || []])),
    };
  }, { limit: 240 });

  // Ancien format (disques), pour les versions précédentes des applications.
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
    segments: { ...segStats, running: segRunning, error: segError },
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
