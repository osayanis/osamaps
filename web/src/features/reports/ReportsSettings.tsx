import { KIND_ORDER, KINDS } from "./catalog";
import { KindDisc } from "./Icon";
import { useReports } from "./state";

/** Réglages : types d'alertes reçues en conduite + « Toujours là ? ». */
export function ReportsSettings() {
  const settings = useReports((s) => s.settings);
  const setSettings = useReports((s) => s.setSettings);
  return (
    <section className="card reports-settings" aria-labelledby="reports-settings-title">
      <h3 id="reports-settings-title">Signalements</h3>
      <p className="reports-settings-hint">Les alertes que tu reçois en conduite, quand un signalement est devant toi.</p>
      <ul>
        {KIND_ORDER.map((k) => (
          <li key={k}>
            <label className="reports-row">
              <KindDisc kind={k} size={30} />
              <span>{KINDS[k].label}</span>
              <input
                type="checkbox"
                className="reports-switch"
                checked={settings.alerts[k]}
                onChange={(e) => setSettings({ alerts: { ...settings.alerts, [k]: e.target.checked } })}
              />
            </label>
          </li>
        ))}
        <li>
          <label className="reports-row">
            <span className="reports-row-text">
              Demander « Toujours là ? »
              <small>En passant à côté d'un signalement</small>
            </span>
            <input type="checkbox" className="reports-switch" checked={settings.ask} onChange={(e) => setSettings({ ask: e.target.checked })} />
          </label>
        </li>
      </ul>
    </section>
  );
}
