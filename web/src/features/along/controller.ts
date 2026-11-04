import type { Map as MLMap } from "maplibre-gl";
import { core, useCore, type Route } from "../../core/store";
import { emit, on } from "../../core/bus";
import { cumulativeDistances, formatDistance } from "../../core/geometry";
import { fetchEvBbox, fetchEvRoute, fetchFuelBbox, fetchFuelRoute, fetchRestAhead, thin, type Bbox } from "./api";
import { alongPrefs, useAlongPrefs } from "./prefs";
import { along$, useAlong } from "./state";
import { fetchRouteWeather } from "./weather";
import { price3 } from "./format";
import { rankOnRoute } from "./suggest";

/**
 * Le cerveau du module : charge les stations (autour de la carte / le long du trajet), la météo du
 * trajet, et surveille la conduite (alerte météo à l'approche, rappel de pause après ~2 h).
 */

// ——— position le long du trajet ———————————————————————————————————————

let cumCache: { id: string; cum: number[] } | null = null;
function cumOf(route: Route) {
  if (cumCache?.id !== route.id) cumCache = { id: route.id, cum: cumulativeDistances(route.coords) };
  return cumCache.cum;
}
/** Mètres déjà parcourus sur l'itinéraire actif (0 hors conduite). */
export function currentAlong(): number {
  const { routes, activeRoute, progress, mode } = core();
  const route = routes[activeRoute];
  if (!route || mode !== "drive" || !progress) return 0;
  const cum = cumOf(route);
  return cum[Math.min(cum.length - 1, Math.max(0, progress.shapeIndex))] ?? 0;
}

// ——— stations autour de la carte ————————————————————————————————————————

let lastBox: Bbox | null = null;
let lastEnergyKind = "";
let nearbyTimer: number | undefined;
const contains = (a: Bbox, b: Bbox) => a[0] <= b[0] && a[1] <= b[1] && a[2] >= b[2] && a[3] >= b[3];

/** À appeler après un déplacement de carte (le calque s'en charge). Débounce + cache de zone. */
export function loadNearby(map: MLMap) {
  window.clearTimeout(nearbyTimer);
  nearbyTimer = window.setTimeout(async () => {
    const { energy, showStations } = alongPrefs();
    if (!showStations || map.getZoom() < 11) return;
    const b = map.getBounds();
    const view: Bbox = [b.getWest(), b.getSouth(), b.getEast(), b.getNorth()];
    const kind = energy === "ev" ? "ev" : "fuel";
    if (lastBox && kind === lastEnergyKind && contains(lastBox, view)) return;
    // on charge un peu plus large que l'écran pour ne pas recharger au moindre glissement
    const cx = (view[0] + view[2]) / 2, cy = (view[1] + view[3]) / 2;
    const hw = Math.min(0.95, ((view[2] - view[0]) / 2) * 1.5), hh = Math.min(0.95, ((view[3] - view[1]) / 2) * 1.5);
    const box: Bbox = [cx - hw, cy - hh, cx + hw, cy + hh];
    try {
      if (kind === "ev") {
        const { stations } = await fetchEvBbox(box);
        useAlong.getState().set({ nearbyEv: stations });
      } else {
        const { stations } = await fetchFuelBbox(box);
        useAlong.getState().set({ nearbyFuel: stations });
      }
      lastBox = box; lastEnergyKind = kind;
    } catch (e) {
      console.warn("[along] stations autour :", e);
    }
  }, 350);
}
export function resetNearby() { lastBox = null; }

// ——— stations le long du trajet ————————————————————————————————————————

let routeCtrl: AbortController | null = null;
async function loadRouteStations(route: Route) {
  const energy = alongPrefs().energy;
  const cur = along$().route;
  if (cur && cur.routeId === route.id && cur.energy === energy && cur.status !== "error") return;
  routeCtrl?.abort();
  const ctrl = (routeCtrl = new AbortController());
  useAlong.getState().set({ route: { routeId: route.id, energy, status: "loading", fuel: [], ev: [] } });
  try {
    const pts = thin(route.coords, 500);
    if (energy === "ev") {
      const { stations } = await fetchEvRoute(pts, 1500, ctrl.signal);
      if (!ctrl.signal.aborted) useAlong.getState().set({ route: { routeId: route.id, energy, status: "ready", fuel: [], ev: stations } });
    } else {
      const { stations } = await fetchFuelRoute(pts, 1000, ctrl.signal);
      if (!ctrl.signal.aborted) useAlong.getState().set({ route: { routeId: route.id, energy, status: "ready", fuel: stations, ev: [] } });
    }
  } catch (e) {
    if (!ctrl.signal.aborted) {
      console.warn("[along] stations du trajet :", e);
      useAlong.getState().set({ route: { routeId: route.id, energy, status: "error", fuel: [], ev: [] } });
    }
  }
}

