import { usePrefs } from "../../core/prefs";
import { useGuidePrefs } from "./state";

/** Section « Guidage » de l'écran Réglages. */
export function GuidanceSettings() {
  const voice = usePrefs((s) => s.voice);
  const tolerance = usePrefs((s) => s.speedTolerance);
  const setPref = usePrefs((s) => s.setPref);
  const speedBeep = useGuidePrefs((s) => s.speedBeep);
  const speedVoice = useGuidePrefs((s) => s.speedVoice);
  const setGuidePref = useGuidePrefs((s) => s.setGuidePref);

  return (
    <section className="card guidance-settings" aria-labelledby="guidance-settings-title">
      <h3 id="guidance-settings-title">Guidage</h3>
      <Toggle label="Guidage vocal" hint="Les annonces de virages, d'alertes et de recalcul" checked={voice} onChange={(v) => setPref("voice", v)} />
      <Toggle label="Bip de dépassement" hint="Un petit bip quand vous dépassez la limitation" checked={speedBeep} onChange={(v) => setGuidePref("speedBeep", v)} />
      <Toggle label="Annoncer les limitations" hint="Dire la nouvelle limitation quand elle change" checked={speedVoice} onChange={(v) => setGuidePref("speedVoice", v)} />
      <label className="guidance-setting guidance-range">
        <span className="guidance-setting-text">
          <span>Tolérance de vitesse</span>
          <small>Au-delà de la limitation + {tolerance} km/h, le compteur passe au rouge</small>
        </span>
        <span className="guidance-range-value">+{tolerance} km/h</span>
        <input type="range" min={0} max={20} step={1} value={tolerance} onChange={(e) => setPref("speedTolerance", Number(e.target.value))} aria-label="Tolérance de vitesse en km/h" />
      </label>
    </section>
  );
}

function Toggle({ label, hint, checked, onChange }: { label: string; hint: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="guidance-setting">
      <span className="guidance-setting-text">
        <span>{label}</span>
        <small>{hint}</small>
      </span>
      <input type="checkbox" role="switch" className="guidance-switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}
