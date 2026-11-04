import { create } from "zustand";
import type { EvStation, FuelStation } from "./api";
import type { Energy } from "./prefs";
import type { RouteWeather } from "./weather";

export interface RouteStations {
  routeId: string;
  energy: Energy;
  status: "loading" | "ready" | "error";
  fuel: FuelStation[];
  ev: EvStation[];
}

interface AlongState {
  /** Stations visibles autour de la carte (mode exploration). */
  nearbyFuel: FuelStation[];
  nearbyEv: EvStation[];
  /** Stations le long de l'itinéraire actif. */
  route: RouteStations | null;
  weather: RouteWeather | null;
  weatherStatus: "idle" | "loading" | "ready" | "error";
  set: (p: Partial<AlongState>) => void;
}

export const useAlong = create<AlongState>((set) => ({
  nearbyFuel: [],
  nearbyEv: [],
  route: null,
  weather: null,
  weatherStatus: "idle",
  set: (p) => set(p),
}));
export const along$ = () => useAlong.getState();

/** Données du panneau « station » (core.panelData). */
export type StationPanelData = { kind: "fuel"; station: FuelStation } | { kind: "ev"; station: EvStation };
