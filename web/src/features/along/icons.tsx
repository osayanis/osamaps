import type { ReactNode } from "react";

/** Icônes SVG simples (trait 2 px, coins ronds), comme le reste de la suite Osa. */
function Svg({ size = 20, children, label }: { size?: number; children: ReactNode; label?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"
      strokeLinecap="round" strokeLinejoin="round" aria-hidden={label ? undefined : true} role={label ? "img" : undefined} aria-label={label}>
      {children}
    </svg>
  );
}
type P = { size?: number };
export const IconFuel = ({ size }: P) => <Svg size={size}><path d="M4 21V5a2 2 0 0 1 2-2h7a2 2 0 0 1 2 2v16" /><path d="M3 21h13" /><path d="M7 8h5" /><path d="M15 11h1.5a1.5 1.5 0 0 1 1.5 1.5V17a1.5 1.5 0 0 0 3 0V8.5L18 6" /></Svg>;
export const IconBolt = ({ size }: P) => <Svg size={size}><path d="M13 2 4 14h7l-1 8 9-12h-7l1-8z" /></Svg>;
export const IconClose = ({ size }: P) => <Svg size={size}><path d="M18 6 6 18M6 6l12 12" /></Svg>;
export const IconGo = ({ size }: P) => <Svg size={size}><path d="m3 11 18-8-8 18-2-8-8-2z" /></Svg>;
export const IconPlus = ({ size }: P) => <Svg size={size}><path d="M12 5v14M5 12h14" /></Svg>;
export const IconChevron = ({ size }: P) => <Svg size={size}><path d="m9 6 6 6-6 6" /></Svg>;
export const IconClock = ({ size }: P) => <Svg size={size}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></Svg>;
export const IconRoad = ({ size }: P) => <Svg size={size}><path d="M5 21 9 3M19 21 15 3M12 5v2M12 11v2M12 17v2" /></Svg>;
export const IconSun = ({ size }: P) => <Svg size={size}><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></Svg>;
export const IconCloud = ({ size }: P) => <Svg size={size}><path d="M7 18h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6.1 9.2 4.5 4.5 0 0 0 7 18z" /></Svg>;
export const IconRain = ({ size }: P) => <Svg size={size}><path d="M7 14h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6.1 5.2 4.5 4.5 0 0 0 7 14z" /><path d="M8 18l-1 3M12 18l-1 3M16 18l-1 3" /></Svg>;
export const IconSnow = ({ size }: P) => <Svg size={size}><path d="M12 2v20M4.9 7l14.2 10M4.9 17 19.1 7" /><path d="m9 4 3 2 3-2M9 20l3-2 3 2" /></Svg>;
export const IconStorm = ({ size }: P) => <Svg size={size}><path d="M7 14h10a4 4 0 0 0 .5-7.97A6 6 0 0 0 6.1 5.2 4.5 4.5 0 0 0 7 14z" /><path d="m12 14-2 4h4l-2 4" /></Svg>;
export const IconFog = ({ size }: P) => <Svg size={size}><path d="M4 9h16M3 13h18M5 17h14M8 21h8" /></Svg>;
export const IconWarn = ({ size }: P) => <Svg size={size}><path d="M10.3 3.9 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" /><path d="M12 9v4M12 17h.01" /></Svg>;

export function WeatherGlyph({ kind, size = 18 }: { kind: "sun" | "cloud" | "rain" | "snow" | "storm" | "fog"; size?: number }) {
  const C = { sun: IconSun, cloud: IconCloud, rain: IconRain, snow: IconSnow, storm: IconStorm, fog: IconFog }[kind];
  return <C size={size} />;
}
