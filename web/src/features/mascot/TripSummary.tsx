import { useCore } from "../../core/store";
import { formatDistance, formatDuration } from "../../core/geometry";
import { Mascot } from "./Mascot";
import { BadgeIcon } from "./BadgeIcon";
import { badgeById, levelOf } from "./data";
import { useMascot, wornAccessories, type Trip } from "./engine";

export const kmh = (v: number) => `${Math.round(v)} km/h`;

/** Panneau « Résumé du trajet » (panel "trip-summary", data = Trip). */
export function TripSummary() {
  const panel = useCore((s) => s.panel);
  const data = useCore((s) => s.panelData) as Trip | null;
  const openPanel = useCore((s) => s.openPanel);
  const worn = useMascot(wornAccessories);
  const points = useMascot((s) => s.points);
  if (panel !== "trip-summary" || !data) return null;
  const t = data;
  const lvl = levelOf(points);
  const badge = t.badges.length ? badgeById(t.badges[0]) : null;

  return (
    <section className="mascot-sheet glass" role="dialog" aria-label="Résumé du trajet">
      <div className="mascot-grabber" aria-hidden="true" />
      <header className="mascot-sum-head">
        <div className="mascot-sum-hero">
          <Mascot size={74} mood="happy" arms="up" hop={1} accessories={worn} />
        </div>
        <div className="mascot-sum-title">
          <p className="mascot-eyebrow">Résumé du trajet</p>
          <h2>{t.arrived ? "Bien arrivé !" : "Trajet terminé"}</h2>
          {t.destination && <p className="mascot-dim">{t.destination}</p>}
        </div>
      </header>

      <div className="mascot-stats">
        <Stat label="Distance" value={formatDistance(t.distance)} />
        <Stat label="Durée" value={formatDuration(t.duration)} />
        <Stat label="Moyenne" value={kmh(t.avgKmh)} />
        <Stat label="Max" value={kmh(t.maxKmh)} />
        <Stat label="Arrêts" value={String(t.stops)} />
        <Stat label="Points" value={`+${t.points}`} strong />
      </div>

      {badge && (
        <div className="mascot-unlock card">
          <span className="mascot-unlock-icon"><BadgeIcon icon={badge.icon} size={24} /></span>
          <div>
            <p className="mascot-eyebrow">Badge débloqué</p>
            <strong>{badge.name}</strong>
            {t.badges.length > 1 && <span className="mascot-dim"> et {t.badges.length - 1} autre{t.badges.length > 2 ? "s" : ""}</span>}
          </div>
        </div>
      )}
      {t.levelUp && (
        <div className="mascot-unlock card">
          <span className="mascot-unlock-icon mascot-level-num">{t.levelUp.level}</span>
          <div>
            <p className="mascot-eyebrow">Niveau supérieur</p>
            <strong>{t.levelUp.name}</strong>
          </div>
        </div>
      )}

      <div className="mascot-level-line">
        <span>Niv. {lvl.level}</span>
        <div className="mascot-bar" aria-hidden="true"><i style={{ transform: `scaleX(${lvl.progress})` }} /></div>
        <span className="mascot-dim">{lvl.next ? `${points} / ${lvl.next}` : `${points} pts`}</span>
      </div>

      <div className="mascot-actions">
        <button className="pill secondary" onClick={() => openPanel("profile")}>Mon profil</button>
        <button className="pill" onClick={() => openPanel(null)}>Fermer</button>
      </div>
    </section>
  );
}

function Stat({ label, value, strong }: { label: string; value: string; strong?: boolean }) {
  return (
    <div className={`mascot-stat${strong ? " is-strong" : ""}`}>
      <span className="mascot-stat-value">{value}</span>
      <span className="mascot-stat-label">{label}</span>
    </div>
  );
}
