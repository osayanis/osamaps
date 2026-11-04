import type { LngLat } from "../../core/store";
import { EXTERNAL } from "../../core/services";

/**
 * Recherche minimale d'étape (Base Adresse Nationale / IGN), propre à ce module : le module
 * search possède la vraie recherche, ici on veut juste pouvoir taper « Varennes » pour un arrêt.
 * Mise en cache ; l'appelant attend que l'on arrête de taper avant d'appeler.
 */
export interface Hit { name: string; detail?: string; coord: LngLat }

const cache = new Map<string, Hit[]>();

interface BanFeature {
  geometry: { coordinates: [number, number] };
  properties: { label?: string; name?: string; city?: string; postcode?: string; context?: string; type?: string };
}

function toHit(f: BanFeature): Hit {
  const p = f.properties;
  const name = p.name || p.label || "Lieu";
  const detail = [p.postcode, p.city].filter(Boolean).join(" ") || p.context;
  return { name: p.type === "municipality" ? p.city || name : name, detail: p.type === "municipality" ? p.context : detail, coord: f.geometry.coordinates };
}

export async function searchPlaces(q: string, near?: LngLat, signal?: AbortSignal): Promise<Hit[]> {
  const query = q.trim();
  if (query.length < 3) return [];
  const k = `${query.toLowerCase()}|${near ? near.map((n) => n.toFixed(1)).join(",") : ""}`;
  const hit = cache.get(k);
  if (hit) return hit;
  const u = new URL(`${EXTERNAL.geocodeFr}/search`);
  u.searchParams.set("q", query.slice(0, 120));
  u.searchParams.set("limit", "5");
  if (near) { u.searchParams.set("lon", near[0].toFixed(4)); u.searchParams.set("lat", near[1].toFixed(4)); }
  const r = await fetch(u, { signal });
  if (!r.ok) throw new Error(String(r.status));
  const data = (await r.json()) as { features?: BanFeature[] };
  const out = (data.features ?? []).map(toHit);
  cache.set(k, out);
  if (cache.size > 60) cache.delete(cache.keys().next().value!);
  return out;
}

export async function reverseGeocode(coord: LngLat): Promise<Hit | null> {
  const u = new URL(`${EXTERNAL.geocodeFr}/reverse`);
  u.searchParams.set("lon", coord[0].toFixed(5));
  u.searchParams.set("lat", coord[1].toFixed(5));
  u.searchParams.set("limit", "1");
  const r = await fetch(u, { signal: AbortSignal.timeout(6000) });
  if (!r.ok) return null;
  const data = (await r.json()) as { features?: BanFeature[] };
  const f = data.features?.[0];
  return f ? toHit(f) : null;
}
