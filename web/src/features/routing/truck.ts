import type { Vehicle } from "../../core/prefs";

/**
 * Règles poids lourds (France), même logique que ios/…/Routing/RoutingTruck.swift.
 *
 * Vitesses — Code de la route :
 *  R413-8 (PTAC ou PTRA > 3,5 t) : 90 autoroute ; 80 route prioritaire (90 pour ≤ 12 t sur 2×2 à terre-plein
 *  central) ; 80 autres routes (60 pour articulés / avec remorque > 12 t) ; 50 agglomération.
 *  R413-9 (matières dangereuses > 12 t, transports exceptionnels) : 80 autoroute, 60 route, 50 agglomération.
 *  Transports exceptionnels (arrêté du 4 mai 2006, art. 3 et 14) : 2e cat. 40 en agglomération ;
 *  3e cat. (> 25 m, > 4 m ou > 72 t) 60 autoroute, 50 route, 30 agglomération.
 *  Limite affichée = min(limite OSM, maxspeed:hgv, plafond). Approximation : trunk / primary / secondary =
 *  route prioritaire, le reste = « autres routes » ; l'agglomération est portée par la limite OSM (≤ 50).
 *
 * Interdictions > 7,5 t (arrêté du 16 avril 2021 art. 1-2, calendrier 2026 : arrêté du 26 décembre 2025) :
 *  samedi et veille de fête 22-24 h ; dimanche et férié 0-22 h ; samedi férié ou dimanche veille de fête 0-24 h ;
 *  samedis d'été 7-19 h (remplace 22-24 h) ; hiver Auvergne-Rhône-Alpes (axes alpins) 7-18 h + 22-24 h.
 *  Non géré : régime des autoroutes d'Île-de-France (art. 3), fériés d'Alsace-Moselle.
 */

const isTruck = (v: Vehicle) => v.kind !== "car";

export function convoyCategory(v: Vehicle): 1 | 2 | 3 {
  if (v.length > 25 || v.width > 4 || v.weight > 72) return 3;
  if (v.length > 20 || v.width > 3 || v.weight > 48) return 2;
  return 1;
}

/** Vitesse maximale du véhicule (Valhalla top_speed) : limiteur 90 km/h, R413-9 80, convoi 3e cat. 60. */
export function topSpeed(v: Vehicle): number {
  if (v.kind === "car") return 130;
  if (v.kind === "superheavy") return convoyCategory(v) === 3 ? 60 : 80;
  return v.hazmat && v.weight > 12 ? 80 : 90;
}

type Cat = "motorway" | "divided" | "priority" | "other";

function category(rc: string | undefined, car: number | null): Cat {
  switch (rc) {
    case "motorway": return "motorway";
    case "trunk":
    case "primary": return (car ?? 0) >= 100 ? "divided" : "priority";
    case "secondary": return "priority";
    case undefined:
      if (car == null) return "priority";
      return car >= 130 ? "motorway" : car >= 100 ? "divided" : "priority";
    default: return "other";
  }
}

function cap(v: Vehicle, c: Cat): number | null {
  if (!isTruck(v)) return null;
  if (v.kind === "superheavy") {
    if (convoyCategory(v) === 3) return c === "motorway" ? 60 : 50;
    return c === "motorway" ? 80 : 60;
  }
  if (v.hazmat && v.weight > 12) return c === "motorway" ? 80 : 60;
  const light = v.weight <= 12;
  switch (c) {
    case "motorway": return 90;
    case "divided": return light ? 90 : 80;
    case "priority": return 80;
    default: return v.kind === "heavy" && !light ? 60 : 80;
  }
}

/** Limite à afficher pour un tronçon (voiture : la limite OSM telle quelle). */
export function truckLimit(car: number | null, hgv: number | null | undefined, rc: string | undefined, v: Vehicle): number | null {
  if (!isTruck(v)) return car;
  const c = category(rc, car);
  const known = [car, hgv].filter((x): x is number => typeof x === "number");
  let out: number | null = known.length ? Math.min(...known) : null;
  if (out == null && c !== "motorway") return null;
  const k = cap(v, c);
  if (k != null) out = Math.min(out ?? k, k);
  if (v.kind === "superheavy" && out != null && out <= 50 && convoyCategory(v) >= 2) out = Math.min(out, convoyCategory(v) === 3 ? 30 : 40);
  return out;
}

// ——— interdictions de circuler ———————————————————————————————————————————

export const bansApply = (v: Vehicle) => isTruck(v) && v.weight > 7.5;

export interface Ban { start: Date; end: Date; label: string; regional?: string }

