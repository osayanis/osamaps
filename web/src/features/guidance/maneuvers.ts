import type { Maneuver } from "../../core/store";

/**
 * Types de manœuvre Valhalla → forme d'icône + phrases françaises.
 * https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/#trip-legs-and-maneuvers
 */
export type ManeuverKind =
  | "depart" | "straight"
  | "slight-right" | "right" | "sharp-right" | "uturn-right"
  | "slight-left" | "left" | "sharp-left" | "uturn-left"
  | "ramp-right" | "ramp-left" | "exit-right" | "exit-left"
  | "keep-right" | "keep-left" | "merge" | "merge-right" | "merge-left"
  | "roundabout" | "roundabout-exit" | "ferry" | "ferry-exit"
  | "arrive" | "arrive-right" | "arrive-left";

const BY_NUMBER: Record<number, ManeuverKind> = {
  1: "depart", 2: "depart", 3: "depart",
  4: "arrive", 5: "arrive-right", 6: "arrive-left",
  7: "straight", 8: "straight",
  9: "slight-right", 10: "right", 11: "sharp-right", 12: "uturn-right",
  13: "uturn-left", 14: "sharp-left", 15: "left", 16: "slight-left",
  17: "straight", 18: "ramp-right", 19: "ramp-left",
  20: "exit-right", 21: "exit-left",
  22: "straight", 23: "keep-right", 24: "keep-left",
  25: "merge", 26: "roundabout", 27: "roundabout-exit",
  28: "ferry", 29: "ferry-exit",
  37: "merge-right", 38: "merge-left",
};

const KINDS = new Set<string>(Object.values(BY_NUMBER));

export function kindOf(m: Maneuver): ManeuverKind {
  if (typeof m.type === "number") return BY_NUMBER[m.type] ?? "straight";
  const t = String(m.type).toLowerCase().replace(/[_ ]/g, "-");
  if (KINDS.has(t)) return t as ManeuverKind;
  // libellés souples (« turn-right », « roundabout »…)
  if (t.includes("roundabout") || t.includes("rotary")) return "roundabout";
  if (t.includes("arrive") || t.includes("destination")) return "arrive";
  if (t.includes("uturn") || t.includes("u-turn")) return "uturn-left";
  const side = t.includes("left") ? "left" : t.includes("right") ? "right" : null;
  if (!side) return "straight";
  if (t.includes("slight")) return `slight-${side}`;
  if (t.includes("sharp")) return `sharp-${side}`;
  return side;
}

export const isArrive = (k: ManeuverKind) => k === "arrive" || k === "arrive-left" || k === "arrive-right";

/** Numéro de sortie d'un rond-point : champ `roundaboutExit` s'il existe, sinon lu dans le texte. */
export function roundaboutExit(m: Maneuver): number | null {
  const extra = (m as Maneuver & { roundaboutExit?: number; roundabout_exit_count?: number });
  const n = extra.roundaboutExit ?? extra.roundabout_exit_count;
  if (typeof n === "number" && n > 0) return n;
  const match = /(\d+)\s*(?:e|è|ème|eme|re|ère|er)\s+sortie/i.exec(m.instruction ?? "");
  return match ? Number(match[1]) : null;
}

const ORDINALS = ["", "première", "deuxième", "troisième", "quatrième", "cinquième", "sixième", "septième", "huitième", "neuvième", "dixième"];
const ordinalWord = (n: number) => ORDINALS[n] ?? `${n}e`;
/** « 1re », « 2e » pour l'affichage. */
export const ordinalShort = (n: number) => (n === 1 ? "1re" : `${n}e`);

/** Premier nom de rue (Valhalla donne parfois « Cours Jean Jaurès/D 528 »). */
export function mainStreet(m: Maneuver | undefined): string {
  const s = (m?.street ?? "").split(/\s*\/\s*|\s*,\s*/)[0]?.trim() ?? "";
  return s;
}

