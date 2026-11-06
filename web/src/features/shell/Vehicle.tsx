import { useEffect, useState } from "react";
import { create } from "zustand";
import { usePrefs, vehiclePreset, VEHICLE_LABELS, type Vehicle, type VehicleKind } from "../../core/prefs";
import { core, useCore } from "../../core/store";
import { emit } from "../../core/bus";
import { haptic } from "./haptics";
import { Switch } from "./Onboarding";
import { IconChevronRight, IconClose, IconChevronLeft, IconRefresh } from "./icons";

/**
 * Profil véhicule côté shell : « Tu conduis quoi ? » (accueil, ou une fois en feuille pour ceux qui avaient
 * déjà passé l'accueil), dimensions des camions, section « Véhicule » des réglages, badge du mode camion.
 * Tout est lu / écrit dans usePrefs.vehicle. Tests : ?vehicle=heavy (choisi), ?vehicleSheet=1 (feuille).
 */

export const useVehicleSheet = create<{ open: boolean }>(() => ({
  open: new URLSearchParams(location.search).has("vehicleSheet"),
}));
const openSheet = () => useVehicleSheet.setState({ open: true });

/** ?vehicle=heavy : profil de test (considéré comme choisi). */
export function applyVehicleParam() {
  const k = new URLSearchParams(location.search).get("vehicle") as VehicleKind | null;
  if (k && k in VEHICLE_LABELS) {
    const { setPref, vehicle } = usePrefs.getState();
    if (vehicle.kind !== k) setPref("vehicle", vehiclePreset(k));
    setPref("vehicleChosen", true);
  }
}

// ——— pictogrammes (trait 2 px) ————————————————————————————————————————————

