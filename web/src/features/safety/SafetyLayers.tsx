import { useEffect, useRef } from "react";
import type maplibregl from "maplibre-gl";
import type { GeoJSONSource, Map as MLMap } from "maplibre-gl";
import { emit } from "../../core/bus";
import { formatDistance } from "../../core/geometry";
import { useCore, type LngLat } from "../../core/store";
import { cachedZoneTile, circlePolygon, fetchZoneTiles, fetchZfe, zoneTilesIn, type DangerZone, type ZfeResponse } from "./data";
import { useSafety } from "./engine";
import { useSafetySettings } from "./settings";

/**
 * Calques de la carte (zones de danger « façon Waze ») :
 *  - safety-zfe-*          périmètres ZFE (trait discret), à partir du zoom 8 ;
 *  - safety-zone-icons     une icône discrète par zone, au MILIEU du tronçon (jamais sur l'appareil),
 *                          regroupées quand elles se chevauchent, à partir du zoom 7,5 (rien en vue large) ;
 *  - safety-zone-lines     de près, le tronçon surligné sur la route (sous les libellés) ;
 *  - safety-route-zones    portions de l'itinéraire en zone de danger (aperçu et conduite).
 * Seules les tuiles visibles sont chargées. Le serveur n'envoie jamais la position d'un radar.
 */
const EMPTY = { type: "FeatureCollection" as const, features: [] };
type FC = GeoJSON.FeatureCollection;

const DANGER = "#ffcc00";
const ICON = "safety-zone-icon";
const MIN_ZOOM = 7.5;
const RATIO = 2;

/** Pastille sombre, liseré jaune, triangle « danger » (24 px logiques). */
function drawIcon(): ImageData {
  const px = 24 * RATIO;
  const cv = document.createElement("canvas");
  cv.width = cv.height = px;
  const g = cv.getContext("2d")!;
  g.beginPath();
  g.arc(px / 2, px / 2, px / 2 - 1.5 * RATIO, 0, Math.PI * 2);
  g.fillStyle = "rgba(14,14,20,0.92)";
  g.fill();
  g.lineWidth = 1.5 * RATIO;
  g.strokeStyle = "rgba(255,204,0,0.9)";
  g.stroke();
  // triangle arrondi + point d'exclamation
  const c = px / 2, h = 11 * RATIO, w = 12.5 * RATIO, top = c - h / 2 - 0.5 * RATIO;
  g.beginPath();
  g.moveTo(c, top);
  g.lineTo(c + w / 2, top + h);
  g.lineTo(c - w / 2, top + h);
  g.closePath();
  g.lineJoin = "round";
  g.lineWidth = 2 * RATIO;
  g.strokeStyle = DANGER;
  g.stroke();
  g.fillStyle = DANGER;
  g.fill();
  g.fillStyle = "#000";
  g.fillRect(c - 0.8 * RATIO, top + 3.2 * RATIO, 1.6 * RATIO, 4.2 * RATIO);
  g.fillRect(c - 0.8 * RATIO, top + 8.4 * RATIO, 1.6 * RATIO, 1.6 * RATIO);
  return g.getImageData(0, 0, px, px);
}

function firstSymbolLayer(map: MLMap) {
  return map.getStyle().layers?.find((l) => l.type === "symbol")?.id;
}

function sliceLine(coords: LngLat[], cum: number[], a: number, b: number): LngLat[] {
  const out: LngLat[] = [];
  const at = (d: number): LngLat => {
    let i = 1;
    while (i < cum.length - 1 && cum[i] < d) i++;
    const t = (d - cum[i - 1]) / (cum[i] - cum[i - 1] || 1);
    return [coords[i - 1][0] + (coords[i][0] - coords[i - 1][0]) * t, coords[i - 1][1] + (coords[i][1] - coords[i - 1][1]) * t];
  };
  out.push(at(a));
  for (let i = 0; i < cum.length; i++) if (cum[i] > a && cum[i] < b) out.push(coords[i]);
  out.push(at(b));
  return out;
}

