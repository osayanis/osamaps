import { core, useCore, type LngLat, type Place, type Route } from "../../core/store";
import { prefs, usePrefs } from "../../core/prefs";
import { emit, on } from "../../core/bus";
import { distance } from "../../core/geometry";
import { bestInsertIndex, computeRoutes, fetchSpeedLimits, RouteError, type Computed, type Waypoint } from "./engine";
import { routing, useRouting, placeFrom, type DepartChoice } from "./state";

/*
 * Évènements ajoutés par ce module (augmentation locale du bus, sans toucher au socle) :
 *   "route:add-stop"  { name, lng, lat }  → ajoute une étape au trajet en cours (aperçu ou conduite),
 *                                           insérée là où elle rallonge le moins, puis recalcule.
 */
declare module "../../core/bus" {
  interface BusEvents {
    "route:add-stop": { name: string; lng: number; lat: number };
  }
}

let previewAbort: AbortController | null = null;
let rerouteAbort: AbortController | null = null;
let retryTimer: number | undefined;
const speedJobs = new Map<string, AbortController>();
let lastReroute = 0;
let pendingFrom: LngLat | null = null;

function options(extra: { alternates?: number; heading?: number | null; dateTime?: DepartChoice | null } = {}) {
  const p = prefs();
  return {
    avoidTolls: p.avoidTolls,
    avoidHighways: p.avoidHighways,
    avoidFerries: p.avoidFerries,
    alternates: extra.alternates ?? (routing().alternates ? 2 : 0),
    heading: extra.heading ?? null,
    dateTime: extra.dateTime ?? null,
  };
}

function storeMeta(list: Computed[]) {
  const meta = { ...routing().meta };
  for (const c of list) meta[c.route.id] = { stopShapeIndex: c.stopShapeIndex, departAt: c.departAt, arriveAt: c.arriveAt };
  // on ne garde que les itinéraires encore affichés + les nouveaux
  const keep = new Set([...core().routes.map((r) => r.id), ...list.map((c) => c.route.id)]);
  for (const id of Object.keys(meta)) if (!keep.has(id)) delete meta[id];
  routing().set({ meta });
}

function abortSpeeds() {
  speedJobs.forEach((c) => c.abort());
  speedJobs.clear();
}

/** Limites de vitesse d'un itinéraire, en tâche de fond (ne bloque jamais l'aperçu). */
export function ensureSpeedLimits(route: Route | undefined) {
  if (!route || route.speedLimits || speedJobs.has(route.id)) return;
  const ctrl = new AbortController();
  speedJobs.set(route.id, ctrl);
  fetchSpeedLimits(route.coords, ctrl.signal)
    .then((speedLimits) => {
      if (ctrl.signal.aborted) return;
      const routes = core().routes;
      const i = routes.findIndex((r) => r.id === route.id);
      if (i < 0) return;
      const next = routes.slice();
      next[i] = { ...routes[i], speedLimits };
      core().set({ routes: next });
    })
    .catch(() => { /* sans limites : le module sécurité fera sans */ })
    .finally(() => { if (speedJobs.get(route.id) === ctrl) speedJobs.delete(route.id); });
}

// ——— aperçu ———————————————————————————————————————————————————————————

export function startPreview(dest: Place) {
  if (core().mode === "drive") emit("drive:stop", { arrived: false });
  abortAll();
  routing().set({ stops: [], depart: null, section: null, pickOnMap: false, meta: {} });
  core().set({ destination: dest, routes: [], activeRoute: 0, mode: "preview", follow: false, panel: null, panelData: null });
  computePreview();
}

export async function computePreview() {
  const { destination, position } = core();
  if (!destination) return;
  previewAbort?.abort();
  abortSpeeds();
  const ctrl = new AbortController();
  previewAbort = ctrl;
  if (!position) {
    routing().set({ status: "error", error: "Votre position est encore inconnue.", retryable: true });
    return;
  }
  routing().set({ status: "loading", error: null });
  const { stops, depart } = routing();
  const points: Waypoint[] = [
    { coord: position.coord },
    ...stops.map((s) => ({ coord: s.coord, name: s.name })),
    { coord: destination.coord, name: destination.name },
  ];
  try {
    const list = await computeRoutes(points, options({ dateTime: depart }), ctrl.signal);
    if (ctrl.signal.aborted || core().mode !== "preview") return;
    storeMeta(list);
    core().set({ routes: list.map((c) => c.route), activeRoute: 0 });
    routing().set({ status: "ready" });
    ensureSpeedLimits(list[0].route);
  } catch (e) {
    if (ctrl.signal.aborted) return;
    const err = e instanceof RouteError ? e : new RouteError("Le calcul a échoué.", true);
    core().set({ routes: [] });
    routing().set({ status: "error", error: err.message, retryable: err.retryable });
  }
}

