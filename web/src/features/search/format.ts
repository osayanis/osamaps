import { bearing, distance, formatDistance } from "../../core/geometry";
import type { LngLat } from "../../core/store";

const KIND_ICON: Record<string, string> = {
  address: "address", street: "street", city: "city", poi: "poi", fuel: "fuel", charge: "charge",
  parking: "parking", truckstop: "truckstop", food: "food", cafe: "cafe", bakery: "bakery", pharmacy: "pharmacy", shop: "shop",
  toilets: "toilets", health: "health", train: "train", bus: "bus", park: "park", home: "home",
  work: "work", car: "car", favorite: "star", recent: "clock", coords: "locate", map: "pin",
};

export const kindIcon = (k?: string) => KIND_ICON[k ?? ""] ?? "poi";

export function distanceLabel(from: LngLat | null | undefined, to: LngLat): string | null {
  if (!from) return null;
  return formatDistance(distance(from, to));
}

const DIRS = ["au nord", "au nord-est", "à l'est", "au sud-est", "au sud", "au sud-ouest", "à l'ouest", "au nord-ouest"];

/** « à 2,3 km au nord-est » + cap en degrés. */
export function directionTo(from: LngLat, to: LngLat): { text: string; deg: number } {
  const deg = bearing(from, to);
  const d = distance(from, to);
  if (d < 30) return { text: "Vous y êtes", deg };
  return { text: `${formatDistance(d)} ${DIRS[Math.round(deg / 45) % 8]}`, deg };
}

/** « il y a 5 min », « il y a 2 h », « hier », « le 3 nov. ». */
export function ago(t: number): string {
  const s = (Date.now() - t) / 1000;
  if (s < 60) return "à l'instant";
  if (s < 3600) return `il y a ${Math.round(s / 60)} min`;
  if (s < 86400) return `il y a ${Math.round(s / 3600)} h`;
  if (s < 172800) return "hier";
  return `le ${new Date(t).toLocaleDateString("fr-FR", { day: "numeric", month: "short" })}`;
}

export const fmtCoord = (c: LngLat) => `${c[1].toFixed(5)}, ${c[0].toFixed(5)}`;
