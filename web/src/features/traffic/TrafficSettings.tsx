import { usePrefs } from "../../core/prefs";
import { useTraffic } from "./state";

function Switch({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <button role="switch" aria-checked={checked} aria-label={label} className={`traffic-switch${checked ? " is-on" : ""}`} onClick={() => onChange(!checked)}>
      <span className="traffic-switch-knob" />
    </button>
  );
}

/** Slot "settings" : afficher le trafic, contribuer (avec ce qui est envoyé, en clair). */
export function TrafficSettings() {
  const contribute = usePrefs((s) => s.contributeTraffic);
  const setPref = usePrefs((s) => s.setPref);
  const visible = useTraffic((s) => s.visible);
  const setVisible = useTraffic((s) => s.setVisible);
  const sent = useTraffic((s) => s.sent);
  const tripActive = useTraffic((s) => s.tripActive);

  return (
    <section className="traffic-settings card">
      <h3>Trafic en direct</h3>

      <div className="traffic-row">
        <div>
          <strong>Afficher le trafic</strong>
          <p>Vert fluide, orange ralenti, rouge bouchon. Plus les travaux, accidents et fermetures du réseau national.</p>
        </div>
        <Switch checked={visible} onChange={setVisible} label="Afficher le trafic" />
      </div>

      <div className="traffic-row">
        <div>
          <strong>Contribuer au trafic</strong>
          <p>Votre vitesse aide les autres à éviter les bouchons, et inversement.</p>
        </div>
        <Switch checked={contribute} onChange={(v) => setPref("contributeTraffic", v)} label="Contribuer au trafic" />
      </div>

      <details className="traffic-details">
        <summary>Ce qui est envoyé, exactement</summary>
        <ul>
          <li>Pendant un trajet, toutes les 5 secondes : un petit bout de trajet (point précédent → point actuel), la vitesse et la direction.</li>
          <li>Aucun compte, aucun identifiant de votre téléphone : juste un code au hasard, changé à chaque trajet.</li>
          <li>Les 300 premiers et les 300 derniers mètres ne partent jamais : votre domicile et vos arrivées restent chez vous.</li>
          <li>Le serveur ne garde que des moyennes par tronçon de route (≈ 60 m), jamais vos trajets. Les détails s'effacent au bout de 15 minutes.</li>
          <li>À pied ou à vélo, rien ne part : il faut avoir dépassé 30 km/h, ou être en navigation.</li>
        </ul>
        {contribute && tripActive && <p className="traffic-sent">Trajet en cours : {sent} segment{sent > 1 ? "s" : ""} envoyé{sent > 1 ? "s" : ""}.</p>}
      </details>

      <p className="traffic-credit">
        Sources : contributions OsaMaps et Bison Futé / Directions interdépartementales des routes (mesures et évènements, Licence Ouverte).
        Tant qu'il y a peu d'utilisateurs, la carte reste souvent vide hors grands axes : c'est normal, rien n'est inventé.
      </p>
    </section>
  );
}
