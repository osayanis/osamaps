import type { CSSProperties } from "react";

/** Icônes SVG maison : trait 2 px, coins ronds, `currentColor`. */
const P: Record<string, string> = {
  search: "M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14ZM20 20l-4-4",
  x: "M6 6l12 12M18 6 6 18",
  back: "M15 5l-7 7 7 7",
  chevron: "M9 6l6 6-6 6",
  home: "M4 11.5 12 5l8 6.5M6.5 10v9h11v-9M10 19v-5h4v5",
  work: "M4 8h16v11H4zM9 8V6a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M4 13h16",
  car: "M5 16v2.5M19 16v2.5M4 12.5l1.8-5A2 2 0 0 1 7.7 6h8.6a2 2 0 0 1 1.9 1.5l1.8 5M4 12.5h16V16H4zM7.5 14.2h.01M16.5 14.2h.01",
  star: "M12 4.5l2.3 4.7 5.2.8-3.8 3.6.9 5.2L12 16.4l-4.6 2.4.9-5.2-3.8-3.6 5.2-.8z",
  clock: "M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16ZM12 8v4l2.5 2.5",
  pin: "M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11ZM12 7.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Z",
  address: "M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11ZM12 7.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Z",
  poi: "M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11ZM12 7.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Z",
  street: "M8 4 6 20M16 4l2 16M12 5v2.5M12 11v2.5M12 17v2.5",
  city: "M4 20h16M6 20V9l5-3v14M11 20V4h7v16M14 8h1M14 11h1M14 14h1M8 12h1M8 15h1",
  fuel: "M5 20V6a2 2 0 0 1 2-2h5a2 2 0 0 1 2 2v14M4 20h11M7.5 8h4M14 10h2a1.5 1.5 0 0 1 1.5 1.5V16a1.5 1.5 0 0 0 3 0V8.5L18 6",
  charge: "M13 3 6 13h5l-1 8 7-10h-5z",
  parking: "M5 4h14v16H5zM10 16V8h3a2.5 2.5 0 0 1 0 5h-3",
  truckstop: "M3 6h11v10H3zM14 9.5h3.5L20.5 13v3H14M6.5 18.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3ZM16.5 18.5a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3Z",
  food: "M7 3v8M5 3v5a2 2 0 0 0 4 0V3M7 11v10M16 21V3c-2 1.5-3 4-3 7h3",
  bakery: "M4.5 14.5c-1-3 1.5-7 7.5-7s8.5 4 7.5 7c-.4 1.3-1.8 2-3.2 2H7.7c-1.4 0-2.8-.7-3.2-2ZM9 8.5l1.5 8M15 8.5l-1.5 8",
  cafe: "M5 9h11v5a5 5 0 0 1-5 5h-1a5 5 0 0 1-5-5zM16 10h1.5a2.5 2.5 0 0 1 0 5H16M8.5 3.5v2M12 3.5v2",
  pharmacy: "M10 4h4v6h6v4h-6v6h-4v-6H4v-4h6z",
  shop: "M3.5 5h2l2 10h10l2-7H7M9.5 19.5h.01M16.5 19.5h.01",
  toilets: "M7 6.5h.01M17 6.5h.01M5 10h4l-.5 5H8v5H6v-5h-.5zM15 10h4l1 6h-1.5v4h-3v-4H14zM12 4v16",
  health: "M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17ZM12 8v8M8 12h8",
  train: "M7 4h10a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2ZM5 11h14M9 14h.01M15 14h.01M8 20l1.5-3M16 20l-1.5-3",
  bus: "M6 4h12a1 1 0 0 1 1 1v12H5V5a1 1 0 0 1 1-1ZM5 11h14M8 14h.01M16 14h.01M7 17v2.5M17 17v2.5",
  park: "M12 20v-5M12 15c-3.5 0-6-2-6-5a6 6 0 0 1 12 0c0 3-2.5 5-6 5Z",
  share: "M12 4v11M7.5 8.5 12 4l4.5 4.5M6 13v6h12v-6",
  go: "M5 12h13M13 6l6 6-6 6",
  external: "M14 4h6v6M20 4l-9 9M18 14v5H5V6h5",
  plus: "M12 5v14M5 12h14",
  edit: "M5 19h4L19 9l-4-4L5 15zM13.5 6.5l4 4",
  trash: "M5 7h14M10 7V5h4v2M7 7l1 12h8l1-12",
  locate: "M12 3v3M12 18v3M3 12h3M18 12h3M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10Z",
  copy: "M8 8h11v11H8zM5 15V5h10",
  arrow: "M12 4l6 15-6-3.5L6 19z",
  more: "M6 12h.01M12 12h.01M18 12h.01",
  history: "M4 12a8 8 0 1 0 2.3-5.6M4 4v4h4M12 8v4l3 2",
  map: "M9 5 4 7v12l5-2 6 2 5-2V5l-5 2zM9 5v12M15 7v12",
  check: "M5 12.5 10 17l9-10",
};

const FILLED = new Set(["star-filled", "arrow"]);

export function Icon({ name, size = 20, style, className }: { name: string; size?: number; style?: CSSProperties; className?: string }) {
  const filled = FILLED.has(name);
  const d = P[name.replace("-filled", "")] ?? P.poi;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill={filled ? "currentColor" : "none"}
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      style={style}
      className={className}
    >
      <path d={d} />
    </svg>
  );
}

/** Même icône en chaîne SVG, pour les marqueurs HTML de la carte (hors React). */
export function iconSvg(name: string, size = 16): string {
  const filled = FILLED.has(name);
  const d = P[name.replace("-filled", "")] ?? P.poi;
  return `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="${filled ? "currentColor" : "none"}" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${d}"/></svg>`;
}
