import { core, useCore, type LngLat } from "./store";
import { emit } from "./bus";
import { along, bearing, cumulativeDistances } from "./geometry";

/**
 * Position : GPS du navigateur, ou SIMULATEUR (indispensable pour tester sans voiture).
 * Simulateur actif si l'URL contient `?sim=1` (ou `?sim=<km/h>`) : la position part de Moulins
 * et, quand une conduite est en cours, avance le long de l'itinéraire actif.
 * `?sim=90&speedup=4` → 90 km/h, temps accéléré ×4.
 */
const params = new URLSearchParams(location.search);
export const simulated = params.has("sim");
const simSpeedKmh = Number(params.get("sim")) || 50;
const speedup = Number(params.get("speedup")) || 1;

/** Point de départ par défaut (Moulins, Allier). */
export const DEFAULT_CENTER: LngLat = [3.3332, 46.5646];

let stop: (() => void) | null = null;

export function startGeo() {
  stop?.();
  stop = simulated ? startSim() : startGps();
}

function push(coord: LngLat, heading: number | null, speed: number | null, accuracy: number | null) {
  core().set({ position: { coord, heading, speed, accuracy, time: Date.now(), simulated } });
  emit("geo:tick", { lng: coord[0], lat: coord[1], speed });
}

function startGps() {
  if (!("geolocation" in navigator)) {
    push(DEFAULT_CENTER, null, null, null);
    return () => {};
  }
  const id = navigator.geolocation.watchPosition(
    (p) => push([p.coords.longitude, p.coords.latitude], p.coords.heading ?? null, p.coords.speed ?? null, p.coords.accuracy),
    () => { if (!core().position) push(DEFAULT_CENTER, null, null, null); },
    { enableHighAccuracy: true, maximumAge: 1000, timeout: 15000 },
  );
  return () => navigator.geolocation.clearWatch(id);
}

function startSim() {
  push(DEFAULT_CENTER, 0, 0, 5);
  let distOnRoute = 0;
  let routeId = "";
  let last = performance.now();
  const timer = window.setInterval(() => {
    const now = performance.now();
    const dt = ((now - last) / 1000) * speedup;
    last = now;
    const { mode, routes, activeRoute } = useCore.getState();
    const route = routes[activeRoute];
    if (mode !== "drive" || !route) { distOnRoute = 0; return; }
    if (route.id !== routeId) {
      routeId = route.id;
      // recalcul : on repart du point du nouveau tracé le plus proche de la position (≈ début)
      distOnRoute = 0;
    }
    const cum = cumulativeDistances(route.coords);
    const total = cum[cum.length - 1];
    distOnRoute = Math.min(total, distOnRoute + (simSpeedKmh / 3.6) * dt);
    const p = along(route.coords, cum, distOnRoute);
    const ahead = along(route.coords, cum, Math.min(total, distOnRoute + 15));
    push(p, bearing(p, ahead), distOnRoute >= total ? 0 : simSpeedKmh / 3.6, 5);
  }, 250);
  return () => window.clearInterval(timer);
}
