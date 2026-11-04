import { colorVar, iconKey, inkOn, PATHS, type Kind } from "./catalog";

/** Pictogramme SVG (trait 2 px, coins ronds). */
export function Icon({ name, size = 24, color = "currentColor", stroke = 2 }: { name: string; size?: number; color?: string; stroke?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={stroke} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={PATHS[name] ?? PATHS.hazard} />
    </svg>
  );
}

/** Pastille ronde de couleur d'état avec le pictogramme du signalement. */
export function KindDisc({ kind, sub, size = 44 }: { kind: Kind; sub?: string | null; size?: number }) {
  const c = colorVar(kind, sub);
  return (
    <span className="reports-disc" style={{ width: size, height: size, background: `var(${c})` }}>
      <Icon name={iconKey(kind, sub)} size={Math.round(size * 0.56)} color={inkOn(c)} />
    </span>
  );
}