// ——— météo du trajet ————————————————————————————————————————————————————

let weatherCtrl: AbortController | null = null;
async function loadWeather(route: Route, force = false) {
  const w = along$().weather;
  if (!force && w && w.routeId === route.id && Date.now() - w.fetchedAt < 30 * 60_000) return w;
  weatherCtrl?.abort();
  const ctrl = (weatherCtrl = new AbortController());
  useAlong.getState().set({ weatherStatus: "loading" });
  try {
    const res = await fetchRouteWeather(route, Date.now(), ctrl.signal);
    if (ctrl.signal.aborted) return null;
    useAlong.getState().set({ weather: res, weatherStatus: "ready" });
    return res;
  } catch (e) {
    if (!ctrl.signal.aborted) { console.warn("[along] météo :", e); useAlong.getState().set({ weatherStatus: "error" }); }
    return null;
  }
}

// ——— conduite : alertes météo et pauses ————————————————————————————————

const PAUSE_AFTER_MS = (Number(new URLSearchParams(location.search).get("pause")) || 120) * 60_000; // ?pause=1 pour tester
const BREAK_MS = 10 * 60_000; // un arrêt de 10 min compte comme une pause

const drive = {
  active: false,
  /** Début de la conduite continue (remis à zéro après une vraie pause). */
  since: 0,
  stoppedSince: 0,
  pauseAlerts: 0,
  restQueried: false,
  weatherNear: false,
};

/** Le module guidance affiche ET annonce les drive:alert (« Attention, <texte>, dans 12 km ») : texte court. */
function alert(id: string, text: string, distance: number, tone: "info" | "warn" | "danger", kind: string) {
  emit("drive:alert", { id, kind, text, distance: Math.max(0, Math.round(distance)), tone });
}

async function startDriveWatch() {
  Object.assign(drive, { active: true, since: Date.now(), stoppedSince: 0, pauseAlerts: 0, restQueried: false, weatherNear: false });
  const { routes, activeRoute } = core();
  const route = routes[activeRoute];
  if (!route || !alongPrefs().weatherAlerts) return;
  const w = await loadWeather(route);
  const hz = w?.hazard;
  if (hz && drive.active) alert(`along-weather-${route.id}`, hz.short, hz.point.along, hz.tone, "weather");
}

/** Alerte de pause, avec l'aire de repos la plus proche devant si on en connaît une. */
async function pauseAlert() {
  const { routes, activeRoute } = core();
  const route = routes[activeRoute];
  const n = ++drive.pauseAlerts;
  const hours = Math.round(((Date.now() - drive.since) / 3600_000) * 2) / 2;
  let text = `${hours >= 1 ? `${String(hours).replace(".", ",")} h` : "Un moment"} de route : pense à faire une pause`;
  let distance = 0;
  if (route) {
    try {
      const pos = currentAlong();
      const { areas } = await fetchRestAhead(thin(route.coords, 500), pos, 40_000);
      const a = areas.find((x) => x.along > pos + 1500);
      if (a) {
        distance = a.along - pos;
        const label = a.name ? (a.kind === "rest_area" && !/^aire/i.test(a.name) ? `aire de ${a.name}` : a.name)
          : a.kind === "services" ? (a.city ? `aire de services vers ${a.city}` : "aire de services") : "aire de repos";
        text = `Pause conseillée : ${label}`;
      }
    } catch { /* hors ligne : message générique */ }
  }
  if (drive.active) alert(`along-pause-${n}`, text, distance, "info", "pause");
}

