import { useMascot } from "./engine";

/** Pas d'animation si le système le demande OU si l'utilisateur les a coupées dans les réglages. */
export function reducedMotion(): boolean {
  const sys = typeof matchMedia === "function" && matchMedia("(prefers-reduced-motion: reduce)").matches;
  return sys || !useMascot.getState().settings.animations;
}
