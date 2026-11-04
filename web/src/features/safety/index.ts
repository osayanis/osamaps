import type { Feature } from "../../core/registry";
import "./safety.css";
import { SafetyLayers } from "./SafetyLayers";
import { PassengerOverlay, SafetyHud, SafetySettingsSection, SafetySheet } from "./SafetyUI";
import { nightCheck, startSafetyEngine, useSafety } from "./engine";
import { startPassengerWatch } from "./passenger";

/**
 * Sécurité routière : zones de danger (légales), ZFE, virages serrés, passages à niveau, écoles,
 * fatigue de nuit, « Tu es passager ? ». Contrat d'intégration : en-tête de passenger.ts (utilitaire « Tu es passager ? ») et engine.ts (alertes).
 */
export const safety: Feature = {
  id: "safety",
  name: "Sécurité routière",
  slots: [
    { slot: "map", order: 20, Component: SafetyLayers },
    { slot: "hud", order: 40, Component: SafetyHud },
    { slot: "sheet", order: 30, Component: SafetySheet },
    { slot: "overlay", order: 80, Component: PassengerOverlay },
    { slot: "settings", order: 40, Component: SafetySettingsSection },
  ],
  init: () => {
    const a = startSafetyEngine();
    const b = startPassengerWatch();
    // débogage / tests headless
    const w = window as unknown as { osamaps?: Record<string, unknown> };
    if (w.osamaps) w.osamaps.safety = { ...(w.osamaps.safety as object), state: () => useSafety.getState(), nightCheck };
    return () => { a(); b(); };
  },
};
