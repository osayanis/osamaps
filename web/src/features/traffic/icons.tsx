import type { EventKind } from "./api";

/** Tracés SVG (viewBox 24, trait 2 px, coins ronds) — servent à l'UI ET aux icônes de la carte. */
export const EVENT_GLYPHS: Record<EventKind, string[]> = {
  accident: ["M12 3.5 21.5 20h-19z", "M12 10v4", "M12 17h.01"],
  obstacle: ["M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z", "M12 7.5v5.5", "M12 16.5h.01"],
  works: ["M10 3.5h4l5 16.5H5z", "M7.6 12h8.8", "M6.4 16.2h11.2"],
  closure: ["M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z", "M7 12h10"],
  lanes: ["M7 21v-7l5-10", "M17 21v-7L12 4", "M12 4v4"],
  slow: ["M4 12h3", "M10.5 12h3", "M17 12h3", "M4 7h16", "M4 17h16"],
  conditions: ["M12 3v18", "M4.2 7.5l15.6 9", "M4.2 16.5l15.6-9"],
};

/** Couleur d'état de chaque type (variables de tokens.css). */
export const EVENT_TONE: Record<EventKind, string> = {
  closure: "--jam", slow: "--jam", accident: "--danger", obstacle: "--danger", conditions: "--danger", works: "--slow", lanes: "--slow",
};

export function EventIcon({ kind, size = 20 }: { kind: EventKind; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {(EVENT_GLYPHS[kind] ?? EVENT_GLYPHS.obstacle).map((d) => <path key={d} d={d} />)}
    </svg>
  );
}

export function TrafficLightIcon({ size = 22 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <rect x="7" y="2.5" width="10" height="19" rx="3" />
      <circle cx="12" cy="7.5" r="1.4" />
      <circle cx="12" cy="12" r="1.4" />
      <circle cx="12" cy="16.5" r="1.4" />
    </svg>
  );
}

export function GaugeIcon({ size = 18 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M4 17a8 8 0 1 1 16 0" />
      <path d="M12 17l4-5" />
    </svg>
  );
}

/** Dessine une icône d'évènement pour la carte (pastille sombre, anneau de couleur d'état). */
export function eventImage(kind: EventKind, color: string, ratio = 2): ImageData {
  const S = 30 * ratio;
  const c = document.createElement("canvas");
  c.width = c.height = S;
  const g = c.getContext("2d")!;
  g.beginPath();
  g.arc(S / 2, S / 2, S / 2 - 1.5 * ratio, 0, Math.PI * 2);
  g.fillStyle = "rgba(14,14,20,0.92)";
  g.fill();
  g.lineWidth = 2.5 * ratio;
  g.strokeStyle = color;
  g.stroke();
  const k = (S * 0.56) / 24;
  g.save();
  g.translate(S / 2 - 12 * k, S / 2 - 12 * k);
  g.scale(k, k);
  g.strokeStyle = "#fff";
  g.lineWidth = 2.2;
  g.lineCap = "round";
  g.lineJoin = "round";
  for (const d of EVENT_GLYPHS[kind] ?? EVENT_GLYPHS.obstacle) g.stroke(new Path2D(d));
  g.restore();
  return g.getImageData(0, 0, S, S);
}
