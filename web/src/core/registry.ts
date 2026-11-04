import type { ComponentType } from "react";

/**
 * Chaque fonctionnalité d'OsaMaps est un module autonome dans `src/features/<id>/`.
 * Elle exporte un objet `Feature` et s'enregistre dans `src/features/index.ts` (une ligne).
 * Le shell (App.tsx) place ses composants dans des emplacements (« slots ») fixes : aucune
 * fonctionnalité n'a besoin de modifier le shell ni une autre fonctionnalité.
 */
export type Slot =
  /** Calques posés sur la carte (sources/couches MapLibre, marqueurs). Rendu dans <MapView>. */
  | "map"
  /** Barre du haut en mode exploration (recherche). Un seul occupant attendu : search. */
  | "top"
  /** Contenu du panneau du bas, empilé (fiche d'un lieu, aperçu d'itinéraire, signaler…). */
  | "sheet"
  /** Boutons ronds sur le bord droit (recentrer, signaler, calques…). */
  | "rail"
  /** Affichage de conduite (prochaine manœuvre, vitesse, alertes) — visible en mode "drive". */
  | "hud"
  /** Couches plein écran par-dessus tout (accueil, modales, toasts). */
  | "overlay"
  /** Sections de l'écran Réglages. */
  | "settings";

export interface FeatureSlotEntry {
  slot: Slot;
  /** Ordre dans le slot (petit = d'abord / en haut). */
  order?: number;
  Component: ComponentType;
}

export interface Feature {
  id: string;
  /** Nom affiché (réglages, debug). */
  name: string;
  slots: FeatureSlotEntry[];
  /** Appelé une fois au démarrage (abonnements socket, minuteries…). Peut renvoyer un nettoyage. */
  init?: () => void | (() => void);
}

const features: Feature[] = [];

export function registerFeatures(list: Feature[]) {
  for (const f of list) {
    if (features.some((x) => x.id === f.id)) continue;
    features.push(f);
  }
}

export function slotEntries(slot: Slot): (FeatureSlotEntry & { featureId: string })[] {
  return features
    .flatMap((f) => f.slots.filter((s) => s.slot === slot).map((s) => ({ ...s, featureId: f.id })))
    .sort((a, b) => (a.order ?? 100) - (b.order ?? 100));
}

export function allFeatures() {
  return features;
}
