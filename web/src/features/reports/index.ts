import type { Feature } from "../../core/registry";
import "./reports.css";
import { ReportButton } from "./ReportButton";
import { ReportSheet } from "./ReportSheet";
import { ReportsLayer } from "./ReportsLayer";
import { AskCard } from "./AskCard";
import { ReportsSettings } from "./ReportsSettings";
import { connectRealtime } from "./state";
import { startDriveWatch } from "./watch";

/**
 * Signalements de la communauté : bouton Signaler (rail), panneaux "reports" / "report-detail"
 * (sheet), marqueurs (map), « Toujours là ? » (hud), réglages. Serveur : server/features/reports.js.
 */
export const reportsFeature: Feature = {
  id: "reports",
  name: "Signalements",
  slots: [
    { slot: "map", order: 40, Component: ReportsLayer },
    { slot: "rail", order: 20, Component: ReportButton },
    { slot: "sheet", order: 30, Component: ReportSheet },
    { slot: "hud", order: 80, Component: AskCard },
    { slot: "settings", order: 40, Component: ReportsSettings },
  ],
  init: () => {
    const a = connectRealtime();
    const b = startDriveWatch();
    return () => { a(); b(); };
  },
};
