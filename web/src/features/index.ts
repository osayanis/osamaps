import type { Feature } from "../core/registry";
import { searchFeature } from "./search";

/**
 * Les fonctionnalités d'OsaMaps. Chaque module ajoute SA ligne d'import et son entrée dans la
 * liste (rien d'autre à toucher dans ce fichier).
 */
export const FEATURES: Feature[] = [
  searchFeature,
];
