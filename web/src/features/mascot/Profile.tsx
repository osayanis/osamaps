import { useShallow } from "zustand/react/shallow";
import { useEffect, useState } from "react";
import { useCore } from "../../core/store";
import { formatDistance, formatDuration } from "../../core/geometry";
import { Mascot } from "./Mascot";
import { BadgeIcon, LockIcon } from "./BadgeIcon";
import { ACCESSORIES, BADGES, levelOf, unlockText } from "./data";
import { isUnlocked, poke, toggleAccessory, useMascot, wornAccessories } from "./engine";
import { syncBoard, type Board } from "./leaderboard";
import { kmh } from "./TripSummary";

/** Bouton rond du rail avec la tête de la mascotte : ouvre le profil. Caché en conduite. */
export function ProfileButton() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const openPanel = useCore((s) => s.openPanel);
  const worn = useMascot(useShallow(wornAccessories));
  const sleeping = useMascot((s) => s.live.sleeping);
  if (mode === "drive") return null;
  const open = panel === "profile";
  return (
    <button
      className={`round mascot-rail${open ? " is-open" : ""}`}
      aria-label="Mon profil"
      aria-pressed={open}
      onClick={() => openPanel(open ? null : "profile")}
    >
      <Mascot size={34} crop="head" mood={sleeping ? "sleepy" : "calm"} accessories={worn} />
    </button>
  );
}

const fmtDate = (t: number) =>
  new Date(t).toLocaleDateString("fr-FR", { weekday: "short", day: "numeric", month: "short" }) +
  " · " + new Date(t).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });

/** Panneau "profile" : niveau, progression, badges, totaux, historique, accessoires, classement. */
export function Profile() {
  const panel = useCore((s) => s.panel);
  const openPanel = useCore((s) => s.openPanel);
  const s = useMascot();
  const worn = wornAccessories(s);
  const [hop, setHop] = useState(0);
  const [tab, setTab] = useState<"badges" | "trajets" | "style">("badges");
  const [board, setBoard] = useState<Board | null>(null);

  useEffect(() => {
    if (panel !== "profile" || !s.settings.leaderboard) return;
    let alive = true;
    syncBoard().then((b) => { if (alive) setBoard(b); });
    return () => { alive = false; };
  }, [panel, s.settings.leaderboard]);

  if (panel !== "profile") return null;
  const lvl = levelOf(s.points);
  const nBadges = Object.keys(s.badges).length;

  return (
    <section className="mascot-sheet glass mascot-profile" role="dialog" aria-label="Mon profil">
      <div className="mascot-grabber" aria-hidden="true" />
      <header className="mascot-prof-head">
        <button className="mascot-prof-hero" onClick={() => { setHop((h) => h + 1); poke(); }} aria-label="Caresser la mascotte">
          <Mascot size={64} hop={hop} accessories={worn} />
        </button>
        <div className="mascot-prof-title">
          <p className="mascot-eyebrow">Niveau {lvl.level}</p>
          <h2>{lvl.name}</h2>
          <div className="mascot-bar" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={Math.round(lvl.progress * 100)}>
            <i style={{ transform: `scaleX(${lvl.progress})` }} />
          </div>
          <p className="mascot-dim mascot-small">
            {lvl.next ? `${s.points} pts · encore ${lvl.next - s.points} pour le niveau ${lvl.level + 1}` : `${s.points} pts · niveau maximum`}
          </p>
        </div>
        <button className="btn-ghost mascot-close" onClick={() => openPanel(null)} aria-label="Fermer">
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M6 6l12 12M18 6L6 18" /></svg>
        </button>
      </header>

      <div className="mascot-stats mascot-stats-3">
        <Stat label="km au total" value={(s.totalDistance / 1000).toLocaleString("fr-FR", { maximumFractionDigits: s.totalDistance < 10000 ? 1 : 0 })} />
        <Stat label={s.trips > 1 ? "trajets" : "trajet"} value={String(s.trips)} />
        <Stat label="cette semaine" value={`${s.week.key ? s.week.points : 0} pts`} />
      </div>

      <div className="mascot-tabs" role="tablist">
        {([["badges", `Badges ${nBadges}/${BADGES.length}`], ["trajets", "Trajets"], ["style", "Style"]] as const).map(([id, label]) => (
          <button key={id} role="tab" aria-selected={tab === id} className={tab === id ? "is-on" : ""} onClick={() => setTab(id)}>{label}</button>
        ))}
      </div>

      <div className="mascot-scroll">
        {tab === "badges" && (
          <ul className="mascot-badges">
            {BADGES.map((b) => {
              const got = !!s.badges[b.id];
              return (
                <li key={b.id} className={got ? "is-got" : ""} title={b.hint}>
                  <span className="mascot-badge-icon"><BadgeIcon icon={b.icon} /></span>
                  <strong>{b.name}</strong>
                  <span>{got ? new Date(s.badges[b.id]).toLocaleDateString("fr-FR", { day: "numeric", month: "short" }) : b.hint}</span>
                </li>
              );
            })}
          </ul>
        )}

        {tab === "trajets" && (
          s.history.length === 0 ? (
            <p className="mascot-empty">Pas encore de trajet. Choisis une destination et lance le guidage : je compte les kilomètres pour toi.</p>
          ) : (
            <ul className="mascot-history">
              {s.history.map((t) => (
                <li key={t.id}>
                  <div>
                    <strong>{t.destination || (t.arrived ? "Trajet" : "Trajet interrompu")}</strong>
                    <span className="mascot-dim">{fmtDate(t.start)}</span>
                  </div>
                  <div className="mascot-history-nums">
                    <span>{formatDistance(t.distance)} · {formatDuration(t.duration)}</span>
                    <span className="mascot-dim">{kmh(t.avgKmh)} moy. · +{t.points} pts</span>
                  </div>
                </li>
              ))}
            </ul>
          )
        )}

        {tab === "style" && (
          <ul className="mascot-skins">
            {ACCESSORIES.map((a) => {
              const ok = isUnlocked(a.id);
              const on = worn.includes(a.id);
              return (
                <li key={a.id}>
                  <button className={`mascot-skin${on ? " is-on" : ""}`} disabled={!ok} aria-pressed={on} onClick={() => toggleAccessory(a.id)}>
                    <Mascot size={44} crop="head" blink={false} accessories={[a.id]} />
                    <strong>{a.name}</strong>
                    <span>{ok ? (on ? "Porté" : "Mettre") : <><LockIcon size={12} /> {unlockText(a)}</>}</span>
                  </button>
                </li>
              );
            })}
          </ul>
        )}

        {s.settings.leaderboard && board && board.top.length > 0 && (
          <div className="mascot-board">
            <p className="mascot-eyebrow">Classement de la semaine</p>
            <ol>
              {board.top.slice(0, 10).map((r, i) => (
                <li key={i} className={r.me ? "is-me" : ""}>
                  <span className="mascot-rank">{i + 1}</span>
                  <span className="mascot-board-name">{r.name}{r.me ? " (toi)" : ""}</span>
                  <span>{r.points} pts</span>
                </li>
              ))}
            </ol>
            {board.rank && board.rank > 10 && <p className="mascot-dim mascot-small">Tu es {board.rank}e sur {board.total}.</p>}
          </div>
        )}
      </div>
    </section>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="mascot-stat">
      <span className="mascot-stat-value">{value}</span>
      <span className="mascot-stat-label">{label}</span>
    </div>
  );
}
