import { useEffect, useMemo, useRef, useState } from "react";
import type { GeoJSONSource, Map as MLMap, MapLayerMouseEvent } from "maplibre-gl";
import { core, useCore } from "../../core/store";
import { useAlong, type StationPanelData } from "./state";
import { useAlongPrefs, type FuelKey } from "./prefs";
import { loadNearby } from "./controller";
import { isFresh, price3 } from "./format";
import { cheapestIds } from "./suggest";
import type { EvStation, FuelStation } from "./api";
import { useSearch } from "../search/state";

const SRC = "along-stations";
const L_DOT = "along-dot";
const L_PILL = "along-pill";
/** Exploration simple (carte épurée « comme Waze ») : prix seulement de près, et les quelques moins chers visibles. */
const BROWSE_MIN_ZOOM = 13;
const BROWSE_MAX = 7;
/** Calques d'évènements qui passent devant les prix en exploration (placés avant eux par MapLibre). */
const ABOVE = ["traffic-events-icons", "reports-points", "reports-clusters", "reports-cluster-count"];
const IMG = { white: "along-pill-white", green: "along-pill-green", dim: "along-pill-dim" } as const;

/** Pilule étirable dessinée au canvas (icon-text-fit) : blanche, verte (la moins chère) ou sombre (prix ancien). */
function pillImage(fill: string, stroke: string | null) {
  const ratio = 2, w = 64, h = 44, r = 22;
  const c = document.createElement("canvas");
  c.width = w; c.height = h;
  const g = c.getContext("2d")!;
  g.beginPath();
  g.roundRect(1, 1, w - 2, h - 2, r - 1);
  g.fillStyle = fill;
  g.fill();
  if (stroke) { g.lineWidth = 2; g.strokeStyle = stroke; g.stroke(); }
  return {
    data: g.getImageData(0, 0, w, h),
    options: { pixelRatio: ratio, stretchX: [[r, w - r]] as [number, number][], stretchY: [[r - 1, r + 1]] as [number, number][], content: [14, 6, w - 14, h - 6] as [number, number, number, number] },
  };
}

function ensure(map: MLMap) {
  if (!map.hasImage(IMG.white)) { const p = pillImage("rgba(255,255,255,0.96)", null); map.addImage(IMG.white, p.data, p.options); }
  if (!map.hasImage(IMG.green)) { const p = pillImage("#34c759", null); map.addImage(IMG.green, p.data, p.options); }
  if (!map.hasImage(IMG.dim)) { const p = pillImage("rgba(20,20,26,0.92)", "rgba(255,255,255,0.22)"); map.addImage(IMG.dim, p.data, p.options); }
  if (!map.getSource(SRC)) map.addSource(SRC, { type: "geojson", data: { type: "FeatureCollection", features: [] } });
  if (!map.getLayer(L_DOT)) {
    map.addLayer({
      id: L_DOT, type: "circle", source: SRC,
      paint: {
        "circle-radius": 4,
        "circle-color": ["match", ["get", "bg"], IMG.green, "#34c759", IMG.dim, "rgba(160,160,170,1)", "#ffffff"],
        "circle-stroke-color": "rgba(0,0,0,0.75)", "circle-stroke-width": 1.5,
      },
    });
  }
  if (!map.getLayer(L_PILL)) {
    map.addLayer({
      id: L_PILL, type: "symbol", source: SRC,
      layout: {
        "text-field": ["get", "label"],
        "text-font": ["Noto Sans Bold"],
        "text-size": 12.5,
        "text-anchor": "bottom",
        "text-offset": [0, -0.85],
        "icon-image": ["get", "bg"],
        "icon-text-fit": "both",
        "icon-text-fit-padding": [3, 4, 2, 4],
        "icon-anchor": "bottom",
        "symbol-sort-key": ["get", "sort"],
        "text-allow-overlap": false,
        "icon-allow-overlap": false,
        "text-padding": 2,
      },
      paint: {
        "text-color": ["match", ["get", "bg"], IMG.dim, "rgba(255,255,255,0.85)", "#000000"],
      },
    });
  }
}

type Feat = GeoJSON.Feature<GeoJSON.Point, { id: string; kind: "fuel" | "ev"; label: string; bg: string; sort: number }>;

function fuelFeatures(list: FuelStation[], fuel: FuelKey): Feat[] {
  const cheap = cheapestIds(list, fuel);
  const now = Date.now();
  const out: Feat[] = [];
  for (const s of list) {
    const pr = s.prices[fuel];
    if (!pr) continue;
    const ok = isFresh(pr.maj, now) && !s.shortage.includes(fuel);
    out.push({
      type: "Feature", geometry: { type: "Point", coordinates: [s.lng, s.lat] },
      properties: { id: s.id, kind: "fuel", label: s.shortage.includes(fuel) ? "Rupture" : price3(pr.p), bg: cheap.has(s.id) ? IMG.green : ok ? IMG.white : IMG.dim, sort: cheap.has(s.id) ? -1 : ok ? pr.p : 10 + pr.p },
    });
  }
  return out;
}
function evFeatures(list: EvStation[]): Feat[] {
  return list.map((s) => ({
    type: "Feature", geometry: { type: "Point", coordinates: [s.lng, s.lat] },
    properties: { id: s.id, kind: "ev", label: s.kw ? `${s.kw} kW` : "Borne", bg: s.kw >= 50 ? IMG.white : IMG.dim, sort: -s.kw },
  }));
}

