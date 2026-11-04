import type { FuelStation } from "./api";
import type { FuelKey } from "./prefs";
import { usablePrice } from "./format";

export interface FuelPick { station: FuelStation; price: number; /** mètres devant (depuis fromAlong) */ ahead: number }

/**
 * Stations du trajet triées par prix puis par détour (écart au tracé), uniquement celles devant
 * (au moins 300 m après `fromAlong`) avec un prix frais pour mon carburant.
 */
export function rankOnRoute(stations: FuelStation[], fuel: FuelKey, fromAlong = 0): FuelPick[] {
  const now = Date.now();
  const out: FuelPick[] = [];
  for (const s of stations) {
    if (s.along == null || s.along < fromAlong + 300) continue;
    const price = usablePrice(s, fuel, now);
    if (price != null) out.push({ station: s, price, ahead: s.along - fromAlong });
  }
  return out.sort((a, b) => a.price - b.price || (a.station.offset ?? 0) - (b.station.offset ?? 0));
}

/** Prix médian (frais) de mon carburant parmi des stations, ou null. */
export function medianPrice(stations: FuelStation[], fuel: FuelKey): number | null {
  const now = Date.now();
  const v = stations.map((s) => usablePrice(s, fuel, now)).filter((p): p is number => p != null).sort((a, b) => a - b);
  if (!v.length) return null;
  const m = v.length >> 1;
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2;
}

/** Ids des stations les moins chères (prix frais, égalités comprises), pour les mettre en vert. */
export function cheapestIds(stations: FuelStation[], fuel: FuelKey): Set<string> {
  const now = Date.now();
  let min = Infinity;
  const prices = new Map<string, number>();
  for (const s of stations) {
    const p = usablePrice(s, fuel, now);
    if (p == null) continue;
    prices.set(s.id, p);
    if (p < min) min = p;
  }
  return new Set([...prices].filter(([, p]) => p <= min + 1e-9).map(([id]) => id));
}
