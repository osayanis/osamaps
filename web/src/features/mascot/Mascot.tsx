import { useEffect, useId, useState } from "react";
import { reducedMotion } from "./motion";

/**
 * La mascotte de la suite Osa, en SVG — reproduction fidèle de `Mascot.swift` (OsaHUB) :
 * corps crème arrondi (largeur w, hauteur 0,92 w, rayon 0,42 w), éclairé en haut à gauche,
 * bras en capsules derrière le corps, pieds ovales, yeux en capsules avec un reflet, joues roses.
 * Toutes les cotes sont celles du Swift avec w = 100 (repère centré sur le cadre 1,6 w × 1,35 h).
 */
export type Mood = "calm" | "curious" | "excited" | "busy" | "happy" | "worried" | "sad" | "sleepy";
export type Arms = "rest" | "up" | "wave";
export type Accessory = "casquette" | "bonnet" | "couronne" | "lunettes" | "echarpe" | "noeud";

export interface MascotProps {
  mood?: Mood;
  arms?: Arms;
  /** Où regarde le visage, de -1 à 1 sur chaque axe (le visage glisse sur le corps). */
  look?: { x: number; y: number };
  /** Largeur rendue en px (le cadre fait 1,6 × cette largeur… recadré selon `crop`). */
  size?: number;
  /** Change → petit saut. */
  hop?: number;
  /** Assise dans sa petite voiture (vue de face). */
  kart?: boolean;
  accessories?: Accessory[];
  /** Cligner des yeux tout seul (désactivé dans les miniatures statiques). */
  blink?: boolean;
  /** "full" : tout le cadre ; "head" : recadré sur le corps (bouton rond). */
  crop?: "full" | "head";
  /** Rebond léger en boucle (en roulant). */
  bounce?: boolean;
  className?: string;
}

const INK = "#1b1d24";
const LIGHT = "#fefdf7";
const SHADE = "#d6cec2";
const FEET_LOW = "#b3ab9e";
const CHEEK = "#ff8096";

/** Arc : sourire (`up` faux) ou œil fermé de joie / bouche triste (`up` vrai), dans un cadre w × h centré. */
function smile(w: number, h: number, up: boolean) {
  const x0 = -w / 2, x1 = w / 2;
  const y = up ? h / 2 : -h / 2;
  const cy = up ? -h / 2 - h : h / 2 + h;
  return `M${x0} ${y} Q0 ${cy} ${x1} ${y}`;
}

