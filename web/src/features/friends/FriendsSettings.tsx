import { useState } from "react";
import { usePrefs } from "../../core/prefs";
import { useFriends, setShowDest, deleteMyData } from "./store";
import { NicknameField } from "./FriendsSheet";
import { prettyCode } from "./util";

function Switch({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <button role="switch" aria-checked={checked} aria-label={label} className={`friends-switch${checked ? " is-on" : ""}`} onClick={() => onChange(!checked)}>
      <span />
    </button>
  );
}

/** Section « Amis et partage » de l'écran Réglages. */
export function FriendsSettings() {
  const shareLocation = usePrefs((s) => s.shareLocation);
  const setPref = usePrefs((s) => s.setPref);
  const showDest = useFriends((s) => s.showDest);
  const me = useFriends((s) => s.me);
  const [confirm, setConfirm] = useState(false);

  return (
    <section className="friends-settings card">
      <h3>Amis et partage</h3>

      <label className="friends-label">Pseudo</label>
      <NicknameField />

      <div className="friends-setting">
        <div>
          <strong>Partager ma position avec mes amis</strong>
          <span>Seuls tes amis acceptés te voient. Ta position n'est jamais enregistrée : elle disparaît 5 min après la dernière mise à jour.</span>
        </div>
        <Switch checked={shareLocation} onChange={(v) => setPref("shareLocation", v)} label="Partager ma position" />
      </div>

      <div className={`friends-setting${shareLocation ? "" : " is-disabled"}`}>
        <div>
          <strong>Montrer ma destination</strong>
          <span>En conduite, tes amis voient « en route vers … · arrivée 18 h 42 ». Sinon, seulement « en route ».</span>
        </div>
        <Switch checked={showDest} onChange={setShowDest} label="Montrer ma destination" />
      </div>

      {me && <p className="friends-muted">Mon code ami : <strong>{prettyCode(me.code)}</strong></p>}

      <div className="friends-setting">
        <div>
          <strong>Supprimer mes données</strong>
          <span>Efface ton pseudo, tes amis, tes demandes et tes trajets partagés du serveur.</span>
        </div>
        {confirm ? (
          <span className="friends-confirm">
            <button className="btn-ghost" onClick={() => setConfirm(false)}>Annuler</button>
            <button className="btn-ghost friends-danger" onClick={() => { void deleteMyData(); setConfirm(false); }}>Supprimer</button>
          </span>
        ) : (
          <button className="btn-ghost friends-danger" onClick={() => setConfirm(true)}>Supprimer</button>
        )}
      </div>
    </section>
  );
}
