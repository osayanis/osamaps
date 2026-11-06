import { useEffect, useRef } from "react";
import type { GeoJSONSource, Map as MLMap, MapMouseEvent } from "maplibre-gl";
import { useCore, core } from "../../core/store";
import { getSocket } from "../../core/services";
import { fetchEvents, fetchSegments, type Bbox, type EventFeature, type EventKind, type SegmentFeature } from "./api";
import { useTraffic } from "./state";
import { EVENT_GLYPHS, EVENT_TONE, eventImage } from "./icons";
import { notifyTrafficUpdate } from "./drive";

const SRC = "traffic-segments";
const SRC_EV = "traffic-events";
const L_LINES = "traffic-lines";
const L_EVENTS = "traffic-events-icons";
const L_CLUSTER = "traffic-events-cluster";
const L_CLUSTER_N = "traffic-events-cluster-count";
const SRC_EVL = "traffic-event-lines";
const L_EVLINES = "traffic-event-lines";
const MIN_ZOOM = 7;
const MAX_SPAN = 3.8; // degrés (le serveur refuse au-delà de 4)
const ATTRIBUTION = "Trafic : OsaMaps, Bison Futé, DiaLog, collectivités, Météo-France/MeteoAlarm, ONISR, Autobahn, NDW, DGT, SCT, CITA";

/** Densité selon le zoom (le serveur filtre déjà ; on affine sans recharger). */
function visibleAt(p: EventFeature["properties"], z: number) {
  if (p.type === "weather" || p.type === "flood") return z < 12 || p.severity >= 3; // vigilance : vue d'ensemble
  // le serveur classe chaque évènement : en vue ville, seulement ce qui compte pour un conducteur ;
  // chantiers de rue, arrêtés locaux et points noirs seulement de près
  if (typeof p.minZoom === "number") return z >= p.minZoom;
  switch (p.type) {
    case "hotspot": return z >= 12.5 || (z >= 11 && p.severity >= 2);
    case "fuel": return z >= 11;
    case "works": case "lanes": return p.severity >= 2 ? z >= 9 : z >= 12;
    default: return p.severity >= 3 || z >= 9;
  }
}
const RANK: Record<EventKind, number> = { closure: 0, accident: 1, jam: 2, danger: 3, flood: 4, weather: 5, lanes: 6, works: 7, fuel: 8, hotspot: 9 };

const cssVar = (name: string, fallback: string) =>
  getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;

