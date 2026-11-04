/**
 * Retour haptique (vibration) pour les actions importantes.
 *
 *   haptic("tap")      — appui confirmé (bouton du rail, choix d'un réglage)       10 ms
 *   haptic("success")  — action réussie (signalement envoyé, arrivée)             double impulsion courte
 *   haptic("warn")     — alerte de conduite (danger, police, bouchon devant)      deux impulsions marquées
 *   haptic("error")    — échec (pas de réseau, action refusée)                    trois impulsions
 *
 * Les autres modules n'importent pas ce fichier (règle : pas d'import entre modules). Ils peuvent :
 *   window.dispatchEvent(new CustomEvent("osamaps:haptic", { detail: "success" }))
 * Le shell déclenche aussi tout seul : "warn" sur `drive:alert` (tone warn/danger), "success" sur
 * `drive:arrived`, "tap" sur `drive:start`, "error" quand le réseau tombe. Sans effet là où `navigator.vibrate` n'existe pas
 * (iPhone/Safari, ordinateur) ; désactivable via loadLocal("shell.haptics").
 */
import { loadLocal } from "../../core/identity";

export type HapticKind = "tap" | "success" | "warn" | "error";

const PATTERNS: Record<HapticKind, number | number[]> = {
  tap: 10,
  success: [14, 60, 22],
  warn: [40, 80, 40],
  error: [30, 50, 30, 50, 30],
};

let last = 0;

export function haptic(kind: HapticKind = "tap") {
  if (!loadLocal("shell.haptics", true)) return;
  if (typeof navigator === "undefined" || typeof navigator.vibrate !== "function") return;
  // évite les rafales (plusieurs modules qui réagissent au même évènement)
  const now = Date.now();
  if (now - last < 120 && kind === "tap") return;
  last = now;
  try { navigator.vibrate(PATTERNS[kind]); } catch { /* refusé par le navigateur */ }
}

export const HAPTIC_EVENT = "osamaps:haptic";

export function listenHaptics(): () => void {
  const fn = (e: Event) => {
    const kind = (e as CustomEvent).detail;
    haptic(kind in PATTERNS ? (kind as HapticKind) : "tap");
  };
  window.addEventListener(HAPTIC_EVENT, fn);
  return () => window.removeEventListener(HAPTIC_EVENT, fn);
}
