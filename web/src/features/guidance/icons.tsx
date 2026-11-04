import type { ManeuverKind } from "./maneuvers";

/**
 * Icônes du guidage, en SVG (viewBox 48 pour les flèches, 24 pour l'interface).
 * Les flèches sont tracées en `currentColor` : la couleur suit le texte de la carte.
 */
const rad = (d: number) => (d * Math.PI) / 180;
const f = (n: number) => Math.round(n * 10) / 10;

/** Pointe de flèche au point (x, y), orientée selon l'angle `theta` (0 = haut, 90 = droite). */
function head(x: number, y: number, theta: number, size = 8) {
  const back = rad(theta + 180);
  const p = (spread: number) => [x + size * Math.sin(back + rad(spread)), y - size * Math.cos(back + rad(spread))];
  const [a, b] = [p(-42), p(42)];
  return `M${f(a[0])} ${f(a[1])} L${f(x)} ${f(y)} L${f(b[0])} ${f(b[1])}`;
}

/** Flèche de virage : tige verticale puis branche à l'angle `theta`, coin arrondi. */
function turnPaths(theta: number, opts: { pivotY?: number; len?: number; baseX?: number } = {}) {
  if (theta === 0) {
    const x = opts.baseX ?? 24;
    return [`M${x} 43 L${x} 7`, head(x, 7, 0)];
  }
  const s = Math.sin(rad(theta)), c = Math.cos(rad(theta));
  const sharp = Math.abs(theta) > 100;
  const py = opts.pivotY ?? (sharp ? 18 : 24);
  const len = opts.len ?? (sharp ? 15 : 16);
  const px = opts.baseX ?? 24 - 7 * s;
  const r = 6;
  const ex = px + len * s, ey = py - len * c;
  const stem = `M${f(px)} 43 L${f(px)} ${f(py + r)} Q${f(px)} ${f(py)} ${f(px + r * s)} ${f(py - r * c)} L${f(ex)} ${f(ey)}`;
  return [stem, head(ex, ey, theta)];
}

const UTURN_LEFT = ["M31 43 L31 20 A8.5 8.5 0 0 0 14 20 L14 33", head(14, 33, 180)];
const UTURN_RIGHT = ["M17 43 L17 20 A8.5 8.5 0 0 1 34 20 L34 33", head(34, 33, 180)];

interface Shape { main: string[]; dim?: string[] }

function shapeFor(kind: ManeuverKind): Shape {
  switch (kind) {
    case "depart":
    case "straight": return { main: turnPaths(0) };
    case "slight-right": return { main: turnPaths(45) };
    case "right": return { main: turnPaths(90) };
    case "sharp-right": return { main: turnPaths(135) };
    case "slight-left": return { main: turnPaths(-45) };
    case "left": return { main: turnPaths(-90) };
    case "sharp-left": return { main: turnPaths(-135) };
    case "uturn-left": return { main: UTURN_LEFT };
    case "uturn-right": return { main: UTURN_RIGHT };
    case "ramp-right":
    case "exit-right": return { dim: ["M19 43 L19 6"], main: turnPaths(45, { baseX: 19, pivotY: 28, len: 17 }) };
    case "ramp-left":
    case "exit-left": return { dim: ["M29 43 L29 6"], main: turnPaths(-45, { baseX: 29, pivotY: 28, len: 17 }) };
    case "keep-right": return { dim: ["M24 26 L13 8"], main: ["M24 43 L24 26 L35 8", head(35, 8, 31)] };
    case "keep-left": return { dim: ["M24 26 L35 8"], main: ["M24 43 L24 26 L13 8", head(13, 8, -31)] };
    case "merge":
    case "merge-right": return { dim: ["M12 43 Q12 30 24 22"], main: ["M36 43 Q36 30 24 22 L24 7", head(24, 7, 0)] };
    case "merge-left": return { dim: ["M36 43 Q36 30 24 22"], main: ["M12 43 Q12 30 24 22 L24 7", head(24, 7, 0)] };
    default: return { main: turnPaths(0) };
  }
}

