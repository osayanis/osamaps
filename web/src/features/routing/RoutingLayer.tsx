import { useEffect, useRef } from "react";
import maplibregl, { type GeoJSONSource, type Map as MLMap, type MapMouseEvent } from "maplibre-gl";
import { core, useCore, type LngLat, type Route } from "../../core/store";
import { useRouting, routing, placeFrom } from "./state";
import { addStop, selectRoute } from "./controller";
import { reverseGeocode } from "./geocode";

/**
 * Calques de l'itinéraire : alternatives grises cliquables, tracé actif blanc avec halo, partie
 * déjà parcourue estompée en conduite, marqueurs d'arrivée et d'étapes.
 */
const SRC_ALT = "routing-alt";
const SRC_ACTIVE = "routing-active";
const SRC_PASSED = "routing-passed";
const LAYERS = ["routing-alt-casing", "routing-alt-line", "routing-alt-hit", "routing-passed-line", "routing-line-glow", "routing-line-casing", "routing-line"];

type FC = GeoJSON.FeatureCollection<GeoJSON.LineString, { idx: number }>;
const empty: FC = { type: "FeatureCollection", features: [] };
const line = (coords: LngLat[], idx: number): GeoJSON.Feature<GeoJSON.LineString, { idx: number }> =>
  ({ type: "Feature", properties: { idx }, geometry: { type: "LineString", coordinates: coords } });

/**
 * Calque devant lequel insérer le tracé : le premier libellé du fond de carte situé APRÈS toutes
 * ses routes. (Le premier calque « symbol » ne suffit pas : certains styles mettent des libellés
 * d'eau avant les routes, qui se dessineraient alors par-dessus notre tracé.)
 */
function labelLayer(map: MLMap): string | undefined {
  const layers = map.getStyle().layers ?? [];
  const isBase = (l: (typeof layers)[number]) => !("source" in l) || map.getSource(String(l.source))?.type !== "geojson";
  let last = -1;
  layers.forEach((l, i) => { if (l.type !== "symbol" && isBase(l)) last = i; });
  for (let i = last + 1; i < layers.length; i++) if (layers[i].type === "symbol" && isBase(layers[i])) return layers[i].id;
  return undefined;
}

function addLayers(map: MLMap) {
  for (const id of [SRC_ALT, SRC_ACTIVE, SRC_PASSED]) {
    if (!map.getSource(id)) map.addSource(id, { type: "geojson", data: empty, lineMetrics: false });
  }
  const before = labelLayer(map);
  const add = (spec: maplibregl.LayerSpecification) => { if (!map.getLayer(spec.id)) map.addLayer(spec, before); };
  const round = { "line-cap": "round", "line-join": "round" } as const;
  add({ id: "routing-alt-casing", type: "line", source: SRC_ALT, layout: round, paint: { "line-color": "#000", "line-opacity": 0.35, "line-width": ["interpolate", ["linear"], ["zoom"], 8, 6, 16, 12] } });
  add({ id: "routing-alt-line", type: "line", source: SRC_ALT, layout: round, paint: { "line-color": "#9a9aa2", "line-opacity": 0.7, "line-width": ["interpolate", ["linear"], ["zoom"], 8, 3.5, 16, 8] } });
  // zone de clic large et invisible (au doigt, une ligne de 4 px est introuvable)
  add({ id: "routing-alt-hit", type: "line", source: SRC_ALT, layout: round, paint: { "line-color": "#000", "line-opacity": 0, "line-width": 28 } });
  add({ id: "routing-passed-line", type: "line", source: SRC_PASSED, layout: round, paint: { "line-color": "#ffffff", "line-opacity": 0.22, "line-width": ["interpolate", ["linear"], ["zoom"], 8, 3.5, 16, 9] } });
  add({ id: "routing-line-glow", type: "line", source: SRC_ACTIVE, layout: round, paint: { "line-color": "#ffffff", "line-opacity": 0.14, "line-blur": ["interpolate", ["linear"], ["zoom"], 8, 8, 16, 14], "line-width": ["interpolate", ["linear"], ["zoom"], 8, 16, 16, 30] } });
  add({ id: "routing-line-casing", type: "line", source: SRC_ACTIVE, layout: round, paint: { "line-color": "#0a0a0f", "line-opacity": 0.8, "line-width": ["interpolate", ["linear"], ["zoom"], 8, 7, 16, 14] } });
  add({ id: "routing-line", type: "line", source: SRC_ACTIVE, layout: round, paint: { "line-color": "#ffffff", "line-width": ["interpolate", ["linear"], ["zoom"], 8, 4, 16, 9] } });
}