function Pic({ kind, size = 34 }: { kind: VehicleKind; size?: number }) {
  const common = { width: size, height: size, viewBox: "0 0 32 32", fill: "none", stroke: "currentColor", strokeWidth: 2, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
  switch (kind) {
    case "car":
      return <svg {...common}><path d="M5 20v-4l2.6-5.2A2 2 0 0 1 9.4 9.6h13.2a2 2 0 0 1 1.8 1.2L27 16v4" /><path d="M4 20h24v3H4z" /><circle cx="9.5" cy="23.5" r="2" /><circle cx="22.5" cy="23.5" r="2" /><path d="M8 16h16" /></svg>;
    case "truck":
      return <svg {...common}><path d="M3 8h15v14H3z" /><path d="M18 13h6l4 5v4H18" /><circle cx="8" cy="23.5" r="2.2" /><circle cx="23" cy="23.5" r="2.2" /></svg>;
    case "heavy":
      return <svg {...common}><path d="M2 9h19v12H2z" /><path d="M21 13h5l4 4v4h-9" /><circle cx="6" cy="23.5" r="2" /><circle cx="11" cy="23.5" r="2" /><circle cx="25" cy="23.5" r="2" /></svg>;
    default:
      return <svg {...common}><path d="M1 15h20v6H1z" /><path d="M5 15v-4h10v4" /><path d="M21 12h5l4 4v5h-9" /><circle cx="5" cy="23.5" r="2" /><circle cx="10" cy="23.5" r="2" /><circle cx="15" cy="23.5" r="2" /><circle cx="25" cy="23.5" r="2" /></svg>;
  }
}

const PHRASE: Record<VehicleKind, string> = {
  car: "Voiture, moto ou utilitaire jusqu’à 3,5 t.",
  truck: "Porteur jusqu’à 19 t : livraisons, BTP, déménagement.",
  heavy: "Semi-remorque jusqu’à 44 t, la route au long cours.",
  superheavy: "Convoi exceptionnel, plus de 44 t ou hors gabarit.",
};

const num = (v: number) => v.toLocaleString("fr-FR", { maximumFractionDigits: 2 });
export const vehicleSummary = (v: Vehicle) =>
  v.kind === "car" ? "Voiture" : `${VEHICLE_LABELS[v.kind].label} · ${num(v.height)} m · ${num(v.weight)} t${v.hazmat ? " · ADR" : ""}`;

// ——— grille des quatre catégories ——————————————————————————————————————————

export function KindGrid({ vehicle, onChange }: { vehicle: Vehicle; onChange: (v: Vehicle) => void }) {
  const kinds: VehicleKind[] = ["car", "truck", "heavy", "superheavy"];
  return (
    <div className="shell-veh-grid" role="radiogroup" aria-label="Ton véhicule">
      {kinds.map((k) => {
        const on = vehicle.kind === k;
        return (
          <button key={k} role="radio" aria-checked={on} className={`shell-veh-card${on ? " on" : ""}`}
            onClick={() => { if (!on) { haptic("tap"); onChange(vehiclePreset(k)); } }}>
            <span className="shell-veh-pic"><Pic kind={k} /></span>
            <b>{VEHICLE_LABELS[k].label}</b>
            <small>{PHRASE[k]}</small>
          </button>
        );
      })}
    </div>
  );
}

// ——— dimensions ——————————————————————————————————————————————————————————

type Key = "height" | "width" | "length" | "weight" | "axleLoad";
const ROWS: { key: Key; label: string; hint?: string; step: number; min: number; max: number; unit: "m" | "t" }[] = [
  { key: "height", label: "Hauteur", hint: "Ponts et tunnels bas évités.", step: 0.05, min: 2, max: 6, unit: "m" },
  { key: "width", label: "Largeur", step: 0.05, min: 1.8, max: 6, unit: "m" },
  { key: "length", label: "Longueur", step: 0.5, min: 4, max: 50, unit: "m" },
  { key: "weight", label: "Poids total", hint: "En charge (PTAC ou PTRA).", step: 1, min: 3.5, max: 250, unit: "t" },
  { key: "axleLoad", label: "Charge à l’essieu", step: 0.5, min: 1, max: 20, unit: "t" },
];

export function Dimensions({ vehicle, onChange }: { vehicle: Vehicle; onChange: (v: Vehicle) => void }) {
  const set = (r: (typeof ROWS)[number], value: number) => {
    const v = Math.round(Math.min(r.max, Math.max(r.min, Math.round(value / r.step) * r.step)) * 100) / 100;
    haptic("tap");
    onChange({ ...vehicle, [r.key]: v });
  };
  const preset = vehiclePreset(vehicle.kind);
  const isPreset = ROWS.every((r) => preset[r.key] === vehicle[r.key]) && preset.hazmat === vehicle.hazmat;
  return (
    <>
      <div className="shell-veh-dims card">
        {ROWS.map((r) => (
          <div key={r.key} className="shell-veh-row">
            <div className="shell-veh-row-text">
              <span>{r.label}</span>
              {r.hint && <small>{r.hint}</small>}
            </div>
            <button className="shell-veh-step" aria-label={`Diminuer ${r.label.toLowerCase()}`} disabled={vehicle[r.key] <= r.min} onClick={() => set(r, vehicle[r.key] - r.step)}>−</button>
            <output className="shell-veh-val" aria-live="polite">{num(vehicle[r.key])} {r.unit}</output>
            <button className="shell-veh-step" aria-label={`Augmenter ${r.label.toLowerCase()}`} disabled={vehicle[r.key] >= r.max} onClick={() => set(r, vehicle[r.key] + r.step)}>+</button>
          </div>
        ))}
        <label className="shell-veh-row">
          <div className="shell-veh-row-text">
            <span>Matières dangereuses (ADR)</span>
            <small>Évite les tunnels et les routes interdits au transport de matières dangereuses.</small>
          </div>
          <Switch checked={vehicle.hazmat} onChange={(hazmat) => onChange({ ...vehicle, hazmat })} label="Matières dangereuses" />
        </label>
      </div>
      {!isPreset && (
        <button className="btn-ghost shell-veh-reset" onClick={() => { haptic("tap"); onChange(preset); }}>
          <IconRefresh size={16} /> Valeurs habituelles d’un {VEHICLE_LABELS[vehicle.kind].label.toLowerCase()}
        </button>
      )}
    </>
  );
}

export function ConvoyNote() {
  return (
    <p className="shell-veh-convoy" role="note">
      Convoi exceptionnel : ton itinéraire réel est celui imposé par ton arrêté préfectoral de transport exceptionnel. OsaMaps n’est qu’une aide.
    </p>
  );
}

// ——— feuille (question unique + modification) —————————————————————————————

export function VehicleSheet() {
  const open = useVehicleSheet((s) => s.open);
  const onboarded = usePrefs((s) => s.onboarded);
  const chosen = usePrefs((s) => s.vehicleChosen);
  const mode = useCore((s) => s.mode);
  const settingsOpen = useCore((s) => s.settingsOpen);

  // ceux qui avaient passé l'accueil avant la question : on la pose une fois (jamais en conduite)
  const ask = onboarded && !chosen && mode === "browse" && !settingsOpen && !open;
  useEffect(() => {
    if (!ask) return;
    const t = window.setTimeout(openSheet, 1200);
    return () => window.clearTimeout(t);
  }, [ask]);

  return open ? <SheetBody /> : null;
}

function SheetBody() {
  const saved = usePrefs((s) => s.vehicle);
  const setPref = usePrefs((s) => s.setPref);
  const [draft, setDraftRaw] = useState<Vehicle>(saved);
  const [touched, setTouched] = useState(false);
  const setDraft = (v: Vehicle) => { setTouched(true); setDraftRaw(v); };
  // profil arrivé après l'ouverture (paramètre de test, autre onglet) : on le reprend tant que rien n'est modifié
  useEffect(() => { if (!touched) setDraftRaw(saved); }, [saved, touched]);
  const [dims, setDims] = useState(false);
  const truck = draft.kind !== "car";

  const close = (save: boolean) => {
    if (save) {
      setPref("vehicle", draft);
      haptic("success");
      emit("toast", { id: "shell-vehicle", text: truck ? `Mode ${VEHICLE_LABELS[draft.kind].label.toLowerCase()} activé : ${vehicleSummary(draft)}.` : "Mode voiture.", tone: "good" });
    }
    if (!usePrefs.getState().vehicleChosen) setPref("vehicleChosen", true);
    useVehicleSheet.setState({ open: false });
  };

  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "Escape") close(false); };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  });

  return (
    <div className="shell-veh-backdrop" onClick={(e) => { if (e.target === e.currentTarget) close(false); }}>
      <div className="shell-veh-sheet glass" role="dialog" aria-modal="true" aria-label="Ton véhicule">
        <header className="shell-veh-head">
          {dims ? <button className="btn-ghost" onClick={() => setDims(false)}><IconChevronLeft size={18} /> Retour</button> : <span />}
          <button className="shell-veh-close" aria-label="Fermer" onClick={() => close(false)}><IconClose size={18} /></button>
        </header>
        <div className="shell-veh-scroll">
          {dims ? (
            <>
              <h2>Ton {VEHICLE_LABELS[draft.kind].label.toLowerCase()}, en chiffres</h2>
              <p className="shell-veh-lead">Pré-rempli avec les valeurs habituelles : ajuste-les pour des itinéraires sûrs (ponts bas, routes limitées en tonnage).</p>
              <Dimensions vehicle={draft} onChange={setDraft} />
              {draft.kind === "superheavy" && <ConvoyNote />}
            </>
          ) : (
            <>
              <h2>Tu conduis quoi&nbsp;?</h2>
              <p className="shell-veh-lead">OsaMaps adapte les itinéraires, les limitations de vitesse et les alertes à ton véhicule.</p>
              <KindGrid vehicle={draft} onChange={setDraft} />
            </>
          )}
        </div>
        <button className="pill shell-veh-go" onClick={() => (!dims && truck ? setDims(true) : close(true))}>
          {!dims && truck ? "Continuer" : "Valider"}
        </button>
      </div>
    </div>
  );
}

