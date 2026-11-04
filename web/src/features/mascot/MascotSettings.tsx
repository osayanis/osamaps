import { useCore } from "../../core/store";
import { nickname } from "../../core/identity";
import { Mascot } from "./Mascot";
import { ACCESSORIES } from "./data";
import { isUnlocked, setSetting, toggleAccessory, useMascot, wornAccessories, type Settings } from "./engine";
import { leaveBoard, syncBoard } from "./leaderboard";

/** Section « Mascotte » des réglages : accessoires portés, animations, messages, classement. */
export function MascotSettings() {
  const s = useMascot();
  const worn = wornAccessories(s);
  const set = useCore((x) => x.set);
  const unlocked = ACCESSORIES.filter((a) => isUnlocked(a.id));

  const toggle = (k: keyof Settings) => {
    const v = !s.settings[k];
    setSetting(k, v);
    if (k === "leaderboard") { if (v) void syncBoard(); else void leaveBoard(); }
  };

  return (
    <section className="card mascot-settings">
      <div className="mascot-set-head">
        <Mascot size={40} crop="head" accessories={worn} />
        <div>
          <h3>Mascotte</h3>
          <p className="mascot-dim mascot-small">Elle te représente sur la carte.</p>
        </div>
      </div>

      <div className="mascot-set-row mascot-set-col">
        <span>Accessoires</span>
        {unlocked.length === 0 ? (
          <span className="mascot-dim mascot-small">Le premier se débloque au niveau 2.</span>
        ) : (
          <div className="mascot-chips">
            {unlocked.map((a) => (
              <button key={a.id} className={`mascot-chip${worn.includes(a.id) ? " is-on" : ""}`} aria-pressed={worn.includes(a.id)} onClick={() => toggleAccessory(a.id)}>
                {a.name}
              </button>
            ))}
          </div>
        )}
        <button className="btn-ghost mascot-small" onClick={() => { set({ settingsOpen: false }); useCore.getState().openPanel("profile"); }}>
          Voir tous les accessoires
        </button>
      </div>

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