/** « la rue de Paris », « l'avenue Victor Hugo », « le boulevard… », « la D 2009 », « l'A 71 ». */
export function withArticle(name: string): string {
  const n = name.trim();
  if (!n) return "";
  if (/^(la|le|les|l')\s?/i.test(n)) return n.replace(/^(\S)/, (c) => c.toLowerCase());
  const low = n.charAt(0).toLowerCase() + n.slice(1);
  if (/^(rue|route|place|voie|rocade|traverse|petite rue|grande rue|nationale|départementale)\b/i.test(n)) return `la ${low}`;
  if (/^(avenue|allée|impasse|esplanade|autoroute)\b/i.test(n)) return `l'${low}`;
  if (/^(boulevard|chemin|quai|cours|faubourg|pont|rond-point|carrefour|square|passage|sentier|mail|clos|parvis|périphérique)\b/i.test(n)) return `le ${low}`;
  if (/^(A|E)\s?\d/.test(n)) return `l'${n}`;
  if (/^(D|N|RN|RD|M|C|R)\s?\d/.test(n)) return `la ${n}`;
  return n;
}

/** Texte Valhalla nettoyé, utilisable en milieu de phrase (première phrase, minuscule, sans point). */
function cleanInstruction(text: string): string {
  const first = (text || "").split(/(?<=\.)\s+/)[0] ?? "";
  const t = first.replace(/\.$/, "").replace(/\s*\/\s*/g, ", ").trim();
  return t.charAt(0).toLowerCase() + t.slice(1);
}

/**
 * Action à l'impératif, en minuscule, sans distance : « tournez à droite sur la rue de Paris ».
 * Pour les bretelles / sorties / fusions on garde le texte Valhalla (il contient les panneaux).
 */
export function action(m: Maneuver): string {
  const k = kindOf(m);
  const street = mainStreet(m);
  const on = street ? ` sur ${withArticle(street)}` : "";
  switch (k) {
    case "depart": return street ? `suivez ${withArticle(street)}` : "suivez l'itinéraire";
    case "straight": return `continuez tout droit${on}`;
    case "slight-right": return `tournez légèrement à droite${on}`;
    case "right": return `tournez à droite${on}`;
    case "sharp-right": return `tournez fortement à droite${on}`;
    case "slight-left": return `tournez légèrement à gauche${on}`;
    case "left": return `tournez à gauche${on}`;
    case "sharp-left": return `tournez fortement à gauche${on}`;
    case "uturn-left":
    case "uturn-right": return `faites demi-tour${on}`;
    case "keep-right": return m.instruction ? cleanInstruction(m.instruction) : `restez à droite${on}`;
    case "keep-left": return m.instruction ? cleanInstruction(m.instruction) : `restez à gauche${on}`;
    case "ramp-right":
    case "exit-right": return m.instruction ? cleanInstruction(m.instruction) : `prenez la sortie à droite${on}`;
    case "ramp-left":
    case "exit-left": return m.instruction ? cleanInstruction(m.instruction) : `prenez la sortie à gauche${on}`;
    case "merge":
    case "merge-left":
    case "merge-right": return m.instruction ? cleanInstruction(m.instruction) : `insérez-vous${on}`;
    case "roundabout": {
      const n = roundaboutExit(m);
      // la rue de sortie est souvent dans le texte (« … 2e sortie dans Rue Philippe Thomas »)
      const exitStreet = /sortie\s+(?:dans|sur|vers)\s+([^,./]+)/i.exec(m.instruction ?? "")?.[1]?.trim();
      const to = exitStreet ? ` sur ${withArticle(exitStreet)}` : "";
      return n ? `au rond-point, prenez la ${ordinalWord(n)} sortie${to}` : `au rond-point, suivez l'itinéraire${to}`;
    }
    case "roundabout-exit": return `sortez du rond-point${on}`;
    case "ferry": return "prenez le ferry";
    case "ferry-exit": return `débarquez du ferry${on}`;
    case "arrive": return "vous arriverez à destination";
    case "arrive-right": return "vous arriverez à destination, sur la droite";
    case "arrive-left": return "vous arriverez à destination, sur la gauche";
  }
}

/** Libellé court pour l'affichage quand il n'y a pas de nom de rue. */
export function shortLabel(m: Maneuver): string {
  const k = kindOf(m);
  switch (k) {
    case "roundabout": {
      const n = roundaboutExit(m);
      return n ? `${ordinalShort(n)} sortie` : "Rond-point";
    }
    case "roundabout-exit": return "Sortez du rond-point";
    case "arrive": return "Destination";
    case "arrive-right": return "Destination à droite";
    case "arrive-left": return "Destination à gauche";
    default: {
      const a = action({ ...m, street: undefined });
      return a.charAt(0).toUpperCase() + a.slice(1);
    }
  }
}

/** Distance dite à voix haute : « 300 mètres », « 1,5 kilomètre », « 2 kilomètres ». */
export function spokenDistance(m: number): string {
  if (m < 95) return `${Math.max(10, Math.round(m / 10) * 10)} mètres`;
  if (m < 975) return `${Math.round(m / 50) * 50} mètres`;
  const km = Math.round(m / 500) / 2;
  const txt = Number.isInteger(km) ? String(km) : km.toFixed(1).replace(".", ",");
  return `${txt} kilomètre${km >= 2 ? "s" : ""}`;
}

export const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
