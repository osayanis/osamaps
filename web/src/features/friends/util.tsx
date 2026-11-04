import type { ReactNode } from "react";
import type { LngLat } from "../../core/store";
import { EXTERNAL } from "../../core/services";
import type { Friend } from "./store";

/** « YB » pour « Yanis B. », « ? » sans pseudo. */
export function initials(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return "?";
  const s = parts.length === 1 ? [...parts[0]][0] : [...parts[0]][0] + [...parts[1]][0];
  return s.toUpperCase();
}

/** « 18 h 42 ». */
export function clock(ms: number): string {
  const d = new Date(ms);
  return `${d.getHours()} h ${String(d.getMinutes()).padStart(2, "0")}`;
}

/** « 482 913 ». */
export const prettyCode = (c: string) => `${c.slice(0, 3)} ${c.slice(3)}`;

/** Ligne de statut d'un ami : « En route vers Vichy · arrivée 18 h 42 », « En ligne », … */
export function statusLine(f: Friend): string {
  const d = f.loc?.drive;
  if (d) {
    const to = d.to ? `En route vers ${d.to}` : "En route";
    return d.eta ? `${to} · arrivée ${clock(d.eta)}` : to;
  }
  if (f.loc) return f.online ? "En ligne · position partagée" : "Position partagée";
  return f.online ? "En ligne" : "Hors ligne";
}

/** Point milieu sur le grand cercle. */
export function midpoint(a: LngLat, b: LngLat): LngLat {
  const r = Math.PI / 180;
  const [l1, p1] = [a[0] * r, a[1] * r];
  const [l2, p2] = [b[0] * r, b[1] * r];
  const bx = Math.cos(p2) * Math.cos(l2 - l1);
  const by = Math.cos(p2) * Math.sin(l2 - l1);
  const p = Math.atan2(Math.sin(p1) + Math.sin(p2), Math.sqrt((Math.cos(p1) + bx) ** 2 + by ** 2));
  const l = l1 + Math.atan2(by, Math.cos(p1) + bx);
  return [l / r, p / r];
}

/** Nom d'un point par géocodage inverse IGN (« Saint-Pourçain-sur-Sioule »). */
export async function reverseName(p: LngLat): Promise<string | null> {
  try {
    const r = await fetch(`${EXTERNAL.geocodeFr}/reverse?lat=${p[1]}&lon=${p[0]}&limit=1`);
    if (!r.ok) return null;
    const j = await r.json();
    const pr = j?.features?.[0]?.properties;
    return pr?.city ?? pr?.label ?? null;
  } catch {
    return null;
  }
}

/* --- icônes (trait 2 px, coins ronds) ------------------------------------------------------ */
type P = { size?: number };
const svg = (size: number, children: ReactNode) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{children}</svg>
);
export const IconFriends = ({ size = 22 }: P) => svg(size, <><circle cx="9" cy="8" r="3.5" /><path d="M2.5 20c.8-3.6 3.4-5.5 6.5-5.5s5.7 1.9 6.5 5.5" /><path d="M15.5 4.8a3.5 3.5 0 0 1 0 6.4" /><path d="M18 14.8c1.8.7 3 2.4 3.5 5.2" /></>);
export const IconShare = ({ size = 22 }: P) => svg(size, <><path d="M12 15V3" /><path d="m7 8 5-5 5 5" /><path d="M5 12v7a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7" /></>);
export const IconClose = ({ size = 20 }: P) => svg(size, <><path d="M6 6l12 12" /><path d="M18 6 6 18" /></>);
export const IconBack = ({ size = 20 }: P) => svg(size, <path d="m15 18-6-6 6-6" />);
export const IconChevron = ({ size = 18 }: P) => svg(size, <path d="m9 18 6-6-6-6" />);
export const IconCopy = ({ size = 18 }: P) => svg(size, <><rect x="9" y="9" width="12" height="12" rx="2.5" /><path d="M5 15H4a1 1 0 0 1-1-1V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v1" /></>);
export const IconCheck = ({ size = 18 }: P) => svg(size, <path d="M4.5 12.5 9.5 17.5 19.5 6.5" />);
export const IconPin = ({ size = 18 }: P) => svg(size, <><path d="M12 21s-7-6.1-7-11.5A7 7 0 0 1 19 9.5C19 14.9 12 21 12 21z" /><circle cx="12" cy="9.5" r="2.5" /></>);
export const IconMeet = ({ size = 18 }: P) => svg(size, <><circle cx="5" cy="12" r="2" /><circle cx="19" cy="12" r="2" /><path d="M7 12h3" /><path d="M14 12h3" /><circle cx="12" cy="12" r="1" fill="currentColor" /></>);
export const IconNav = ({ size = 18 }: P) => svg(size, <path d="M3 11 21 3l-8 18-2-8-8-2z" />);
export const IconLock = ({ size = 16 }: P) => svg(size, <><rect x="4.5" y="10.5" width="15" height="10" rx="2.5" /><path d="M8 10.5V7.5a4 4 0 0 1 8 0v3" /></>);
export const IconCar = ({ size = 18 }: P) => svg(size, <><path d="M5 16V11l2-5h10l2 5v5" /><path d="M3 16h18v3H3z" /><circle cx="7.5" cy="13" r=".5" fill="currentColor" /><circle cx="16.5" cy="13" r=".5" fill="currentColor" /></>);
