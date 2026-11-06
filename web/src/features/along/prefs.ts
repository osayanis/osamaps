import { create } from "zustand";
import { loadLocal, saveLocal } from "../../core/identity";
import { usePrefs, type VehicleKind } from "../../core/prefs";

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

/** Consommation réaliste par défaut en mode camion (L/100 km, gazole). */
export const TRUCK_CONSUMPTION: Record<VehicleKind, number> = { car: 6.5, truck: 25, heavy: 32, superheavy: 45 };

/** Réglages mémorisés : la voiture et les camions ont chacun leur carburant et leur consommation. */
interface Stored extends AlongPrefs {
  truckEnergy: Energy;
  /** Par catégorie de camion. */
  truckConsumption: Partial<Record<VehicleKind, number>>;
}

interface State extends Stored {
  setAlong: <K extends keyof AlongPrefs>(k: K, v: AlongPrefs[K]) => void;
  /** Bornes de la consommation thermique pour le véhicule actuel. */
  range: () => [number, number];
}

const kind = () => usePrefs.getState().vehicle.kind;
const isTruck = () => kind() !== "car";
const saved = loadLocal<Partial<Stored>>("along.prefs", {});
// `energy` / `consumption` (lus partout) reflètent le véhicule actuel ; la voiture garde les siens à part.
const car = { energy: saved.energy ?? DEFAULTS.energy, consumption: saved.consumption ?? DEFAULTS.consumption };

function effective(s: Pick<Stored, "truckEnergy" | "truckConsumption">): Pick<AlongPrefs, "energy" | "consumption"> {
  if (!isTruck()) return car;
  const k = kind();
  return { energy: s.truckEnergy, consumption: s.truckConsumption[k] ?? TRUCK_CONSUMPTION[k] };
}

/** Réglages propres au module, stockés sous « osamaps.along.prefs ». */
export const useAlongPrefs = create<State>((set, get) => {
  const base: Stored = { ...DEFAULTS, ...saved, truckEnergy: saved.truckEnergy ?? "gazole", truckConsumption: saved.truckConsumption ?? {} };
  const save = () => {
    const s = get();
    saveLocal("along.prefs", {
      energy: car.energy, consumption: car.consumption, evConsumption: s.evConsumption, showStations: s.showStations,
      pauseReminder: s.pauseReminder, weatherAlerts: s.weatherAlerts, truckEnergy: s.truckEnergy, truckConsumption: s.truckConsumption,
    } satisfies Stored);
  };
  return {
    ...base,
    ...effective(base),
    range: () => (isTruck() ? [10, 90] : [2, 25]),
    setAlong: (k, v) => {
      const s = get();
      if (k === "energy") {
        if (isTruck()) set({ truckEnergy: v as Energy, energy: v as Energy });
        else { car.energy = v as Energy; set({ energy: v as Energy }); }
      } else if (k === "consumption") {
        if (isTruck()) set({ truckConsumption: { ...s.truckConsumption, [kind()]: v as number }, consumption: v as number });
        else { car.consumption = v as number; set({ consumption: v as number }); }
      } else set({ [k]: v } as Partial<State>);
      save();
    },
  };
});

// changement de véhicule : on bascule sur son carburant et sa consommation
usePrefs.subscribe((s, prev) => {
  if (s.vehicle.kind !== prev.vehicle.kind) useAlongPrefs.setState(effective(useAlongPrefs.getState()));
});

export const alongPrefs = () => useAlongPrefs.getState();