const SUMMER: Record<number, [number, number][]> = { 2026: [[7, 11], [7, 18], [7, 25], [8, 1], [8, 8]] };
const WINTER_AURA: Record<number, [number, number][]> = { 2026: [[2, 7], [2, 14], [2, 21], [2, 28], [3, 7]] };

function easter(y: number): [number, number] {
  const a = y % 19, b = Math.floor(y / 100), c = y % 100, d = Math.floor(b / 4), e = b % 4;
  const f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3), h = (19 * a + b - d - g + 15) % 30;
  const i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
  return [Math.floor((h + l - 7 * m + 114) / 31), ((h + l - 7 * m + 114) % 31) + 1];
}

// heure légale française : on raisonne en heure locale de l'appareil (OsaMaps roule en France)
const dayAt = (y: number, m: number, d: number) => new Date(y, m - 1, d);
const addDays = (t: Date, n: number) => new Date(t.getFullYear(), t.getMonth(), t.getDate() + n);
const same = (a: Date, b: Date) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();

export function isHoliday(day: Date): boolean {
  const y = day.getFullYear(), m = day.getMonth() + 1, d = day.getDate();
  const fixed = [[1, 1], [5, 1], [5, 8], [7, 14], [8, 15], [11, 1], [11, 11], [12, 25]];
  if (fixed.some(([fm, fd]) => fm === m && fd === d)) return true;
  const [em, ed] = easter(y);
  const e = dayAt(y, em, ed);
  return [1, 39, 50].some((o) => same(addDays(e, o), day)); // lundi de Pâques, Ascension, lundi de Pentecôte
}

export function dayBans(day: Date): { from: number; to: number; regional?: string }[] {
  const wd = day.getDay(); // 0 = dimanche, 6 = samedi
  const hol = isHoliday(day), nextHol = isHoliday(addDays(day, 1));
  const sat = wd === 6, sun = wd === 0;
  let out: { from: number; to: number; regional?: string }[] = [];
  if ((sat && hol) || (sun && nextHol)) out.push({ from: 0, to: 24 });
  else {
    if (sun || hol) out.push({ from: 0, to: 22 });
    if (sat || nextHol) out.push({ from: 22, to: 24 });
  }
  const y = day.getFullYear(), m = day.getMonth() + 1, d = day.getDate();
  if (!hol && SUMMER[y]?.some(([a, b]) => a === m && b === d)) {
    // samedi d'été : 7 h → 19 h remplace le 22 h → 24 h (art. 2)
    if (!nextHol) out = out.filter((b) => !(b.from === 22 && b.to === 24));
    out.push({ from: 7, to: 19 });
  }
  if (WINTER_AURA[y]?.some(([a, b]) => a === m && b === d)) out.push({ from: 7, to: 18, regional: "certains axes alpins d'Auvergne-Rhône-Alpes" });
  return out;
}

const dayFmt = new Intl.DateTimeFormat("fr-FR", { weekday: "long", day: "numeric", month: "long" });
const h = (t: Date, end: boolean) => {
  const hh = t.getHours(), mm = t.getMinutes();
  if (mm) return `${hh} h ${String(mm).padStart(2, "0")}`;
  return `${end && hh === 0 ? 24 : hh} h`;
};

function label(s: Date, e: Date): string {
  const endDay = new Date(e.getTime() - 1000);
  if (same(s, endDay)) return `${dayFmt.format(s)}, ${h(s, false)} – ${h(e, true)}`;
  return `du ${dayFmt.format(s)} ${h(s, false)} au ${dayFmt.format(endDay)} ${h(e, true)}`;
}

/** Interdictions qui chevauchent le trajet [départ, arrivée] (plages nationales accolées fusionnées). */
export function bansBetween(start: Date, end: Date): Ban[] {
  const raw: { s: Date; e: Date; regional?: string }[] = [];
  for (let day = addDays(new Date(start.getFullYear(), start.getMonth(), start.getDate()), -1); day <= end; day = addDays(day, 1)) {
    for (const b of dayBans(day)) {
      raw.push({ s: new Date(day.getFullYear(), day.getMonth(), day.getDate(), b.from), e: new Date(day.getFullYear(), day.getMonth(), day.getDate(), b.to), regional: b.regional });
    }
  }
  raw.sort((a, b) => a.s.getTime() - b.s.getTime());
  const merged: typeof raw = [];
  for (const r of raw) {
    const last = merged[merged.length - 1];
    if (last && !last.regional && !r.regional && r.s <= last.e) { if (r.e > last.e) last.e = r.e; }
    else merged.push({ ...r });
  }
  return merged.filter((r) => r.s < end && r.e > start).map((r) => ({ start: r.s, end: r.e, label: label(r.s, r.e), regional: r.regional }));
}
