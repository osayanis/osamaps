import type { Feature } from "../../core/registry";
import "./shell.css";
import { Onboarding } from "./Onboarding";
import { Toasts } from "./Toasts";
import { SettingsButton, CompassButton, RecenterButton, listenRecenter } from "./RailButtons";
import { MapStyle } from "./MapStyle";
import { GeneralSettings, AboutSettings } from "./SettingsSections";
import { listenToasts } from "./toastStore";
import { listenHaptics } from "./haptics";
import { startLayoutClass } from "./layout";
import { startPwa } from "./pwa";
import { startWakeLock, startComfortEvents, startKeyboard } from "./comfort";

/**
 * Le shell d'OsaMaps : tout ce qui entoure la carte.
 *   overlay   accueil du premier lancement (10), toasts + bannière hors ligne (90)
 *   rail      Réglages (5), Boussole (6), Recentrer (990)
 *   map       application du style clair / sombre / auto
 *   settings  « Général » (1), « Accueil et données » + « À propos » (1000)
 * + PWA (manifest, service worker, installation), Wake Lock en conduite, raccourcis clavier,
 *   retours haptiques, agencement latéral sur grand écran (classe osa-side sur <html>).
 *
 * Contrats exposés aux autres modules (sans import) :
 *   emit("toast", { text, icon?, tone?, id?, duration? })
 *   emit("map:recenter", {})
 *   window.dispatchEvent(new CustomEvent("osamaps:haptic", { detail: "tap" | "success" | "warn" | "error" }))
 *   window.addEventListener("osamaps:search", (e) => { e.preventDefault(); monChamp.focus(); })
 *   html.osa-side / html.osa-stack, html[data-map-theme="light" | "dark"]
 */
export const shell: Feature = {
  id: "shell",
  name: "Accueil, réglages et PWA",
  slots: [
    { slot: "overlay", order: 10, Component: Onboarding },
    { slot: "overlay", order: 90, Component: Toasts },
    { slot: "rail", order: 5, Component: SettingsButton },
    { slot: "rail", order: 6, Component: CompassButton },
    { slot: "rail", order: 990, Component: RecenterButton },
    { slot: "map", order: 0, Component: MapStyle },
    { slot: "settings", order: 1, Component: GeneralSettings },
    { slot: "settings", order: 1000, Component: AboutSettings },
  ],
  init: () => {
    const stops = [
      startLayoutClass(),
      listenToasts(),
      listenHaptics(),
      listenRecenter(),
      startPwa(),
      startWakeLock(),
      startComfortEvents(),
      startKeyboard(),
    ];
    return () => stops.forEach((s) => s());
  },
};
