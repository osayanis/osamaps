import { api } from "../../core/services";
import { decodePolyline, distance } from "../../core/geometry";
import type { LngLat } from "../../core/store";

export type ZoneKind = "city" | "road" | "motorway";

/** Une zone de danger telle qu'envoyée par le serveur (format compact, tuiles zoom 8). */
interface ZoneDTO {
  /** Identifiant opaque (pas le numéro du radar). */
  i: string;
  k: ZoneKind;
  /** Milieu du tronçon [lng, lat] (l'icône), ou centre du disque de repli. */
  m: LngLat;
  /** Tronçon : une polyline encodée (précision 5) par chaussée. */
  p?: string[];
  /** 1 : polylines dans le sens de circulation, 0 : double sens. */
  o?: 0 | 1;
  /** Repli (aucune route trouvée ou pas encore calculé) : disque de rayon r (m). */
  r?: number;
}

/**
 * Une zone de danger : un TRONÇON de route (une ligne par chaussée) ou, en repli, un disque.
 * L'appareil est quelque part entre 15 et 85 % du tronçon : le serveur ne dit jamais où.
 */
export interface DangerZone {
  id: string;
  kind: ZoneKind;
  mid: LngLat;
  lines: LngLat[][];
  oneway: boolean;
  /** Disque de repli (m), absent pour un tronçon. */
  r?: number;
  /** Longueur (m) du tronçon, ou diamètre du disque. */
  length: number;
}

interface SegmentsResponse {
  available: boolean;
  error: string | null;
  complete?: boolean;
  zoom: number;
  tiles: Record<string, ZoneDTO[]>;
}

export interface ZfeProps {
  id: string;
  name: string;
  /** Première vignette interdite aux voitures particulières (null = pas de règle voiture). */
  vp: string | null;
  hours: string | null;
  from: string | null;
  to: string | null;
  url: string | null;
}
export interface ZfeFeature {
  type: "Feature";
  geometry: { type: "MultiPolygon"; coordinates: LngLat[][][] };
  properties: ZfeProps;
}
export interface ZfeResponse {
  available: boolean;
  error: string | null;
  source: { name: string; page: string; updated: string | null };
  type: "FeatureCollection";
  features: ZfeFeature[];
}

export interface PoiTile { lc: LngLat[]; sc: LngLat[] }

// ------------------------------------------------------------------ appels serveur (avec cache)

export const ZONE_ZOOM = 8;

function lineLength(l: LngLat[]) {
  let d = 0;
  for (let i = 1; i < l.length; i++) d += distance(l[i - 1], l[i]);
  return d;
}

function decodeZone(d: ZoneDTO): DangerZone {
  const lines = (d.p ?? []).map((s) => decodePolyline(s, 5)).filter((l) => l.length >= 2);
  const r = lines.length ? undefined : d.r ?? 150;
  return { id: d.i, kind: d.k, mid: d.m, lines, oneway: d.o === 1, r, length: lines.length ? lineLength(lines[0]) : 2 * (r ?? 150) };
}

interface CachedTile { at: number; complete: boolean; zones: DangerZone[] }
const zoneTiles = new Map<string, CachedTile>();
const tileTasks = new Map<string, Promise<void>>();
/** Dernier état connu des données serveur. */
export const zonesStatus: { available: boolean | null; error: string | null } = { available: null, error: null };

async function fetchTiles(keys: string[]) {
  try {
    const r = await api<SegmentsResponse>(`safety/segments?tiles=${keys.join(",")}`);
    zonesStatus.available = r.available;
    zonesStatus.error = r.available ? null : r.error ?? "indisponible";
    if (!r.available) return;
    for (const k of keys) zoneTiles.set(k, { at: Date.now(), complete: r.complete ?? true, zones: (r.tiles[k] ?? []).map(decodeZone) });
  } catch (e) {
    if (zonesStatus.available == null) zonesStatus.error = String((e as Error).message || e);
  } finally {
    for (const k of keys) tileTasks.delete(k);
  }
}

/** Zones déjà connues d'une tuile (sans réseau). */
export function cachedZoneTile(key: string): DangerZone[] | undefined {
  return zoneTiles.get(key)?.zones;
}

/**
 * Zones des tuiles demandées : cache, puis serveur pour les tuiles manquantes ou périmées (une
 * journée ; 10 min tant que le serveur calcule encore les tronçons). Hors ligne : la dernière version.
 */
export async function fetchZoneTiles(keys: string[]): Promise<Map<string, DangerZone[]>> {
  const now = Date.now();
  const stale = keys.filter((k) => {
    const t = zoneTiles.get(k);
    return !t || now - t.at > (t.complete ? 86_400_000 : 600_000);
  });
  const waits = stale.filter((k) => tileTasks.has(k)).map((k) => tileTasks.get(k)!);
  const todo = stale.filter((k) => !tileTasks.has(k));
  for (let i = 0; i < todo.length; i += 32) {
    const chunk = todo.slice(i, i + 32);
    const p = fetchTiles(chunk);
    chunk.forEach((k) => tileTasks.set(k, p));
    waits.push(p);
  }
  await Promise.all(waits);
  const out = new Map<string, DangerZone[]>();
  for (const k of keys) { const z = zoneTiles.get(k); if (z) out.set(k, z.zones); }
  return out;
}

