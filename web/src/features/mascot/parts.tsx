import type { ReactNode } from "react";
import type { VehicleKind } from "../../core/prefs";
import { RIDE_COLORS, rideIsLight, type Face, type Glasses, type Hat, type Neck, type Ride } from "./look";

/**
 * Chapeaux, lunettes, détails du cou, expressions et véhicules de la mascotte, en SVG.
 * Mêmes tracés que `MascotDrawing.swift` (iOS) : corps de 100 unités centré sur l'origine.
 */
const INK = "#1b1d24";
const RIM = { stroke: "#fff", strokeOpacity: 0.26, strokeWidth: 1.6, strokeLinejoin: "round" as const };
const R = { strokeLinecap: "round" as const, strokeLinejoin: "round" as const, fill: "none" };

/* ───────── tête ───────── */

export function HatPart({ hat, uid }: { hat: Hat; uid: string }) {
  switch (hat) {
    case "none": return null;
    case "casquette": return (
      <g>
        <path d="M-43 -28 C-43 -66 43 -66 43 -28 Z" fill={INK} {...RIM} />
        <path d="M-46 -31 Q4 -40 56 -30 Q58 -25 52 -24 Q4 -31 -44 -25 Q-50 -27 -46 -31 Z" fill="#2a2d38" {...RIM} />
        <path d="M0 -56 L0 -30" stroke="#fff" strokeOpacity="0.14" strokeWidth="2" />
        <circle cx="0" cy="-56" r="3.4" fill="#fff" fillOpacity="0.85" />
      </g>
    );
    case "bonnet": return (
      <g>
        <path d="M-42 -28 C-44 -64 44 -64 42 -28 Z" fill="#2c2f3a" {...RIM} />
        {[-24, -8, 8, 24].map((x) => <path key={x} d={`M${x} -30 L${x * 0.8} -52`} stroke="#fff" strokeOpacity="0.16" strokeWidth="2.4" {...R} />)}
        <rect x="-46" y="-34" width="92" height="12" rx="6" fill="#3a3e4b" {...RIM} />
        <circle cx="0" cy="-60" r="7" fill="#fefdf7" stroke="#000" strokeOpacity="0.18" strokeWidth="1" />
      </g>
    );
    case "beret": return (
      <g>
        <rect x="-6.5" y="-67" width="5" height="9" rx="2.5" fill="#24262f" />
        <path d="M-47 -33 C-56 -60 24 -72 43 -41 Q-2 -27 -47 -33 Z" fill="#24262f" {...RIM} />
        <path d="M-32 -47 Q-14 -59 10 -59" stroke="#fff" strokeOpacity="0.13" strokeWidth="2.6" {...R} />
      </g>
    );
    case "chapeau": return (
      <g>
        <clipPath id={`${uid}fedora`}><path d="M-31 -36 C-34 -56 -28 -68 -16 -70 Q0 -63 16 -70 C28 -68 34 -56 31 -36 Z" /></clipPath>
        <path d="M-31 -36 C-34 -56 -28 -68 -16 -70 Q0 -63 16 -70 C28 -68 34 -56 31 -36 Z" fill="#2b2e38" {...RIM} />
        <rect x="-40" y="-47" width="80" height="9" fill="#14151a" clipPath={`url(#${uid}fedora)`} />
        <path d="M-21 -62 Q-25 -57 -25 -49" stroke="#fff" strokeOpacity="0.13" strokeWidth="2.6" {...R} />
        <path d="M-60 -33 Q0 -47 60 -33 Q63 -28 55 -27 Q0 -38 -55 -27 Q-63 -28 -60 -33 Z" fill="#363a47" {...RIM} />
      </g>
    );
    case "chantier": return (
      <g>
        <clipPath id={`${uid}hardhat`}><path d="M-42 -30 C-42 -70 42 -70 42 -30 Z" /></clipPath>
        <path d="M-42 -30 C-42 -70 42 -70 42 -30 Z" fill="#ffc21a" />
        <rect x="-6.5" y="-70" width="13" height="42" rx="6.5" fill="#ffd75a" clipPath={`url(#${uid}hardhat)`} />
        <path d="M-42 -30 C-42 -70 42 -70 42 -30 Z" fill="none" stroke={INK} strokeOpacity="0.4" strokeWidth="1.4" />
        <path d="M-31 -44 Q-26 -56 -14 -59" stroke="#fff" strokeOpacity="0.5" strokeWidth="3" {...R} />
        <path d="M-54 -33 Q0 -41 54 -33 L52 -26 Q0 -34 -52 -26 Z" fill="#eca800" stroke={INK} strokeOpacity="0.4" strokeWidth="1.2" />
      </g>
    );
    case "couronne": return (
      <g>
        <path d="M-26 -38 L-30 -62 L-14 -50 L0 -66 L14 -50 L30 -62 L26 -38 Z" fill="#ffcc00" stroke={INK} strokeWidth="2.4" strokeLinejoin="round" />
        <circle cx="0" cy="-47" r="3" fill={INK} fillOpacity="0.8" />
      </g>
    );
  }
}

