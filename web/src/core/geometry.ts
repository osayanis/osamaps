import type { LngLat } from "./store";

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;
const deg = (r: number) => (r * 180) / Math.PI;

/** Distance en mètres (haversine). */
export function distance(a: LngLat, b: LngLat): number {
  const dLat = rad(b[1] - a[1]);
  const dLng = rad(b[0] - a[0]);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a[1])) * Math.cos(rad(b[1])) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

/** Cap de a vers b, en degrés (0 = nord). */
export function bearing(a: LngLat, b: LngLat): number {
  const y = Math.sin(rad(b[0] - a[0])) * Math.cos(rad(b[1]));
  const x = Math.cos(rad(a[1])) * Math.sin(rad(b[1])) - Math.sin(rad(a[1])) * Math.cos(rad(b[1])) * Math.cos(rad(b[0] - a[0]));
  return (deg(Math.atan2(y, x)) + 360) % 360;
}

/** Distances cumulées le long d'une polyligne (même longueur que coords, commence à 0). */
export function cumulativeDistances(coords: LngLat[]): number[] {
  const out = [0];
  for (let i = 1; i < coords.length; i++) out.push(out[i - 1] + distance(coords[i - 1], coords[i]));
  return out;
}

/** Point situé à `d` mètres du début de la polyligne. */
export function along(coords: LngLat[], cum: number[], d: number): LngLat {
  if (d <= 0) return coords[0];
  const total = cum[cum.length - 1];
  if (d >= total) return coords[coords.length - 1];
  let i = 1;
  while (cum[i] < d) i++;
  const t = (d - cum[i - 1]) / (cum[i] - cum[i - 1] || 1);
  const a = coords[i - 1], b = coords[i];
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
}

/**
 * Projection d'un point sur la polyligne : index du segment, point projeté, distance au tracé
 * (m) et distance parcourue depuis le début (m). Approximation plane locale (suffisante < 50 km).
 */
export function snapToLine(p: LngLat, coords: LngLat[], cum?: number[], fromIndex = 0) {
  const c = cum ?? cumulativeDistances(coords);
  const k = Math.cos(rad(p[1]));
  let best = { index: fromIndex, point: coords[fromIndex] ?? p, offset: Infinity, along: 0 };
  for (let i = Math.max(1, fromIndex); i < coords.length; i++) {
    const a = coords[i - 1], b = coords[i];
    const ax = (a[0] - p[0]) * k, ay = a[1] - p[1];
    const bx = (b[0] - p[0]) * k, by = b[1] - p[1];
    const dx = bx - ax, dy = by - ay;
    const len2 = dx * dx + dy * dy;
    const t = len2 ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len2)) : 0;
    const q: LngLat = [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
    const off = distance(p, q);
    if (off < best.offset) best = { index: i - 1, point: q, offset: off, along: c[i - 1] + distance(a, q) };
  }
  return best;
}

/** Décode une polyligne encodée (Valhalla : précision 6 ; Google/OSRM : 5). Renvoie [lng, lat]. */
export function decodePolyline(str: string, precision = 6): LngLat[] {
  const factor = 10 ** precision;
  const out: LngLat[] = [];
  let index = 0, lat = 0, lng = 0;
  while (index < str.length) {
    for (const which of [0, 1]) {
      let result = 0, shift = 0, byte: number;
      do { byte = str.charCodeAt(index++) - 63; result |= (byte & 0x1f) << shift; shift += 5; } while (byte >= 0x20);
      const delta = result & 1 ? ~(result >> 1) : result >> 1;
      if (which === 0) lat += delta; else lng += delta;
    }
    out.push([lng / factor, lat / factor]);
  }
  return out;
}

/** « 1,2 km », « 350 m ». */
export function formatDistance(m: number): string {
  if (m < 950) return `${Math.max(10, Math.round(m / 10) * 10)} m`;
  const km = m / 1000;
  return `${km < 10 ? km.toFixed(1).replace(".", ",") : Math.round(km)} km`;
}

/** « 1 h 05 », « 12 min ». */
export function formatDuration(s: number): string {
  const min = Math.max(1, Math.round(s / 60));
  if (min < 60) return `${min} min`;
  return `${Math.floor(min / 60)} h ${String(min % 60).padStart(2, "0")}`;
}

/** Heure d'arrivée « 14:32 ». */
export function formatEta(secondsFromNow: number): string {
  return new Date(Date.now() + secondsFromNow * 1000).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
}
