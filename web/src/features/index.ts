import type { Feature } from "../core/registry";
import { reportsFeature } from "./reports";
import { friends } from "./friends";

/**
 * Les fonctionnalités d'OsaMaps. Chaque module ajoute SA ligne d'import et son entrée dans la
 * liste (rien d'autre à toucher dans ce fichier).
 */
export const FEATURES: Feature[] = [
  reportsFeature,
  friends,
];
