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
const MIN_ZOOM = 7;
const MAX_SPAN = 3.8; // degrés (le serveur refuse au-delà de 4)
const ATTRIBUTION = "Trafic : OsaMaps, Bison Futé";

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
      map.addSource(SRC_EV, { type: "geojson", data: { type: "FeatureCollection", features: events } });
    }
    for (const kind of Object.keys(EVENT_GLYPHS) as EventKind[]) {
      const id = `traffic-ev-${kind}`;
      if (!map.hasImage(id)) map.addImage(id, eventImage(kind, cssVar(EVENT_TONE[kind], "#fff")), { pixelRatio: 2 });
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
    if (!map.getLayer(L_EVENTS)) {
      map.addLayer({
        id: L_EVENTS,
        type: "symbol",
        source: SRC_EV,
        minzoom: 8,
        layout: {
          visibility: vis,
          "icon-image": ["concat", "traffic-ev-", ["get", "kind"]],
          "icon-size": ["interpolate", ["linear"], ["zoom"], 8, 0.7, 12, 0.9, 16, 1.05],
          "icon-allow-overlap": ["step", ["zoom"], false, 11, true],
          "icon-padding": 2,
          "symbol-sort-key": ["match", ["get", "kind"], "closure", 0, "accident", 1, "slow", 2, "obstacle", 3, 5],
        },
      });
    }
  }

  function uninstall() {
    for (const l of [L_EVENTS, L_LINES]) if (map.getLayer(l)) map.removeLayer(l);
    for (const s of [SRC_EV, SRC]) if (map.getSource(s)) map.removeSource(s);
  }

  function segCollection() {
    return { type: "FeatureCollection" as const, features: [...segs.values()] };
  }

  function render() {
    if (raf) return;
    raf = requestAnimationFrame(() => {
      raf = 0;
      (map.getSource(SRC) as GeoJSONSource | undefined)?.setData(segCollection());
      (map.getSource(SRC_EV) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: events });
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
      const [s, e] = await Promise.all([fetchSegments(bb), fetchEvents(bb)]);
      if (my !== seq) return;
      segs.clear();
      for (const f of s.features) segs.set(f.properties.id, f);
      events = e.features;
      render();
    } catch {
      /* serveur injoignable : on garde ce qu'on a */
    }
  }

  let debounce = 0;
  const onMoveEnd = () => { window.clearTimeout(debounce); debounce = window.setTimeout(refresh, 600); };

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
    const layers = [L_EVENTS, L_LINES].filter((l) => map.getLayer(l));
    const { x, y } = e.point;
    const hits = map.queryRenderedFeatures([[x - 12, y - 12], [x + 12, y + 12]], { layers });
    const ev = hits.find((h) => h.layer.id === L_EVENTS);
    const seg = hits.find((h) => h.layer.id === L_LINES);
    if (ev) core().openPanel("traffic-event", ev.properties);
    else if (seg) core().openPanel("traffic-segment", seg.properties);
  };

  const onStyle = () => { install(); render(); };
  // setStyle(url) en mode diff (par défaut) remplace le style SANS « style.load » et retire nos
  // calques : on revérifie après chaque styledata et à chaque idle (simple test d'existence).
  const check = () => { if (map.isStyleLoaded() && !map.getSource(SRC)) onStyle(); };
  const onStyleData = () => { window.setTimeout(check, 0); };

  function setVisible(v: boolean) {
    visible = v;
    for (const l of [L_LINES, L_EVENTS]) if (map.getLayer(l)) map.setLayoutProperty(l, "visibility", v ? "visible" : "none");
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