export function SafetyLayers() {
  const map = useCore((s) => s.map);
  const mode = useCore((s) => s.mode);
  const { dangers, coords, cum } = useSafety();
  const showZones = useSafetySettings((s) => s.dangerZones);
  const showZfe = useSafetySettings((s) => s.zfe);
  const data = useRef<{ zones: FC; dots: FC; route: FC; zfe: FC }>({ zones: EMPTY, dots: EMPTY, route: EMPTY, zfe: EMPTY });
  const loaded = useRef(new Map<string, DangerZone>());

  // sources + calques (et remise en place après un changement de style clair/sombre)
  useEffect(() => {
    if (!map) return;
    const ensure = () => {
      if (!map.isStyleLoaded() && !map.getStyle()) return;
      const before = firstSymbolLayer(map);
      if (!map.getSource("safety-zfe")) map.addSource("safety-zfe", { type: "geojson", data: data.current.zfe });
      if (!map.getSource("safety-zones")) map.addSource("safety-zones", { type: "geojson", data: data.current.zones });
      if (!map.getSource("safety-zone-dots")) map.addSource("safety-zone-dots", { type: "geojson", data: data.current.dots, cluster: true, clusterRadius: 30, clusterMaxZoom: 12 });
      if (!map.getSource("safety-route-zones")) map.addSource("safety-route-zones", { type: "geojson", data: data.current.route });
      if (!map.getLayer("safety-zfe-fill")) {
        map.addLayer({ id: "safety-zfe-fill", type: "fill", source: "safety-zfe", minzoom: 8, paint: { "fill-color": "#ffffff", "fill-opacity": 0.035 } }, before);
      }
      if (!map.getLayer("safety-zfe-line")) {
        map.addLayer({
          id: "safety-zfe-line", type: "line", source: "safety-zfe", minzoom: 8,
          paint: { "line-color": "#ffffff", "line-opacity": 0.4, "line-width": 1.5, "line-dasharray": [3, 2] },
        }, before);
      }
      if (!map.hasImage(ICON)) map.addImage(ICON, drawIcon(), { pixelRatio: RATIO });
      if (!map.getLayer("safety-zones-fill")) {
        // disques de repli (aucune route trouvée)
        map.addLayer({ id: "safety-zones-fill", type: "fill", source: "safety-zones", minzoom: 11, filter: ["==", ["geometry-type"], "Polygon"], paint: { "fill-color": DANGER, "fill-opacity": 0.08 } }, before);
      }
      if (!map.getLayer("safety-zone-lines")) {
        map.addLayer({
          id: "safety-zone-lines", type: "line", source: "safety-zones", minzoom: 10,
          layout: { "line-cap": "round", "line-join": "round" },
          paint: {
            "line-color": DANGER,
            "line-opacity": ["interpolate", ["linear"], ["zoom"], 10, 0.3, 12, 0.5],
            "line-width": ["interpolate", ["linear"], ["zoom"], 10, 3, 14, 7, 17, 12],
          },
        }, before);
      }
      if (!map.getLayer("safety-zone-clusters")) {
        map.addLayer({
          id: "safety-zone-clusters", type: "symbol", source: "safety-zone-dots", minzoom: MIN_ZOOM,
          filter: ["has", "point_count"],
          layout: {
            "icon-image": ICON, "icon-allow-overlap": true,
            "text-field": ["get", "point_count_abbreviated"], "text-font": ["Noto Sans Bold"], "text-size": 11,
            "text-offset": [1.1, -0.9], "text-allow-overlap": true,
          },
          paint: { "text-color": "#000000", "text-halo-color": "#ffffff", "text-halo-width": 3 },
        });
      }
      if (!map.getLayer("safety-zone-icons")) {
        map.addLayer({
          id: "safety-zone-icons", type: "symbol", source: "safety-zone-dots", minzoom: MIN_ZOOM,
          filter: ["!", ["has", "point_count"]],
          layout: { "icon-image": ICON, "icon-allow-overlap": true, "icon-size": ["interpolate", ["linear"], ["zoom"], 8, 0.85, 14, 1] },
        });
      }
      if (!map.getLayer("safety-route-zones")) {
        map.addLayer({
          id: "safety-route-zones", type: "line", source: "safety-route-zones",
          layout: { "line-cap": "round", "line-join": "round" },
          paint: { "line-color": DANGER, "line-opacity": 0.5, "line-width": ["interpolate", ["linear"], ["zoom"], 8, 6, 16, 16] },
        });
      }
    };
    ensure();
    map.on("style.load", ensure);
    return () => {
      map.off("style.load", ensure);
      if (!map.getStyle()) return;
      for (const l of ["safety-route-zones", "safety-zone-icons", "safety-zone-clusters", "safety-zone-lines", "safety-zones-fill", "safety-zfe-line", "safety-zfe-fill"]) if (map.getLayer(l)) map.removeLayer(l);
      for (const s of ["safety-route-zones", "safety-zone-dots", "safety-zones", "safety-zfe"]) if (map.getSource(s)) map.removeSource(s);
    };
  }, [map]);

  const setData = (id: "safety-zfe" | "safety-zones" | "safety-zone-dots" | "safety-route-zones", key: "zfe" | "zones" | "dots" | "route", fc: FC) => {
    data.current[key] = fc;
    (map?.getSource(id) as GeoJSONSource | undefined)?.setData(fc);
  };

  // ZFE (une fois, le serveur met en cache)
  useEffect(() => {
    if (!map || !showZfe) { setData("safety-zfe", "zfe", EMPTY); return; }
    let alive = true;
    fetchZfe().then((r: ZfeResponse) => { if (alive) setData("safety-zfe", "zfe", r as unknown as FC); }).catch(() => {});
    return () => { alive = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, showZfe]);

  // zones de danger : seulement les tuiles visibles (zoom 8), à partir du zoom 7,5
  useEffect(() => {
    if (!map) return;
    if (!showZones) { setData("safety-zones", "zones", EMPTY); setData("safety-zone-dots", "dots", EMPTY); return; }
    let alive = true;
    let t = 0;
    const push = (keys: string[], area: [number, number, number, number]) => {
      let added = false;
      for (const k of keys) for (const z of cachedZoneTile(k) ?? []) if (!loaded.current.has(z.id)) { loaded.current.set(z.id, z); added = true; }
      if (added) {
        // tronçons : tout ce qui est chargé (peu d'objets : quelques centaines)
        setData("safety-zones", "zones", {
          type: "FeatureCollection",
          features: [...loaded.current.values()].map((z: DangerZone) => ({
            type: "Feature",
            properties: { id: z.id, kind: z.kind },
            geometry: z.r != null
              ? { type: "Polygon", coordinates: [circlePolygon(z.mid[0], z.mid[1], z.r, 32)] }
              : { type: "MultiLineString", coordinates: z.lines },
          })),
        });
      }
      // icônes : seulement la zone visible (+ marge)
      const [w, s, e, n] = area;
      setData("safety-zone-dots", "dots", {
        type: "FeatureCollection",
        features: [...loaded.current.values()]
          .filter((z) => z.mid[0] >= w && z.mid[0] <= e && z.mid[1] >= s && z.mid[1] <= n)
          .map((z) => ({ type: "Feature", properties: { id: z.id, len: Math.round(z.length) }, geometry: { type: "Point", coordinates: z.mid } })),
      });
    };
    const refresh = () => {
      if (t) return;
      // limitation (pas d'anti-rebond) : en conduite « moveend » tombe en continu
      t = window.setTimeout(() => {
        t = 0;
        if (!alive) return;
        if (map.getZoom() < MIN_ZOOM) { setData("safety-zone-dots", "dots", EMPTY); return; }
        const b = map.getBounds();
        const px = (b.getEast() - b.getWest()) * 0.25, py = (b.getNorth() - b.getSouth()) * 0.25;
        const area: [number, number, number, number] = [b.getWest() - px, b.getSouth() - py, b.getEast() + px, b.getNorth() + py];
        const keys = zoneTilesIn(...area, 24);
        push(keys, area);
        fetchZoneTiles(keys).then(() => { if (alive) push(keys, area); }).catch(() => {});
      }, 250);
    };
    map.on("moveend", refresh);
    refresh();
    const onCluster = async (e: maplibregl.MapLayerMouseEvent) => {
      const f = e.features?.[0];
      const src = map.getSource("safety-zone-dots") as GeoJSONSource | undefined;
      if (!f || !src) return;
      const zoom = await src.getClusterExpansionZoom(f.properties?.cluster_id as number);
      map.easeTo({ center: (f.geometry as GeoJSON.Point).coordinates as [number, number], zoom: zoom + 0.5, duration: 300 });
    };
    const onIcon = (e: maplibregl.MapLayerMouseEvent) => {
      const len = Number(e.features?.[0]?.properties?.len) || 0;
      emit("toast", { text: `Zone de danger sur ${formatDistance(len)} : reste attentif`, tone: "warn" });
    };
    map.on("click", "safety-zone-clusters", onCluster);
    map.on("click", "safety-zone-icons", onIcon);
    return () => {
      alive = false;
      window.clearTimeout(t);
      map.off("moveend", refresh);
      map.off("click", "safety-zone-clusters", onCluster);
      map.off("click", "safety-zone-icons", onIcon);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, showZones]);

  // portions de l'itinéraire en zone de danger
  useEffect(() => {
    if (!map) return;
    if (!showZones || mode === "browse" || !coords.length) { setData("safety-route-zones", "route", EMPTY); return; }
    setData("safety-route-zones", "route", {
      type: "FeatureCollection",
      features: dangers.map((z) => ({
        type: "Feature",
        properties: { id: z.id },
        geometry: { type: "LineString", coordinates: sliceLine(coords, cum, z.start, z.end) },
      })),
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, mode, dangers, coords, cum, showZones]);

  return null;
}
