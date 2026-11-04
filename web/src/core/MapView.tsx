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
    map.on("load", () => core().set({ map, mapReady: true }));
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
      padding: driving ? { top: window.innerHeight * 0.35, bottom: 0, left: 0, right: 0 } : { top: 0, bottom: 0, left: 0, right: 0 },
      duration: driving ? 900 : 600,
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