export function selectRoute(i: number) {
  const { routes, mode } = core();
  if (mode !== "preview" || !routes[i]) return;
  core().set({ activeRoute: i });
  ensureSpeedLimits(routes[i]);
}

export function cancelPreview() {
  abortAll();
  routing().set({ status: "idle", stops: [], depart: null, section: null, pickOnMap: false, meta: {} });
  core().set({ mode: "browse", routes: [], activeRoute: 0, destination: null });
}

export function startDrive() {
  const { routes, activeRoute } = core();
  const route = routes[activeRoute];
  if (!route) return;
  routing().set({ section: null, pickOnMap: false });
  // en conduite on ne garde que l'itinéraire choisi
  core().set({ mode: "drive", follow: true, routes: [route], activeRoute: 0, panel: null, panelData: null });
  ensureSpeedLimits(route);
  emit("drive:start", { routeId: route.id });
}

export function setDepart(d: DepartChoice | null) {
  routing().set({ depart: d });
  if (core().mode === "preview") computePreview();
}

// ——— étapes ——————————————————————————————————————————————————————————

function afterStopsChange() {
  const mode = core().mode;
  if (mode === "preview") computePreview();
  else if (mode === "drive") {
    const pos = core().position;
    if (pos) reroute(pos.coord, { force: true });
  }
}

export function addStop(place: Place, index?: number) {
  const { destination, position, mode } = core();
  if (!destination || mode === "browse") return;
  const stops = routing().stops.slice();
  if (stops.length >= 8) { emit("toast", { text: "8 étapes au maximum.", tone: "warn" }); return; }
  const origin = position?.coord ?? place.coord;
  const at = index ?? bestInsertIndex(origin, stops.map((s) => s.coord), destination.coord, place.coord);
  stops.splice(at, 0, place);
  routing().set({ stops, pickOnMap: false });
  afterStopsChange();
}

export function removeStop(i: number) {
  const stops = routing().stops.filter((_, k) => k !== i);
  routing().set({ stops });
  afterStopsChange();
}

export function moveStop(i: number, dir: -1 | 1) {
  const stops = routing().stops.slice();
  const j = i + dir;
  if (j < 0 || j >= stops.length) return;
  [stops[i], stops[j]] = [stops[j], stops[i]];
  routing().set({ stops });
  afterStopsChange();
}

// ——— recalcul en conduite ——————————————————————————————————————————————

/** Étapes pas encore atteintes sur l'itinéraire actif (d'après la progression du guidage). */
function remainingStops(): Place[] {
  const { routes, activeRoute, progress } = core();
  const route = routes[activeRoute];
  const { stops, meta } = routing();
  const idx = route ? meta[route.id]?.stopShapeIndex : undefined;
  if (!idx || !progress) return stops;
  return stops.filter((_, k) => idx[k] == null || idx[k] > progress.shapeIndex);
}

