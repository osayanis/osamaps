import { create } from "zustand";
import { loadLocal, saveLocal } from "../../core/identity";

/** Alerte affichée dans le HUD (reçue via `drive:alert`). */
export interface GuideAlert {
  id: string;
  kind: string;
  text: string;
  tone: "info" | "warn" | "danger";
  /** Distance annoncée à la réception (m) et compteur kilométrique à ce moment-là. */
  baseDistance: number;
  baseOdo: number;
  /** Distance restante (m), recalculée à chaque position. */
  remaining: number;
  receivedAt: number;
}

export interface Arrival {
  name: string;
  side: "left" | "right" | null;
  /** Durée (s) et distance (m) du trajet effectué. */
  tripTime: number;
  tripDistance: number;
}

/** État interne du guidage (propre au module, lu par le HUD et la barre du bas). */
interface GuideState {
  routeId: string | null;
  /** Distance parcourue sur le tracé (m). */
  along: number;
  /** Index de la prochaine manœuvre et distance jusqu'à elle (m). */
  nextIndex: number;
  distToNext: number;
  /** Seuil « maintenant » courant (m), pour l'affichage imminent. */
  nowThreshold: number;
  recalculating: boolean;
  arrived: Arrival | null;
  speedKmh: number | null;
  limitKmh: number | null;
  speeding: boolean;
  alerts: GuideAlert[];
  overview: boolean;
}

export const initialGuide: GuideState = {
  routeId: null,
  along: 0,
  nextIndex: 1,
  distToNext: 0,
  nowThreshold: 30,
  recalculating: false,
  arrived: null,
  speedKmh: null,
  limitKmh: null,
  speeding: false,
  alerts: [],
  overview: false,
};

export const useGuide = create<GuideState>(() => ({ ...initialGuide }));
export const guide = () => useGuide.getState();
export const setGuide = (p: Partial<GuideState>) => useGuide.setState(p);

/** Réglages propres au guidage (stockés sous « osamaps.guidance.prefs »). */
export interface GuidePrefs {
  /** Petit bip une fois par dépassement de la limite (+ tolérance). */
  speedBeep: boolean;
  /** Dire la nouvelle limitation quand elle change. */
  speedVoice: boolean;
}

const PREFS_KEY = "guidance.prefs";
const defaults: GuidePrefs = { speedBeep: true, speedVoice: false };

interface GuidePrefsState extends GuidePrefs {
  setGuidePref: <K extends keyof GuidePrefs>(key: K, value: GuidePrefs[K]) => void;
}

export const useGuidePrefs = create<GuidePrefsState>((set, get) => ({
  ...defaults,
  ...loadLocal<Partial<GuidePrefs>>(PREFS_KEY, {}),
  setGuidePref: (key, value) => {
    set({ [key]: value } as Partial<GuidePrefsState>);
    const { speedBeep, speedVoice } = get();
    saveLocal(PREFS_KEY, { speedBeep, speedVoice });
  },
}));
