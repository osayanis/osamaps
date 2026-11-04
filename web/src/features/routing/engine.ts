import type { LngLat, Maneuver, Route } from "../../core/store";
import { api, EXTERNAL } from "../../core/services";
import { cumulativeDistances, decodePolyline, distance } from "../../core/geometry";

/**
 * Calcul d'itinéraire avec Valhalla. On passe d'abord par le proxy du serveur OsaMaps
 * (/maps/api/routing/…, cache + file d'attente + User-Agent) ; s'il est absent ou en panne, on
 * appelle Valhalla directement (CORS ouvert) pour que l'app reste utilisable.
 */

export interface Waypoint {
  coord: LngLat;
  name?: string;
}

export interface RouteOptions {
  avoidTolls: boolean;
  avoidHighways: boolean;
  avoidFerries: boolean;
  /** Nombre d'alternatives demandées (0 à 2). Ignoré par Valhalla avec des étapes ou une heure. */
  alternates: number;
  /** Cap actuel (degrés) au départ : évite les demi-tours absurdes pendant un recalcul. */
  heading?: number | null;
  /** Départ (type 1) ou arrivée souhaitée (type 2), heure locale « 2026-11-05T08:00 ». */
  dateTime?: { type: 1 | 2; value: string } | null;
}

/** Une proposition calculée : la Route du store + ce dont le module a besoin en plus. */
export interface Computed {
  route: Route;
  /** Index dans route.coords de chaque étape intermédiaire (même ordre que les étapes). */
  stopShapeIndex: number[];
  /** Heures locales renvoyées par Valhalla quand une heure a été demandée. */
  departAt?: string;
  arriveAt?: string;
}

/** Erreur « pas d'itinéraire » (inutile de réessayer) vs panne réseau (réessayer). */
export class RouteError extends Error {
  constructor(message: string, public readonly retryable: boolean) { super(message); }
}

// ——— requêtes ——————————————————————————————————————————————————————————

interface ValhallaManeuver {
  type: number;
  instruction: string;
  verbal_pre_transition_instruction?: string;
  street_names?: string[];
  begin_street_names?: string[];
  begin_shape_index: number;
  length: number;
  time: number;
  lanes?: { directions?: number | string[]; valid?: boolean; active?: boolean }[];
}
interface ValhallaTrip {
  legs: { shape: string; maneuvers: ValhallaManeuver[]; summary: { length: number; time: number } }[];
  summary: { length: number; time: number; has_toll?: boolean; has_highway?: boolean; has_ferry?: boolean };
  locations?: { date_time?: string }[];
  units?: string;
}
interface ValhallaResponse { trip: ValhallaTrip; alternates?: { trip: ValhallaTrip }[] }

function buildRequest(points: Waypoint[], o: RouteOptions) {
  const auto: Record<string, number> = {};
  if (o.avoidTolls) auto.use_tolls = 0;
  if (o.avoidHighways) auto.use_highways = 0;
  if (o.avoidFerries) auto.use_ferry = 0;
  const multi = points.length > 2;
  return {
    locations: points.map((p, i) => {
      const loc: Record<string, unknown> = { lat: p.coord[1], lon: p.coord[0], type: "break" };
      if (i === 0 && o.heading != null && Number.isFinite(o.heading)) { loc.heading = Math.round((o.heading + 360) % 360); loc.heading_tolerance = 45; }
      return loc;
    }),
    costing: "auto",
    costing_options: { auto },
    language: "fr-FR",
    directions_options: { units: "kilometers" },
    // Valhalla ne sait pas proposer d'alternatives avec des étapes ou une heure imposée
    alternates: multi || o.dateTime ? 0 : Math.max(0, Math.min(2, o.alternates)),
    ...(o.dateTime ? { date_time: o.dateTime } : {}),
  };
}

const memo = new Map<string, { at: number; data: ValhallaResponse }>();
const MEMO_TTL = 90_000;

