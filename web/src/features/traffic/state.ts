import { create } from "zustand";
import { loadLocal, saveLocal } from "../../core/identity";
import type { LngLat } from "../../core/store";

export type Level = "ok" | "slow" | "jam";

/** Une portion ralentie de l'itinéraire actif, en mètres depuis le début du tracé de la route. */
export interface RouteRun {
  from: number;
  to: number;
  level: Level;
  /** Retard estimé (s). */
  delay: number;
  speed: number;
  sources: string[];
  /** Position géographique du début (sert d'identifiant stable pour les alertes). */
  start: LngLat;
}

interface TrafficState {
  /** Calque de trafic affiché (préférence locale du module). */
  visible: boolean;
  setVisible: (v: boolean) => void;
  /** Ralentissements sur l'itinéraire actif (null = rien de connu / pas d'itinéraire). */
  route: { routeId: string; runs: RouteRun[]; at: number } | null;
  /** Retard restant devant (s) et prochain ralentissement, recalculés en roulant. */
  ahead: { delay: number; next: (RouteRun & { distance: number }) | null } | null;
  /** Segments envoyés pendant le trajet en cours (affiché dans les réglages, par transparence). */
  sent: number;
  tripActive: boolean;
  set: (p: Partial<TrafficState>) => void;
}

export const useTraffic = create<TrafficState>((set) => ({
  visible: loadLocal("traffic.visible", true),
  setVisible: (v) => { saveLocal("traffic.visible", v); set({ visible: v }); },
  route: null,
  ahead: null,
  sent: 0,
  tripActive: false,
  set: (p) => set(p),
}));

export const traffic = () => useTraffic.getState();
