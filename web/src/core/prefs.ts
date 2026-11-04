import { create } from "zustand";
import { persist } from "zustand/middleware";

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
      setPref: (key, value) => set({ [key]: value } as Partial<PrefsState>),
    }),
    { name: "osamaps.prefs" },
  ),
);

export const prefs = () => usePrefs.getState();
