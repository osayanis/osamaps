/**
 * Catalogue des signalements : types, sous-types, libellés, couleur d'état, pictogrammes.
 * Doit rester aligné avec `server/features/reports.js` (TYPES).
 * Loi française : pas de « radar » — un contrôle s'appelle « Police ».
 */
export type Kind = "police" | "accident" | "jam" | "hazard" | "works" | "closure" | "weather";

export interface Report {
  id: string;
  type: Kind;
  sub: string | null;
  lng: number;
  lat: number;
  heading: number | null;
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
  /** Pseudo de l'auteur ("" = anonyme). */
  by: string;
  confirmations: number;
  denials: number;
}

/** Tracés SVG (viewBox 24, trait 2 px, coins ronds). Plusieurs sous-chemins dans une même chaîne. */
export const PATHS: Record<string, string> = {
  police: "M12 3l7 3v5c0 4.6-3 8.3-7 10-4-1.7-7-5.4-7-10V6l7-3z M9 11.5l2 2 4-4",
  accident: "M4 19v-4l2-5h12l2 5v4z M4 19v1.5 M20 19v1.5 M7.5 15.5h.01 M16.5 15.5h.01 M12 3v3 M7 4.5l1.5 2 M17 4.5l-1.5 2",
  jam: "M5 17v-4l1.6-4.2A2 2 0 018.5 7.5h7a2 2 0 011.9 1.3L19 13v4z M5 13h14 M5 17v2.5 M19 17v2.5 M8 15h.01 M16 15h.01",
  hazard: "M12 3.5L21.5 20h-19z M12 10v4.5 M12 17.4h.01",
  works: "M9.6 4h4.8L19 19.5H5z M7.4 11.5h9.2 M6.3 15.5h11.4 M3.5 19.5h17",
  closure: "M21 12a9 9 0 11-18 0 9 9 0 0118 0z M7.5 12h9",
  weather: "M7 18.5h10a4 4 0 00.6-7.95A6 6 0 006.3 10.6 3.9 3.9 0 007 18.5z",
  // sous-types
  object: "M4 8l8-4 8 4v8l-8 4-8-4z M4 8l8 4 8-4 M12 12v8",
  vehicle: "M3 16v-3l2.5-5h8l3 4H20a1 1 0 011 1v3z M3 16h18 M7 16v2 M17 16v2 M12 8v4",
  pothole: "M3 15c0-2 4-3.5 9-3.5s9 1.5 9 3.5-4 3.5-9 3.5-9-1.5-9-3.5z M9 14.5l2-1.5 1.5 1.5 2-1",
  animal: "M8.5 15.5c0-2.2 1.6-4 3.5-4s3.5 1.8 3.5 4c0 1.7-1.6 3-3.5 3s-3.5-1.3-3.5-3z M7 10a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z M11 6.5a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z M16 6.5a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z M20 10a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z",
  pedestrian: "M14 4.5a1.5 1.5 0 11-3 0 1.5 1.5 0 013 0z M12 8.5l-2 5 3 2 .5 5 M12 8.5l3 3 3 .5 M10 13.5l-2.5 7 M12 8.5l-3.5 2-1 3",
  ice: "M12 3v18 M4.2 7.5l15.6 9 M4.2 16.5l15.6-9 M9.5 4.5L12 6l2.5-1.5 M9.5 19.5L12 18l2.5 1.5",
  fog: "M4 8h16 M4 12h16 M6 16h12 M8 20h8 M7 4h10",
  flood: "M3 12c1.5 0 1.5-1 3-1s1.5 1 3 1 1.5-1 3-1 1.5 1 3 1 1.5-1 3-1 1.5 1 3 1 M3 17c1.5 0 1.5-1 3-1s1.5 1 3 1 1.5-1 3-1 1.5 1 3 1 1.5-1 3-1 1.5 1 3 1 M12 3v5 M9.5 5.5L12 8l2.5-2.5",
  snow: "M7 14.5h10a3.5 3.5 0 00.5-6.96A5 5 0 007.8 7.3 3.4 3.4 0 007 14.5z M8 18h.01 M12 19.5h.01 M16 18h.01 M10 21.5h.01 M14 21.5h.01",
  // interface
  flag: "M5 21V4 M5 4h11.5l-2.2 4.25L16.5 12.5H5",
  close: "M6 6l12 12 M18 6L6 18",
  check: "M5 12.5l4.5 4.5L19 7.5",
  x: "M7 7l10 10 M17 7L7 17",
};

