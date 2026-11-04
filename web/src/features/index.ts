import type { Feature } from "../core/registry";
import { reportsFeature } from "./reports";
import { friends } from "./friends";
import { guidance } from "./guidance";
import { mascot } from "./mascot";
import { searchFeature } from "./search";
import { traffic } from "./traffic";

/**
 * Les fonctionnalités d'OsaMaps. Chaque module ajoute SA ligne d'import et son entrée dans la
 * liste (rien d'autre à toucher dans ce fichier).
 */
export const FEATURES: Feature[] = [
  reportsFeature,
  friends,
  guidance,
  mascot,
  searchFeature,
  traffic,
];