function onTick(speed: number | null) {
  if (!drive.active) return;
  const now = Date.now();
  // arrêt prolongé = pause : on repart de zéro
  if (speed != null && speed < 1.5) {
    if (!drive.stoppedSince) drive.stoppedSince = now;
    else if (now - drive.stoppedSince > BREAK_MS) { drive.since = now; drive.pauseAlerts = 0; drive.restQueried = false; }
  } else drive.stoppedSince = 0;

  const driving = now - drive.since;
  const { routes, activeRoute } = core();
  const route = routes[activeRoute];
  if (alongPrefs().pauseReminder) {
    // un peu avant l'échéance, on fait préparer les aires au serveur (Overpass en arrière-plan)
    if (!drive.restQueried && route && driving > PAUSE_AFTER_MS * 0.85) {
      drive.restQueried = true;
      fetchRestAhead(thin(route.coords, 500), currentAlong(), 40_000).catch(() => {});
    }
    const due = PAUSE_AFTER_MS + drive.pauseAlerts * 30 * 60_000; // puis toutes les 30 min
    if (driving >= due && !drive.stoppedSince) void pauseAlert();
  }
  // à l'approche (≤ 8 km) d'un passage à risque, on le rappelle une fois
  const hz = along$().weather?.hazard;
  if (hz && route && !drive.weatherNear && alongPrefs().weatherAlerts && along$().weather?.routeId === route.id && hz.point.at > 0) {
    const d = hz.point.along - currentAlong();
    if (d > 0 && d <= 8000) {
      drive.weatherNear = true;
      alert(`along-weather-near-${route.id}`, hz.short, d, hz.tone, "weather");
    }
  }
}

// ——— branchements ————————————————————————————————————————————————————————

export function initAlong() {
  let weatherTimer: number | undefined;

  const sync = () => {
    const { mode, routes, activeRoute } = core();
    const route = routes[activeRoute];
    if (mode === "browse" || !route) {
      if (along$().route) useAlong.getState().set({ route: null });
      return;
    }
    void loadRouteStations(route);
    if (mode === "preview") {
      window.clearTimeout(weatherTimer);
      weatherTimer = window.setTimeout(() => void loadWeather(route), 500);
    }
  };

  const offCore = useCore.subscribe((s, prev) => {
    if (s.routes !== prev.routes || s.activeRoute !== prev.activeRoute || s.mode !== prev.mode) sync();
  });
  const offPrefs = useAlongPrefs.subscribe((s, prev) => {
    if (s.energy !== prev.energy) { resetNearby(); sync(); const m = core().map; if (m) loadNearby(m); }
    if (s.showStations !== prev.showStations && s.showStations) { resetNearby(); const m = core().map; if (m) loadNearby(m); }
  });
  const offs = [
    on("drive:start", () => { void startDriveWatch(); }),
    on("drive:stop", () => { drive.active = false; }),
    on("drive:arrived", () => { drive.active = false; }),
    on("drive:rerouted", () => {
      drive.weatherNear = false;
      const { routes, activeRoute } = core();
      const r = routes[activeRoute];
      if (r) void loadWeather(r, true);
    }),
    on("geo:tick", ({ speed }) => onTick(speed)),
  ];
  sync();
  return () => { offCore(); offPrefs(); offs.forEach((o) => o()); window.clearTimeout(weatherTimer); routeCtrl?.abort(); weatherCtrl?.abort(); drive.active = false; };
}

// ——— actions de l'interface ————————————————————————————————————————————

/** Ajoute une station comme étape (évènement déclaré par le module routing). */
export function addAsStop(name: string, lng: number, lat: number) {
  // « route:add-stop » est déclaré par le module routing (augmentation de BusEvents chez lui) :
  // on l'émet sans dépendre de son dossier.
  (emit as unknown as (e: string, p: { name: string; lng: number; lat: number }) => void)("route:add-stop", { name, lng, lat });
  core().openPanel(null);
}

/** Texte de la meilleure suggestion carburant devant, pour la voix ou un toast. */
export function bestFuelText(): string | null {
  const r = along$().route;
  const energy = alongPrefs().energy;
  if (!r || energy === "ev" || r.status !== "ready") return null;
  const best = rankOnRoute(r.fuel, energy, currentAlong())[0];
  return best ? `Le plein le moins cher sur ton trajet : ${price3(best.price)} € à ${formatDistance(best.ahead)}` : null;
}