async function post<T>(endpoint: "route" | "trace", proxyBody: unknown, directPath: string, directBody: unknown, signal?: AbortSignal): Promise<T> {
  // 1) le proxy OsaMaps
  try {
    return await api<T>(`routing/${endpoint}`, { method: "POST", body: JSON.stringify(proxyBody), signal });
  } catch (e) {
    if (signal?.aborted) throw e;
    const msg = e instanceof Error ? e.message : "";
    // 422 = Valhalla a répondu « aucun itinéraire » : inutile d'insister ailleurs
    if (msg.startsWith("422")) throw new RouteError(cleanMessage(msg), false);
  }
  // 2) Valhalla en direct
  let r: Response;
  try {
    r = await fetch(`${EXTERNAL.valhalla}/${directPath}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(directBody),
      signal,
    });
  } catch (e) {
    if (signal?.aborted) throw e;
    throw new RouteError("Pas de connexion au service d'itinéraire.", true);
  }
  const data = await r.json().catch(() => null);
  if (r.ok && data) return data as T;
  if (r.status === 400) throw new RouteError(cleanMessage(String(data?.error ?? "")), false);
  throw new RouteError("Le service d'itinéraire ne répond pas.", true);
}

function cleanMessage(raw: string): string {
  if (/no suitable edges|no path|no route|cannot reach|no data/i.test(raw)) return "Aucun itinéraire routier trouvé vers ce lieu.";
  if (/exceeds the max|distance/i.test(raw)) return "Ce trajet est trop long pour être calculé.";
  return "Aucun itinéraire trouvé.";
}

/** Calcule l'itinéraire (et ses alternatives) entre `points` (départ, étapes…, arrivée). */
export async function computeRoutes(points: Waypoint[], o: RouteOptions, signal?: AbortSignal): Promise<Computed[]> {
  const req = buildRequest(points, o);
  const k = JSON.stringify(req);
  const hit = memo.get(k);
  let data: ValhallaResponse;
  if (hit && Date.now() - hit.at < MEMO_TTL) data = hit.data;
  else {
    data = await post<ValhallaResponse>("route", req, "route", req, signal);
    if (!data?.trip?.legs?.length) throw new RouteError("Aucun itinéraire trouvé.", false);
    memo.set(k, { at: Date.now(), data });
    if (memo.size > 30) memo.delete(memo.keys().next().value!);
  }
  const names = points.slice(1, -1).map((p) => p.name ?? "votre étape");
  const trips = [data.trip, ...(data.alternates ?? []).map((a) => a.trip)];
  const stamp = Date.now().toString(36);
  return trips.map((t, i) => convertTrip(t, `route-${stamp}-${i}`, names));
}

// ——— conversion Valhalla → Route ————————————————————————————————————————

const LANE_BITS: [number, string][] = [
  [1, "straight"], [2, "slight_right"], [4, "right"], [8, "sharp_right"],
  [16, "uturn"], [32, "sharp_left"], [64, "left"], [128, "slight_left"],
];

function convertLanes(lanes: ValhallaManeuver["lanes"]): Maneuver["lanes"] {
  if (!lanes?.length) return undefined;
  return lanes.map((l) => {
    const dirs = Array.isArray(l.directions)
      ? l.directions
      : LANE_BITS.filter(([bit]) => ((l.directions as number) ?? 0) & bit).map(([, n]) => n);
    return { directions: dirs.length ? dirs : ["straight"], valid: Boolean(l.valid ?? l.active) };
  });
}

function convertTrip(trip: ValhallaTrip, id: string, stopNames: string[]): Computed {
  const coords: LngLat[] = [];
  const maneuvers: Maneuver[] = [];
  const stopShapeIndex: number[] = [];
  const kmFactor = trip.units === "miles" ? 1609.344 : 1000;

  trip.legs.forEach((leg, li) => {
    const shape = decodePolyline(leg.shape, 6);
    // chaque étape recommence au point où la précédente s'arrête : on fusionne sans doublon
    const offset = li === 0 ? 0 : coords.length - 1;
    coords.push(...(li === 0 ? shape : shape.slice(1)));
    const last = trip.legs.length - 1;
    leg.maneuvers.forEach((m, mi) => {
      const isLegEnd = mi === leg.maneuvers.length - 1;
      const street = (m.street_names ?? m.begin_street_names ?? [])[0];
      const man: Maneuver = {
        instruction: m.instruction,
        verbal: m.verbal_pre_transition_instruction || m.instruction,
        type: m.type,
        shapeIndex: m.begin_shape_index + offset,
        length: Math.round(m.length * kmFactor),
        time: Math.round(m.time),
        street,
        lanes: convertLanes(m.lanes),
      };
      if (isLegEnd && li < last) {
        // arrivée à une étape (pas à la destination finale) : type à part pour le guidage
        const name = stopNames[li] ?? "votre étape";
        man.type = "waypoint";
        man.instruction = `Étape atteinte : ${name}`;
        man.verbal = `Vous êtes arrivé à votre étape, ${name}.`;
        stopShapeIndex.push(man.shapeIndex);
      }
      if (!man.lanes) delete man.lanes;
      if (!man.street) delete man.street;
      maneuvers.push(man);
    });
  });

  const s = trip.summary;
  const flags: Route["flags"] = {};
  if (s.has_toll) flags.toll = true;
  if (s.has_highway) flags.highway = true;
  if (s.has_ferry) flags.ferry = true;
  const locs = trip.locations ?? [];
  return {
    route: {
      id,
      coords,
      distance: Math.round(s.length * kmFactor),
      duration: Math.round(s.time),
      maneuvers,
      summary: summarize(maneuvers),
      flags,
    },
    stopShapeIndex,
    departAt: locs[0]?.date_time,
    arriveAt: locs[locs.length - 1]?.date_time,
  };
}

/** « par N 7 et D 2209 » : les deux routes les plus empruntées (numéros de route préférés). */
function summarize(maneuvers: Maneuver[]): string | undefined {
  const byName = new Map<string, number>();
  for (const m of maneuvers) {
    if (!m.street) continue;
    byName.set(m.street, (byName.get(m.street) ?? 0) + m.length);
  }
  const ref = /^(A|N|D|E|M|RN|RD)\s?\d+/;
  const ranked = [...byName.entries()]
    .map(([n, l]) => [n, ref.test(n) ? l * 1.5 : l] as const)
    .sort((a, b) => b[1] - a[1])
    .filter(([, l]) => l > 800)
    .slice(0, 2)
    .map(([n]) => n);
  if (!ranked.length) return undefined;
  return `par ${ranked.join(" et ")}`;
}

// ——— limites de vitesse (en tâche de fond) ————————————————————————————————

/** Encode une polyligne (précision 6) — l'inverse de decodePolyline. */
export function encodePolyline(coords: LngLat[], precision = 6): string {
  const f = 10 ** precision;
  let out = "", pLat = 0, pLng = 0;
  const enc = (v: number) => {
    let s = v < 0 ? ~(v << 1) : v << 1;
    let r = "";
    while (s >= 0x20) { r += String.fromCharCode((0x20 | (s & 0x1f)) + 63); s >>= 5; }
    return r + String.fromCharCode(s + 63);
  };
  for (const [lng, lat] of coords) {
    const la = Math.round(lat * f), ln = Math.round(lng * f);
    out += enc(la - pLat) + enc(ln - pLng);
    pLat = la; pLng = ln;
  }
  return out;
}

interface TraceEdges { edges: { b: number; e: number; kmh: number | null }[] }

/**
 * Limites de vitesse le long du tracé via /trace_attributes (edge_walk). Valhalla limite la
 * longueur d'une trace : on découpe en morceaux d'environ 90 km, envoyés l'un après l'autre.
 * Renvoie des plages compactes [{ from, kmh }] triées par index.
 */
export async function fetchSpeedLimits(coords: LngLat[], signal?: AbortSignal): Promise<{ from: number; kmh: number | null }[]> {
  const cum = cumulativeDistances(coords);
  const CHUNK_M = 90_000, CHUNK_PTS = 6000, MAX_CHUNKS = 12;
  const chunks: [number, number][] = [];
  let start = 0;
  while (start < coords.length - 1 && chunks.length < MAX_CHUNKS) {
    let end = start + 1;
    while (end < coords.length - 1 && cum[end] - cum[start] < CHUNK_M && end - start < CHUNK_PTS) end++;
    chunks.push([start, end]);
    start = end;
  }
  const ranges: { from: number; kmh: number | null }[] = [];
  let failed = 0;
  for (const [a, b] of chunks) {
    if (signal?.aborted) break;
    const slice = coords.slice(a, b + 1);
    if (slice.length < 2 || cum[b] - cum[a] < 1) continue;
    const poly = encodePolyline(slice);
    const direct = {
      encoded_polyline: poly,
      shape_match: "edge_walk",
      costing: "auto",
      filters: { attributes: ["edge.speed_limit", "edge.begin_shape_index", "edge.end_shape_index"], action: "include" },
    };
    let res: TraceEdges;
    try {
      const raw = await post<TraceEdges | { edges: { speed_limit?: number; begin_shape_index: number; end_shape_index: number }[] }>(
        "trace", { encoded_polyline: poly }, "trace_attributes", direct, signal);
      // le proxy renvoie la forme compacte, Valhalla direct la forme complète
      res = {
        edges: (raw.edges ?? []).map((e) => ("b" in e
          ? e
          : { b: e.begin_shape_index, e: e.end_shape_index, kmh: e.speed_limit && e.speed_limit > 0 && e.speed_limit < 200 ? e.speed_limit : null })),
      };
    } catch (e) {
      if (signal?.aborted) break;
      // un morceau raté : vitesse inconnue sur ce morceau, on continue
      failed++;
      ranges.push({ from: a, kmh: null });
      continue;
    }
    for (const e of res.edges) {
      const from = a + e.b;
      if (ranges.length && ranges[ranges.length - 1].kmh === e.kmh) continue;
      if (ranges.length && ranges[ranges.length - 1].from === from) ranges[ranges.length - 1].kmh = e.kmh;
      else ranges.push({ from, kmh: e.kmh });
    }
  }
  // tout a échoué (hors ligne) : on n'invente pas de « limites inconnues », on laisse réessayer
  if (failed === chunks.length) throw new RouteError("Limites de vitesse indisponibles.", true);
  ranges.sort((x, y) => x.from - y.from);
  if (!ranges.length || ranges[0].from > 0) ranges.unshift({ from: 0, kmh: null });
  return ranges.filter((r, i, arr) => i === 0 || r.kmh !== arr[i - 1].kmh);
}

/** Position d'insertion d'une étape qui allonge le moins le trajet. */
export function bestInsertIndex(origin: LngLat, stops: LngLat[], destination: LngLat, p: LngLat): number {
  const seq = [origin, ...stops, destination];
  let best = 0, bestCost = Infinity;
  for (let i = 0; i < seq.length - 1; i++) {
    const cost = distance(seq[i], p) + distance(p, seq[i + 1]) - distance(seq[i], seq[i + 1]);
    if (cost < bestCost) { bestCost = cost; best = i; }
  }
  return best;
}
