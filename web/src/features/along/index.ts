import type { Feature } from "../../core/registry";
import { AlongLayer } from "./AlongLayer";
import { AlongSheets } from "./Sheets";
import { AlongSettings } from "./AlongSettings";
import { initAlong } from "./controller";
import "./along.css";

/**
 * Sur le trajet : prix des carburants, bornes de recharge, météo à l'heure de passage, pauses.
 * Données réelles uniquement (flux officiel des carburants, base IRVE, Open-Meteo, OSM).
 *
 * Contrat :
 *  panneaux  "station" (panelData = { kind: "fuel" | "ev", station }), "fuel" (stations du trajet),
 *            "weather" (météo du trajet). Bandeau discret au-dessus de l'aperçu (sheet, order 5).
 *  écoute    drive:start / drive:stop / drive:arrived / drive:rerouted / geo:tick.
 *  émet      place:go (« Y aller »), route:add-stop { name, lng, lat } (déclaré par routing),
 *            drive:alert (kind "weather" : neige/verglas/orage/pluie forte/brouillard ; kind "pause").
 *  lit       core.routes[activeRoute], core.mode, core.progress.shapeIndex, core.position.
 *  serveur   /maps/api/along/* (server/features/along.js).
 *  test      ?pause=1 → rappel de pause après 1 min de conduite au lieu de 2 h.
 */
export const alongFeature: Feature = {
  id: "along",
  name: "Sur le trajet",
  slots: [
    { slot: "map", order: 30, Component: AlongLayer },
    // bandeau d'aperçu (au-dessus du panneau routing, order 20) + panneaux station / fuel / weather
    { slot: "sheet", order: 5, Component: AlongSheets },
    { slot: "settings", order: 40, Component: AlongSettings },
  ],
  init: initAlong,
};