export function Mascot({
  mood = "calm", arms = "rest", look = { x: 0, y: 0 }, size = 90, hop = 0, kart = false,
  accessories = [], blink = true, crop = "full", bounce = false, className,
}: MascotProps) {
  const uid = useId().replace(/:/g, "");
  const [blinking, setBlinking] = useState(false);
  const [hopping, setHopping] = useState(false);

  // clignement : toutes les 2,4 à 5 s, 110 ms (comme le Swift)
  useEffect(() => {
    if (!blink || mood === "happy" || mood === "sleepy") return;
    let t: number;
    const loop = () => {
      t = window.setTimeout(() => {
        setBlinking(true);
        t = window.setTimeout(() => { setBlinking(false); loop(); }, 110);
      }, 2400 + Math.random() * 2600);
    };
    loop();
    return () => window.clearTimeout(t);
  }, [blink, mood]);

  useEffect(() => {
    if (!hop || reducedMotion()) return;
    setHopping(false);
    const r = requestAnimationFrame(() => setHopping(true));
    const t = window.setTimeout(() => setHopping(false), 620);
    return () => { cancelAnimationFrame(r); window.clearTimeout(t); };
  }, [hop]);

  const has = (a: Accessory) => accessories.includes(a);
  const out = (side: number) => {
    // 0° = bras qui pend ; rotation autour de l'épaule
    const deg = arms === "up" ? 150 : arms === "wave" ? (side > 0 ? 150 : 18) : kart ? 8 : 18;
    return -side * deg;
  };

  const viewBox = crop === "head" ? "-58 -64 116 116" : "-80 -66 160 128";
  const ratio = crop === "head" ? 1 : 128 / 160;
  const w = crop === "head" ? size : size * 1.6;
  const fx = Math.max(-1, Math.min(1, look.x)) * 5;
  const fy = Math.max(-1, Math.min(1, look.y)) * 3.5;
  const eyeBig = mood === "excited" ? 1.2 : 1;
  const roundEyes = mood === "worried" || mood === "sad";

  return (
    <svg
      className={`mascot-svg${bounce ? " is-bouncing" : ""}${className ? ` ${className}` : ""}`}
      viewBox={viewBox}
      width={w}
      height={w * ratio}
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <radialGradient id={`b${uid}`} gradientUnits="userSpaceOnUse" cx="-15" cy="-20" r="78">
          <stop offset="0" stopColor={LIGHT} />
          <stop offset="0.5" stopColor={LIGHT} />
          <stop offset="1" stopColor={SHADE} />
        </radialGradient>
        <linearGradient id={`a${uid}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={LIGHT} />
          <stop offset="1" stopColor={SHADE} />
        </linearGradient>
        <linearGradient id={`f${uid}`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor={SHADE} />
          <stop offset="1" stopColor={FEET_LOW} />
        </linearGradient>
        <filter id={`s${uid}`} x="-50%" y="-200%" width="200%" height="500%">
          <feGaussianBlur stdDeviation="2.6" />
        </filter>
        <clipPath id={`m${uid}`}><ellipse cx="0" cy="0" rx="7.5" ry="6" /></clipPath>
      </defs>

      {/* ombre au sol (fixe pendant le saut) */}
      <ellipse className="mascot-shadow" cx="0" cy="51.5" rx={kart ? 64 : 42.5} ry="6" fill="#000" opacity="0.5" filter={`url(#s${uid})`} />

      <g className={`mascot-body${hopping ? " is-hopping" : ""}`}>
        <g className="mascot-bob">
          {!kart && [-1, 1].map((s) => (
            <ellipse key={s} cx={s * 20} cy="43.2" rx="12" ry="6.5" fill={`url(#f${uid})`} />
          ))}
          {[-1, 1].map((s) => (
            <g key={s} className="mascot-arm" style={{ transform: `translate(${s * 44}px, 2px) rotate(${out(s)}deg)` }}>
              <rect x="-7.5" y="0" width="15" height="36" rx="7.5" fill={`url(#a${uid})`} />
            </g>
          ))}
          <rect x="-50" y="-46" width="100" height="92" rx="42" fill={`url(#b${uid})`} />
          <rect x="-49.4" y="-45.4" width="98.8" height="90.8" rx="41.4" fill="none" stroke="#fff" strokeOpacity="0.6" strokeWidth="1.1" />
          <rect x="-50" y="-46" width="100" height="92" rx="42" fill="none" stroke="#000" strokeOpacity="0.28" strokeWidth="1.2" />

          {/* visage */}
          <g className="mascot-face" style={{ transform: `translate(${fx}px, ${fy}px)` }}>
            {[-1, 1].map((s) => (
              <g key={s}>
                <g transform={`translate(${s * 17} -5)`}>
                  {mood === "happy" ? (
                    <path d={smile(15, 8, true)} fill="none" stroke={INK} strokeWidth="4.5" strokeLinecap="round" />
                  ) : mood === "sleepy" ? (
                    <path d={smile(14, 5, false)} fill="none" stroke={INK} strokeWidth="4" strokeLinecap="round" />
                  ) : (
                    <g className={`mascot-eye${blinking ? " is-blink" : ""}`}>
                      <rect
                        x={-6 * eyeBig} y={-(roundEyes ? 6.5 : 10) * eyeBig}
                        width={12 * eyeBig} height={(roundEyes ? 13 : 20) * eyeBig}
                        rx={6 * eyeBig} fill={INK}
                      />
                      <circle cx="1.5" cy={-3.5 * eyeBig} r={2.25 * eyeBig} fill="#fff" fillOpacity="0.92" />
                    </g>
                  )}
                </g>
                {roundEyes && (
                  <rect x="-6.5" y="-1.5" width="13" height="3" rx="1.5" fill={INK}
                    transform={`translate(${s * 18} -20) rotate(${s * (mood === "sad" ? 20 : 16)})`} />
                )}
                <ellipse cx={s * 30} cy="10" rx="8" ry="4" fill={CHEEK} fillOpacity="0.55" />
              </g>
            ))}
            <g transform="translate(0 16)">
              {mood === "sad" && <path d={smile(15, 5, true)} fill="none" stroke={INK} strokeWidth="3.5" strokeLinecap="round" />}
              {mood === "worried" && <rect x="-5" y="-1.5" width="10" height="3" rx="1.5" fill={INK} />}
              {mood === "excited" && (
                <g clipPath={`url(#m${uid})`}>
                  <ellipse cx="0" cy="0" rx="7.5" ry="6" fill={INK} />
                  <ellipse cx="0" cy="3" rx="4" ry="2.25" fill={CHEEK} />
                </g>
              )}
              {(mood === "curious" || mood === "busy" || mood === "sleepy") && <circle r={mood === "sleepy" ? 2.6 : 3.5} fill={INK} />}
              {(mood === "calm" || mood === "happy") && (
                <path d={smile(mood === "happy" ? 24 : 18, 7, false)} fill="none" stroke={INK} strokeWidth="3.5" strokeLinecap="round" />
              )}
            </g>
            {has("lunettes") && <Glasses />}
          </g>

          {kart && <Kart />}
          {has("echarpe") && <Scarf />}
          {has("noeud") && <Bow />}
          {has("casquette") && <Cap />}
          {has("bonnet") && <Beanie />}
          {has("couronne") && <Crown />}
        </g>
      </g>
    </svg>
  );
}

/** La petite voiture vue de face : une coque sombre avec deux phares, devant le bas du corps. */
function Kart() {
  return (
    <g className="mascot-kart">
      {[-1, 1].map((s) => <rect key={s} x={s * 46 - 11} y="44" width="22" height="16" rx="6" fill="#0c0d11" />)}
      <rect x="-62" y="22" width="124" height="32" rx="16" fill={INK} stroke="#fff" strokeOpacity="0.28" strokeWidth="1.6" />
      <rect x="-40" y="27" width="80" height="4" rx="2" fill="#fff" fillOpacity="0.12" />
      {[-1, 1].map((s) => <circle key={s} cx={s * 44} cy="38" r="5" fill="#fff" fillOpacity="0.92" />)}
      <rect x="-14" y="38" width="28" height="7" rx="3.5" fill="#fff" fillOpacity="0.1" />
    </g>
  );
}

function Glasses() {
  return (
    <g>
      <path d="M-5 -6 Q0 -9 5 -6" fill="none" stroke={INK} strokeWidth="2.6" strokeLinecap="round" />
      {[-1, 1].map((s) => (
        <g key={s}>
          <rect x={s * 17 - 11} y="-13" width="22" height="16" rx="7" fill={INK} />
          <path d={`M${s * 17 - 6} -9 L${s * 17 - 1} -9`} stroke="#fff" strokeOpacity="0.55" strokeWidth="2" strokeLinecap="round" />
          <path d={`M${s * 28} -8 L${s * 46} -12`} stroke={INK} strokeWidth="2.6" strokeLinecap="round" />
        </g>
      ))}
    </g>
  );
}

function Cap() {
  return (
    <g>
      <path d="M-41 -30 C-41 -58 41 -58 41 -30 Z" fill={INK} />
      <path d="M-46 -31 Q4 -40 56 -30 Q58 -25 52 -24 Q4 -31 -44 -25 Q-50 -27 -46 -31 Z" fill="#2a2d38" />
      <path d="M-36 -36 Q0 -52 36 -36" fill="none" stroke="#fff" strokeOpacity="0.14" strokeWidth="2" />
      <circle cx="0" cy="-50" r="3.2" fill="#fff" fillOpacity="0.85" />
    </g>
  );
}

function Beanie() {
  return (
    <g>
      <path d="M-42 -28 C-44 -64 44 -64 42 -28 Z" fill="#2c2f3a" />
      {[-24, -8, 8, 24].map((x) => <path key={x} d={`M${x} -30 L${x * 0.8} -52`} stroke="#fff" strokeOpacity="0.16" strokeWidth="2.4" strokeLinecap="round" />)}
      <rect x="-46" y="-34" width="92" height="12" rx="6" fill="#3a3e4b" />
      <circle cx="0" cy="-60" r="7" fill={LIGHT} />
    </g>
  );
}

function Crown() {
  return (
    <g>
      <path d="M-26 -38 L-30 -62 L-14 -50 L0 -66 L14 -50 L30 -62 L26 -38 Z" fill="#ffcc00" stroke={INK} strokeWidth="2.4" strokeLinejoin="round" />
      <circle cx="0" cy="-47" r="3" fill={INK} fillOpacity="0.8" />
    </g>
  );
}

function Scarf() {
  return (
    <g>
      <path d="M26 24 L34 52 L22 54 L16 26 Z" fill="#c9455c" />
      <path d="M-47 16 Q0 30 47 16 L46 27 Q0 41 -46 27 Z" fill="#e05a70" />
      <path d="M-30 25 L-26 33 M-10 28 L-7 36 M10 28 L7 36 M30 25 L26 33" stroke="#fff" strokeOpacity="0.45" strokeWidth="2.2" strokeLinecap="round" />
    </g>
  );
}

function Bow() {
  return (
    <g transform="translate(0 33)">
      <path d="M0 0 L-16 -9 Q-19 0 -16 9 Z M0 0 L16 -9 Q19 0 16 9 Z" fill={INK} strokeLinejoin="round" />
      <rect x="-4.5" y="-4.5" width="9" height="9" rx="3" fill="#2f3240" />
    </g>
  );
}