/* ───────── lunettes ───────── */

export function GlassesPart({ glasses, uid }: { glasses: Glasses; uid: string }) {
  switch (glasses) {
    case "none": return null;
    case "soleil": return (
      <g>
        <path d="M-5 -6 Q0 -9 5 -6" stroke={INK} strokeWidth="2.6" {...R} />
        {[-1, 1].map((s) => (
          <g key={s}>
            <rect x={s * 17 - 11} y="-13" width="22" height="16" rx="7" fill={INK} />
            <path d={`M${s * 17 - 6} -9 L${s * 17 - 1} -9`} stroke="#fff" strokeOpacity="0.55" strokeWidth="2" {...R} />
            <path d={`M${s * 28} -8 L${s * 46} -12`} stroke={INK} strokeWidth="2.6" {...R} />
          </g>
        ))}
      </g>
    );
    case "rondes": return (
      <g>
        <path d="M-5.5 -7 Q0 -11.5 5.5 -7" stroke={INK} strokeWidth="2.2" {...R} />
        {[-1, 1].map((s) => {
          const cx = s * 17;
          // reflet : arc de 200° à 245° (rayon 8)
          const a0 = (200 * Math.PI) / 180, a1 = (245 * Math.PI) / 180;
          return (
            <g key={s}>
              <circle cx={cx} cy="-5" r="11.5" fill="#fff" fillOpacity="0.2" stroke={INK} strokeWidth="2.4" />
              <path d={`M${cx + 8 * Math.cos(a0)} ${-5 + 8 * Math.sin(a0)} A8 8 0 0 1 ${cx + 8 * Math.cos(a1)} ${-5 + 8 * Math.sin(a1)}`}
                stroke="#fff" strokeOpacity="0.85" strokeWidth="2" {...R} />
              <path d={`M${s * 28.5} -7 L${s * 46} -11`} stroke={INK} strokeWidth="2.2" {...R} />
            </g>
          );
        })}
      </g>
    );
    case "aviateur": {
      const lens = "M5 -14 L29 -15 C31.5 -3 27 6 18 6 C9 6 3.5 -3 5 -14 Z";
      return (
        <g>
          <defs>
            <linearGradient id={`${uid}avi`} x1="0" y1="-15" x2="0" y2="6" gradientUnits="userSpaceOnUse">
              <stop offset="0" stopColor="#232733" /><stop offset="1" stopColor="#4a5468" />
            </linearGradient>
          </defs>
          {[1, -1].map((s) => <path key={s} d={lens} transform={`scale(${s} 1)`} fill={`url(#${uid}avi)`} stroke="#b8934a" strokeWidth="1.8" />)}
          {[-1, 1].map((s) => (
            <g key={s}>
              <path d={`M${s * 9} -10 L${s * 15} -10`} stroke="#fff" strokeOpacity="0.4" strokeWidth="1.8" {...R} />
              <path d={`M${s * 29} -14 L${s * 46} -12`} stroke="#b8934a" strokeWidth="1.8" {...R} />
            </g>
          ))}
          <path d="M-5 -13.5 L5 -13.5" stroke="#b8934a" strokeWidth="1.8" {...R} />
          <path d="M-4.5 -8.5 Q0 -10.5 4.5 -8.5" stroke="#b8934a" strokeWidth="1.6" {...R} />
        </g>
      );
    }
    case "carrees": return (
      <g>
        <rect x="-5" y="-9.5" width="10" height="3.2" rx="1.6" fill={INK} />
        {[-1, 1].map((s) => (
          <g key={s}>
            <rect x={s * 17 - 12.5} y="-15" width="25" height="19.5" rx="5.5" fill="#fff" fillOpacity="0.16" stroke={INK} strokeWidth="3.6" />
            <path d={`M${s * 17 - 7} -10 L${s * 17 - 3} -10`} stroke="#fff" strokeOpacity="0.75" strokeWidth="1.8" {...R} />
            <path d={`M${s * 29.5} -9 L${s * 46} -12`} stroke={INK} strokeWidth="3" {...R} />
          </g>
        ))}
      </g>
    );
  }
}