export interface KindInfo {
  label: string;
  /** Titre court pour l'alerte et la fiche quand aucun sous-type n'est précisé. */
  title: string;
  /** Variable CSS d'état. */
  color: string;
  tone: "info" | "warn" | "danger";
  subs: { id: string; label: string; title: string }[];
}

export const KINDS: Record<Kind, KindInfo> = {
  police: { label: "Police", title: "Police signalée", color: "--police", tone: "info", subs: [] },
  accident: { label: "Accident", title: "Accident signalé", color: "--jam", tone: "danger", subs: [] },
  jam: {
    label: "Bouchon", title: "Bouchon signalé", color: "--jam", tone: "warn",
    subs: [
      { id: "moderate", label: "Modéré", title: "Ralentissement" },
      { id: "heavy", label: "Dense", title: "Bouchon dense" },
      { id: "standstill", label: "À l'arrêt", title: "Bouchon à l'arrêt" },
    ],
  },
  hazard: {
    label: "Danger", title: "Danger signalé", color: "--danger", tone: "warn",
    subs: [
      { id: "object", label: "Objet", title: "Objet sur la route" },
      { id: "vehicle", label: "Véhicule arrêté", title: "Véhicule arrêté" },
      { id: "pothole", label: "Nid-de-poule", title: "Nid-de-poule" },
      { id: "animal", label: "Animal", title: "Animal sur la route" },
      { id: "pedestrian", label: "Piéton", title: "Piéton sur la route" },
    ],
  },
  works: { label: "Travaux", title: "Travaux", color: "--slow", tone: "warn", subs: [] },
  closure: { label: "Route fermée", title: "Route fermée", color: "--jam", tone: "danger", subs: [] },
  weather: {
    label: "Météo", title: "Météo difficile", color: "--danger", tone: "warn",
    subs: [
      { id: "ice", label: "Verglas", title: "Verglas signalé" },
      { id: "fog", label: "Brouillard", title: "Brouillard" },
      { id: "flood", label: "Inondation", title: "Route inondée" },
      { id: "snow", label: "Neige", title: "Neige sur la route" },
    ],
  },
};

export const KIND_ORDER: Kind[] = ["police", "accident", "jam", "hazard", "works", "closure", "weather"];

/** Couleur d'état d'un signalement (un bouchon modéré est orange, les autres rouges). */
export function colorVar(kind: Kind, sub?: string | null): string {
  if (kind === "jam" && sub === "moderate") return "--slow";
  return KINDS[kind].color;
}

/** Les pastilles jaunes / orange portent un pictogramme noir (contraste), les autres blanc. */
export function inkOn(color: string): string {
  return color === "--danger" || color === "--slow" ? "#000" : "#fff";
}

/** Pictogramme : celui du sous-type s'il en a un, sinon celui du type. */
export function iconKey(kind: Kind, sub?: string | null): string {
  return sub && PATHS[sub] ? sub : kind;
}

export function titleOf(kind: Kind, sub?: string | null): string {
  return KINDS[kind].subs.find((s) => s.id === sub)?.title ?? KINDS[kind].title;
}

/** « à l'instant », « il y a 12 min », « il y a 2 h », « il y a 3 j ». */
export function ago(t: number, now = Date.now()): string {
  const min = Math.floor((now - t) / 60_000);
  if (min < 1) return "à l'instant";
  if (min < 60) return `il y a ${min} min`;
  const h = Math.floor(min / 60);
  if (h < 24) return `il y a ${h} h`;
  return `il y a ${Math.floor(h / 24)} j`;
}
