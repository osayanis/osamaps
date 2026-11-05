/** Niveaux : seuils de points cumulés et petits noms. */
export const LEVELS = [
  { min: 0, name: "Apprenti du volant" },
  { min: 100, name: "Rouleur du dimanche" },
  { min: 300, name: "Copilote fiable" },
  { min: 700, name: "As du rond-point" },
  { min: 1500, name: "Routier sympa" },
  { min: 3000, name: "Éclaireur des routes" },
  { min: 6000, name: "Légende de la nationale" },
  { min: 12000, name: "Maître des cartes" },
] as const;

export function levelOf(points: number) {
  let i = 0;
  while (i + 1 < LEVELS.length && points >= LEVELS[i + 1].min) i++;
  const cur = LEVELS[i];
  const next = LEVELS[i + 1] ?? null;
  const progress = next ? (points - cur.min) / (next.min - cur.min) : 1;
  return { level: i + 1, name: cur.name, min: cur.min, next: next?.min ?? null, progress: Math.max(0, Math.min(1, progress)) };
}

export type BadgeIcon = "flag" | "gauge" | "globe" | "moon" | "sunrise" | "megaphone" | "check" | "vote" | "compass" | "calendar" | "road" | "wheel";

export interface BadgeDef { id: string; name: string; hint: string; icon: BadgeIcon }

export const BADGES: BadgeDef[] = [
  { id: "premier-trajet", name: "Premier trajet", hint: "Arriver au bout d'un premier trajet", icon: "flag" },
  { id: "10-trajets", name: "Habitué", hint: "Terminer 10 trajets", icon: "wheel" },
  { id: "100-km", name: "100 km", hint: "Rouler 100 km au total", icon: "gauge" },
  { id: "1000-km", name: "Grand voyageur", hint: "Rouler 1 000 km au total", icon: "globe" },
  { id: "marathon", name: "Long courrier", hint: "Un trajet de plus de 100 km", icon: "road" },
  { id: "nuit", name: "Conducteur de nuit", hint: "Rouler entre 22 h et 5 h", icon: "moon" },
  { id: "matinal", name: "Lève-tôt", hint: "Partir entre 5 h et 7 h", icon: "sunrise" },
  { id: "signaleur", name: "Vigie", hint: "Faire 10 signalements", icon: "megaphone" },
  { id: "confirme", name: "Œil de lynx", hint: "10 signalements confirmés", icon: "check" },
  { id: "entraide", name: "Entraide", hint: "Voter sur 10 signalements", icon: "vote" },
  { id: "explorateur", name: "Explorateur", hint: "Aller vers 10 destinations différentes", icon: "compass" },
  { id: "fidele", name: "Fidèle", hint: "Rouler 7 jours différents", icon: "calendar" },
];

export const badgeById = (id: string) => BADGES.find((b) => b.id === id);

/** « 12 500 » */
export const nf = (n: number) => Math.round(n).toLocaleString("fr-FR");

/** Points gagnés. */
export const POINTS = {
  perKm: 1,
  arrived: 20,
  badge: 50,
  /** plafond d'un seul évènement points:earn venu d'un autre module */
  maxEvent: 200,
} as const;
