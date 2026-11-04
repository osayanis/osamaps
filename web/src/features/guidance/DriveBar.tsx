import { useEffect, useState } from "react";
import { useCore } from "../../core/store";
import { usePrefs } from "../../core/prefs";
import { formatDistance, formatDuration, formatEta } from "../../core/geometry";
import { useGuide } from "./state";
import { showOverview, resumeFollow, stopGuidance, toggleVoice } from "./engine";
import { IconClose, IconVolume, IconVolumeOff, IconOverview, IconFollow } from "./icons";

/** Barre du bas en conduite (slot "sheet", mode drive, aucun panneau ouvert). */
export function DriveBar() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const route = useCore((s) => s.routes[s.activeRoute]);
  const progress = useCore((s) => s.progress);
  const voice = usePrefs((s) => s.voice);
  const overview = useGuide((s) => s.overview);
  const arrived = useGuide((s) => s.arrived);
  const [confirm, setConfirm] = useState(false);

  // la confirmation d'arrêt se replie toute seule
  useEffect(() => {
    if (!confirm) return;
    const t = window.setTimeout(() => setConfirm(false), 5000);
    return () => window.clearTimeout(t);
  }, [confirm]);

  if (mode !== "drive" || panel !== null || !route || arrived) return null;

  const remainingTime = progress?.remainingTime ?? route.duration;
  const remainingDistance = progress?.remainingDistance ?? route.distance;
  const done = route.distance > 0 ? Math.min(1, Math.max(0, 1 - remainingDistance / route.distance)) : 0;

  return (
    <div className="guidance-bar glass">
      <div className="guidance-progress" aria-hidden><i style={{ transform: `scaleX(${done})` }} /></div>
      {confirm ? (
        <div className="guidance-bar-row guidance-confirm">
          <span className="guidance-confirm-text">Arrêter le guidage ?</span>
          <button className="pill secondary guidance-pill" onClick={() => setConfirm(false)}>Continuer</button>
          <button className="pill guidance-pill guidance-stop" onClick={() => { setConfirm(false); stopGuidance(); }}>Arrêter</button>
        </div>
      ) : (
        <div className="guidance-bar-row">
          <button className="guidance-btn" aria-label="Arrêter le guidage" onClick={() => setConfirm(true)}>
            <IconClose size={26} />
          </button>
          <div className="guidance-eta">
            <b>{formatEta(remainingTime)}</b>
            <span>{formatDuration(remainingTime)} · {formatDistance(remainingDistance)}</span>
          </div>
          <button className={`guidance-btn${voice ? "" : " is-off"}`} aria-label={voice ? "Couper la voix" : "Remettre la voix"} aria-pressed={!voice} onClick={toggleVoice}>
            {voice ? <IconVolume size={26} /> : <IconVolumeOff size={26} />}
          </button>
          <button className={`guidance-btn${overview ? " is-on" : ""}`} aria-label={overview ? "Reprendre le suivi" : "Vue d'ensemble"} onClick={overview ? resumeFollow : showOverview}>
            {overview ? <IconFollow size={24} /> : <IconOverview size={26} />}
          </button>
        </div>
      )}
    </div>
  );
}
