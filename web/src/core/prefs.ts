import { create } from "zustand";
import { persist } from "zustand/middleware";

/** Profil du véhicule (partagé : accueil, itinéraires, guidage, sécurité, mascotte…). */
export type VehicleKind = "car" | "truck" | "heavy" | "superheavy";
export interface Vehicle {
  kind: VehicleKind;
  /** Mètres. */
  height: number;
  width: number;
  length: number;
  /** Tonnes (poids total en charge). */
  weight: number;
  /** Tonnes par essieu. */
  axleLoad: number;
  /** Matières dangereuses (ADR). */
  hazmat: boolean;
}

export const VEHICLE_LABELS: Record<VehicleKind, { label: string; detail: string }> = {
  car: { label: "Voiture", detail: "Voiture, moto, utilitaire léger" },
  truck: { label: "Camion", detail: "Porteur jusqu'à 19 t" },
  heavy: { label: "Poids lourd", detail: "Semi-remorque jusqu'à 44 t" },
  superheavy: { label: "Super lourd", detail: "Convoi exceptionnel, plus de 44 t" },
};

/** Valeurs par défaut de chaque catégorie (modifiables ensuite dans les Réglages). */
export function vehiclePreset(kind: VehicleKind): Vehicle {
  switch (kind) {
    case "truck": return { kind, height: 3.6, width: 2.55, length: 10, weight: 19, axleLoad: 11.5, hazmat: false };
    case "heavy": return { kind, height: 4, width: 2.55, length: 16.5, weight: 44, axleLoad: 11.5, hazmat: false };
    case "superheavy": return { kind, height: 4.5, width: 3.5, length: 25, weight: 72, axleLoad: 13, hazmat: false };
    default: return { kind: "car", height: 1.6, width: 1.9, length: 4.5, weight: 1.8, axleLoad: 1, hazmat: false };
  }
}

/** Costing Valhalla + options pour la requête d'itinéraire. */
export function vehicleCosting(v: Vehicle): { costing: "auto" | "truck"; options: Record<string, unknown> } {
  if (v.kind === "car") return { costing: "auto", options: {} };
  return { costing: "truck", options: { height: v.height, width: v.width, length: v.length, weight: v.weight, axle_load: v.axleLoad, hazmat: v.hazmat } };
}

/**
 * Préférences partagées entre fonctionnalités (persistées dans localStorage « osamaps.prefs »).
 * Chaque fonctionnalité affiche SES réglages dans le slot "settings" et lit/écrit ici.
 * Pour ajouter une préférence propre à un module, préfère loadLocal/saveLocal (core/identity)
 * avec une clé préfixée par l'id du module : ce fichier est commun, on évite les conflits.
 */
export interface Prefs {
  /** Options d'itinéraire. */
  avoidTolls: boolean;
  avoidHighways: boolean;
  avoidFerries: boolean;
  /** Style de carte : auto = sombre la nuit, clair le jour. */
  mapStyle: "auto" | "dark" | "light";
  /** Guidage vocal. */
  voice: boolean;
  /** Alerte de dépassement : tolérance en km/h au-dessus de la limite. */
  speedTolerance: number;
  /** Partage de position avec les amis (opt-in). */
  shareLocation: boolean;
  /** Envoi anonyme de la vitesse pour le trafic communautaire (opt-in, activé à l'accueil). */
  contributeTraffic: boolean;
  /** L'écran d'accueil a été vu. */
  onboarded: boolean;
  /** Profil du véhicule. */
  vehicle: Vehicle;
  /** Le véhicule a été choisi (à l'accueil, ou plus tard pour ceux qui avaient déjà passé l'accueil). */
  vehicleChosen: boolean;
}

interface PrefsState extends Prefs {
  setPref: <K extends keyof Prefs>(key: K, value: Prefs[K]) => void;
}

export const usePrefs = create<PrefsState>()(
  persist(
    (set) => ({
      avoidTolls: false,
      avoidHighways: false,
      avoidFerries: false,
      mapStyle: "dark",
      voice: true,
      speedTolerance: 5,
      shareLocation: false,
      contributeTraffic: true,
      onboarded: false,
      vehicle: vehiclePreset("car"),
      vehicleChosen: false,
      setPref: (key, value) => set({ [key]: value } as Partial<PrefsState>),
    }),
    { name: "osamaps.prefs" },
  ),
);

export const prefs = () => usePrefs.getState();