export async function reroute(from: LngLat, opts: { force?: boolean; attempt?: number } = {}) {
  const { destination, mode, position } = core();
  if (mode !== "drive" || !destination) return;
  const attempt = opts.attempt ?? 0;
  if (attempt === 0) {
    if (routing().rerouting && !opts.force) { pendingFrom = from; return; }
    // anti-rafale : le guidage peut redemander pendant qu'on rejoint le nouveau tracé
    if (!opts.force && Date.now() - lastReroute < 4000) return;
    window.clearTimeout(retryTimer);
  }
  rerouteAbort?.abort();
  abortSpeeds();
  const ctrl = new AbortController();
  rerouteAbort = ctrl;
  pendingFrom = null;
  const stops = remainingStops();
  routing().set({ rerouting: true, stops });
  const heading = position && (position.speed ?? 0) > 2 ? position.heading : null;
  const points: Waypoint[] = [
    { coord: from },
    ...stops.map((s) => ({ coord: s.coord, name: s.name })),
    { coord: destination.coord, name: destination.name },
  ];
  try {
    const list = await computeRoutes(points, options({ alternates: 0, heading }), ctrl.signal);
    if (ctrl.signal.aborted || core().mode !== "drive") return;
    const route = list[0].route;
    storeMeta(list);
    core().set({ routes: [route], activeRoute: 0 });
    lastReroute = Date.now();
    routing().set({ rerouting: false });
    if (attempt > 0) emit("toast", { text: "Itinéraire recalculé.", tone: "good" });
    emit("drive:rerouted", { routeId: route.id });
    ensureSpeedLimits(route);
    // une demande arrivée pendant le calcul et encore loin du nouveau tracé : on la rejoue
    const again = pendingFrom as LngLat | null;
    if (again && distance(again, from) > 150) reroute(again, { force: true });
  } catch (e) {
    if (ctrl.signal.aborted || core().mode !== "drive") return;
    const err = e instanceof RouteError ? e : new RouteError("Le calcul a échoué.", true);
    if (!err.retryable) {
      routing().set({ rerouting: false });
      emit("toast", { text: `Recalcul impossible : ${err.message}`, tone: "warn" });
      return;
    }
    if (attempt === 0) emit("toast", { text: "Pas de réseau pour recalculer, nouvel essai en cours…", tone: "warn" });
    const delay = Math.min(30_000, 3000 * 2 ** attempt);
    retryTimer = window.setTimeout(() => {
      // on repart de la position la plus récente
      const p = core().position?.coord ?? from;
      reroute(pendingFrom ?? p, { force: true, attempt: attempt + 1 });
    }, delay);
  }
}

function abortAll() {
  previewAbort?.abort();
  rerouteAbort?.abort();
  window.clearTimeout(retryTimer);
  abortSpeeds();
  pendingFrom = null;
  routing().set({ rerouting: false });
}

export function stopDrive() {
  abortAll();
  routing().set({ status: "idle", stops: [], depart: null, section: null, pickOnMap: false, meta: {} });
  core().set({ mode: "browse", routes: [], activeRoute: 0, destination: null });
}

// ——— branchements ——————————————————————————————————————————————————————

export function initRouting() {
  const offs = [
    on("place:go", ({ name, lng, lat }) => {
      if (!Number.isFinite(lng) || !Number.isFinite(lat)) return;
      startPreview({ id: `dest-${lng.toFixed(5)},${lat.toFixed(5)}`, name: name || "Destination", coord: [lng, lat], kind: "destination" });
    }),
    on("route:recompute", ({ from }) => {
      if (Array.isArray(from) && from.length === 2) reroute([from[0], from[1]]);
    }),
    on("drive:stop", () => stopDrive()),
    on("route:add-stop", ({ name, lng, lat }) => {
      if (!Number.isFinite(lng) || !Number.isFinite(lat)) return;
      addStop(placeFrom(name || "Étape", [lng, lat]));
    }),
  ];

  // options d'évitement changées pendant l'aperçu → nouveau calcul (petit délai : plusieurs clics)
  let t: number | undefined;
  const offPrefs = usePrefs.subscribe((s, prev) => {
    if (s.avoidTolls === prev.avoidTolls && s.avoidHighways === prev.avoidHighways && s.avoidFerries === prev.avoidFerries) return;
    if (core().mode !== "preview") return;
    window.clearTimeout(t);
    t = window.setTimeout(computePreview, 250);
  });
  const offAlt = useRouting.subscribe((s, prev) => {
    if (s.alternates !== prev.alternates && core().mode === "preview") computePreview();
  });
  // la position arrive après le choix de destination (GPS lent) : on relance l'aperçu
  const offPos = useCore.subscribe((s, prev) => {
    if (s.position && !prev.position && s.mode === "preview" && routing().status === "error" && routing().retryable) computePreview();
  });

  return () => { offs.forEach((o) => o()); offPrefs(); offAlt(); offPos(); window.clearTimeout(t); abortAll(); };
}
