import { core, type LngLat } from "../../core/store";
import { searchNearby } from "./api";
import { categoryById } from "./categories";
import { search } from "./state";

let ctrl: AbortController | null = null;

/** Centre de recherche « autour » : la zone regardée si l'utilisateur a bougé la carte, sinon sa position. */
export function searchCenter(): LngLat {
  const { map, follow, position } = core();
  if (map && (!follow || !position)) {
    const c = map.getCenter();
    return [c.lng, c.lat];
  }
  return position?.coord ?? (map ? [map.getCenter().lng, map.getCenter().lat] : [3.3332, 46.5646]);
}

/** Lance (ou relance) une recherche par catégorie et ouvre la liste. */
export async function runCategory(id: string, center: LngLat = searchCenter()) {
  const cat = categoryById(id);
  if (!cat) return;
  ctrl?.abort();
  ctrl = new AbortController();
  const signal = ctrl.signal;
  const s = search();
  s.set({ category: { id, center, results: [], loading: true, error: null }, focused: false });
  core().openPanel("search-results");
  try {
    const results = await searchNearby(cat, center, signal);
    if (signal.aborted) return;
    s.set({ category: { id, center, results, loading: false, error: results.length ? null : "empty" } });
    fitResults(center, results.map((r) => r.coord));
  } catch (e) {
    if ((e as Error).name === "AbortError") return;
    s.set({ category: { id, center, results: [], loading: false, error: "network" } });
  }
}

export function closeCategory() {
  ctrl?.abort();
  search().set({ category: null });
  if (core().panel === "search-results") core().openPanel(null);
}

function fitResults(center: LngLat, coords: LngLat[]) {
  const map = core().map;
  if (!map || !coords.length) return;
  // les 8 plus proches suffisent à cadrer (sinon une borne à 50 km dézoome tout)
  const pts = [center, ...coords.slice(0, 8)];
  let [w, s, e, n] = [center[0], center[1], center[0], center[1]];
  for (const [x, y] of pts) { w = Math.min(w, x); e = Math.max(e, x); s = Math.min(s, y); n = Math.max(n, y); }
  core().set({ follow: false });
  map.fitBounds([[w, s], [e, n]], {
    padding: { top: 150, bottom: Math.round(window.innerHeight * 0.45), left: 40, right: 40 },
    maxZoom: 16,
    duration: 700,
  });
}
