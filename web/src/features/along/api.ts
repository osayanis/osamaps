import { api } from "../../core/services";
import type { LngLat } from "../../core/store";
import type { FuelKey } from "./prefs";

export interface FuelPrice { p: number; maj: string | null }
export interface FuelStation {
  id: string; lng: number; lat: number;
  address: string; city: string; cp: string;
  /** Station d'autoroute. */
  highway: boolean;
  /** Automate carte bancaire 24 h/24. */
  h24: boolean;
  /** 7 jours (lundi → dimanche) : créneaux [ouverture, fermeture] ; [] = fermé ; null = inconnu. */
  hours: ([string, string][] | null)[] | null;
  /** Carburants en rupture temporaire. */
  shortage: string[];
  prices: Partial<Record<FuelKey, FuelPrice>>;
  /** Le long d'un tracé : mètres depuis le début / écart au tracé. */
  along?: number; offset?: number;
}
export interface EvStation {
  id: string; lng: number; lat: number;
  operator: string; name: string; address: string; hours: string; free: boolean;
  /** Puissance max (kW, 0 = inconnue), nombre de points de charge, prises. */
  kw: number; points: number; plugs: string[];
  along?: number; offset?: number;
}
export interface RestArea {
  id: string; lng: number; lat: number; kind: "rest_area" | "services";
  name: string | null; city?: string; fuel?: boolean; toilets?: boolean;
  along: number; offset: number;
}

export type Bbox = [number, number, number, number];

export const fetchFuelBbox = (b: Bbox) =>
  api<{ updatedAt: number; stations: FuelStation[] }>(`along/fuel?bbox=${b.map((x) => x.toFixed(4)).join(",")}`);
export const fetchEvBbox = (b: Bbox) =>
  api<{ updatedAt: number; stations: EvStation[] }>(`along/ev?bbox=${b.map((x) => x.toFixed(4)).join(",")}`);

const post = (body: unknown, signal?: AbortSignal): RequestInit => ({ method: "POST", body: JSON.stringify(body), signal });

export const fetchFuelRoute = (points: LngLat[], maxDist: number, signal?: AbortSignal) =>
  api<{ updatedAt: number; stations: FuelStation[] }>("along/fuel/route", post({ points, maxDist }, signal));
export const fetchEvRoute = (points: LngLat[], maxDist: number, signal?: AbortSignal) =>
  api<{ updatedAt: number; stations: EvStation[] }>("along/ev/route", post({ points, maxDist, minKw: 7 }, signal));
export const fetchRestAhead = (points: LngLat[], fromAlong: number, window: number) =>
  api<{ areas: RestArea[]; partial: boolean }>("along/rest/route", post({ points, fromAlong, window }));

/**
 * Réduit un tracé à `max` points au plus pour l'envoyer au serveur, en gardant les extrémités.
 * Les distances « along » renvoyées restent cohérentes avec le vrai tracé à quelques mètres près.
 */
export function thin(coords: LngLat[], max = 500): LngLat[] {
  if (coords.length <= max) return coords.map(([x, y]) => [+x.toFixed(5), +y.toFixed(5)]);
  const step = (coords.length - 1) / (max - 1);
  const out: LngLat[] = [];
  for (let i = 0; i < max; i++) {
    const [x, y] = coords[Math.round(i * step)];
    out.push([+x.toFixed(5), +y.toFixed(5)]);
  }
  return out;
}