/* ───────── cou ───────── */

function star(cx: number, cy: number, r: number, r2: number) {
  let d = "";
  for (let i = 0; i < 10; i++) {
    const a = (i * Math.PI) / 5 - Math.PI / 2;
    const rad = i % 2 === 0 ? r : r2;
    d += `${i === 0 ? "M" : "L"}${(cx + rad * Math.cos(a)).toFixed(2)} ${(cy + rad * Math.sin(a)).toFixed(2)} `;
  }
  return d + "Z";
}

export function NeckPart({ neck, uid }: { neck: Neck; uid: string }) {
  switch (neck) {
    case "none": return null;
    case "noeud": return (
      <g>
        <path d="M0 33 L-16 24 Q-19 33 -16 42 Z M0 33 L16 24 Q19 33 16 42 Z" fill={INK} />
        <rect x="-4.5" y="28.5" width="9" height="9" rx="3" fill="#2f3240" />
      </g>
    );
    case "echarpe": return (
      <g>
        <path d="M26 24 L34 52 L22 54 L16 26 Z" fill="#c9455c" />
        <path d="M-47 16 Q0 30 47 16 L46 27 Q0 41 -46 27 Z" fill="#e05a70" />
        <path d="M-30 25 L-26 33 M-10 28 L-7 36 M10 28 L7 36 M30 25 L26 33" stroke="#fff" strokeOpacity="0.45" strokeWidth="2.2" {...R} />
      </g>
    );
    case "bandana": return (
      <g>
        <path d="M-25 25 Q0 32 25 25 Q10 38 0 47 Q-10 38 -25 25 Z" fill="#2f63c8" />
        <path d="M-45 18 Q0 32 45 18 L44 25 Q0 39 -44 25 Z" fill="#3a72dc" />
        {[[-30, 23.5], [-14, 28], [14, 28], [30, 23.5], [-7, 35], [7, 35], [0, 41.5]].map(([x, y]) => (
          <circle key={`${x},${y}`} cx={x} cy={y} r="1.7" fill="#fff" fillOpacity="0.8" />
        ))}
      </g>
    );
    case "cravate": return (
      <g>
        <clipPath id={`${uid}tie`}><path d="M-4 27.5 L4 27.5 L7.5 39 L0 45 L-7.5 39 Z" /></clipPath>
        <path d="M-5.5 21 L5.5 21 L4 27.5 L-4 27.5 Z" fill="#26346a" />
        <path d="M-4 27.5 L4 27.5 L7.5 39 L0 45 L-7.5 39 Z" fill="#30448c" />
        <g clipPath={`url(#${uid}tie)`}>
          <path d="M-9 36 L9 30 M-9 43 L9 37" stroke="#fff" strokeOpacity="0.28" strokeWidth="1.8" />
        </g>
      </g>
    );
    case "medaille": return (
      <g>
        <path d="M-15 19 L-7.5 19 L1.5 32 L-3 34 Z" fill="#2e68d2" />
        <path d="M15 19 L7.5 19 L-1.5 32 L3 34 Z" fill="#d63b42" />
        <circle cx="0" cy="36" r="8" fill="#f2c232" stroke="#c2911a" strokeWidth="1.6" />
        <path d={star(0, 36, 4, 1.8)} fill="#c2911a" />
      </g>
    );
  }
}

