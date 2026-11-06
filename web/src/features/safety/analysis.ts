import type { LngLat, Route } from "../../core/store";
import type { DangerZone, ZfeFeature, ZfeProps } from "./data";
import { inMultiPolygon } from "./data";

/**
 * Analyse d'un itinéraire : tout est exprimé en « distance le long du tracé » (mètres depuis le
 * départ), ce qui rend les alertes en conduite triviales (on compare à la distance parcourue).
 */

export interface DangerInterval { id: string; start: number; end: number; kind: DangerZone["kind"] }
export interface Curve { id: string; start: number; end: number; radius: number; angle: number; /** Virages enchaînés (lacets). */ count: number }
export interface RoutePoi { id: string; along: number; kind: "level-crossing" | "school" }
export interface ZfeCrossing { entry: number; exit: number; props: ZfeProps }

const M_PER_DEG = 111320;

// ------------------------------------------------------------------ index spatial des segments

const CELL = 0.02; // ≈ 2 km

export interface SegIndex {
  coords: LngLat[];
  cum: number[];
  cells: Map<string, number[]>;
}

export function buildSegIndex(coords: LngLat[], cum: number[]): SegIndex {
  const cells = new Map<string, number[]>();
  for (let i = 1; i < coords.length; i++) {
    const [ax, ay] = coords[i - 1], [bx, by] = coords[i];
    for (let x = Math.floor(Math.min(ax, bx) / CELL); x <= Math.floor(Math.max(ax, bx) / CELL); x++) {
      for (let y = Math.floor(Math.min(ay, by) / CELL); y <= Math.floor(Math.max(ay, by) / CELL); y++) {
        const k = `${x}:${y}`;
        let arr = cells.get(k);
        if (!arr) cells.set(k, (arr = []));
        arr.push(i);
      }
    }
  }
  return { coords, cum, cells };
}

/** Segments (index de fin i : segment i-1 → i) dont la boîte touche le disque (centre, rayon m). */
function segmentsNear(ix: SegIndex, c: LngLat, r: number): number[] {
  const dLat = r / M_PER_DEG, dLng = r / (M_PER_DEG * Math.cos((c[1] * Math.PI) / 180));
  const out = new Set<number>();
  for (let x = Math.floor((c[0] - dLng) / CELL); x <= Math.floor((c[0] + dLng) / CELL); x++) {
    for (let y = Math.floor((c[1] - dLat) / CELL); y <= Math.floor((c[1] + dLat) / CELL); y++) {
      ix.cells.get(`${x}:${y}`)?.forEach((i) => out.add(i));
    }
  }
  return [...out].sort((a, b) => a - b);
}

/** Géométrie plane locale autour de c (mètres). */
function local(c: LngLat) {
  const kx = M_PER_DEG * Math.cos((c[1] * Math.PI) / 180);
  return (p: LngLat): [number, number] => [(p[0] - c[0]) * kx, (p[1] - c[1]) * M_PER_DEG];
}

/** Distance (m) du point c au segment ab, et paramètre t de la projection. */
function segDist(c: LngLat, a: LngLat, b: LngLat) {
  const L = local(c);
  const [ax, ay] = L(a), [bx, by] = L(b);
  const dx = bx - ax, dy = by - ay, len2 = dx * dx + dy * dy;
  const t = len2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2)) : 0;
  return { d: Math.hypot(ax + t * dx, ay + t * dy), t };
}

/** Projette un point sur le tracé : distance au tracé et distance le long. */
export function projectOnRoute(ix: SegIndex, p: LngLat, maxDist: number): { offset: number; along: number } | null {
  let best: { offset: number; along: number } | null = null;
  for (const i of segmentsNear(ix, p, maxDist)) {
    const { d, t } = segDist(p, ix.coords[i - 1], ix.coords[i]);
    if (d <= maxDist && (!best || d < best.offset)) best = { offset: d, along: ix.cum[i - 1] + t * (ix.cum[i] - ix.cum[i - 1]) };
  }
  return best;
}

// ------------------------------------------------------------------ zones de danger

function headingOf(a: LngLat, b: LngLat) {
  const [x, y] = local(a)(b);
  return (Math.atan2(x, y) * 180) / Math.PI;
}

