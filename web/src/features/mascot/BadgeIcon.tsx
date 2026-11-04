import type { BadgeIcon as Kind } from "./data";

/** Icônes de badges : SVG simples, trait 2 px, coins ronds. */
const PATHS: Record<Kind, string> = {
  flag: "M6 21V4 M6 4h10l-2 4 2 4H6",
  wheel: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18 M12 9a3 3 0 1 0 0 6a3 3 0 1 0 0-6 M3.5 10.5l5.6.9 M20.5 10.5l-5.6.9 M12 15v5.8",
  gauge: "M4 17a8 8 0 1 1 16 0 M12 17l4-5 M7 17h.01 M17 17h.01",
  globe: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18 M3 12h18 M12 3c3 3.2 3 14.8 0 18 M12 3c-3 3.2-3 14.8 0 18",
  road: "M8 3L4 21 M16 3l4 18 M12 4v3 M12 10.5v3 M12 17v3",
  moon: "M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z",
  sunrise: "M3 18h18 M7 18a5 5 0 0 1 10 0 M12 4v4 M5.6 9.6l1.8 1.8 M18.4 9.6l-1.8 1.8 M9 6l3-2 3 2",
  megaphone: "M4 10v4h3l7 4V6L7 10H4z M17.5 9a4 4 0 0 1 0 6",
  check: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18 M8 12.5l2.7 2.7L16 9.8",
  compass: "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18 M15.5 8.5l-2 5-5 2 2-5z",
  calendar: "M5 5h14v15H5z M5 10h14 M9 3v4 M15 3v4 M9 14l2 2 4-4",
};

export function BadgeIcon({ icon, size = 22 }: { icon: Kind; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={PATHS[icon]} />
    </svg>
  );
}

export function LockIcon({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M6 11h12v9H6z M8.5 11V8a3.5 3.5 0 0 1 7 0v3" />
    </svg>
  );
}
