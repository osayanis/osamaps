import type { ReactNode } from "react";

/** Icônes SVG du module (trait 2 px, coins ronds). */
function Svg({ children, size = 20 }: { children: ReactNode; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2}
      strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">
      {children}
    </svg>
  );
}

export const IconClose = () => <Svg><path d="M6 6l12 12M18 6L6 18" /></Svg>;
export const IconClock = () => <Svg size={18}><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></Svg>;
export const IconPlus = () => <Svg size={18}><path d="M12 5v14M5 12h14" /></Svg>;
export const IconToll = () => <Svg size={16}><circle cx="12" cy="12" r="9" /><path d="M15 8.5a4 4 0 1 0 0 7M7.5 11h6M7.5 13.5h6" /></Svg>;
export const IconHighway = () => <Svg size={18}><path d="M8 3L5 21M16 3l3 18M12 4v3M12 10.5v3M12 17v3" /></Svg>;
export const IconFerry = () => <Svg size={16}><path d="M3 17c1.5 1 3 1 4.5 0s3-1 4.5 0 3 1 4.5 0 3-1 4.5 0M5 14l1-5h12l1 5M9 9V6h6v3" /></Svg>;
export const IconUp = () => <Svg size={18}><path d="M6 15l6-6 6 6" /></Svg>;
export const IconDown = () => <Svg size={18}><path d="M6 9l6 6 6-6" /></Svg>;
export const IconGo = () => <Svg><path d="M12 2.5l7.5 18-7.5-4-7.5 4z" /></Svg>;
export const IconSearch = () => <Svg size={18}><circle cx="11" cy="11" r="6.5" /><path d="M16 16l4.5 4.5" /></Svg>;
export const IconPin = () => <Svg size={18}><path d="M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11z" /><circle cx="12" cy="10" r="2.3" /></Svg>;
export const IconRetry = () => <Svg size={18}><path d="M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7" /></Svg>;
export const IconCheck = () => <Svg size={16}><path d="M5 12.5l4.5 4.5L19 7.5" /></Svg>;