/** Projection avec le segment touché (pour comparer les caps). */
function projectSeg(ix: SegIndex, p: LngLat, maxDist: number): { along: number; seg: number } | null {
  let best: { d: number; along: number; seg: number } | null = null;
  for (const i of segmentsNear(ix, p, maxDist)) {
    const { d, t } = segDist(p, ix.coords[i - 1], ix.coords[i]);
    if (d <= maxDist && (!best || d < best.d)) best = { d, along: ix.cum[i - 1] + t * (ix.cum[i] - ix.cum[i - 1]), seg: i };
  }
  return best;
}

/**
 * Portions de l'itinéraire qui suivent une ligne de tronçon : on parcourt la ligne tous les 15 m,
 * chaque point doit être à moins de 22 m du tracé ET dans le même sens (écart de cap < 50° ; les
 * deux sens pour une route à double sens). Une route qui ne fait que croiser le tronçon ne compte pas.
 */
export function lineOverlap(ix: SegIndex, line: LngLat[], oneway: boolean): { start: number; end: number }[] {
  if (line.length < 2) return [];
  let lineLen = 0;
  for (let i = 1; i < line.length; i++) lineLen += Math.hypot(...local(line[i - 1])(line[i]));
  const out: { start: number; end: number }[] = [];
  let run: { lo: number; hi: number } | null = null;
  let misses = 0;
  const close = () => {
    if (run && run.hi - run.lo >= Math.min(60, 0.5 * lineLen)) out.push({ start: run.lo, end: run.hi });
    run = null;
  };
  for (let i = 1; i < line.length; i++) {
    const a = line[i - 1], b = line[i];
    const len = Math.hypot(...local(a)(b));
    const h = headingOf(a, b);
    const n = Math.max(1, Math.ceil(len / 15));
    for (let k = 0; k <= (i === line.length - 1 ? n : n - 1); k++) {
      const t = k / n;
      const p: LngLat = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
      const hit = projectSeg(ix, p, 22);
      if (hit) {
        const diff = Math.abs(angleDiff(headingOf(ix.coords[hit.seg - 1], ix.coords[hit.seg]), h));
        if (diff < 50 || (!oneway && diff > 130)) {
          run = run ? { lo: Math.min(run.lo, hit.along), hi: Math.max(run.hi, hit.along) } : { lo: hit.along, hi: hit.along };
          misses = 0;
          continue;
        }
      }
      if (++misses > 3) close(); // un trou de plus de ~45 m coupe la portion
    }
  }
  close();
  return out;
}

/**
 * Zones de danger sur l'itinéraire, en distance le long du tracé :
 *  - tronçon : la portion de l'itinéraire qui le parcourt (dans le sens de circulation si connu) ;
 *  - disque de repli : la corde du disque sur le tracé si le tracé passe à moins de r/2 du centre
 *    (le serveur garantit que l'appareil y est), allongée jusqu'à la longueur réglementaire (2r).
 */
export function dangerIntervals(ix: SegIndex, zones: DangerZone[]): DangerInterval[] {
  const total = ix.cum[ix.cum.length - 1] ?? 0;
  const raw: DangerInterval[] = [];
  for (const z of zones) {
    if (z.r != null) { raw.push(...diskIntervals(ix, z, z.r, total)); continue; }
    for (const line of z.lines) {
      for (const p of lineOverlap(ix, line, z.oneway)) raw.push({ id: z.id, start: Math.max(0, p.start), end: Math.min(total, p.end), kind: z.kind });
    }
  }
  // fusion des zones qui se chevauchent (deux appareils proches, deux chaussées = une seule zone)
  raw.sort((a, b) => a.start - b.start);
  const out: DangerInterval[] = [];
  for (const z of raw) {
    const last = out[out.length - 1];
    if (last && z.start <= last.end + 30) last.end = Math.max(last.end, z.end);
    else out.push({ ...z });
  }
  return out;
}

