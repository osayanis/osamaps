import { create } from "zustand";
import type { LngLat, Place } from "../../core/store";
import { loadLocal, saveLocal } from "../../core/identity";

/** Heure choisie : type 1 = partir à, type 2 = arriver à (heure locale « 2026-11-05T08:00 »). */
export interface DepartChoice { type: 1 | 2; value: string }

export interface RouteMeta {
  stopShapeIndex: number[];
  departAt?: string;
  arriveAt?: string;
}

interface RoutingState {
  status: "idle" | "loading" | "ready" | "error";
  error: string | null;
  retryable: boolean;
  /** Étapes intermédiaires, dans l'ordre de passage. */
  stops: Place[];
  depart: DepartChoice | null;
  /** Informations propres au module, par id d'itinéraire. */
  meta: Record<string, RouteMeta>;
  /** Hauteur du panneau d'aperçu (pour les marges de fitBounds). */
  sheetHeight: number;
  /** Recalcul en cours pendant la conduite. */
  rerouting: boolean;
  /** Sous-panneau ouvert dans l'aperçu. */
  section: null | "depart" | "stops";
  /** En attente d'un toucher sur la carte pour poser une étape. */
  pickOnMap: boolean;
  /** Proposer des alternatives (réglage du module). */
  alternates: boolean;
  set: (p: Partial<RoutingState>) => void;
}

export const useRouting = create<RoutingState>((set) => ({
  status: "idle",
  error: null,
  retryable: false,
  stops: [],
  depart: null,
  meta: {},
  sheetHeight: 0,
  rerouting: false,
  section: null,
  pickOnMap: false,
  alternates: loadLocal("routing.alternates", true),
  set: (p) => {
    if ("alternates" in p) saveLocal("routing.alternates", p.alternates);
    set(p);
  },
}));

export const routing = () => useRouting.getState();

export function placeFrom(name: string, coord: LngLat, detail?: string): Place {
  return { id: `stop-${coord[0].toFixed(5)},${coord[1].toFixed(5)}-${Date.now().toString(36)}`, name, coord, detail, kind: "stop" };
}

/** Date → « 2026-11-05T08:00 » (heure locale). */
export function localStamp(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

/** « 08:00 », « demain 08:00 », « jeu. 6 08:00 ». */
export function formatStamp(stamp: string): string {
  const d = new Date(stamp);
  if (Number.isNaN(d.getTime())) return stamp.slice(11, 16);
  const hm = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  const today = new Date();
  const days = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
    - new Date(today.getFullYear(), today.getMonth(), today.getDate()).getTime()) / 86_400_000);
  if (days === 0) return hm;
  if (days === 1) return `demain ${hm}`;
  return `${d.toLocaleDateString("fr-FR", { weekday: "short", day: "numeric" })} ${hm}`;
}
