import type { Feature } from "../../core/registry";
import { TrafficLayer } from "./TrafficLayer";
import { TrafficButton } from "./TrafficButton";
import { TrafficDelay } from "./TrafficDelay";
import { TrafficSheet } from "./TrafficSheet";
import { TrafficSettings } from "./TrafficSettings";
import { startContribution } from "./contribute";
import { startDriveTraffic } from "./drive";
import "./traffic.css";

export const traffic: Feature = {
  id: "traffic",
  name: "Trafic en direct",
  slots: [
    { slot: "map", order: 20, Component: TrafficLayer },
    { slot: "rail", order: 40, Component: TrafficButton },
    { slot: "hud", order: 60, Component: TrafficDelay },
    { slot: "sheet", order: 50, Component: TrafficSheet },
    { slot: "settings", order: 40, Component: TrafficSettings },
  ],
  init: () => {
    const stopContrib = startContribution();
    const stopDrive = startDriveTraffic();
    return () => { stopContrib(); stopDrive(); };
  },
};