function diskIntervals(ix: SegIndex, z: DangerZone, r: number, total: number): DangerInterval[] {
  const c = z.mid;
  const L = local(c);
  const parts: { start: number; end: number; minD: number }[] = [];
  for (const i of segmentsNear(ix, c, r)) {
    const a = ix.coords[i - 1], b = ix.coords[i];
    const [ax, ay] = L(a), [bx, by] = L(b);
    const dx = bx - ax, dy = by - ay;
    const qa = dx * dx + dy * dy;
    if (!qa) continue;
    const qb = 2 * (dx * ax + dy * ay);
    const qc = ax * ax + ay * ay - r * r;
    const disc = qb * qb - 4 * qa * qc;
    if (disc < 0) continue;
    const s = Math.sqrt(disc);
    const t0 = Math.max(0, (-qb - s) / (2 * qa)), t1 = Math.min(1, (-qb + s) / (2 * qa));
    if (t0 >= t1) continue;
    const len = ix.cum[i] - ix.cum[i - 1];
    const minD = segDist(c, a, b).d;
    const start = ix.cum[i - 1] + t0 * len, end = ix.cum[i - 1] + t1 * len;
    const last = parts[parts.length - 1];
    if (last && start - last.end < 50) { last.end = Math.max(last.end, end); last.minD = Math.min(last.minD, minD); }
    else parts.push({ start, end, minD });
  }
  const out: DangerInterval[] = [];
  for (const p of parts) {
    if (p.minD > r / 2) continue;
    let { start, end } = p;
    const need = 2 * r - (end - start);
    if (need > 0) { start -= need / 2; end += need / 2; }
    out.push({ id: z.id, start: Math.max(0, start), end: Math.min(total, end), kind: z.kind });
  }
  return out;
}

// ------------------------------------------------------------------ virages serrés

const TURN_TYPES = new Set([9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 26, 27]);

function angleDiff(a: number, b: number) {
  return ((b - a + 540) % 360) - 180;
}

/**
 * Virages serrés depuis la géométrie : rééchantillonnage tous les 10 m, rayon de courbure estimé
 * sur une fenêtre de 50 m. Les changements de direction aux intersections (manœuvres) et dans les
 * ronds-points sont ignorés : ce ne sont pas des virages de la route.
 */
export function findCurves(route: Route, cum: number[]): Curve[] {
  const coords = route.coords;
  const total = cum[cum.length - 1] ?? 0;
  if (coords.length < 3 || total < 200) return [];
  const STEP = 10, W = 5;
  const pts: LngLat[] = [];
  let j = 1;
  for (let d = 0; d <= total; d += STEP) {
    while (j < cum.length - 1 && cum[j] < d) j++;
    const t = (d - cum[j - 1]) / (cum[j] - cum[j - 1] || 1);
    const a = coords[j - 1], b = coords[j];
    pts.push([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]);
  }
  const head: number[] = [];
  for (let i = 0; i < pts.length - 1; i++) {
    const L = local(pts[i]);
    const [x, y] = L(pts[i + 1]);
    head.push((Math.atan2(x, y) * 180) / Math.PI);
  }
  // zones exclues : autour des manœuvres de type « tourner », et dans les ronds-points
  const excluded: [number, number][] = [];
  let roundaboutStart: number | null = null;
  for (const m of route.maneuvers) {
    const at = cum[Math.min(m.shapeIndex, cum.length - 1)] ?? 0;
    const type = Number(m.type);
    if (type === 26) roundaboutStart = at;
    if (type === 27 && roundaboutStart != null) { excluded.push([roundaboutStart - 60, at + 60]); roundaboutStart = null; }
    if (TURN_TYPES.has(type)) excluded.push([at - 60, at + 60]);
  }
  const isExcluded = (a: number, b: number) => excluded.some(([s, e]) => a <= e && b >= s);

  const curves: Curve[] = [];
  let i = 0;
  while (i < head.length - W) {
    const turn = angleDiff(head[i], head[i + W]);
    const radius = (W * STEP) / ((Math.abs(turn) * Math.PI) / 180 || 1e-9);
    if (radius >= 120) { i++; continue; }
    const sign = Math.sign(turn);
    let k = i, minR = radius;
    while (k + 1 < head.length - W) {
      const t2 = angleDiff(head[k + 1], head[k + 1 + W]);
      const r2 = (W * STEP) / ((Math.abs(t2) * Math.PI) / 180 || 1e-9);
      if (r2 >= 120 || Math.sign(t2) !== sign) break;
      minR = Math.min(minR, r2);
      k++;
    }
    let angle = 0;
    for (let q = i; q < k + W && q + 1 < head.length; q++) angle += angleDiff(head[q], head[q + 1]);
    const start = i * STEP, end = (k + W) * STEP;
    if (Math.abs(angle) >= 40 && !isExcluded(start, end)) {
      const prev = curves[curves.length - 1];
      if (prev && start - prev.end < 200) {
        // virages enchaînés : une seule alerte « Virages serrés »
        prev.end = end;
        prev.radius = Math.min(prev.radius, Math.round(minR));
        prev.count++;
      } else {
        curves.push({ id: `${route.id}-c${Math.round(start)}`, start, end, radius: Math.round(minR), angle: Math.round(angle), count: 1 });
      }
    }
    i = k + W;
  }
  return curves;
}

