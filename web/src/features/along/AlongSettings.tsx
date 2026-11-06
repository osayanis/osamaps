import { usePrefs, VEHICLE_LABELS } from "../../core/prefs";
import { ENERGY_LABEL, FUELS, useAlongPrefs, type Energy } from "./prefs";

/** Section « Sur le trajet » de l'écran Réglages. */
export function AlongSettings() {
  const p = useAlongPrefs();
  const kind = usePrefs((s) => s.vehicle.kind);
  const [lo, hi] = p.range();
  const ev = p.energy === "ev";
  const energies: Energy[] = [...FUELS, "ev"];
  const step = ev || kind !== "car" ? 1 : 0.5;
  const value = ev ? p.evConsumption : p.consumption;
  const setValue = (v: number) => ev
    ? p.setAlong("evConsumption", Math.min(40, Math.max(8, Math.round(v))))
    : p.setAlong("consumption", Math.min(hi, Math.max(lo, kind === "car" ? Math.round(v * 2) / 2 : Math.round(v))));
  return (
    <section className="along-settings card" aria-labelledby="along-settings-title">
      <h3 id="along-settings-title">Sur le trajet</h3>
      <div className="along-set-block">
        <span className="along-set-label">Mon carburant</span>
        <div className="along-set-chips" role="radiogroup" aria-label="Mon carburant">
          {energies.map((e) => (
            <button key={e} role="radio" aria-checked={p.energy === e} className={`along-set-chip${p.energy === e ? " is-on" : ""}`} onClick={() => p.setAlong("energy", e)}>
              {ENERGY_LABEL[e]}
            </button>
          ))}
        </div>
      </div>
      <div className="along-set-row">
        <span className="along-set-text">
          <span>Consommation</span>
          <small>{kind === "car" || ev ? "Pour estimer le coût du trajet." : `${VEHICLE_LABELS[kind].label} : pour estimer le coût du trajet.`}</small>
        </span>
        <div className="along-stepper">
          <button onClick={() => setValue(value - step)} aria-label="Moins">−</button>
          <output>{String(value).replace(".", ",")} <small>{ev ? "kWh/100" : "L/100"}</small></output>
          <button onClick={() => setValue(value + step)} aria-label="Plus">+</button>
        </div>
      </div>
      <Toggle label="Afficher les stations" hint={ev ? "Bornes de recharge sur la carte." : "Prix de mon carburant sur la carte, la moins chère en vert."}
        checked={p.showStations} onChange={(v) => p.setAlong("showStations", v)} />
      <Toggle label="Rappel de pause" hint="Après environ 2 h de conduite, avec l'aire la plus proche."
        checked={p.pauseReminder} onChange={(v) => p.setAlong("pauseReminder", v)} />
      <Toggle label="Alertes météo" hint="Neige, verglas, orages ou forte pluie prévus sur le trajet."
        checked={p.weatherAlerts} onChange={(v) => p.setAlong("weatherAlerts", v)} />
    </section>
  );
}

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="along-set-row along-toggle">
      <span className="along-set-text"><span>{label}</span>{hint && <small>{hint}</small>}</span>
      <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span className="along-switch" aria-hidden="true" />
    </label>
  );
}
