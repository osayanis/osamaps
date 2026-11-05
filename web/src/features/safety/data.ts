import { api } from "../../core/services";
import type { LngLat } from "../../core/store";

/** Un disque de zone de danger tel qu'envoyé par le serveur (jamais la position de l'appareil). */
export interface DangerZone {
  id: string;
  lng: number;
  lat: number;
  /** Rayon (m) = longueur réglementaire de la zone / 2. */
  r: number;
  kind: "city" | "road" | "motorway";
}

export interface ZonesResponse {
  available: boolean;
  error: string | null;
  source: { name: string; page: string; updated: string | null };
  zones: DangerZone[];
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

/** Toutes les zones de France (≈ 3 300, la liste change ~1×/an) : une seule requête par session. */
let allZones: Promise<ZonesResponse> | null = null;
export function fetchAllZones(): Promise<ZonesResponse> {
  if (!allZones) {
    allZones = api<ZonesResponse>("safety/zones/all").then(
      (r) => { if (!r.available) allZones = null; return r; },
      (e) => { allZones = null; throw e; },
    );
  }
  return allZones;
}

const zoneCache = new Map<string, Promise<ZonesResponse>>();
export function fetchZones(bbox: [number, number, number, number]): Promise<ZonesResponse> {
  const key = bbox.map((v) => v.toFixed(2)).join(",");
  let p = zoneCache.get(key);
  if (!p) {
    p = api<ZonesResponse>(`safety/zones?bbox=${key}`).then(
      (r) => { if (!r.available) zoneCache.delete(key); return r; },
      (e) => { zoneCache.delete(key); throw e; },
    );
    zoneCache.set(key, p);
    if (zoneCache.size > 40) zoneCache.delete(zoneCache.keys().next().value!);
  }
  return p;
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
