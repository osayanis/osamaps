import type { Feature } from "../../core/registry";
import { MascotMarker } from "./MascotMarker";
import { TripSummary } from "./TripSummary";
import { Profile, ProfileButton } from "./Profile";

// une seule entrée par slot : le shell utilise l'id du module comme clé React
function MascotSheet() {
  return <><TripSummary /><Profile /></>;
}
import { MascotSettings } from "./MascotSettings";
import { initMascot } from "./engine";
import { syncBoard } from "./leaderboard";
import { on } from "../../core/bus";
import "./mascot.css";

/**
 * La mascotte Osa au volant : « ma position » sur la carte, points, niveaux, badges,
 * accessoires, statistiques de trajet (panneau "trip-summary") et profil (panneau "profile").
 */
export const mascot: Feature = {
  id: "mascot",
  name: "Mascotte et progression",
  slots: [
    { slot: "map", order: 90, Component: MascotMarker },
    { slot: "rail", order: 5, Component: ProfileButton },
    { slot: "sheet", order: 60, Component: MascotSheet },
    { slot: "settings", order: 70, Component: MascotSettings },
  ],
  init: () => {
    const stop = initMascot();
    // classement : resynchronise après chaque trajet (si activé)
    const off = on("drive:stop", () => { window.setTimeout(() => void syncBoard(), 1500); });
    return () => { stop(); off(); };
  },
};
