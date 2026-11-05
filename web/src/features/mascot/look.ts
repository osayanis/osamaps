import { create } from "zustand";
import { api } from "../../core/services";
import { deviceId, friendCode, loadLocal, saveLocal } from "../../core/identity";
import { levelOf } from "./data";
import { useMascot } from "./engine";

/**
 * L'apparence choisie de la mascotte (éditeur « Ma mascotte »). Même format que l'app iOS
 * (`MascotLook.swift`) et que le serveur (`/mascot/look`) : des identifiants courts.
 */
export const LOOK_OPTIONS = {
  body: ["creme", "nuage", "peche", "bonbon", "citron", "menthe", "ciel", "lavande"],
  hat: ["none", "casquette", "bonnet", "beret", "chapeau", "chantier", "couronne"],
  glasses: ["none", "soleil", "rondes", "aviateur", "carrees"],
  face: ["doux", "rieur", "malin", "timide", "cool"],
  neck: ["none", "noeud", "echarpe", "bandana", "cravate", "medaille"],
  ride: ["nuit", "glacier", "rouge", "orange", "soleil", "sapin", "ocean", "prune"],
} as const;

export type BodyColor = (typeof LOOK_OPTIONS.body)[number];
export type Hat = (typeof LOOK_OPTIONS.hat)[number];
export type Glasses = (typeof LOOK_OPTIONS.glasses)[number];
export type Face = (typeof LOOK_OPTIONS.face)[number];
export type Neck = (typeof LOOK_OPTIONS.neck)[number];
export type Ride = (typeof LOOK_OPTIONS.ride)[number];

export interface Look {
  body: BodyColor;
  hat: Hat;
  glasses: Glasses;
  face: Face;
  neck: Neck;
  ride: Ride;
  name: string;
}

export const DEFAULT_NAME = "Osa";
export const MAX_NAME = 16;
export const DEFAULT_LOOK: Look = { body: "creme", hat: "none", glasses: "none", face: "doux", neck: "none", ride: "nuit", name: DEFAULT_NAME };

export const LABELS: { [K in keyof typeof LOOK_OPTIONS]: Record<(typeof LOOK_OPTIONS)[K][number], string> } = {
  body: { creme: "Crème", nuage: "Nuage", peche: "Pêche", bonbon: "Bonbon", citron: "Citron", menthe: "Menthe", ciel: "Ciel", lavande: "Lavande" },
  hat: { none: "Rien", casquette: "Casquette", bonnet: "Bonnet", beret: "Béret", chapeau: "Chapeau", chantier: "Casque", couronne: "Couronne" },
  glasses: { none: "Aucune", soleil: "Soleil", rondes: "Rondes", aviateur: "Aviateur", carrees: "Carrées" },
  face: { doux: "Doux", rieur: "Rieur", malin: "Malin", timide: "Timide", cool: "Détendu" },
  neck: { none: "Rien", noeud: "Nœud pap'", echarpe: "Écharpe", bandana: "Bandana", cravate: "Cravate", medaille: "Médaille" },
  ride: { nuit: "Nuit", glacier: "Glacier", rouge: "Rouge", orange: "Orange", soleil: "Soleil", sapin: "Sapin", ocean: "Océan", prune: "Prune" },
};

/** Clair (éclairage), ombre (bords, bras), bas des pieds. */
export const BODY_TONES: Record<BodyColor, [string, string, string]> = {
  creme: ["#fefdf7", "#d6cec2", "#b3ab9e"],
  nuage: ["#f5f7fb", "#c3cad6", "#a1a9b7"],
  peche: ["#ffede2", "#f1b79c", "#d3987d"],
  bonbon: ["#ffeaf0", "#efadc0", "#d08fa2"],
  citron: ["#fff8d6", "#e9cf78", "#c9b05c"],
  menthe: ["#e6f8ee", "#a3dabc", "#84bc9e"],
  ciel: ["#e6f2ff", "#a2c6ec", "#84a8ce"],
  lavande: ["#f0ebff", "#beb0ec", "#a092ce"],
};