export function ManeuverIcon({ kind, exit, size = 64 }: { kind: ManeuverKind; exit?: number | null; size?: number }) {
  const common = { width: size, height: size, viewBox: "0 0 48 48", fill: "none", stroke: "currentColor", strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
  if (kind === "roundabout" || kind === "roundabout-exit") {
    // sens giratoire français (anti-horaire) : on entre par le bas, on tourne par la droite.
    // Le numéro de sortie est écrit en gros à côté (« 2e sortie »), pas dans l'icône : plus lisible.
    const exitOnly = kind === "roundabout-exit";
    return (
      <svg {...common} strokeWidth={4}>
        <circle cx="24" cy="25" r="12" opacity={0.32} />
        <path d="M24 46 L24 37 A12 12 0 0 0 24 13 L24 4" opacity={exitOnly ? 0.32 : 1} />
        <path d={head(24, 4, 0)} />
        {exitOnly && <path d="M24 13 L24 4" />}
      </svg>
    );
  }
  if (kind === "waypoint") {
    return (
      <svg {...common} strokeWidth={3.5}>
        <path d="M14 44 V6" />
        <path d="M14 7 H36 L31 15.5 L36 24 H14" />
      </svg>
    );
  }
  if (kind === "arrive" || kind === "arrive-left" || kind === "arrive-right") {
    return (
      <svg {...common} strokeWidth={3.5}>
        <path d="M24 44 C24 44 11 31 11 20 a13 13 0 0 1 26 0 C37 31 24 44 24 44 Z" />
        <circle cx="24" cy="20" r="4.5" fill="currentColor" stroke="none" />
      </svg>
    );
  }
  if (kind === "ferry" || kind === "ferry-exit") {
    return (
      <svg {...common} strokeWidth={3.5}>
        <path d="M7 30 H41 L36 39 H12 Z" />
        <path d="M14 30 V20 H34 V30" />
        <path d="M24 20 V11" />
      </svg>
    );
  }
  const shape = shapeFor(kind);
  return (
    <svg {...common} strokeWidth={4.5}>
      {shape.dim?.map((d) => <path key={d} d={d} opacity={0.32} />)}
      {shape.main.map((d) => <path key={d} d={d} />)}
    </svg>
  );
}

/** Flèche de voie : « straight », « slight_right », « left », « uturn »… (plusieurs par voie). */
const LANE_ANGLE: Record<string, number> = {
  through: 0, straight: 0, none: 0,
  slight_right: 45, right: 90, sharp_right: 135,
  slight_left: -45, left: -90, sharp_left: -135,
  merge_to_right: 30, merge_to_left: -30,
};

export function LaneIcon({ directions, valid }: { directions: string[]; valid: boolean }) {
  const dirs = directions.length ? directions : ["straight"];
  return (
    <svg width="38" height="38" viewBox="0 0 48 48" fill="none" stroke="currentColor" strokeWidth={5} strokeLinecap="round" strokeLinejoin="round" opacity={valid ? 1 : 0.3} aria-hidden>
      {dirs.map((raw) => {
        const d = raw.toLowerCase().replace(/[\s-]/g, "_");
        const paths = d.includes("uturn") || d === "reverse" ? UTURN_LEFT : turnPaths(LANE_ANGLE[d] ?? 0, { baseX: 24 });
        return paths.map((p) => <path key={raw + p} d={p} />);
      })}
    </svg>
  );
}

/* --- interface (viewBox 24, trait 2) --- */
const ui = (size: number) => ({ width: size, height: size, viewBox: "0 0 24 24", fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true });

export const IconClose = ({ size = 24 }) => <svg {...ui(size)}><path d="M6 6l12 12M18 6L6 18" /></svg>;
export const IconVolume = ({ size = 24 }) => (
  <svg {...ui(size)}><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z" /><path d="M15.5 9a4.2 4.2 0 0 1 0 6" /><path d="M18.3 6.5a8 8 0 0 1 0 11" /></svg>
);
export const IconVolumeOff = ({ size = 24 }) => (
  <svg {...ui(size)}><path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4z" /><path d="M16 9.5l5 5M21 9.5l-5 5" /></svg>
);
/** Vue d'ensemble : un tracé entre deux points. */
export const IconOverview = ({ size = 24 }) => (
  <svg {...ui(size)}><circle cx="6" cy="18" r="2" /><circle cx="18" cy="6" r="2" /><path d="M7.5 16.5C11 14 9 10.5 12 9s3.5-1 4.5-1.5" /></svg>
);
/** Reprendre le suivi : une flèche de navigation. */
export const IconFollow = ({ size = 24 }) => <svg {...ui(size)}><path d="M12 3l7 17-7-4-7 4z" /></svg>;
export const IconFlag = ({ size = 24 }) => <svg {...ui(size)}><path d="M5 21V4" /><path d="M5 4h11l-2 4 2 4H5" /></svg>;
export const IconReroute = ({ size = 24 }) => (
  <svg {...ui(size)}><path d="M20 12a8 8 0 1 1-2.3-5.7" /><path d="M20 4v4.5h-4.5" /></svg>
);

/** Icône d'alerte selon le type (police, accident, bouchon, radar, travaux, météo…). */
export function AlertIcon({ kind, size = 24 }: { kind: string; size?: number }) {
  const k = kind.toLowerCase();
  if (/police|gendarm|control/.test(k)) {
    return <svg {...ui(size)}><path d="M7 17v-5a5 5 0 0 1 10 0v5" /><path d="M5 17h14v3H5z" /><path d="M12 2.5v2M4.5 6l1.4 1.4M19.5 6l-1.4 1.4" /></svg>;
  }
  if (/jam|traffic|bouchon|trafic|slow/.test(k)) {
    return <svg {...ui(size)}><path d="M5 17v-4l2-5h10l2 5v4z" /><path d="M5 13h14" /><circle cx="8" cy="17" r="1.5" /><circle cx="16" cy="17" r="1.5" /></svg>;
  }
  if (/camera|radar|speed/.test(k)) {
    return <svg {...ui(size)}><rect x="3" y="7" width="12" height="10" rx="2" /><path d="M15 11l6-3v8l-6-3" /></svg>;
  }
  if (/closure|closed|ferm|block/.test(k)) {
    return <svg {...ui(size)}><circle cx="12" cy="12" r="9" /><path d="M7.5 12h9" /></svg>;
  }
  if (/work|travaux|construction/.test(k)) {
    return <svg {...ui(size)}><path d="M4 20h16" /><path d="M7 20l4-14h2l4 14" /><path d="M8.5 14h7" /></svg>;
  }
  if (/weather|meteo|météo|rain|fog|ice|verglas|pluie|brouillard/.test(k)) {
    return <svg {...ui(size)}><path d="M7 17a4 4 0 0 1-.6-8A5.5 5.5 0 0 1 17 8.5a3.8 3.8 0 0 1 0 8.5z" /><path d="M9 20v1M13 20v1" /></svg>;
  }
  return <svg {...ui(size)}><path d="M12 3.5L21.5 20h-19z" /><path d="M12 10v4.5M12 17.3v.2" /></svg>;
}
