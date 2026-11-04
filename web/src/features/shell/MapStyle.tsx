import { useEffect, useState } from "react";
import { useCore, core } from "../../core/store";
import { usePrefs } from "../../core/prefs";
import { EXTERNAL } from "../../core/services";
import { DEFAULT_CENTER } from "../../core/geo";
import { isDaytime } from "./sun";

/**
 * Applique usePrefs.mapStyle à la carte (slot "map", monté quand la carte est prête).
 *   auto  → clair entre le lever et le coucher du soleil (calculés pour la position), sombre sinon
 *   dark / light → forcé
 * `map.setStyle(url, { diff: false })` : rechargement complet, donc l'évènement `style.load` est
 * bien émis et chaque module remet ses sources/calques (avec diff, MapLibre supprimerait les
 * calques des modules sans prévenir).
 * Pose aussi `data-map-theme="light|dark"` sur <html> pour les modules qui veulent adapter
 * leurs couleurs au fond de carte.
 */

export type Theme = "light" | "dark";

/** Le thème que l'on veut maintenant, selon le réglage, l'heure et la position. */
export function wantedTheme(style: "auto" | "dark" | "light", at = new Date()): Theme {
  if (style !== "auto") return style;
  const c = core().position?.coord ?? DEFAULT_CENTER;
  return isDaytime(at, c[1], c[0]) ? "light" : "dark";
}

// Thème appliqué à chaque instance de carte (MapView la crée avec le style sombre ; en dev,
// StrictMode peut la recréer, d'où la WeakMap plutôt qu'une variable globale).
const applied = new WeakMap<object, Theme>();

export function MapStyle() {
  const map = useCore((s) => s.map);
  const style = usePrefs((s) => s.mapStyle);
  const [tick, setTick] = useState(0);

  // en auto, on réévalue chaque minute (lever/coucher du soleil en pleine conduite)
  useEffect(() => {
    if (style !== "auto") return;
    const t = window.setInterval(() => setTick((n) => n + 1), 60_000);
    return () => window.clearInterval(t);
  }, [style]);

  useEffect(() => {
    if (!map) return;
    const theme = wantedTheme(style);
    document.documentElement.dataset.mapTheme = theme;
    if (theme === (applied.get(map) ?? "dark")) return;
    applied.set(map, theme);
    map.setStyle(theme === "light" ? EXTERNAL.styleLight : EXTERNAL.styleDark, { diff: false });
  }, [map, style, tick]);

  return null;
}
