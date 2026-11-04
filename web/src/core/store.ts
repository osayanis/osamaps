import { create } from "zustand";
import type { Map as MLMap } from "maplibre-gl";

/** [longitude, latitude] — l'ordre de MapLibre et GeoJSON. */
export type LngLat = [number, number];

export interface Place {
  id: string;
  name: string;
  /** Ligne secondaire (adresse, ville). */
  detail?: string;
  coord: LngLat;
  /** Catégorie libre : "address", "poi", "fuel", "friend", "favorite"… */
  kind?: string;
}

export interface Maneuver {
  /** Texte à afficher (« Tournez à droite sur la rue de Paris »). */
  instruction: string;
  /** Texte court à dire avant la manœuvre (fourni par le moteur ou construit). */
  verbal?: string;
  /** Type Valhalla (numérique) ou libellé, pour l'icône. */
  type: number | string;
  /** Index dans `Route.coords` où la manœuvre commence. */
  shapeIndex: number;
  /** Mètres jusqu'à la manœuvre suivante. */
  length: number;
  /** Secondes jusqu'à la manœuvre suivante. */
  time: number;
  street?: string;
  /** Voies (si connues). */
  lanes?: { directions: string[]; valid: boolean }[];
}

export interface Route {
  id: string;
  coords: LngLat[];
  /** Mètres. */
  distance: number;
  /** Secondes (sans trafic communautaire). */
  duration: number;
  maneuvers: Maneuver[];
  /** Limites de vitesse le long du tracé : à partir de l'index `from`, `kmh` (null = inconnue). */
  speedLimits?: { from: number; kmh: number | null }[];
  summary?: string;
  /** Péages, autoroutes… */
  flags?: { toll?: boolean; highway?: boolean; ferry?: boolean };
}

export type Mode = "browse" | "preview" | "drive";

export interface Position {
  coord: LngLat;
  /** Degrés, 0 = nord. null si inconnu. */
  heading: number | null;
  /** m/s. null si inconnu. */
  speed: number | null;
  accuracy: number | null;
  time: number;
  simulated: boolean;
}

interface CoreState {
  map: MLMap | null;
  mapReady: boolean;
  position: Position | null;
  /** La carte suit la position (bouton « recentrer »). */
  follow: boolean;
  mode: Mode;
  destination: Place | null;
  routes: Route[];
  activeRoute: number;
  /** Progression sur l'itinéraire actif pendant la conduite. */
  progress: { shapeIndex: number; maneuverIndex: number; remainingDistance: number; remainingTime: number } | null;
  /** Panneau du bas actuellement ouvert (id libre décidé par les fonctionnalités) ; null = accueil. */
  panel: string | null;
  /** Données associées au panneau ouvert (ex. le lieu sélectionné). */
  panelData: unknown;
  settingsOpen: boolean;

  set: (p: Partial<CoreState>) => void;
  openPanel: (panel: string | null, data?: unknown) => void;
}

export const useCore = create<CoreState>((set) => ({
  map: null,
  mapReady: false,
  position: null,
  follow: true,
  mode: "browse",
  destination: null,
  routes: [],
  activeRoute: 0,
  progress: null,
  panel: null,
  panelData: null,
  settingsOpen: false,
  set: (p) => set(p),
  openPanel: (panel, data) => set({ panel, panelData: data ?? null }),
}));

/** Accès hors React. */
export const core = () => useCore.getState();