function removeLayers(map: MLMap) {
  try {
    for (const id of LAYERS) if (map.getLayer(id)) map.removeLayer(id);
    for (const id of [SRC_ALT, SRC_ACTIVE, SRC_PASSED]) if (map.getSource(id)) map.removeSource(id);
  } catch { /* carte déjà détruite */ }
}

function boundsOf(routes: Route[]): maplibregl.LngLatBounds | null {
  let b: maplibregl.LngLatBounds | null = null;
  for (const r of routes) for (const c of r.coords) {
    if (!b) b = new maplibregl.LngLatBounds(c, c); else b.extend(c);
  }
  return b;
}

function markerEl(kind: "dest" | "stop", label?: string) {
  const el = document.createElement("div");
  el.className = `routing-marker routing-marker-${kind}`;
  if (label) el.textContent = label;
  el.setAttribute("aria-hidden", "true");
  return el;
}

export function RoutingLayer() {
  const map = useCore((s) => s.map);
  const routes = useCore((s) => s.routes);
  const activeRoute = useCore((s) => s.activeRoute);
  const mode = useCore((s) => s.mode);
  const destination = useCore((s) => s.destination);
  const shapeIndex = useCore((s) => (s.mode === "drive" ? s.progress?.shapeIndex ?? 0 : 0));
  const stops = useRouting((s) => s.stops);
  const meta = useRouting((s) => s.meta);
  const sheetHeight = useRouting((s) => s.sheetHeight);
  const pickOnMap = useRouting((s) => s.pickOnMap);
  const status = useRouting((s) => s.status);
  const styleTick = useRef(0);
  const destMarker = useRef<maplibregl.Marker | null>(null);
  const stopMarkers = useRef<maplibregl.Marker[]>([]);
  const fitted = useRef<{ key: string; touched: boolean; height: number }>({ key: "", touched: false, height: 0 });

  // sources/calques + remise après un changement de style
  useEffect(() => {
    if (!map) return;
    const draw = () => { addLayers(map); styleTick.current++; paint(); };
    draw();
    map.on("style.load", draw);
    const touched = (e: { originalEvent?: unknown }) => { if (e.originalEvent) fitted.current.touched = true; };
    map.on("dragstart", touched);
    map.on("zoomstart", touched);
    return () => {
      map.off("style.load", draw);
      map.off("dragstart", touched);
      map.off("zoomstart", touched);
      removeLayers(map);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map]);

  // données des tracés
  function paint() {
    if (!map) return;
    const { routes, activeRoute, mode, progress } = core();
    const active = routes[activeRoute];
    const alt = mode === "preview" ? routes.map((r, i) => (i === activeRoute ? null : line(r.coords, i))).filter(Boolean) : [];
    const idx = mode === "drive" && active ? Math.min(Math.max(0, progress?.shapeIndex ?? 0), active.coords.length - 1) : 0;
    const remaining = active ? active.coords.slice(idx) : [];
    const passed = active && idx > 0 ? active.coords.slice(0, idx + 1) : [];
    (map.getSource(SRC_ALT) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: alt as FC["features"] });
    (map.getSource(SRC_ACTIVE) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: remaining.length > 1 ? [line(remaining, activeRoute)] : [] });
    (map.getSource(SRC_PASSED) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: passed.length > 1 ? [line(passed, activeRoute)] : [] });
  }
  useEffect(paint, [map, routes, activeRoute, mode, shapeIndex]);

  // clic sur une alternative = la choisir ; mode « poser une étape » = toucher la carte
  useEffect(() => {
    if (!map) return;
    const onClick = async (e: MapMouseEvent) => {
      const { mode } = core();
      if (routing().pickOnMap && mode !== "browse") {
        const coord: LngLat = [e.lngLat.lng, e.lngLat.lat];
        routing().set({ pickOnMap: false });
        const found = await reverseGeocode(coord).catch(() => null);
        addStop(placeFrom(found?.name ?? "Étape", coord, found?.detail));
        return;
      }
      if (mode !== "preview") return;
      const box: [maplibregl.PointLike, maplibregl.PointLike] = [[e.point.x - 10, e.point.y - 10], [e.point.x + 10, e.point.y + 10]];
      if (map.queryRenderedFeatures(box, { layers: ["routing-line"] }).length) return;
      const hit = map.queryRenderedFeatures(box, { layers: ["routing-alt-hit"] })[0];
      const idx = hit?.properties?.idx;
      if (typeof idx === "number") selectRoute(idx);
    };
    const enter = () => { map.getCanvas().style.cursor = "pointer"; };
    const leave = () => { map.getCanvas().style.cursor = routing().pickOnMap ? "crosshair" : ""; };
    map.on("click", onClick);
    map.on("mouseenter", "routing-alt-hit", enter);
    map.on("mouseleave", "routing-alt-hit", leave);
    return () => {
      map.off("click", onClick);
      map.off("mouseenter", "routing-alt-hit", enter);
      map.off("mouseleave", "routing-alt-hit", leave);
    };
  }, [map]);

  useEffect(() => {
    if (map) map.getCanvas().style.cursor = pickOnMap ? "crosshair" : "";
  }, [map, pickOnMap]);

  // cadrage : à chaque nouveau calcul (aperçu), et quand le panneau change de taille tant que
  // l'utilisateur n'a pas bougé la carte
  useEffect(() => {
    if (!map || mode !== "preview" || !routes.length) return;
    const key = routes.map((r) => r.id).join("|");
    const f = fitted.current;
    const isNew = key !== f.key;
    if (!isNew && (f.touched || Math.abs(sheetHeight - f.height) < 24)) return;
    const b = boundsOf(routes);
    if (!b) return;
    const pos = core().position?.coord;
    if (pos) b.extend(pos);
    const h = window.innerHeight;
    // on garde au moins ~160 px de carte utile au-dessus du panneau
    const bottom = Math.max(40, Math.min(h - 96 - 160, (sheetHeight || h * 0.4) + 24));
    const raf = requestAnimationFrame(() => {
      map.fitBounds(b, {
        padding: { top: 96, bottom, left: 36, right: 64 },
        bearing: 0,
        pitch: 0,
        duration: isNew && f.key === "" ? 0 : 500,
        maxZoom: 16,
      });
      fitted.current = { key, touched: false, height: sheetHeight };
    });
    return () => cancelAnimationFrame(raf);
  }, [map, mode, routes, sheetHeight]);

  useEffect(() => { if (mode === "browse") fitted.current = { key: "", touched: false, height: 0 }; }, [mode]);

  // pas d'itinéraire : on montre au moins où se trouve la destination
  useEffect(() => {
    if (!map || mode !== "preview" || status !== "error" || !destination) return;
    const b = new maplibregl.LngLatBounds(destination.coord, destination.coord);
    const pos = core().position?.coord;
    if (pos) b.extend(pos);
    const h = window.innerHeight;
    map.fitBounds(b, { padding: { top: 96, bottom: Math.min(h - 256, routing().sheetHeight + 24), left: 48, right: 64 }, maxZoom: 14, duration: 400 });
  }, [map, mode, status, destination]);

  // marqueur d'arrivée
  useEffect(() => {
    if (!map) return;
    destMarker.current?.remove();
    destMarker.current = null;
    if (!destination || mode === "browse") return;
    destMarker.current = new maplibregl.Marker({ element: markerEl("dest"), anchor: "center" }).setLngLat(destination.coord).addTo(map);
    return () => { destMarker.current?.remove(); destMarker.current = null; };
  }, [map, destination, mode]);

  // marqueurs d'étapes (numérotés ; ceux déjà passés disparaissent en conduite)
  const activeId = routes[activeRoute]?.id;
  const stopIdx = activeId ? meta[activeId]?.stopShapeIndex : undefined;
  const passedStops = mode === "drive" && stopIdx ? stopIdx.filter((i) => i < shapeIndex).length : 0;
  useEffect(() => {
    if (!map) return;
    stopMarkers.current.forEach((m) => m.remove());
    stopMarkers.current = [];
    if (mode === "browse") return;
    stops.forEach((s, k) => {
      if (k < passedStops) return;
      stopMarkers.current.push(new maplibregl.Marker({ element: markerEl("stop", String(k + 1)), anchor: "center" }).setLngLat(s.coord).addTo(map));
    });
    return () => { stopMarkers.current.forEach((m) => m.remove()); stopMarkers.current = []; };
  }, [map, stops, mode, passedStops]);

  return null;
}
