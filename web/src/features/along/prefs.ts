import { create } from "zustand";
import { loadLocal, saveLocal } from "../../core/identity";

/** Carburants du flux officiel (mêmes clés que le serveur). */
export const FUELS = ["gazole", "sp95", "e10", "sp98", "gplc", "e85"] as const;
export type FuelKey = (typeof FUELS)[number];
export type Energy = FuelKey | "ev";

export const ENERGY_LABEL: Record<Energy, string> = {
  gazole: "Gazole", sp95: "SP95", e10: "SP95-E10", sp98: "SP98", gplc: "GPL", e85: "E85", ev: "Électrique",
};

export interface AlongPrefs {
  /** Mon carburant, ou véhicule électrique. */
  energy: Energy;
  /** Consommation thermique, L/100 km. */
  consumption: number;
  /** Consommation électrique, kWh/100 km. */
  evConsumption: number;
  /** Afficher les stations sur la carte. */
  showStations: boolean;
  /** Rappel de pause après ~2 h de conduite. */
  pauseReminder: boolean;
  /** Alertes météo sur le trajet. */
  weatherAlerts: boolean;
}

const DEFAULTS: AlongPrefs = {
  energy: "gazole", consumption: 6.5, evConsumption: 17, showStations: true, pauseReminder: true, weatherAlerts: true,
};

interface State extends AlongPrefs { setAlong: <K extends keyof AlongPrefs>(k: K, v: AlongPrefs[K]) => void }

/** Réglages propres au module, stockés sous « osamaps.along.prefs ». */
export const useAlongPrefs = create<State>((set, get) => ({
  ...DEFAULTS,
  ...loadLocal<Partial<AlongPrefs>>("along.prefs", {}),
  setAlong: (k, v) => {
    set({ [k]: v } as Partial<State>);
    const { setAlong: _omit, ...rest } = get();
    void _omit;
    saveLocal("along.prefs", rest);
  },
}));
export const alongPrefs = () => useAlongPrefs.getState();
