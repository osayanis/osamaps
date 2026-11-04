import { useEffect, useRef } from "react";
import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import { useCore, core } from "./store";
import { EXTERNAL } from "./services";
import { DEFAULT_CENTER } from "./geo";
import { slotEntries } from "./registry";

/**
 * La carte plein écran. Les calques des fonctionnalités (slot "map") sont montés une fois la
 * carte chargée ; ils récupèrent l'instance avec `useCore((s) => s.map)`.
 * Le suivi de position (follow) est géré ici : en conduite, la carte suit et s'oriente.
 */
/** Sur grand écran, le panneau devient une colonne à gauche (classe posée par le module shell) :
 *  on décale le centre de la carte pour que la position ne soit pas cachée dessous. */
function sidePanel() {
  if (!document.documentElement.classList.contains("osa-side")) return 0;
  const col = document.querySelector<HTMLElement>(".slot-sheet");
  return col && col.offsetHeight > 0 ? col.offsetWidth + 12 : 0;
}

export function MapView() {
  const el = useRef<HTMLDivElement>(null);
  const mapReady = useCore((s) => s.mapReady);

  useEffect(() => {
    if (!el.current) return;
    const map = new maplibregl.Map({
      container: el.current,
      style: EXTERNAL.styleDark,
      center: DEFAULT_CENTER,
      zoom: 13,
      attributionControl: { compact: true },
      pitchWithRotate: true,
    });
    // un geste de l'utilisateur coupe le suivi (le bouton « recentrer » le remet)
    const userMove = (e: { originalEvent?: unknown }) => { if (e.originalEvent) core().set({ follow: false }); };
    map.on("dragstart", userMove);
    map.on("rotatestart", userMove);
    map.on("load", () => {
      // l'attribution compacte s'ouvre seule au démarrage : on la replie (le « i » reste visible)
      el.current?.querySelector(".maplibregl-ctrl-attrib")?.classList.remove("maplibregl-compact-show");
      core().set({ map, mapReady: true });
    });
    return () => { core().set({ map: null, mapReady: false }); map.remove(); };
  }, []);

  // suivi de la position
  useEffect(() => useCore.subscribe((s, prev) => {
    const { map, position, follow, mode } = s;
    if (!map || !position || !follow) return;
    if (position === prev.position && follow === prev.follow && mode === prev.mode) return;
    const driving = mode === "drive";
    map.easeTo({
      center: position.coord,
      zoom: driving ? Math.max(map.getZoom(), 16.5) : map.getZoom(),
      bearing: driving && position.heading != null ? position.heading : map.getBearing(),
      pitch: driving ? 55 : map.getPitch(),
      // en conduite, la position est placée plus bas que le centre (on voit la route devant)
      padding: { top: driving ? window.innerHeight * 0.35 : 0, bottom: 0, right: 0, left: sidePanel() },
      // durée = intervalle entre deux positions : la caméra arrive juste quand la suivante tombe
      // (sinon chaque easeTo est interrompu et le retard s'accumule à grande vitesse)
      duration: driving && prev.position ? Math.min(1000, Math.max(150, position.time - prev.position.time)) : 600,
      easing: (t) => t,
    });
  }), []);

  return (
    <div className="map-root">
      <div ref={el} className="map-canvas" />
      {mapReady && slotEntries("map").map(({ featureId, Component }, i) => <Component key={`${featureId}-${i}`} />)}
    </div>
  );
}