/** Contrôleur impératif du calque (une instance par carte). */
function createController(map: MLMap) {
  const segs = new Map<string, SegmentFeature>();
  let events: EventFeature[] = [];
  let seq = 0;
  let raf = 0;
  let watching = false;
  let visible = useTraffic.getState().visible;
  const color = { ok: cssVar("--ok", "#34c759"), slow: cssVar("--slow", "#ff9f0a"), jam: cssVar("--jam", "#ff453a") };

  const firstSymbolLayer = () => map.getStyle().layers?.find((l) => l.type === "symbol")?.id;

  function install() {
    if (!map.getSource(SRC)) {
      map.addSource(SRC, { type: "geojson", data: segCollection(), attribution: ATTRIBUTION });
    }
    if (!map.getSource(SRC_EV)) {
      // regroupement natif de MapLibre (comme Waze) ; l'évènement le plus important du groupe donne l'icône
      map.addSource(SRC_EV, {
        type: "geojson", data: evCollection(), cluster: true, clusterRadius: 46, clusterMaxZoom: 14,
        clusterProperties: { top: ["min", ["get", "rank"]] },
      });
    }
    if (!map.getSource(SRC_EVL)) map.addSource(SRC_EVL, { type: "geojson", data: lineCollection() });
    for (const kind of Object.keys(EVENT_GLYPHS) as EventKind[]) {
      for (const severe of [false, true]) {
        const id = `traffic-ev-${kind}${severe ? "-s" : ""}`;
        if (!map.hasImage(id)) map.addImage(id, eventImage(kind, cssVar(EVENT_TONE[kind], "#fff"), 2, severe), { pixelRatio: 2 });
      }
    }
    const vis = visible ? "visible" : "none";
    if (!map.getLayer(L_LINES)) {
      // sous les libellés : les noms de rues restent lisibles par-dessus le trafic
      map.addLayer({
        id: L_LINES,
        type: "line",
        source: SRC,
        layout: {
          visibility: vis,
          "line-cap": "round",
          "line-join": "round",
          "line-sort-key": ["match", ["get", "level"], "jam", 3, "slow", 2, 1],
        },
        paint: {
          "line-color": ["match", ["get", "level"], "jam", color.jam, "slow", color.slow, color.ok],
          "line-width": ["interpolate", ["exponential", 1.5], ["zoom"], 6, 1.2, 10, 2.6, 14, 5, 18, 11],
          // décalé vers la droite du sens de circulation : les deux sens d'une route ne se superposent pas
          "line-offset": ["interpolate", ["exponential", 1.5], ["zoom"], 6, 0.6, 10, 1.6, 14, 3.5, 18, 8],
          "line-opacity": ["match", ["get", "level"], "ok", 0.7, 0.95],
        },
      }, firstSymbolLayer());
    }
    if (!map.getLayer(L_EVLINES)) {
      map.addLayer({
        id: L_EVLINES, type: "line", source: SRC_EVL, minzoom: 12,
        layout: { visibility: vis, "line-cap": "round" },
        paint: {
          "line-color": ["match", ["get", "type"], "closure", color.jam, color.slow],
          "line-width": ["match", ["get", "type"], "closure", 5, 4],
          "line-dasharray": ["match", ["get", "type"], "closure", ["literal", [0.4, 1.6]], ["literal", [1.5, 1.5]]],
          "line-opacity": 0.9,
        },
      }, firstSymbolLayer());
    }
    if (!map.getLayer(L_CLUSTER)) {
      const sym = (k: EventKind) => ["==", ["get", "top"], RANK[k]];
      map.addLayer({
        id: L_CLUSTER, type: "symbol", source: SRC_EV, minzoom: 7, filter: ["has", "point_count"],
        layout: {
          visibility: vis,
          "icon-image": ["case",
            ...(Object.keys(RANK) as EventKind[]).flatMap((k) => [sym(k), `traffic-ev-${k}`]), "traffic-ev-danger"] as never,
          "icon-size": 0.85,
          "icon-allow-overlap": true,
          "symbol-sort-key": ["get", "top"],
        },
      });
      map.addLayer({
        id: L_CLUSTER_N, type: "symbol", source: SRC_EV, minzoom: 7, filter: ["has", "point_count"],
        layout: {
          visibility: vis,
          "text-field": ["case", [">", ["get", "point_count"], 99], "99+", ["to-string", ["get", "point_count"]]],
          "text-font": ["Noto Sans Bold"], "text-size": 9.5, "text-offset": [1.05, -0.95], "text-allow-overlap": true, "icon-allow-overlap": true,
        },
        paint: { "text-color": "#000", "text-halo-color": "#fff", "text-halo-width": 4 },
      });
    }
    if (!map.getLayer(L_EVENTS)) {
      map.addLayer({
        id: L_EVENTS,
        type: "symbol",
        source: SRC_EV,
        minzoom: 7,
        filter: ["!", ["has", "point_count"]],
        layout: {
          visibility: vis,
          "icon-image": ["concat", "traffic-ev-", ["get", "type"],
            ["case", ["all", [">=", ["get", "severity"], 3], ["!=", ["get", "type"], "hotspot"]], "-s", ""]],
          // points noirs (accidentalité passée) : petites pastilles discrètes, annoncées surtout en conduite
          "icon-size": ["interpolate", ["linear"], ["zoom"],
            8, ["case", ["==", ["get", "type"], "hotspot"], 0.55, 0.8],
            12, ["case", ["==", ["get", "type"], "hotspot"], 0.62, 0.95],
            16, ["case", ["==", ["get", "type"], "hotspot"], 0.7, 1.05]],
          "icon-allow-overlap": ["step", ["zoom"], false, 11, true],
          "icon-padding": 2,
          "symbol-sort-key": ["get", "rank"],
        },
        paint: { "icon-opacity": ["case", ["==", ["get", "type"], "hotspot"], 0.75, 1] },
      });
    }
  }

  function uninstall() {
    for (const l of [L_EVENTS, L_CLUSTER_N, L_CLUSTER, L_EVLINES, L_LINES]) if (map.getLayer(l)) map.removeLayer(l);
    for (const s of [SRC_EV, SRC_EVL, SRC]) if (map.getSource(s)) map.removeSource(s);
  }

  /** Évènements visibles au zoom courant, avec un rang numérique (pour le regroupement). */
  function evCollection() {
    const z = map.getZoom();
    return {
      type: "FeatureCollection" as const,
      features: events.filter((e) => visibleAt(e.properties, z)).map((e) => ({
        type: "Feature" as const, geometry: e.geometry,
        // MapLibre aplatit les objets imbriqués : on ne garde que l'utile, la fiche relit l'original par id
        properties: { id: e.properties.id, type: e.properties.type, severity: e.properties.severity, rank: RANK[e.properties.type] ?? 9 },
      })),
    };
  }
  function lineCollection() {
    return {
      type: "FeatureCollection" as const,
      features: events.filter((e) => e.properties.line && ["closure", "lanes", "works"].includes(e.properties.type) && visibleAt(e.properties, map.getZoom()))
        .map((e) => ({ type: "Feature" as const, geometry: { type: "LineString" as const, coordinates: e.properties.line! }, properties: { id: e.properties.id, type: e.properties.type } })),
    };
  }

  function segCollection() {
    return { type: "FeatureCollection" as const, features: [...segs.values()] };
  }

  function render() {
    if (raf) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      (map.getSource(SRC) as GeoJSONSource | undefined)?.setData(segCollection());
      (map.getSource(SRC_EV) as GeoJSONSource | undefined)?.setData(evCollection());
      (map.getSource(SRC_EVL) as GeoJSONSource | undefined)?.setData(lineCollection());
    });
  }

  function viewBbox(): Bbox | null {
    if (map.getZoom() < MIN_ZOOM) return null;
    const b = map.getBounds();
    let w = b.getWest(), s = b.getSouth(), e = b.getEast(), n = b.getNorth();
    const mx = (e - w) * 0.15, my = (n - s) * 0.15;
    w -= mx; e += mx; s -= my; n += my;
    const cx = (w + e) / 2, cy = (s + n) / 2;
    if (e - w > MAX_SPAN) { w = cx - MAX_SPAN / 2; e = cx + MAX_SPAN / 2; }
    if (n - s > MAX_SPAN) { s = cy - MAX_SPAN / 2; n = cy + MAX_SPAN / 2; }
    return [Math.max(-180, w), Math.max(-85, s), Math.min(180, e), Math.min(85, n)];
  }

  async function refresh() {
    const my = ++seq;
    const bb = visible ? viewBbox() : null;
    if (!bb) {
      if (watching) { getSocket().emit("traffic:watch", { bbox: null }); watching = false; }
      if (segs.size || events.length) { segs.clear(); events = []; render(); }
      return;
    }
    getSocket().emit("traffic:watch", { bbox: bb });
    watching = true;
    try {
      // les évènements ne doivent pas faire échouer le trafic (serveur plus ancien, source lente…)
      const [s, e] = await Promise.all([fetchSegments(bb), fetchEvents(bb, map.getZoom()).catch(() => null)]);
      if (my !== seq) return;
      segs.clear();
      for (const f of s.features) segs.set(f.properties.id, f);
      if (e) events = e.features;
      render();
    } catch {
      /* serveur injoignable : on garde ce qu'on a */
    }
  }

  let debounce = 0;
  let lastZoom = map.getZoom();
  const onMoveEnd = () => {
    // le filtre de densité dépend du zoom : on redessine tout de suite, puis on recharge
    if (Math.round(map.getZoom() * 2) !== Math.round(lastZoom * 2)) { lastZoom = map.getZoom(); render(); }
    window.clearTimeout(debounce); debounce = window.setTimeout(refresh, 600);
  };

  const onUpdate = (p: { features?: SegmentFeature[]; removed?: string[] }) => {
    if (!visible) return notifyTrafficUpdate();
    for (const f of p.features ?? []) if (f?.properties?.id) segs.set(f.properties.id, f);
    for (const id of p.removed ?? []) segs.delete(id);
    render();
    notifyTrafficUpdate();
  };
  const onConnect = () => { if (watching) refresh(); };

  const onClick = (e: MapMouseEvent) => {
    if (!visible) return;
    const layers = [L_CLUSTER, L_EVENTS, L_EVLINES, L_LINES].filter((l) => map.getLayer(l));
    const { x, y } = e.point;
    const hits = map.queryRenderedFeatures([[x - 12, y - 12], [x + 12, y + 12]], { layers });
    const cl = hits.find((h) => h.layer.id === L_CLUSTER);
    if (cl) {
      // groupe : on zoome dessus
      const src = map.getSource(SRC_EV) as GeoJSONSource;
      const center = (cl.geometry as unknown as { coordinates: [number, number] }).coordinates;
      Promise.resolve(src.getClusterExpansionZoom(cl.properties.cluster_id as number))
        .then((z) => map.easeTo({ center, zoom: Math.min(16, (z as number) + 0.3), duration: 300 }))
        .catch(() => map.easeTo({ center, zoom: map.getZoom() + 2, duration: 300 }));
      return;
    }
    const ev = hits.find((h) => h.layer.id === L_EVENTS || h.layer.id === L_EVLINES);
    const seg = hits.find((h) => h.layer.id === L_LINES);
    const full = ev && events.find((x) => x.properties.id === ev.properties.id);
    if (full) core().openPanel("traffic-event", full.properties);
    else if (seg) core().openPanel("traffic-segment", seg.properties);
  };

  const onStyle = () => { install(); render(); };
  // setStyle(url) en mode diff (par défaut) remplace le style SANS « style.load » et retire nos
  // calques : on revérifie après chaque styledata et à chaque idle (simple test d'existence).
  const check = () => { if (map.isStyleLoaded() && !map.getSource(SRC)) onStyle(); };
  const onStyleData = () => { window.setTimeout(check, 0); };

  function setVisible(v: boolean) {
    visible = v;
    for (const l of [L_LINES, L_EVENTS, L_CLUSTER, L_CLUSTER_N, L_EVLINES]) if (map.getLayer(l)) map.setLayoutProperty(l, "visibility", v ? "visible" : "none");
    refresh();
  }

  install();
  map.on("style.load", onStyle);
  map.on("styledata", onStyleData);
  map.on("idle", check);
  map.on("moveend", onMoveEnd);
  map.on("click", onClick);
  const socket = getSocket();
  socket.on("traffic:update", onUpdate);
  socket.on("connect", onConnect);
  refresh();

  return {
    setVisible,
    destroy() {
      window.clearTimeout(debounce);
      cancelAnimationFrame(raf);
      map.off("style.load", onStyle);
      map.off("styledata", onStyleData);
      map.off("idle", check);
      map.off("moveend", onMoveEnd);
      map.off("click", onClick);
      socket.off("traffic:update", onUpdate);
      socket.off("connect", onConnect);
      if (watching) socket.emit("traffic:watch", { bbox: null });
      try { uninstall(); } catch { /* carte déjà détruite */ }
    },
  };
}

/** Slot "map" : calque de trafic (segments colorés + évènements officiels). */
export function TrafficLayer() {
  const map = useCore((s) => s.map);
  const visible = useTraffic((s) => s.visible);
  const ctl = useRef<ReturnType<typeof createController> | null>(null);

  useEffect(() => {
    if (!map) return;
    const c = createController(map);
    ctl.current = c;
    return () => { c.destroy(); ctl.current = null; };
  }, [map]);

  useEffect(() => { ctl.current?.setVisible(visible); }, [visible]);

  return null;
}
