import { useEffect } from "react";
import maplibregl, { type MapGeoJSONFeature, type MapMouseEvent, type MapTouchEvent } from "maplibre-gl";
import { useCore, core, type LngLat } from "../../core/store";
import { osmLabel, reverseGeocode } from "./api";
import { toPlaceData } from "./PlaceSheet";
import { completePick, openPlace, search, useSearch, type Saved } from "./state";
import { kindIcon } from "./format";
import { iconSvg as svg } from "./icons";

function marker(map: maplibregl.Map, coord: LngLat, el: HTMLElement, anchor: "center" | "bottom" = "center") {
  const label = el.getAttribute("aria-label");
  const m = new maplibregl.Marker({ element: el, anchor }).setLngLat(coord).addTo(map);
  // MapLibre remplace l'aria-label par « Map marker » : on remet le nôtre
  if (label) el.setAttribute("aria-label", label);
  return m;
}

/**
 * Calques du module sur la carte : marqueurs des résultats par catégorie, épingle du lieu ouvert,
 * lieux enregistrés (maison, travail, voiture, favoris), appui long / clic droit → fiche du point,
 * tap sur un POI du fond de carte → sa fiche.
 */
export function MapLayer() {
  const map = useCore((s) => s.map);
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const panelData = useCore((s) => s.panelData);
  const category = useSearch((s) => s.category);
  const { home, work, car, favorites } = useSearch();
  const browse = mode === "browse";
  const selected = panel === "place" ? toPlaceData(panelData) : null;

  // résultats de catégorie : pastilles numérotées
  useEffect(() => {
    if (!map || !browse || !category?.results.length) return;
    const ms = category.results.map((r, i) => {
      const el = document.createElement("button");
      el.className = "search-mk-num";
      el.type = "button";
      el.setAttribute("aria-label", r.name);
      el.textContent = String(i + 1);
      const isSel = !!selected && Math.abs(selected.coord[0] - r.coord[0]) < 1e-6 && Math.abs(selected.coord[1] - r.coord[1]) < 1e-6;
      if (isSel) el.classList.add("is-selected");
      el.addEventListener("click", (e) => { e.stopPropagation(); openPlace({ ...r, from: "list" }); });
      return marker(map, r.coord, el);
    });
    return () => ms.forEach((m) => m.remove());
  }, [map, browse, category?.results, selected?.coord[0], selected?.coord[1]]);

  // épingle du lieu ouvert (sauf s'il est déjà une pastille de la liste)
  useEffect(() => {
    if (!map || !browse || !selected) return;
    if (selected.from === "list" && category?.results.some((r) => r.coord[0] === selected.coord[0] && r.coord[1] === selected.coord[1])) return;
    const el = document.createElement("div");
    el.className = "search-mk-pin";
    el.innerHTML = `<span>${svg(selected.kind === "car" ? "car" : kindIcon(selected.kind), 16)}</span>`;
    const m = marker(map, selected.coord, el, "bottom");
    return () => { m.remove(); };
  }, [map, browse, selected?.coord[0], selected?.coord[1], selected?.kind]);

  // lieux enregistrés : discrets, toujours visibles en exploration
  useEffect(() => {
    if (!map || !browse) return;
    const list: [Saved, string, string][] = [];
    if (home) list.push([home, "home", "Maison"]);
    if (work) list.push([work, "work", "Travail"]);
    if (car) list.push([car, "car", "Ma voiture"]);
    for (const f of favorites) list.push([f, "star", f.name]);
    const ms = list.map(([p, icon, label]) => {
      const el = document.createElement("button");
      el.type = "button";
      el.className = `search-mk-saved${icon === "star" ? " is-fav" : ""}`;
      el.setAttribute("aria-label", label);
      el.innerHTML = svg(icon, icon === "star" ? 12 : 15);
      el.addEventListener("click", (e) => { e.stopPropagation(); openPlace({ ...p, from: "home" }); });
      return marker(map, p.coord, el);
    });
    return () => ms.forEach((m) => m.remove());
  }, [map, browse, home, work, car, favorites]);

  // appui long (tactile) / clic droit → fiche du point ; tap sur un POI du fond de carte
  useEffect(() => {
    if (!map) return;
    let timer = 0;
    let start: { x: number; y: number } | null = null;
    let lastFire = 0;

    const fire = async (ll: maplibregl.LngLat) => {
      if (Date.now() - lastFire < 900) return;
      lastFire = Date.now();
      if (core().mode !== "browse") return;
      navigator.vibrate?.(12);
      const coord: LngLat = [ll.lng, ll.lat];
      if (search().picking) {
        let name = "Point choisi", detail: string | undefined;
        try { const a = await reverseGeocode(coord); if (a) { name = a.name; detail = a.detail; } } catch { /* hors ligne */ }
        completePick({ id: `pt:${coord.join(",")}`, name, detail, coord, kind: "address" });
        return;
      }
      openPlace({ id: `pt:${coord.map((n) => n.toFixed(5)).join(",")}`, name: "Point sur la carte", coord, kind: "map", from: "map", needsAddress: true });
    };
    const clear = () => { window.clearTimeout(timer); start = null; };

    const onTouchStart = (e: MapTouchEvent) => {
      clear();
      if (e.originalEvent.touches.length !== 1) return;
      start = { x: e.point.x, y: e.point.y };
      const ll = e.lngLat;
      timer = window.setTimeout(() => { start = null; fire(ll); }, 550);
    };
    const onTouchMove = (e: MapTouchEvent) => {
      if (start && Math.hypot(e.point.x - start.x, e.point.y - start.y) > 10) clear();
    };
    const onContext = (e: MapMouseEvent) => { e.preventDefault(); fire(e.lngLat); };

    const onClick = (e: MapMouseEvent) => {
      if (core().mode !== "browse" || e.originalEvent.target !== map.getCanvas()) return;
      const { x, y } = e.point;
      let feats: MapGeoJSONFeature[] = [];
      try { feats = map.queryRenderedFeatures([[x - 8, y - 8], [x + 8, y + 8]]); } catch { return; }
      const top = feats[0];
      if (!top || (top.sourceLayer !== "poi" && top.sourceLayer !== "place") || top.geometry.type !== "Point") return;
      const pr = top.properties as Record<string, string | undefined>;
      const name = pr["name:fr"] || pr.name;
      if (!name) return;
      const isPlace = top.sourceLayer === "place";
      const [typeLabel, kind] = isPlace ? osmLabel("place", pr.class) : osmLabel(undefined, pr.subclass || pr.class);
      const c = top.geometry.coordinates as LngLat;
      // une ville n'a pas d'adresse : pas de géocodage inverse (il renverrait une rue au hasard du centre)
      openPlace({ id: `poi:${top.id ?? c.join(",")}`, name, coord: [c[0], c[1]], kind, typeLabel, from: "map", needsAddress: !isPlace });
    };

    map.on("touchstart", onTouchStart);
    map.on("touchmove", onTouchMove);
    map.on("touchend", clear);
    map.on("touchcancel", clear);
    map.on("contextmenu", onContext);
    map.on("click", onClick);
    return () => {
      clear();
      map.off("touchstart", onTouchStart);
      map.off("touchmove", onTouchMove);
      map.off("touchend", clear);
      map.off("touchcancel", clear);
      map.off("contextmenu", onContext);
      map.off("click", onClick);
    };
  }, [map]);

  return null;
}