// ——— réglages et badge ———————————————————————————————————————————————————

export function VehicleRow() {
  const v = usePrefs((s) => s.vehicle);
  const hint = v.kind === "car"
    ? "Itinéraires et limitations pour les voitures."
    : `${num(v.height)} m de haut · ${num(v.width)} m de large · ${num(v.length)} m de long · ${num(v.weight)} t${v.hazmat ? " · matières dangereuses" : ""}`;
  return (
    <button className="shell-set-row clickable" onClick={() => { haptic("tap"); core().set({ settingsOpen: false }); window.setTimeout(openSheet, 250); }}>
      <div className="shell-set-text"><span>{VEHICLE_LABELS[v.kind].label}</span><small>{hint}</small></div>
      <span className="shell-veh-row-pic"><Pic kind={v.kind} size={26} /></span>
      <IconChevronRight size={18} />
    </button>
  );
}

/** Badge discret du mode camion (rail) : pictogramme + poids ; touché hors conduite = modifier. */
export function VehicleBadge() {
  const v = usePrefs((s) => s.vehicle);
  const onboarded = usePrefs((s) => s.onboarded);
  const mode = useCore((s) => s.mode);
  if (v.kind === "car" || !onboarded) return null;
  return (
    <button className="round shell-rail-btn shell-rail-top shell-veh-badge" disabled={mode === "drive"}
      aria-label={`Mode ${VEHICLE_LABELS[v.kind].label.toLowerCase()}, ${num(v.weight)} tonnes`} title="Modifier le véhicule"
      onClick={() => { haptic("tap"); openSheet(); }}>
      <Pic kind={v.kind} size={22} />
      <small>{num(Math.round(v.weight))} t</small>
    </button>
  );
}