/** Tuiles (zoom 8) couvrant un rectangle, au plus `limit`. */
export function zoneTilesIn(w: number, s: number, e: number, n: number, limit = 64): string[] {
  const k = 2 ** ZONE_ZOOM;
  const tx = (lng: number) => Math.max(0, Math.min(k - 1, Math.floor(((lng + 180) / 360) * k)));
  const ty = (lat: number) => {
    const r = (Math.max(-85, Math.min(85, lat)) * Math.PI) / 180;
    return Math.max(0, Math.min(k - 1, Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * k)));
  };
  const out: string[] = [];
  for (let x = tx(w); x <= tx(e); x++) for (let y = ty(n); y <= ty(s); y++) { out.push(`${ZONE_ZOOM}/${x}/${y}`); if (out.length >= limit) return out; }
  return out;
}

let zfePromise: Promise<ZfeResponse> | null = null;
export function fetchZfe(): Promise<ZfeResponse> {
  zfePromise ??= api<ZfeResponse>("safety/zfe").then(
    (r) => { if (!r.available) zfePromise = null; return r; },
    (e) => { zfePromise = null; throw e; },
  );
  return zfePromise;
}

const poiTiles = new Map<string, PoiTile>();
let poiRetryAt = 0;
let poiBusy = false;
/** Demande au serveur les passages à niveau / écoles des tuiles manquantes (cache local + serveur). */
export async function fetchPoiTiles(keys: string[]): Promise<Map<string, PoiTile>> {
  const missing = keys.filter((k) => !poiTiles.has(k)).slice(0, 40);
  if (missing.length && !poiBusy && Date.now() >= poiRetryAt) {
    poiBusy = true;
    try {
      const r = await api<{ tiles: Record<string, PoiTile>; pending: string[]; retryAfter: number }>("safety/pois", {
        method: "POST",
        body: JSON.stringify({ tiles: missing }),
      });
      for (const [k, v] of Object.entries(r.tiles)) poiTiles.set(k, v);
      if (r.retryAfter) poiRetryAt = Date.now() + r.retryAfter * 1000;
    } catch {
      poiRetryAt = Date.now() + 60_000;
    } finally {
      poiBusy = false;
    }
  }
  return new Map(keys.filter((k) => poiTiles.has(k)).map((k) => [k, poiTiles.get(k)!]));
}

// ------------------------------------------------------------------ géométrie utilitaire

export const POI_ZOOM = 12;
export function tileKey([lng, lat]: LngLat, z = POI_ZOOM): string {
  const n = 2 ** z;
  const x = Math.floor(((lng + 180) / 360) * n);
  const r = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n);
  return `${z}/${x}/${y}`;
}

/** Polygone (64 côtés) approchant un cercle, pour l'affichage. */
export function circlePolygon(lng: number, lat: number, r: number, steps = 64): LngLat[] {
  const out: LngLat[] = [];
  const k = 111320 * Math.cos((lat * Math.PI) / 180);
  for (let i = 0; i <= steps; i++) {
    const a = (i / steps) * 2 * Math.PI;
    out.push([lng + (r * Math.sin(a)) / k, lat + (r * Math.cos(a)) / 111320]);
  }
  return out;
}

function inRing(p: LngLat, ring: LngLat[]): boolean {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i], [xj, yj] = ring[j];
    if (yi > p[1] !== yj > p[1] && p[0] < ((xj - xi) * (p[1] - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/** Point dans un MultiPolygon (anneaux intérieurs = trous). */
export function inMultiPolygon(p: LngLat, mp: LngLat[][][]): boolean {
  return mp.some((poly) => poly.length > 0 && inRing(p, poly[0]) && !poly.slice(1).some((hole) => inRing(p, hole)));
}

/** « Mo-Fr 08:00-20:00; PH off » → « lun-ven 08:00-20:00, sauf jours fériés ». */
export function hoursFr(h: string | null): string | null {
  if (!h) return null;
  const s = h.trim().replace(/\s+:\s+/g, " ");
  if (s === "24/7") return "tous les jours, 24 h/24";
  const allDay = /^Mo-Su 00:00-(00:00|24:00|23:59)(; PH off)?$/.exec(s);
  if (allDay) return allDay[2] ? "tous les jours, sauf jours fériés" : "tous les jours, 24 h/24";
  const days: Record<string, string> = { Mo: "lun", Tu: "mar", We: "mer", Th: "jeu", Fr: "ven", Sa: "sam", Su: "dim" };
  return s
    .replace(/\bPH off\b/g, "sauf jours fériés")
    .replace(/\bMay 1 off\b/g, "sauf 1er mai")
    .replace(/\b(Mo|Tu|We|Th|Fr|Sa|Su)\b/g, (d) => days[d])
    .replace(/;\s*/g, ", ")
    .replace(/\s+/g, " ")
    .trim();
}
