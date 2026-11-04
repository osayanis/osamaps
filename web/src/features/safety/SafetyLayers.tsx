import { useEffect, useRef } from "react";
import type { GeoJSONSource, Map as MLMap } from "maplibre-gl";
import { useCore, type LngLat } from "../../core/store";
import { circlePolygon, fetchZfe, fetchZones, type DangerZone, type ZfeResponse } from "./data";
import { useSafety } from "./engine";
import { useSafetySettings } from "./settings";

/**
 * Calques de la carte :
 *  - safety-zfe-*        périmètres ZFE (trait discret), toujours visibles à partir du zoom 8 ;
 *  - safety-zones-*      disques des zones de danger en exploration (zoom ≥ 9) ;
 *  - safety-route-zones  portions de l'itinéraire en zone de danger (aperçu et conduite).
 * Jamais de marqueur ponctuel : on ne montre pas où est l'appareil.
 */
const EMPTY = { type: "FeatureCollection" as const, features: [] };
type FC = GeoJSON.FeatureCollection;

const DANGER = "#ffcc00";

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
  const data = useRef<{ zones: FC; route: FC; zfe: FC }>({ zones: EMPTY, route: EMPTY, zfe: EMPTY });

  // sources + calques (et remise en place après un changement de style clair/sombre)
  useEffect(() => {
    if (!map) return;
    const ensure = () => {
      if (!map.isStyleLoaded() && !map.getStyle()) return;
      const before = firstSymbolLayer(map);
      if (!map.getSource("safety-zfe")) map.addSource("safety-zfe", { type: "geojson", data: data.current.zfe });
      if (!map.getSource("safety-zones")) map.addSource("safety-zones", { type: "geojson", data: data.current.zones });
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
      if (!map.getLayer("safety-zones-fill")) {
        map.addLayer({ id: "safety-zones-fill", type: "fill", source: "safety-zones", minzoom: 9, paint: { "fill-color": DANGER, "fill-opacity": 0.07 } }, before);
      }
      if (!map.getLayer("safety-zones-line")) {
        map.addLayer({
          id: "safety-zones-line", type: "line", source: "safety-zones", minzoom: 9,
          paint: { "line-color": DANGER, "line-opacity": 0.55, "line-width": 1.2, "line-dasharray": [2, 2] },
        }, before);
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
      for (const l of ["safety-route-zones", "safety-zones-line", "safety-zones-fill", "safety-zfe-line", "safety-zfe-fill"]) if (map.getLayer(l)) map.removeLayer(l);
      for (const s of ["safety-route-zones", "safety-zones", "safety-zfe"]) if (map.getSource(s)) map.removeSource(s);
    };
  }, [map]);

  const setData = (id: "safety-zfe" | "safety-zones" | "safety-route-zones", key: "zfe" | "zones" | "route", fc: FC) => {
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

  // disques des zones de danger visibles en exploration
  useEffect(() => {
    if (!map) return;
    if (!showZones || mode !== "browse") { setData("safety-zones", "zones", EMPTY); return; }
    let timer = 0;
    let alive = true;
    const load = () => {
      window.clearTimeout(timer);
      timer = window.setTimeout(() => {
        if (map.getZoom() < 9) return;
        const b = map.getBounds();
        fetchZones([b.getWest(), b.getSouth(), b.getEast(), b.getNorth()])
          .then((r) => {
            if (!alive) return;
            setData("safety-zones", "zones", {
              type: "FeatureCollection",
              features: r.zones.map((z: DangerZone) => ({
                type: "Feature",
                properties: { id: z.id, kind: z.kind },
                geometry: { type: "Polygon", coordinates: [circlePolygon(z.lng, z.lat, z.r)] },
              })),
            });
          })
          .catch(() => {});
      }, 350);
    };
    load();
    map.on("moveend", load);
    return () => { alive = false; window.clearTimeout(timer); map.off("moveend", load); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [map, mode, showZones]);

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