export const RIDE_COLORS: Record<Ride, string> = {
  nuit: "#1b1d24", glacier: "#e9ebf0", rouge: "#d63b42", orange: "#ee7f2d",
  soleil: "#f1c232", sapin: "#2c9461", ocean: "#2e68d2", prune: "#7656d2",
};
export const rideIsLight = (r: Ride) => r === "glacier" || r === "soleil";

/** La couronne reste une récompense. */
export const HAT_LEVEL: Partial<Record<Hat, number>> = { couronne: 4 };

export const displayName = (l: Look) => l.name.trim() || DEFAULT_NAME;

/** Lecture tolérante : une valeur inconnue retombe sur la valeur par défaut. */
export function cleanLook(v: unknown): Look {
  const o = (v && typeof v === "object" ? v : {}) as Record<string, unknown>;
  const pick = <K extends keyof typeof LOOK_OPTIONS>(k: K) =>
    ((LOOK_OPTIONS[k] as readonly string[]).includes(o[k] as string) ? o[k] : DEFAULT_LOOK[k]) as Look[K];
  return {
    body: pick("body"), hat: pick("hat"), glasses: pick("glasses"), face: pick("face"), neck: pick("neck"), ride: pick("ride"),
    name: typeof o.name === "string" ? o.name.slice(0, MAX_NAME) : DEFAULT_NAME,
  };
}

function initial(): Look {
  const saved = loadLocal<unknown>("mascot.look", null);
  if (saved) return cleanLook(saved);
  // première fois : on reprend les anciens accessoires portés (avant l'éditeur)
  const l = { ...DEFAULT_LOOK };
  const old = loadLocal<{ equipped?: string[] }>("mascot.state", {}).equipped ?? [];
  for (const a of old) {
    if (a === "casquette" || a === "bonnet" || a === "couronne") l.hat = a;
    else if (a === "lunettes") l.glasses = "soleil";
    else if (a === "echarpe" || a === "noeud") l.neck = a;
  }
  return l;
}

export const useLook = create<Look>(() => initial());

export function hatUnlocked(h: Hat, points = useMascot.getState().points) {
  const need = HAT_LEVEL[h];
  return need == null || levelOf(points).level >= need;
}

/** Ce qu'on dessine : la couronne n'apparaît que si elle est encore débloquée. */
export function useShownLook(): Look {
  const look = useLook();
  const points = useMascot((s) => s.points);
  return hatUnlocked(look.hat, points) ? look : { ...look, hat: "none" };
}

let syncTimer = 0;
export function updateLook(p: Partial<Look>) {
  const next = { ...useLook.getState(), ...p };
  next.name = next.name.slice(0, MAX_NAME);
  useLook.setState(next, true);
  saveLocal("mascot.look", next);
  // pour que les amis la voient (code ami + apparence ; regroupé)
  window.clearTimeout(syncTimer);
  syncTimer = window.setTimeout(() => {
    void api("mascot/look", { method: "POST", body: JSON.stringify({ id: deviceId(), code: friendCode(), look: useLook.getState() }) }).catch(() => {});
  }, 1500);
}

const any = <T,>(a: readonly T[]) => a[Math.floor(Math.random() * a.length)];

/** Tout au hasard (sauf le nom), sans retomber sur la même tenue. */
export function randomLook() {
  const before = useLook.getState();
  let l: Look;
  do {
    l = {
      ...before,
      body: any(LOOK_OPTIONS.body),
      hat: any(LOOK_OPTIONS.hat.filter((h) => hatUnlocked(h))),
      glasses: Math.random() < 0.35 ? "none" : any(LOOK_OPTIONS.glasses),
      face: any(LOOK_OPTIONS.face),
      neck: any(LOOK_OPTIONS.neck),
      ride: any(LOOK_OPTIONS.ride),
    };
  } while (JSON.stringify(l) === JSON.stringify(before));
  updateLook(l);
}
