import { useEffect } from "react";
import type { GeoJSONSource, Map as MLMap, MapLayerMouseEvent } from "maplibre-gl";
import { useCore, core } from "../../core/store";
import { colorVar, iconKey, inkOn, KIND_ORDER, KINDS, PATHS, type Kind, type Report } from "./catalog";
import { useReports, watchArea } from "./state";
import { DETAIL, openOwn } from "./ReportButton";

/**
 * Calques de carte : pastilles rondes par type (pictogramme sur couleur d'état), regroupées à
 * faible zoom (cluster MapLibre). Clic → fiche ; clic sur un groupe → zoom.
 */
const SRC = "reports-src";
const L_CLUSTER = "reports-clusters";
const L_COUNT = "reports-cluster-count";
const L_POINTS = "reports-points";
const SIZE = 34; // px logiques
const RATIO = 2;

function cssVar(name: string) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim() || "#888";
}

/** Dessine une pastille (cercle de couleur, liseré sombre, pictogramme) en ImageData. */
function drawDisc(kind: Kind, sub: string | null): ImageData {
  const px = SIZE * RATIO;
  const cv = document.createElement("canvas");
  cv.width = cv.height = px;
  const g = cv.getContext("2d")!;
  const c = colorVar(kind, sub);
  g.beginPath();
  g.arc(px / 2, px / 2, px / 2 - 1, 0, Math.PI * 2);
  g.fillStyle = "rgba(10,10,15,0.92)";
  g.fill();
  g.beginPath();
  g.arc(px / 2, px / 2, px / 2 - 2.5 * RATIO, 0, Math.PI * 2);
  g.fillStyle = cssVar(c);
  g.fill();
  const icon = 18 * RATIO;
  g.save();
  g.translate((px - icon) / 2, (px - icon) / 2);
  g.scale(icon / 24, icon / 24);
  g.strokeStyle = inkOn(c);
  g.lineWidth = 2.2;
  g.lineCap = "round";
  g.lineJoin = "round";
  g.stroke(new Path2D(PATHS[iconKey(kind, sub)]));
  g.restore();
  return g.getImageData(0, 0, px, px);
}

const imageName = (kind: Kind, sub: string | null) => `reports-${kind}${sub ? `-${sub}` : ""}`;

function addImages(map: MLMap) {
  for (const k of KIND_ORDER) {
    for (const sub of [null, ...KINDS[k].subs.map((s) => s.id)]) {
      const name = imageName(k, sub);
      if (!map.hasImage(name)) map.addImage(name, drawDisc(k, sub), { pixelRatio: RATIO });
    }
  }
}

function toGeoJSON(items: Record<string, Report>): GeoJSON.FeatureCollection {
  const t = Date.now();
  return {
    type: "FeatureCollection",
    features: Object.values(items).filter((r) => r.expiresAt > t).map((r) => ({
      type: "Feature",
      geometry: { type: "Point", coordinates: [r.lng, r.lat] },
      properties: { id: r.id, icon: imageName(r.type, r.sub), type: r.type },
    })),
  };
}

function install(map: MLMap) {
  addImages(map);
  if (!map.getSource(SRC)) {
    map.addSource(SRC, { type: "geojson", data: toGeoJSON(useReports.getState().items), cluster: true, clusterRadius: 42, clusterMaxZoom: 11 });
  }
  if (!map.getLayer(L_CLUSTER)) {
    map.addLayer({
      id: L_CLUSTER, type: "circle", source: SRC, filter: ["has", "point_count"],
      paint: {
        "circle-color": "rgba(14,14,20,0.9)",
        "circle-radius": ["step", ["get", "point_count"], 15, 10, 18, 50, 22],
        "circle-stroke-color": "rgba(255,255,255,0.55)",
        "circle-stroke-width": 1.5,
      },
    });
  }
  if (!map.getLayer(L_COUNT)) {
    map.addLayer({
      id: L_COUNT, type: "symbol", source: SRC, filter: ["has", "point_count"],
      layout: { "text-field": ["get", "point_count_abbreviated"], "text-font": ["Noto Sans Regular"], "text-size": 13, "text-allow-overlap": true },
      paint: { "text-color": "#ffffff" },
    });
  }
  if (!map.getLayer(L_POINTS)) {
    map.addLayer({
      id: L_POINTS, type: "symbol", source: SRC, filter: ["!", ["has", "point_count"]],
      layout: {
        "icon-image": ["get", "icon"],
        "icon-size": ["interpolate", ["linear"], ["zoom"], 10, 0.75, 15, 1, 18, 1.15],
        "icon-allow-overlap": true,
        "icon-ignore-placement": true,
        "icon-pitch-alignment": "viewport",
      },
    });
  }
}

export function ReportsLayer() {
  const map = useCore((s) => s.map);

  useEffect(() => {
    if (!map) return;
    install(map);
    const onStyle = () => install(map);
    map.on("style.load", onStyle);

    // données → source
    const push = () => (map.getSource(SRC) as GeoJSONSource | undefined)?.setData(toGeoJSON(useReports.getState().items));
    const unsub = useReports.subscribe((s, prev) => { if (s.items !== prev.items) push(); });

    // zone visible → chargement + tuiles temps réel (debounce)
    let t = 0;
    const refresh = () => {
      window.clearTimeout(t);
      t = window.setTimeout(() => {
        if (map.getZoom() < 7) return;
        const b = map.getBounds();
        const padX = (b.getEast() - b.getWest()) * 0.25, padY = (b.getNorth() - b.getSouth()) * 0.25;
        void watchArea(b.getWest() - padX, b.getSouth() - padY, b.getEast() + padX, b.getNorth() + padY, core().position?.coord);
      }, 350);
    };
    map.on("moveend", refresh);
    refresh();

    const onClick = (e: MapLayerMouseEvent) => {
      const id = e.features?.[0]?.properties?.id;
      if (typeof id === "string") openOwn(DETAIL, { id });
    };
    const onCluster = async (e: MapLayerMouseEvent) => {
      const f = e.features?.[0];
      const src = map.getSource(SRC) as GeoJSONSource | undefined;
      if (!f || !src) return;
      const zoom = await src.getClusterExpansionZoom(f.properties?.cluster_id as number);
      map.easeTo({ center: (f.geometry as GeoJSON.Point).coordinates as [number, number], zoom: zoom + 0.5, duration: 300 });
    };
    const pointer = () => { map.getCanvas().style.cursor = "pointer"; };
    const unpointer = () => { map.getCanvas().style.cursor = ""; };
    map.on("click", L_POINTS, onClick);
    map.on("click", L_CLUSTER, onCluster);
    for (const l of [L_POINTS, L_CLUSTER]) { map.on("mouseenter", l, pointer); map.on("mouseleave", l, unpointer); }

    return () => {
      window.clearTimeout(t);
      unsub();
      map.off("style.load", onStyle);
      map.off("moveend", refresh);
      map.off("click", L_POINTS, onClick);
      map.off("click", L_CLUSTER, onCluster);
      for (const l of [L_POINTS, L_CLUSTER]) { map.off("mouseenter", l, pointer); map.off("mouseleave", l, unpointer); }
      try {
        for (const l of [L_POINTS, L_COUNT, L_CLUSTER]) if (map.getLayer(l)) map.removeLayer(l);
        if (map.getSource(SRC)) map.removeSource(SRC);
      } catch { /* carte déjà détruite */ }
    };
  }, [map]);

  return null;
}
