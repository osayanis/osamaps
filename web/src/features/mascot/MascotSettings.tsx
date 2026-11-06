import { useCore } from "../../core/store";
import { nickname } from "../../core/identity";
import { Mascot } from "./Mascot";
import { setSetting, useMascot, type Settings } from "./engine";
import { displayName, useShownLook } from "./look";
import { leaveBoard, syncBoard } from "./leaderboard";

/** Section « Mascotte » des réglages : accès à l'éditeur, animations, messages, classement. */
export function MascotSettings() {
  const s = useMascot();
  const look = useShownLook();
  const set = useCore((x) => x.set);

  const toggle = (k: keyof Settings) => {
    const v = !s.settings[k];
    setSetting(k, v);
    if (k === "leaderboard") { if (v) void syncBoard(); else void leaveBoard(); }
  };

  return (
    <section className="card mascot-settings">
      <button
        className="mascot-set-head mascot-set-edit"
        onClick={() => { set({ settingsOpen: false }); useCore.getState().openPanel("mascot-editor"); }}
      >
        <Mascot size={44} crop="head" style={look} />
        <div>
          <h3>{displayName(look)}</h3>
          <p className="mascot-dim mascot-small">Elle te représente sur la carte.</p>
        </div>
        <span className="mascot-set-cta">Personnaliser</span>
      </button>

      <Toggle label="Animations" hint="Rebond, clignements, petits sauts" on={s.settings.animations} onChange={() => toggle("animations")} />
      <Toggle label="Messages de la mascotte" hint="Rares, jamais pendant une manœuvre" on={s.settings.talk} onChange={() => toggle("talk")} />
      <Toggle
        label="Classement de la semaine"
        hint={`Partage seulement ton pseudo${nickname() ? ` (${nickname()})` : " (anonyme)"} et tes points de la semaine`}
        on={s.settings.leaderboard}
        onChange={() => toggle("leaderboard")}
      />
    </section>
  );
}

function Toggle({ label, hint, on, onChange }: { label: string; hint: string; on: boolean; onChange: () => void }) {
  return (
    <label className="mascot-set-row">
      <span>
        {label}
        <small className="mascot-dim">{hint}</small>
      </span>
      <button role="switch" aria-checked={on} className={`mascot-switch${on ? " is-on" : ""}`} onClick={onChange} aria-label={label}>
        <i />
      </button>
    </label>
  );
}