/* ───────── expressions au repos (« doux » est dessiné par Mascot.tsx) ───────── */

export function FacePart({ face, blink, skin, cheek, uid }: { face: Face; blink: boolean; skin: string; cheek: string; uid: string }) {
  const eye = (cx: number, cy: number, w: number, h: number) => {
    const hh = blink ? h * 0.1 : h;
    return (
      <g key={`${cx},${cy}`}>
        <rect x={cx - w / 2} y={cy - hh / 2} width={w} height={hh} rx={Math.min(w, hh) / 2} fill={INK} />
        {!blink && <circle cx={cx + 1.5} cy={cy - h * 0.175} r={w * 0.19} fill="#fff" fillOpacity="0.92" />}
      </g>
    );
  };
  const big = face === "timide";
  const cheeks = [-1, 1].map((s) => (
    <ellipse key={s} cx={s * 30} cy="10" rx={big ? 10 : 8} ry={big ? 5.5 : 4} fill={cheek} fillOpacity={big ? 0.85 : 0.55} />
  ));
  let rest: ReactNode = null;
  switch (face) {
    case "doux": break;
    case "rieur": {
      const m = "M-10.5 12 Q0 15 10.5 12 C10.5 20 5.5 25 0 25 C-5.5 25 -10.5 20 -10.5 12 Z";
      rest = (
        <>
          {eye(-17, -5, 12, 20)}{eye(17, -5, 12, 20)}
          <clipPath id={`${uid}laugh`}><path d={m} /></clipPath>
          <path d={m} fill={INK} />
          <ellipse cx="0" cy="24" rx="6" ry="4" fill={cheek} clipPath={`url(#${uid}laugh)`} />
        </>
      );
      break;
    }
    case "malin": rest = (
      <>
        {eye(-17, -5, 12, 20)}{eye(17, -5, 12, 20)}
        <path d="M10 -21 Q17 -28.5 25 -22" stroke={INK} strokeWidth="3" {...R} />
        <path d="M-25 -19.5 L-10 -18.5" stroke={INK} strokeWidth="3" {...R} />
        <path d="M-8 16.5 Q3 21.5 11 12.5" stroke={INK} strokeWidth="3.5" {...R} />
      </>
    ); break;
    case "timide": rest = (
      <>
        {eye(-16, -3, 10.5, 14)}{eye(16, -3, 10.5, 14)}
        <path d="M-4.5 16.5 Q0 20 4.5 16.5" stroke={INK} strokeWidth="3" {...R} />
      </>
    ); break;
    case "cool": rest = (
      <>
        {eye(-17, -5, 12, 20)}{eye(17, -5, 12, 20)}
        {[-1, 1].map((s) => (
          <g key={s}>
            <rect x={s * 17 - 8} y="-17.5" width="16" height="12" fill={skin} />
            <path d={`M${s * 17 - 7.5} -5.5 L${s * 17 + 7.5} -5.5`} stroke={INK} strokeWidth="3" {...R} />
          </g>
        ))}
        <path d="M-9 16 Q0 20.5 9 15" stroke={INK} strokeWidth="3.5" {...R} />
      </>
    ); break;
  }
  return <g>{cheeks}{rest}</g>;
}

