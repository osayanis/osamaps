import type { Feature } from "../../core/registry";
import { GuidanceHud } from "./Hud";
import { DriveBar } from "./DriveBar";
import { GuidanceSettings } from "./Settings";
import { initGuidance } from "./engine";
import "./guidance.css";

/**
 * Guidage tour par tour : progression sur l'itinéraire actif, HUD de manœuvre, voix française,
 * recalcul en cas de sortie de route, arrivée, vitesse et alertes (évènement `drive:alert`).
 */
export const guidance: Feature = {
  id: "guidance",
  name: "Guidage",
  slots: [
    { slot: "hud", order: 10, Component: GuidanceHud },
    { slot: "sheet", order: 10, Component: DriveBar },
    { slot: "settings", order: 20, Component: GuidanceSettings },
  ],
  init: initGuidance,
};
