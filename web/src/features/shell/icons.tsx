import type { ReactNode, SVGProps } from "react";

/** Icônes SVG du shell : trait 2 px, coins ronds, `currentColor`. */
function Svg({ children, size = 22, ...rest }: SVGProps<SVGSVGElement> & { size?: number; children: ReactNode }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false" {...rest}>
      {children}
    </svg>
  );
}

type P = { size?: number; className?: string; style?: React.CSSProperties };

export const IconLocate = (p: P) => (
  <Svg {...p}><path d="M4.5 11.2 19.5 4.5l-6.7 15-1.9-6.9-6.4-1.4Z" /></Svg>
);
export const IconLocateFilled = (p: P) => (
  <Svg {...p}><path d="M4.5 11.2 19.5 4.5l-6.7 15-1.9-6.9-6.4-1.4Z" fill="currentColor" /></Svg>
);
/** Aiguille de boussole : moitié nord pleine (rouge via CSS), moitié sud en trait. */
export const IconCompass = (p: P) => (
  <Svg {...p}>
    <path className="shell-compass-n" d="M12 3.5 15 12H9l3-8.5Z" fill="currentColor" stroke="none" />
    <path d="M9 12h6l-3 8.5L9 12Z" />
  </Svg>
);
export const IconSettings = (p: P) => (
  <Svg {...p}>
    <path d="M4 7h9M17 7h3M4 17h3M11 17h9" />
    <circle cx="15" cy="7" r="2" />
    <circle cx="9" cy="17" r="2" />
  </Svg>
);
export const IconClose = (p: P) => (<Svg {...p}><path d="M6 6l12 12M18 6 6 18" /></Svg>);
export const IconCheck = (p: P) => (<Svg {...p}><path d="m5 12.5 4.5 4.5L19 7.5" /></Svg>);
export const IconInfo = (p: P) => (<Svg {...p}><circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 7.5v.01" /></Svg>);
export const IconWarn = (p: P) => (<Svg {...p}><path d="M12 4 2.8 19.5h18.4L12 4Z" /><path d="M12 10v4M12 17v.01" /></Svg>);
export const IconWifiOff = (p: P) => (
  <Svg {...p}><path d="M3 3l18 18M8.5 16.4a5 5 0 0 1 7 0M5 12.9a10 10 0 0 1 4.2-2.4M19 12.9a10 10 0 0 0-2.1-1.6M2 9.3a15 15 0 0 1 4.5-2.9M22 9.3A15 15 0 0 0 11 5.1M12 20v.01" /></Svg>
);
export const IconWifi = (p: P) => (
  <Svg {...p}><path d="M8.5 16.4a5 5 0 0 1 7 0M5 12.9a10 10 0 0 1 14 0M2 9.3a15 15 0 0 1 20 0M12 20v.01" /></Svg>
);
export const IconRefresh = (p: P) => (
  <Svg {...p}><path d="M20 11a8 8 0 1 0-2.3 5.7M20 5v6h-6" /></Svg>
);
export const IconDownload = (p: P) => (
  <Svg {...p}><path d="M12 4v11M7 10.5l5 5 5-5M5 20h14" /></Svg>
);
/** Partage iOS (carré + flèche vers le haut). */
export const IconShare = (p: P) => (
  <Svg {...p}><path d="M12 3v12M8 7l4-4 4 4M7 11H5.5A1.5 1.5 0 0 0 4 12.5v6A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5v-6a1.5 1.5 0 0 0-1.5-1.5H17" /></Svg>
);
export const IconPlusSquare = (p: P) => (
  <Svg {...p}><rect x="4" y="4" width="16" height="16" rx="4" /><path d="M12 8.5v7M8.5 12h7" /></Svg>
);
export const IconRoute = (p: P) => (
  <Svg {...p}><circle cx="6" cy="18" r="2.2" /><circle cx="18" cy="6" r="2.2" /><path d="M8.2 18H15a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h6.8" /></Svg>
);
export const IconUsers = (p: P) => (
  <Svg {...p}><circle cx="9" cy="8.5" r="3.2" /><path d="M3.5 19a5.5 5.5 0 0 1 11 0M16 5.6a3.2 3.2 0 0 1 0 6.1M17.5 14.2A5.5 5.5 0 0 1 20.5 19" /></Svg>
);
export const IconFlag = (p: P) => (
  <Svg {...p}><path d="M5 21V4.5M5 4.5h11l-2 4 2 4H5" /></Svg>
);
export const IconPin = (p: P) => (
  <Svg {...p}><path d="M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11Z" /><circle cx="12" cy="10" r="2.3" /></Svg>
);
export const IconGauge = (p: P) => (
  <Svg {...p}><path d="M4.2 16.5a8.5 8.5 0 1 1 15.6 0" /><path d="m12 13.5 3.5-4.5" /><circle cx="12" cy="13.5" r="1.2" fill="currentColor" /></Svg>
);
export const IconChevronRight = (p: P) => (<Svg {...p}><path d="m9.5 6 6 6-6 6" /></Svg>);
export const IconChevronLeft = (p: P) => (<Svg {...p}><path d="m14.5 6-6 6 6 6" /></Svg>);
export const IconArrowRight = (p: P) => (<Svg {...p}><path d="M5 12h14M13 6l6 6-6 6" /></Svg>);
export const IconHeart = (p: P) => (
  <Svg {...p}><path d="M12 20s-7.5-4.4-7.5-10A4.3 4.3 0 0 1 12 7.4 4.3 4.3 0 0 1 19.5 10c0 5.6-7.5 10-7.5 10Z" fill="currentColor" stroke="none" /></Svg>
);
export const IconSun = (p: P) => (
  <Svg {...p}><circle cx="12" cy="12" r="4" /><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4" /></Svg>
);
export const IconMoon = (p: P) => (
  <Svg {...p}><path d="M19.5 14.5A8 8 0 0 1 9.5 4.5a8 8 0 1 0 10 10Z" /></Svg>
);
export const IconAuto = (p: P) => (
  <Svg {...p}><circle cx="12" cy="12" r="8" /><path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor" stroke="none" /></Svg>
);
export const IconTrash = (p: P) => (
  <Svg {...p}><path d="M4.5 7h15M10 4h4M6.5 7l.9 12a1.5 1.5 0 0 0 1.5 1.4h6.2a1.5 1.5 0 0 0 1.5-1.4l.9-12M10 11v6M14 11v6" /></Svg>
);
export const IconSparkle = (p: P) => (
  <Svg {...p}><path d="M12 3.5c.6 4.4 2.6 6.4 7 7-4.4.6-6.4 2.6-7 7-.6-4.4-2.6-6.4-7-7 4.4-.6 6.4-2.6 7-7Z" /></Svg>
);
export const IconExternal = (p: P) => (<Svg {...p}><path d="M14 4h6v6M20 4l-9 9M18 14v4.5A1.5 1.5 0 0 1 16.5 20h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10" /></Svg>);

/** Icônes nommées utilisables dans `emit("toast", { icon: "check" })`. */
export const NAMED_ICONS: Record<string, (p: P) => JSX.Element> = {
  check: IconCheck, good: IconCheck, info: IconInfo, warn: IconWarn, warning: IconWarn,
  offline: IconWifiOff, online: IconWifi, refresh: IconRefresh, download: IconDownload,
  share: IconShare, route: IconRoute, users: IconUsers, friends: IconUsers, flag: IconFlag,
  pin: IconPin, speed: IconGauge, locate: IconLocate, sparkle: IconSparkle, trash: IconTrash,
  sun: IconSun, moon: IconMoon, heart: IconHeart,
};

/** Le logo OsaMaps (même dessin que public/icons/osamaps.svg) : une flèche de position en
 *  mouvement, avec sa traînée, sur un pavé arrondi. */
export function OsaMapsMark({ size = 72 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 512 512" aria-hidden="true">
      <rect width="512" height="512" rx="116" fill="#0a0a0f" />
      <rect x="1.5" y="1.5" width="509" height="509" rx="114.5" fill="none" stroke="#fff" strokeOpacity="0.1" strokeWidth="3" />
      <g transform="translate(17 -17)">
        <circle className="shell-mark-dot d1" cx="197" cy="353.9" r="15" fill="#fff" fillOpacity="0.5" />
        <circle className="shell-mark-dot d2" cx="174" cy="393.7" r="11.5" fill="#fff" fillOpacity="0.32" />
        <circle className="shell-mark-dot d3" cx="155" cy="426.6" r="8.5" fill="#fff" fillOpacity="0.18" />
        <path d="M333.5 117.5 L299.1 360.8 L242.5 275.1 L140 269 Z" fill="#fff" stroke="#fff" strokeWidth="10" strokeLinejoin="round" />
      </g>
    </svg>
  );
}
