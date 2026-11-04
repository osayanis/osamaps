import { useEffect, useState } from "react";
import { useCore, core } from "../../core/store";
import { emit, on } from "../../core/bus";
import { usePrefs } from "../../core/prefs";
import { IconCompass, IconLocate, IconSettings } from "./icons";
import { haptic } from "./haptics";

/**
 * Boutons du rail (bord droit, empilés de haut en bas par `order`) :
 *   order 5   Réglages   — en haut, hors conduite
 *   order 6   Boussole   — quand la carte est tournée ou inclinée, hors conduite (la carte suit le cap)
 *   order 100 (défaut)   — boutons des autres modules : signaler, trafic, amis, profil…
 *   order 990 Recentrer  — en bas, près du pouce, quand le suivi est coupé
 * Le rail est ancré en bas : un bouton qui apparaît pousse ceux du dessus vers le haut. Recentrer
 * est tout en bas (le geste le plus fréquent après avoir déplacé la carte) ; Réglages et Boussole,
 * rarement utilisés, sont en haut.
 */

/** Remet la carte en suivi de position. Utilisé par le bouton, la touche R et `map:recenter`. */
export function recenter() {
  // MapView réagit au passage follow false → true (easeTo vers la position, cap en conduite)
  core().set({ follow: true });
}

/** Écoute `map:recenter` (émis par d'autres modules ou le clavier). */
export function listenRecenter(): () => void {
  return on("map:recenter", () => { recenter(); });
}

export function SettingsButton() {
  const mode = useCore((s) => s.mode);
  const onboarded = usePrefs((s) => s.onboarded);
  if (mode === "drive" || !onboarded) return null;
  return (
    <button className="round shell-rail-btn" aria-label="Réglages" title="Réglages"
      onClick={() => { haptic("tap"); core().set({ settingsOpen: true }); }}>
      <IconSettings />
    </button>
  );
}

export function CompassButton() {
  const map = useCore((s) => s.map);
  const mode = useCore((s) => s.mode);
  const [view, setView] = useState({ bearing: 0, pitch: 0 });

  useEffect(() => {
    if (!map) return;
    const update = () => {
      const b = map.getBearing(), p = map.getPitch();
      setView((v) => (Math.abs(v.bearing - b) < 0.5 && Math.abs(v.pitch - p) < 0.5 ? v : { bearing: b, pitch: p }));
    };
    update();
    map.on("rotate", update);
    map.on("pitch", update);
    return () => { map.off("rotate", update); map.off("pitch", update); };
  }, [map]);

  const tilted = Math.abs(view.bearing) > 1.5 || view.pitch > 3;
  if (!map || mode === "drive" || !tilted) return null;
  return (
    <button className="round shell-rail-btn shell-compass" aria-label="Remettre la carte au nord" title="Nord en haut"
      onClick={() => { haptic("tap"); map.easeTo({ bearing: 0, pitch: 0, duration: 400 }); }}>
      <IconCompass size={24} style={{ transform: `rotate(${-view.bearing}deg)` }} />
    </button>
  );
}

export function RecenterButton() {
  const follow = useCore((s) => s.follow);
  const mode = useCore((s) => s.mode);
  const hasPosition = useCore((s) => s.position != null);
  if (follow || !hasPosition) return null;
  const go = () => { haptic("tap"); emit("map:recenter", {}); };
  // en conduite : pilule avec libellé, plus facile à viser
  if (mode === "drive") {
    return (
      <button className="pill shell-rail-btn shell-recenter-pill" onClick={go}>
        <IconLocate size={20} /> Recentrer
      </button>
    );
  }
  return (
    <button className="round shell-rail-btn" aria-label="Recentrer sur ma position" title="Recentrer (R)" onClick={go}>
      <IconLocate />
    </button>
  );
}
