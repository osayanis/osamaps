import type { EventKind } from "./api";

/** Tracés SVG (viewBox 24, trait 2 px, coins ronds) — servent à l'UI ET aux icônes de la carte. */
export const EVENT_GLYPHS: Record<EventKind, string[]> = {
  accident: ["M12 3.5 21.5 20h-19z", "M12 10v4", "M12 17h.01"],
  danger: ["M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z", "M12 7.5v5.5", "M12 16.5h.01"],
  works: ["M10 3.5h4l5 16.5H5z", "M7.6 12h8.8", "M6.4 16.2h11.2"],
  closure: ["M12 3a9 9 0 1 0 0 18 9 9 0 1 0 0-18z", "M7 12h10"],
  lanes: ["M7 21v-7l5-10", "M17 21v-7L12 4", "M12 4v4"],
  jam: ["M4 12h3", "M10.5 12h3", "M17 12h3", "M4 7h16", "M4 17h16"],
  weather: ["M7 16a4 4 0 1 1 .9-7.9A5.5 5.5 0 0 1 18.5 10 3 3 0 0 1 18 16z", "M12 13l-2 4h3l-2 4"],
  flood: ["M3 15c2 0 2-1.5 4.5-1.5S9.5 15 12 15s2-1.5 4.5-1.5S18.5 15 21 15", "M3 19.5c2 0 2-1.5 4.5-1.5s2 1.5 4.5 1.5 2-1.5 4.5-1.5 2 1.5 4.5 1.5", "M12 3v7", "M9 7l3 3 3-3"],
  fuel: ["M5 20V5a1.5 1.5 0 0 1 1.5-1.5h6A1.5 1.5 0 0 1 14 5v15", "M4 20h11", "M14 9h2a2 2 0 0 1 2 2v5a1.5 1.5 0 0 0 3 0V8l-3-3", "M3 3l18 18"],
  hotspot: ["M12 3.5 21.5 20h-19z", "M9 15.5h6", "M12 9v3"],
};

/** Couleur d'état de chaque type (variables de tokens.css). */
export const EVENT_TONE: Record<EventKind, string> = {
  closure: "--jam", jam: "--jam", accident: "--danger", danger: "--danger", weather: "--danger", flood: "--danger", hotspot: "--danger",
  works: "--slow", lanes: "--slow", fuel: "--slow",
};

export const EVENT_LABEL: Record<EventKind, string> = {
  closure: "Route fermée", accident: "Accident", jam: "Bouchon", danger: "Danger", flood: "Vigilance crues", weather: "Vigilance météo",
  lanes: "Voies réduites", works: "Travaux", fuel: "Rupture de carburant", hotspot: "Section accidentogène",
};

export function EventIcon({ kind, size = 20 }: { kind: EventKind; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {(EVENT_GLYPHS[kind] ?? EVENT_GLYPHS.danger).map((d) => <path key={d} d={d} />)}
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
export function eventImage(kind: EventKind, color: string, ratio = 2, severe = false): ImageData {
  const S = (severe ? 34 : 28) * ratio;
  const c = document.createElement("canvas");
  c.width = c.height = S;
  const g = c.getContext("2d")!;
  g.beginPath();
  g.arc(S / 2, S / 2, S / 2 - 1.5 * ratio, 0, Math.PI * 2);
  g.fillStyle = "rgba(14,14,20,0.92)";
  g.fill();
  g.lineWidth = (severe ? 3 : 2.2) * ratio;
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
  for (const d of EVENT_GLYPHS[kind] ?? EVENT_GLYPHS.danger) g.stroke(new Path2D(d));
  g.restore();
  return g.getImageData(0, 0, S, S);
}
