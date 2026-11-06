import type { Feature } from "../../core/registry";
import "./shell.css";
import { Onboarding } from "./Onboarding";
import { Toasts } from "./Toasts";
import { SettingsButton, CompassButton, RecenterButton, listenRecenter } from "./RailButtons";
import { MapStyle } from "./MapStyle";
import { GeneralSettings, VehicleSettings, AboutSettings } from "./SettingsSections";
import { VehicleSheet, VehicleBadge, applyVehicleParam } from "./Vehicle";

function ShellOverlay() {
  return <><Onboarding /><VehicleSheet /><Toasts /></>;
}
function ShellRail() {
  return <><SettingsButton /><VehicleBadge /><CompassButton /><RecenterButton /></>;
}
function ShellSettings() {
  return <><GeneralSettings /><VehicleSettings /><AboutSettings /></>;
}
import { listenToasts } from "./toastStore";
import { listenHaptics } from "./haptics";
import { startLayoutClass } from "./layout";
import { startPwa } from "./pwa";
import { startWakeLock, startComfortEvents, startKeyboard } from "./comfort";

/**
 * Le shell d'OsaMaps : tout ce qui entoure la carte.
 *   overlay   accueil du premier lancement, toasts + bannière hors ligne
 *   rail      Réglages et Boussole (en haut, CSS order -10), Recentrer (en bas, CSS order 10)
 *   map       application du style clair / sombre / auto
 *   settings  « Général » (en haut, CSS order -10), « Accueil et données » + « À propos » (en bas, order 10)
 * Une seule entrée par slot (fragment) : les positions viennent de la propriété CSS `order` (les
 * slots rail et settings sont des colonnes flex), les autres modules restent à order 0, entre les
 * deux, quel que soit leur `order` de registre.
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
    { slot: "overlay", order: 10, Component: ShellOverlay },
    { slot: "rail", order: 100, Component: ShellRail },
    { slot: "map", order: 0, Component: MapStyle },
    { slot: "settings", order: 1, Component: ShellSettings },
  ],
  init: () => {
    applyVehicleParam();
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
