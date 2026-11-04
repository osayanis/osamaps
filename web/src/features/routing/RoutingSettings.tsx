import { usePrefs } from "../../core/prefs";
import { useRouting } from "./state";

/** Section « Itinéraires » de l'écran Réglages. */
export function RoutingSettings() {
  const p = usePrefs();
  const alternates = useRouting((s) => s.alternates);
  const setAlt = useRouting((s) => s.set);
  return (
    <section className="routing-settings card" aria-labelledby="routing-settings-title">
      <h3 id="routing-settings-title">Itinéraires</h3>
      <Toggle label="Éviter les péages" checked={p.avoidTolls} onChange={(v) => p.setPref("avoidTolls", v)} />
      <Toggle label="Éviter les autoroutes" checked={p.avoidHighways} onChange={(v) => p.setPref("avoidHighways", v)} />
      <Toggle label="Éviter les ferrys" checked={p.avoidFerries} onChange={(v) => p.setPref("avoidFerries", v)} />
      <Toggle label="Proposer d'autres itinéraires" hint="Jusqu'à deux alternatives à comparer avant de partir."
        checked={alternates} onChange={(v) => setAlt({ alternates: v })} />
    </section>
  );
}

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="routing-toggle">
      <span className="routing-toggle-text">
        <span>{label}</span>
        {hint && <small>{hint}</small>}
      </span>
      <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span className="routing-switch" aria-hidden="true" />
    </label>
  );
}
