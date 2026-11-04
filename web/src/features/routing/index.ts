import type { Feature } from "../../core/registry";
import { RoutingLayer } from "./RoutingLayer";
import { RoutingSheet } from "./RoutingSheet";
import { RoutingSettings } from "./RoutingSettings";
import { initRouting } from "./controller";
import "./routing.css";

/**
 * Itinéraires : calcul (Valhalla), alternatives, aperçu, étapes, départ différé, recalcul en
 * conduite, limites de vitesse le long du tracé. Le guidage tour par tour est au module guidance.
 *
 * Contrat :
 *  écoute   place:go → aperçu ; route:recompute { from } → recalcul en conduite ; drive:stop → nettoyage ;
 *           route:add-stop { name, lng, lat } → ajoute une étape (évènement déclaré par ce module).
 *  émet     drive:start { routeId } (bouton « C'est parti ») ; drive:rerouted { routeId } ; toast.
 *  store    destination, routes (Route complète, speedLimits remplies en tâche de fond), activeRoute,
 *           mode preview/drive/browse, follow. Arrivée à une étape : Maneuver.type === "waypoint".
 */
export const routingFeature: Feature = {
  id: "routing",
  name: "Itinéraires",
  slots: [
    { slot: "map", order: 20, Component: RoutingLayer },
    { slot: "sheet", order: 20, Component: RoutingSheet },
    { slot: "settings", order: 20, Component: RoutingSettings },
  ],
  init: initRouting,
};