/** Calque carte : étiquettes de prix (ou de puissance) des stations, la moins chère en vert. */
export function AlongLayer() {
  const map = useCore((s) => s.map);
  const mode = useCore((s) => s.mode);
  const { energy, showStations } = useAlongPrefs();
  const nearbyFuel = useAlong((s) => s.nearbyFuel);
  const nearbyEv = useAlong((s) => s.nearbyEv);
  const route = useAlong((s) => s.route);
  const panel = useCore((s) => s.panel);
  // catégorie « Essence » choisie dans la recherche : toutes les stations, comme avant
  const fuelCat = useSearch((s) => s.category?.id === "fuel") && panel === "search-results";
  const [viewTick, setViewTick] = useState(0);
  const index = useRef(new Map<string, StationPanelData>());

  // exploration : stations autour ; aperçu / conduite : stations du trajet (≤ 1 km)
  const features = useMemo(() => {
    if (!showStations) return [];
    const onRoute = mode !== "browse" && route?.status === "ready" && route.energy === energy;
    if (mode !== "browse" && !onRoute) return [];
    const idx = new Map<string, StationPanelData>();
    let feats: Feat[];
    if (energy === "ev") {
      const list = onRoute ? route!.ev : nearbyEv;
      list.forEach((s) => idx.set(`ev:${s.id}`, { kind: "ev", station: s }));
      feats = evFeatures(list);
    } else {
      const list = onRoute ? route!.fuel : nearbyFuel;
      list.forEach((s) => idx.set(`fuel:${s.id}`, { kind: "fuel", station: s }));
      feats = fuelFeatures(list, energy);
    }
    index.current = idx;
    return feats;
  }, [showStations, mode, route, energy, nearbyEv, nearbyFuel]);

  const sparse = mode === "browse" && !fuelCat && energy !== "ev";
  const shown = useMemo(() => {
    if (!sparse || !map) return features;
    if (map.getZoom() < BROWSE_MIN_ZOOM - 0.01) return [];
    // zone vraiment visible : sous la barre de recherche, au-dessus du panneau du bas
    const c = map.getCanvas(), w = c.clientWidth, h = c.clientHeight;
    const tl = map.unproject([0, 110]), br = map.unproject([w, h * 0.62]);
    const inView = (f: Feat) => {
      const [x, y] = f.geometry.coordinates;
      return x >= tl.lng && x <= br.lng && y <= tl.lat && y >= br.lat;
    };
    return features.filter(inView).sort((a, b) => a.properties.sort - b.properties.sort).slice(0, BROWSE_MAX);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [features, sparse, map, viewTick]);

  const featuresRef = useRef(shown);
  featuresRef.current = shown;

  // mise en place (et après chaque changement de style clair/sombre)
  useEffect(() => {
    if (!map) return;
    const setup = () => {
      ensure(map);
      (map.getSource(SRC) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: featuresRef.current });
    };
    setup();
    map.on("style.load", setup);
    const onMove = () => { if (core().mode === "browse") { loadNearby(map); setViewTick((t) => t + 1); } };
    map.on("moveend", onMove);
    onMove();
    const click = (e: MapLayerMouseEvent) => {
      const f = e.features?.[0];
      if (!f) return;
      const p = f.properties as { id: string; kind: string };
      const data = index.current.get(`${p.kind}:${p.id}`);
      if (data) core().openPanel("station", data);
    };
    const enter = () => { map.getCanvas().style.cursor = "pointer"; };
    const leave = () => { map.getCanvas().style.cursor = ""; };
    for (const l of [L_PILL, L_DOT]) { map.on("click", l, click); map.on("mouseenter", l, enter); map.on("mouseleave", l, leave); }
    return () => {
      map.off("style.load", setup);
      map.off("moveend", onMove);
      for (const l of [L_PILL, L_DOT]) { map.off("click", l, click); map.off("mouseenter", l, enter); map.off("mouseleave", l, leave); }
      try {
        if (map.getLayer(L_PILL)) map.removeLayer(L_PILL);
        if (map.getLayer(L_DOT)) map.removeLayer(L_DOT);
        if (map.getSource(SRC)) map.removeSource(SRC);
        Object.values(IMG).forEach((i) => { if (map.hasImage(i)) map.removeImage(i); });
      } catch { /* carte déjà détruite */ }
    };
  }, [map]);

  useEffect(() => {
    if (!map) return;
    (map.getSource(SRC) as GeoJSONSource | undefined)?.setData({ type: "FeatureCollection", features: shown });
    // en exploration : prix de près seulement (zoom de quartier avec la catégorie « Essence »)
    if (map.getLayer(L_PILL)) {
      const min = mode !== "browse" ? 0 : sparse ? BROWSE_MIN_ZOOM : 11;
      map.setLayerZoomRange(L_PILL, min, 24);
      map.setLayerZoomRange(L_DOT, min, 24);
      // exploration simple : sous les évènements (ils gagnent les collisions) ; sinon au-dessus, comme avant
      const layers = map.getStyle().layers ?? [];
      const firstAbove = sparse ? layers.find((l) => ABOVE.includes(l.id))?.id : undefined;
      try {
        map.moveLayer(L_DOT, firstAbove);
        map.moveLayer(L_PILL, firstAbove);
      } catch { /* style en cours de rechargement */ }
    }
  }, [map, shown, mode, sparse]);

  useEffect(() => { if (map && mode === "browse") loadNearby(map); }, [map, mode]);

  return null;
}
