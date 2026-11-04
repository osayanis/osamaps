import { useEffect, useState } from "react";
import { useCore } from "../../core/store";
import { formatDistance } from "../../core/geometry";
import { useSafety } from "./engine";
import { answerPassenger, usePassenger } from "./passenger";
import { CRITAIR_LABEL, critairForbidden, useSafetySettings, type CritAir, type SafetySettings } from "./settings";
import { fetchZfe, fetchZones, hoursFr } from "./data";

/** Triangle de danger (SVG, trait 2 px, coins ronds). */
function DangerIcon({ size = 22 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M10.3 3.9 2.4 17.5A2 2 0 0 0 4.1 20.5h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" />
      <path d="M12 9.5v4.5" />
      <path d="M12 17.5h.01" />
    </svg>
  );
}

function LeafIcon() {
  return (
    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M5 19c0-8 5-13 15-14-1 10-6 15-14 15" />
      <path d="M5 19 13 11" />
    </svg>
  );
}

// ------------------------------------------------------------------ HUD (conduite)

/** Bandeau « Zone de danger — reste attentif » tant qu'on est dans une zone. */
export function SafetyHud() {
  const inside = useSafety((s) => s.inside);
  const along = useSafety((s) => s.along);
  const enabled = useSafetySettings((s) => s.dangerZones);
  if (!inside || !enabled) return null;
  const left = Math.max(0, inside.end - along);
  return (
    <div className="safety-hud glass" role="status" aria-live="polite">
      <span className="safety-hud-icon"><DangerIcon /></span>
      <div className="safety-hud-text">
        <strong>Zone de danger — reste attentif</strong>
        <span>encore {formatDistance(left)}</span>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ aperçu d'itinéraire : ZFE

export function SafetySheet() {
  const mode = useCore((s) => s.mode);
  const zfe = useSafety((s) => s.zfe);
  const critair = useSafetySettings((s) => s.critair);
  const enabled = useSafetySettings((s) => s.zfe);
  if (mode !== "preview" || !enabled) return null;
  const restricted = zfe.filter((z) => z.props.vp);
  if (!restricted.length) return null;
  const z = restricted.find((x) => critairForbidden(critair, x.props.vp)) ?? restricted[0];
  const forbidden = critairForbidden(critair, z.props.vp);
  if (forbidden === false && restricted.every((x) => critairForbidden(critair, x.props.vp) === false)) return null;
  const hours = hoursFr(z.props.hours);
  return (
    <div className={`safety-zfe card ${forbidden ? "is-forbidden" : ""}`}>
      <span className="safety-zfe-icon"><LeafIcon /></span>
      <div className="safety-zfe-text">
        <strong>{forbidden ? `${CRITAIR_LABEL[critair]} non autorisée dans la ZFE` : "Ce trajet traverse une ZFE"}</strong>
        <span>
          {z.props.name}
          {hours ? ` · ${hours}` : ""}
          {forbidden == null ? " · règle ta vignette dans Réglages" : ""}
        </span>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ « Tu es passager ? »

export function PassengerOverlay() {
  const open = usePassenger((s) => s.open);
  if (!open) return null;
  return (
    <div className="safety-passenger" role="dialog" aria-modal="true" aria-labelledby="safety-passenger-title">
      <div className="safety-passenger-card glass">
        <h3 id="safety-passenger-title">Tu es passager ?</h3>
        <p>Le véhicule roule. Si c'est toi qui conduis, garde les yeux sur la route : la saisie attendra l'arrêt.</p>
        <div className="safety-passenger-actions">
          <button className="pill" onClick={() => answerPassenger("passenger")}>Oui, je suis passager</button>
          <button className="pill secondary" onClick={() => answerPassenger("driver")}>Non, je conduis</button>
        </div>
      </div>
    </div>
  );
}

// ------------------------------------------------------------------ Réglages

const CRITAIRS: { v: CritAir; short: string }[] = [
  { v: "unset", short: "—" }, { v: "EL", short: "0" }, { v: "V1", short: "1" }, { v: "V2", short: "2" },
  { v: "V3", short: "3" }, { v: "V4", short: "4" }, { v: "V5", short: "5" }, { v: "NC", short: "NC" },
];

const TOGGLES: { key: keyof Omit<SafetySettings, "critair">; label: string; hint?: string }[] = [
  { key: "dangerZones", label: "Zones de danger", hint: "300 m en ville, 2 km sur route, 4 km sur autoroute" },
  { key: "zfe", label: "Zones à faibles émissions" },
  { key: "curves", label: "Virages serrés" },
  { key: "levelCrossings", label: "Passages à niveau" },
  { key: "schools", label: "Abords d'écoles", hint: "en semaine, de 7 h à 19 h" },
  { key: "night", label: "Rappel de fatigue la nuit", hint: "entre 1 h et 5 h" },
  { key: "passenger", label: "Demander « Tu es passager ? »", hint: "quand tu tapes en roulant" },
];

/** Dit honnêtement si les données publiques ne sont pas disponibles côté serveur. */
function useDataStatus() {
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    Promise.allSettled([fetchZones([2.3, 46.5, 2.4, 46.6]), fetchZfe()]).then(([z, f]) => {
      if (!alive) return;
      const missing: string[] = [];
      if (z.status === "rejected" || !z.value.available) missing.push("zones de danger");
      if (f.status === "rejected" || !f.value.available) missing.push("ZFE");
      setMsg(missing.length ? `Données indisponibles pour le moment : ${missing.join(" et ")}. Les autres alertes fonctionnent.` : null);
    });
    return () => { alive = false; };
  }, []);
  return msg;
}

export function SafetySettingsSection() {
  const s = useSafetySettings();
  const status = useDataStatus();
  return (
    <section className="safety-settings card" aria-labelledby="safety-settings-title">
      <h3 id="safety-settings-title">Sécurité routière</h3>

      <div className="safety-settings-row safety-settings-critair">
        <div>
          <span className="safety-settings-label">Vignette Crit'Air</span>
          <span className="safety-settings-hint">{CRITAIR_LABEL[s.critair]} · pour les alertes ZFE</span>
        </div>
        <div className="safety-chips" role="radiogroup" aria-label="Vignette Crit'Air">
          {CRITAIRS.map((c) => (
            <button
              key={c.v}
              role="radio"
              aria-checked={s.critair === c.v}
              aria-label={CRITAIR_LABEL[c.v]}
              className={`safety-chip ${s.critair === c.v ? "is-on" : ""}`}
              onClick={() => s.setSetting("critair", c.v)}
            >
              {c.short}
            </button>
          ))}
        </div>
      </div>

      {TOGGLES.map((t) => (
        <label key={t.key} className="safety-settings-row">
          <div>
            <span className="safety-settings-label">{t.label}</span>
            {t.hint && <span className="safety-settings-hint">{t.hint}</span>}
          </div>
          <input
            type="checkbox"
            className="safety-switch"
            checked={s[t.key]}
            onChange={(e) => s.setSetting(t.key, e.target.checked)}
          />
        </label>
      ))}

      {status && <p className="safety-settings-warn" role="status">{status}</p>}
      <p className="safety-settings-note">
        Conformément à la loi (décret n° 2012-3, art. R413-15 du Code de la route), OsaMaps ne montre jamais
        l'emplacement des radars : seulement des zones de danger, d'après la liste publique des radars fixes
        (data.gouv.fr). Périmètres ZFE : base nationale de transport.data.gouv.fr.
      </p>
    </section>
  );
}
