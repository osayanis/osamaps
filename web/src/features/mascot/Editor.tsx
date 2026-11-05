import { useEffect, useRef, useState, type ReactNode } from "react";
import { useCore } from "../../core/store";
import { usePrefs, VEHICLE_LABELS, type VehicleKind } from "../../core/prefs";
import { Mascot, type Arms, type Mood } from "./Mascot";
import { LockIcon } from "./BadgeIcon";
import {
  HAT_LEVEL, LABELS, LOOK_OPTIONS, MAX_NAME, RIDE_COLORS, displayName, hatUnlocked, randomLook, rideIsLight,
  updateLook, useLook, useShownLook, type Look,
} from "./look";
import { useMascot } from "./engine";

type Tab = "body" | "hat" | "glasses" | "face" | "neck" | "ride";
const TABS: { id: Tab; label: string }[] = [
  { id: "body", label: "Couleur" }, { id: "hat", label: "Tête" }, { id: "glasses", label: "Lunettes" },
  { id: "face", label: "Visage" }, { id: "neck", label: "Cou" }, { id: "ride", label: "Véhicule" },
];

/** Panneau « mascot-editor » : personnaliser sa mascotte, aperçu en direct qui sautille à chaque changement. */
export function MascotEditor() {
  const panel = useCore((s) => s.panel);
  const openPanel = useCore((s) => s.openPanel);
  const look = useLook();
  const shown = useShownLook();
  const points = useMascot((s) => s.points);
  const vehicle = usePrefs((s) => s.vehicle.kind);
  const [tab, setTab] = useState<Tab>(() => (new URLSearchParams(location.search).get("mascotTab") as Tab) || "body");
  const [hop, setHop] = useState(0);
  const [mood, setMood] = useState<Mood>("calm");
  const [arms, setArms] = useState<Arms>("rest");
  const calm = useRef(0);

  useEffect(() => () => window.clearTimeout(calm.current), []);
  if (panel !== "mascot-editor") return null;

  const cheer = (m: Mood, a: Arms, ms: number) => {
    setHop((h) => h + 1);
    setMood(m);
    setArms(a);
    window.clearTimeout(calm.current);
    calm.current = window.setTimeout(() => { setMood("calm"); setArms("rest"); }, ms);
  };
  const pick = (p: Partial<Look>) => { updateLook(p); cheer(tab === "face" ? "calm" : "happy", "rest", 900); };
  const switchTab = (t: Tab) => { if ((tab === "ride") !== (t === "ride")) setHop((h) => h + 1); setTab(t); };

  return (
    <section className="mascot-sheet glass mascot-editor" role="dialog" aria-label="Personnaliser la mascotte">
      <div className="mascot-grabber" aria-hidden="true" />
      <div className="mascot-ed-top">
        <div className={`mascot-ed-title${tab === "ride" && vehicle !== "car" ? " is-hidden" : ""}`}>
          <p className="mascot-eyebrow">Personnaliser</p>
          <h2>Ma mascotte</h2>
        </div>
        <button className="btn-ghost mascot-close" onClick={() => openPanel("profile")} aria-label="Fermer">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
        <button
          className="mascot-ed-stage"
          onClick={() => cheer("happy", "wave", 1400)}
          aria-label={`Aperçu de ${displayName(shown)}, touche pour lui faire coucou`}
        >
          <Mascot size={84} mood={mood} arms={arms} hop={hop} kart={tab === "ride"} style={shown} vehicle={vehicle} />
        </button>
      </div>

      <label className="mascot-ed-name">
        <span className="mascot-sr">Nom de la mascotte</span>
        <input
          value={look.name}
          maxLength={MAX_NAME}
          placeholder="Son nom"
          autoCapitalize="words"
          spellCheck={false}
          onChange={(e) => updateLook({ name: e.target.value })}
          onKeyDown={(e) => { if (e.key === "Enter") (e.target as HTMLInputElement).blur(); }}
        />
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="M4 20h4L19 9l-4-4L4 16v4z" />
        </svg>
      </label>

      <div className="mascot-ed-tabs" role="tablist">
        {TABS.map((t) => (
          <button key={t.id} role="tab" aria-selected={tab === t.id} className={tab === t.id ? "is-on" : ""} onClick={() => switchTab(t.id)}>
            <TabIcon tab={t.id} vehicle={vehicle} />
            <span>{t.label}</span>
          </button>
        ))}
      </div>

      <div className="mascot-ed-options" key={tab}>
        {tab === "ride" ? (
          <RidePicker vehicle={vehicle} ride={look.ride} onPick={(ride) => pick({ ride })} />
        ) : (
          <ul className="mascot-ed-grid">
            {(LOOK_OPTIONS[tab] as readonly string[]).map((v) => {
              const on = look[tab] === v;
              const need = tab === "hat" && !hatUnlocked(v as Look["hat"], points) ? HAT_LEVEL[v as Look["hat"]] : undefined;
              const label = (LABELS[tab] as Record<string, string>)[v];
              return (
                <li key={v}>
                  <button
                    className={`mascot-ed-tile${on ? " is-on" : ""}${need ? " is-locked" : ""}`}
                    aria-pressed={on}
                    aria-label={need ? `${label}, à débloquer au niveau ${need}` : label}
                    disabled={!!need}
                    onClick={() => { if (!on) pick({ [tab]: v } as Partial<Look>); }}
                  >
                    <Mascot size={52} crop="head" blink={false} style={{ ...look, [tab]: v }} />
                    {need ? <span className="mascot-ed-lock"><LockIcon size={11} /> Niveau {need}</span> : <strong>{label}</strong>}
                  </button>
                </li>
              );
            })}
          </ul>
        )}
      </div>

      <div className="mascot-actions">
        <button className="pill secondary" onClick={() => { randomLook(); cheer("excited", "up", 1100); }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinejoin="round" aria-hidden="true">
            <rect x="3.5" y="3.5" width="17" height="17" rx="4" />
            <g fill="currentColor" stroke="none"><circle cx="8.5" cy="8.5" r="1.5" /><circle cx="15.5" cy="15.5" r="1.5" /><circle cx="15.5" cy="8.5" r="1.5" /><circle cx="8.5" cy="15.5" r="1.5" /><circle cx="12" cy="12" r="1.5" /></g>
          </svg>
          Au hasard
        </button>
        <button className="pill" onClick={() => openPanel(null)}>Terminé</button>
      </div>
    </section>
  );
}

function RidePicker({ vehicle, ride, onPick }: { vehicle: VehicleKind; ride: Look["ride"]; onPick: (r: Look["ride"]) => void }) {
  return (
    <div className="mascot-ed-ride">
      <div className="mascot-ed-ride-info">
        <span className="mascot-ed-ride-icon"><TabIcon tab="ride" vehicle={vehicle} /></span>
        <div>
          <strong>{LABELS.ride[ride]}</strong>
          <span className="mascot-dim"> · {vehicle === "car" ? "sa petite voiture" : `ton ${VEHICLE_LABELS[vehicle].label.toLowerCase()}`}</span>
          <small>Le type de véhicule se change dans les Réglages.</small>
        </div>
      </div>
      <div className="mascot-ed-swatches" role="radiogroup" aria-label="Couleur du véhicule">
        {LOOK_OPTIONS.ride.map((r) => (
          <button
            key={r}
            role="radio"
            aria-checked={r === ride}
            aria-label={LABELS.ride[r]}
            className={`mascot-ed-swatch${r === ride ? " is-on" : ""}${rideIsLight(r) ? " is-light" : ""}`}
            style={{ ["--swatch" as string]: RIDE_COLORS[r] }}
            onClick={() => { if (r !== ride) onPick(r); }}
          >
            <i />
          </button>
        ))}
      </div>
    </div>
  );
}

/** Icônes des onglets (trait 2 px, coins ronds). */
function TabIcon({ tab, vehicle }: { tab: Tab; vehicle: VehicleKind }) {
  const paths: Record<Tab, ReactNode> = {
    body: <><path d="M12 3a9 9 0 1 0 0 18c1.4 0 2-1 2-2s-1-1.6-1-2.6c0-1 .8-1.4 1.8-1.4H17a4 4 0 0 0 4-4c0-4.4-4-8-9-8z" /><circle cx="7.5" cy="11" r="1.2" fill="currentColor" /><circle cx="10" cy="7" r="1.2" fill="currentColor" /><circle cx="15" cy="7.5" r="1.2" fill="currentColor" /></>,
    hat: <path d="M4 18h16M5 18l-1.5-9 5 4L12 6l3.5 7 5-4L19 18" />,
    glasses: <><circle cx="6.5" cy="14" r="3.5" /><circle cx="17.5" cy="14" r="3.5" /><path d="M10 13.5c1.3-1 2.7-1 4 0M3 14l1-6M21 14l-1-6" /></>,
    face: <><circle cx="12" cy="12" r="9" /><path d="M8.5 14.5c1.8 2 5.2 2 7 0" /><circle cx="9" cy="10" r="1" fill="currentColor" /><circle cx="15" cy="10" r="1" fill="currentColor" /></>,
    neck: <path d="M8 4 4 6.5l2 4 2-1V20h8V9.5l2 1 2-4L16 4c-.5 1.5-2 2.5-4 2.5S8.5 5.5 8 4z" />,
    ride: vehicle === "car"
      ? <><path d="M4 16v-3l2-5h12l2 5v3zM4 16v2M20 16v2" /><circle cx="8" cy="13.5" r="1" fill="currentColor" /><circle cx="16" cy="13.5" r="1" fill="currentColor" /></>
      : <><path d="M3 6h11v10H3zM14 9h4l3 3.5V16h-7z" /><circle cx="7" cy="17.5" r="1.8" /><circle cx="17" cy="17.5" r="1.8" /></>,
  };
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      {paths[tab]}
    </svg>
  );
}