/* ───────── véhicules (vue de face) ───────── */

const TIRE = "#0c0d11";
const BUMPER = "#2a2d38";
const AMBER = "#ff9f0a";

function paint(ride: Ride) {
  const light = rideIsLight(ride);
  return {
    body: RIDE_COLORS[ride],
    light,
    edge: light ? { stroke: INK, strokeOpacity: 0.4 } : { stroke: "#fff", strokeOpacity: 0.28 },
    hi: light ? { fill: INK, fillOpacity: 0.14 } : { fill: "#fff", fillOpacity: 0.13 },
  };
}

/** La cabine des camions (montants, toit, rétroviseurs…), derrière le corps. Rien pour la voiture. */
export function VehicleBack({ kind, ride, flash, uid }: { kind: VehicleKind; ride: Ride; flash: boolean | null; uid: string }) {
  if (kind === "car") return null;
  const p = paint(ride);
  const markers = kind === "truck" ? [-46, 46] : [-44, -22, 0, 22, 44];
  return (
    <g className="mascot-cab">
      <clipPath id={`${uid}glass`}><rect x="-58" y="-73" width="116" height="96" rx="12" /></clipPath>
      <rect x="-58" y="-73" width="116" height="96" rx="12" fill="#bfd3e6" fillOpacity="0.14" />
      <path d="M-36 -73 L-60 -30" stroke="#fff" strokeOpacity="0.1" strokeWidth="9" clipPath={`url(#${uid}glass)`} />
      {[-1, 1].map((s) => (
        <g key={s}>
          <path d={`M${s * 64} -36 L${s * 76} -40`} stroke={BUMPER} strokeWidth="3" {...R} />
          <rect x={s * 78 - 5} y="-54" width="10" height="25" rx="3.5" fill="#1e2028" stroke="#fff" strokeOpacity="0.2" strokeWidth="1.2" />
          <rect x={s * 61 - 4.5} y="-76" width="9" height="104" rx="4.5" fill={p.body} />
          <rect x={s * 61 - 4.5} y="-76" width="9" height="104" rx="4.5" fill="#000" fillOpacity="0.18" />
        </g>
      ))}
      {kind === "heavy" && (
        <g>
          <path d="M-50 -80 C-46 -101 46 -101 50 -80 Z" fill={p.body} />
          <path d="M-50 -80 C-46 -101 46 -101 50 -80 Z" fill="#000" fillOpacity="0.1" />
          <path d="M-30 -92 L30 -92" stroke={p.hi.fill} strokeOpacity={p.hi.fillOpacity} strokeWidth="2" {...R} />
        </g>
      )}
      <rect x="-69" y="-84" width="138" height="13" rx="6.5" fill={p.body} strokeWidth="1.4" {...p.edge} />
      {markers.map((x) => <rect key={x} x={x - 3.5} y="-79.5" width="7" height="4" rx="2" fill={AMBER} />)}
      {kind === "superheavy" && (
        <g>
          <rect x="-1.5" y="-87" width="3" height="4" fill={BUMPER} />
          <rect x="-46" y="-102" width="92" height="16" rx="3" fill="#ffc400" stroke={INK} strokeWidth="1.6" />
          <text x="0" y="-91.8" textAnchor="middle" fontSize="6" fontWeight="900" fill={INK} fontFamily="system-ui, sans-serif">CONVOI EXCEPTIONNEL</text>
          {[-1, 1].map((s) => {
            const on = flash == null ? true : s < 0 ? flash : !flash;
            const x = s * 57;
            return (
              <g key={s}>
                {on && flash != null && <ellipse cx={x} cy="-94" rx="15" ry="13" fill="#ff8a00" fillOpacity="0.55" className="mascot-glow" />}
                <rect x={x - 7.5} y="-90" width="15" height="6" rx="2" fill={BUMPER} />
                <rect x={x - 6} y="-101" width="12" height="13" rx="6" fill={on ? "#ffa526" : "#b35a00"} />
                <rect x={x - 3.5} y="-98.5" width="3" height="6" rx="1.5" fill="#fff" fillOpacity={on ? 0.75 : 0.25} />
              </g>
            );
          })}
        </g>
      )}
    </g>
  );
}

