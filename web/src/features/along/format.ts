import type { FuelKey } from "./prefs";
import type { FuelStation } from "./api";

/** Un prix est « frais » s'il a été mis à jour il y a moins de 10 jours (sinon on ne le met pas en avant). */
export const FRESH_MS = 10 * 24 * 3600_000;

export const price3 = (p: number) => p.toFixed(3).replace(".", ",");
export const euros = (v: number) => `${v < 10 ? v.toFixed(2).replace(".", ",") : Math.round(v)} €`;

export function isFresh(maj: string | null | undefined, now = Date.now()) {
  if (!maj) return false;
  const t = Date.parse(maj);
  return Number.isFinite(t) && now - t < FRESH_MS;
}

/** Prix utilisable pour mon carburant (présent, frais, pas en rupture). */
export function usablePrice(s: FuelStation, fuel: FuelKey, now = Date.now()): number | null {
  const pr = s.prices[fuel];
  if (!pr || s.shortage.includes(fuel) || !isFresh(pr.maj, now)) return null;
  return pr.p;
}

/** « à l'instant », « il y a 25 min », « il y a 2 h », « il y a 3 j », « il y a 4 mois ». */
export function ago(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "date inconnue";
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return "date inconnue";
  const min = Math.max(0, Math.round((now - t) / 60_000));
  if (min < 2) return "à l'instant";
  if (min < 60) return `il y a ${min} min`;
  const h = Math.round(min / 60);
  if (h < 24) return `il y a ${h} h`;
  const d = Math.round(h / 24);
  if (d < 45) return `il y a ${d} j`;
  return `il y a ${Math.round(d / 30)} mois`;
}

/** État d'ouverture d'une station à l'instant : « Ouvert 24 h/24 », « Ouvert jusqu'à 19:00 »… */
export function openState(s: FuelStation, now = new Date()): { open: boolean | null; text: string } {
  const day = (now.getDay() + 6) % 7; // lundi = 0
  const today = s.hours?.[day];
  const hm = `${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")}`;
  if (today && today.length) {
    const slot = today.find(([o, f]) => o <= hm && hm < f);
    if (slot) return { open: true, text: `Ouvert jusqu'à ${slot[1]}${s.h24 ? " · automate 24 h/24" : ""}` };
    if (s.h24) return { open: true, text: "Boutique fermée · automate 24 h/24" };
    const next = today.find(([o]) => o > hm);
    return { open: false, text: next ? `Fermé · ouvre à ${next[0]}` : "Fermé pour aujourd'hui" };
  }
  if (today && !today.length) return s.h24 ? { open: true, text: "Automate 24 h/24 (boutique fermée)" } : { open: false, text: "Fermé aujourd'hui" };
  if (s.h24) return { open: true, text: "Automate 24 h/24" };
  return { open: null, text: "Horaires non communiqués" };
}

export const DAY_SHORT = ["Lun", "Mar", "Mer", "Jeu", "Ven", "Sam", "Dim"];
