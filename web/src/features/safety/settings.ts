import { create } from "zustand";
import { loadLocal, saveLocal } from "../../core/identity";

/**
 * Réglages du module sécurité (stockés dans localStorage « osamaps.safety.settings », pas dans
 * core/prefs pour éviter les conflits entre modules).
 */
export type CritAir = "unset" | "EL" | "V1" | "V2" | "V3" | "V4" | "V5" | "NC";

export interface SafetySettings {
  /** Vignette Crit'Air du véhicule ("EL" = Crit'Air 0, électrique/hydrogène). */
  critair: CritAir;
  dangerZones: boolean;
  zfe: boolean;
  curves: boolean;
  levelCrossings: boolean;
  schools: boolean;
  night: boolean;
  passenger: boolean;
}

const DEFAULTS: SafetySettings = {
  critair: "unset",
  dangerZones: true,
  zfe: true,
  curves: true,
  levelCrossings: true,
  schools: true,
  night: true,
  passenger: true,
};

interface State extends SafetySettings {
  setSetting: <K extends keyof SafetySettings>(key: K, value: SafetySettings[K]) => void;
}

export const useSafetySettings = create<State>((set, get) => ({
  ...DEFAULTS,
  ...loadLocal<Partial<SafetySettings>>("safety.settings", {}),
  setSetting: (key, value) => {
    set({ [key]: value } as Partial<State>);
    const { setSetting: _, ...rest } = get();
    saveLocal("safety.settings", rest);
  },
}));

export const safetySettings = () => useSafetySettings.getState();

/** Ordre des vignettes défini par le schéma national des ZFE : EL, V1, V2, V3, V4, V5, NC. */
export const CRITAIR_ORDER = ["EL", "V1", "V2", "V3", "V4", "V5", "NC"] as const;

export const CRITAIR_LABEL: Record<CritAir, string> = {
  unset: "Non réglée",
  EL: "Crit'Air 0 (électrique)",
  V1: "Crit'Air 1",
  V2: "Crit'Air 2",
  V3: "Crit'Air 3",
  V4: "Crit'Air 4",
  V5: "Crit'Air 5",
  NC: "Non classé",
};

/**
 * Dans les données ZFE, `vp_critair` = première vignette INTERDITE (« V4 » : Crit'Air 4, 5 et non
 * classés interdits). Renvoie null si on ne sait pas (vignette non réglée ou pas de règle voiture).
 */
export function critairForbidden(mine: CritAir, firstForbidden: string | null): boolean | null {
  if (mine === "unset" || !firstForbidden) return null;
  const a = CRITAIR_ORDER.indexOf(mine as (typeof CRITAIR_ORDER)[number]);
  const b = CRITAIR_ORDER.indexOf(firstForbidden as (typeof CRITAIR_ORDER)[number]);
  if (a < 0 || b < 0) return null;
  return a >= b;
}