/** Le devant : coque de la petite voiture, ou calandre de camion. */
export function VehicleFront({ kind, ride, uid }: { kind: VehicleKind; ride: Ride; uid: string }) {
  const p = paint(ride);
  const lampStroke = p.light ? { stroke: INK, strokeOpacity: 0.45, strokeWidth: 1.2 } : {};
  if (kind === "car") {
    return (
      <g className="mascot-kart">
        {[-1, 1].map((s) => <rect key={s} x={s * 46 - 11} y="44" width="22" height="16" rx="6" fill={TIRE} />)}
        <rect x="-62" y="22" width="124" height="32" rx="16" fill={p.body} strokeWidth="1.6" {...p.edge} />
        <rect x="-40" y="27" width="80" height="4" rx="2" {...p.hi} />
        {[-1, 1].map((s) => <circle key={s} cx={s * 44} cy="38" r="5" fill="#fff" fillOpacity="0.95" {...lampStroke} />)}
        <rect x="-14" y="38" width="28" height="7" rx="3.5" fill={p.light ? INK : "#fff"} fillOpacity={p.light ? 0.16 : 0.1} />
      </g>
    );
  }
  const big = kind !== "truck";
  const slats = big ? [34.5, 38.5, 42.5, 46.5] : [36, 40.5, 45];
  const sx = big ? 23 : 18.5;
  return (
    <g className="mascot-kart">
      {[-1, 1].map((s) => <rect key={s} x={s * 52 - 14} y="46" width="28" height="21" rx="7" fill={TIRE} />)}
      <rect x="-66" y="22" width="132" height="35" rx="12" fill={p.body} strokeWidth="1.6" {...p.edge} />
      <rect x="-46" y="26" width="92" height="3" rx="1.5" {...p.hi} />
      {big
        ? <rect x="-28" y="30.5" width="56" height="19.5" rx="4" fill={p.light ? INK : "#000"} fillOpacity={p.light ? 0.78 : 0.42} />
        : <rect x="-23" y="31.5" width="46" height="17" rx="4" fill={p.light ? INK : "#000"} fillOpacity={p.light ? 0.78 : 0.42} />}
      {slats.map((y) => <path key={y} d={`M${-sx} ${y} L${sx} ${y}`} stroke="#fff" strokeOpacity="0.17" strokeWidth="1.6" {...R} />)}
      {[-1, 1].map((s) => (
        <g key={s}>
          <rect x={s * 49 - 9} y="31" width="18" height="9" rx="3.5" fill="#fff" fillOpacity="0.95" {...lampStroke} />
          <rect x={s * 49 - 9} y="42.5" width="18" height="3.5" rx="1.75" fill={AMBER} />
        </g>
      ))}
      {kind === "superheavy" ? (
        <g>
          <clipPath id={`${uid}bumper`}><rect x="-68" y="51.5" width="136" height="9.5" rx="4.75" /></clipPath>
          <g clipPath={`url(#${uid}bumper)`}>
            <rect x="-68" y="51.5" width="136" height="9.5" fill="#fff" fillOpacity="0.92" />
            {Array.from({ length: 12 }, (_, i) => -80 + i * 14).map((x) => (
              <path key={x} d={`M${x} 62 L${x + 7} 62 L${x + 15} 50 L${x + 8} 50 Z`} fill="#e5383b" />
            ))}
          </g>
        </g>
      ) : (
        <rect x="-68" y="51.5" width="136" height="9.5" rx="4.75" fill={BUMPER} />
      )}
    </g>
  );
}