// ------------------------------------------------------------------ passages à niveau, écoles

export function poisAlong(ix: SegIndex, lc: LngLat[], sc: LngLat[]): RoutePoi[] {
  const out: RoutePoi[] = [];
  for (const p of lc) {
    const hit = projectOnRoute(ix, p, 20); // le nœud est sur la route
    if (hit) out.push({ id: `lc-${p[0].toFixed(5)},${p[1].toFixed(5)}`, along: hit.along, kind: "level-crossing" });
  }
  for (const p of sc) {
    const hit = projectOnRoute(ix, p, 120); // centre du bâtiment / terrain : un peu en retrait
    if (hit) out.push({ id: `sc-${p[0].toFixed(5)},${p[1].toFixed(5)}`, along: hit.along, kind: "school" });
  }
  out.sort((a, b) => a.along - b.along);
  // une seule alerte pour plusieurs écoles proches (ou un passage à niveau à double voie)
  return out.filter((p, i) => !out.slice(0, i).some((q) => q.kind === p.kind && p.along - q.along < (p.kind === "school" ? 400 : 60)));
}

// ------------------------------------------------------------------ ZFE

export function zfeCrossings(coords: LngLat[], cum: number[], features: ZfeFeature[]): ZfeCrossing[] {
  if (!coords.length) return [];
  const out: ZfeCrossing[] = [];
  for (const f of features) {
    let w = Infinity, s = Infinity, e = -Infinity, n = -Infinity;
    for (const poly of f.geometry.coordinates) for (const [x, y] of poly[0] ?? []) { w = Math.min(w, x); e = Math.max(e, x); s = Math.min(s, y); n = Math.max(n, y); }
    let entry = -1, exit = -1;
    for (let i = 0; i < coords.length; i++) {
      // sous-échantillonne les longs segments (autoroutes) tous les ~100 m
      const steps = i === 0 ? 1 : Math.max(1, Math.ceil((cum[i] - cum[i - 1]) / 100));
      for (let k = 1; k <= steps; k++) {
        const t = k / steps;
        const p: LngLat = i === 0 ? coords[0] : [coords[i - 1][0] + (coords[i][0] - coords[i - 1][0]) * t, coords[i - 1][1] + (coords[i][1] - coords[i - 1][1]) * t];
        if (p[0] < w || p[0] > e || p[1] < s || p[1] > n) continue;
        if (inMultiPolygon(p, f.geometry.coordinates)) {
          const along = i === 0 ? 0 : cum[i - 1] + (cum[i] - cum[i - 1]) * t;
          if (entry < 0) entry = along;
          exit = along;
        }
      }
    }
    if (entry >= 0) out.push({ entry, exit, props: f.properties });
  }
  return out.sort((a, b) => a.entry - b.entry);
}

// ------------------------------------------------------------------ suivi en conduite

/** Accrochage au tracé dans une fenêtre autour du dernier index connu (rapide à chaque tick). */
export function snapWindow(p: LngLat, coords: LngLat[], cum: number[], hint: number) {
  const scan = (from: number, to: number) => {
    let best = { index: hint, along: cum[hint] ?? 0, offset: Infinity };
    for (let i = Math.max(1, from); i < Math.min(coords.length, to); i++) {
      const { d, t } = segDist(p, coords[i - 1], coords[i]);
      if (d < best.offset) best = { index: i - 1, along: cum[i - 1] + t * (cum[i] - cum[i - 1]), offset: d };
    }
    return best;
  };
  let best = scan(hint - 5, hint + 400);
  if (best.offset > 80) best = scan(1, coords.length);
  return best;
}
