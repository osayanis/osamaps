import { emit, on } from "../../core/bus";
import { core, useCore, type LngLat, type Route } from "../../core/store";
import { along as pointAlong, cumulativeDistances, formatDistance, snapToLine } from "../../core/geometry";
import { fetchAlong } from "./api";
import { traffic, type RouteRun } from "./state";
import "./events";

/**
 * Trafic sur l'itinéraire actif : le serveur renvoie les portions ralenties devant (contributions
 * + mesures officielles), on en déduit le retard restant et on annonce les bouchons devant
 * (`drive:alert`). Interroge en conduite (toutes les 45 s, + quand le trafic change) et une fois
 * en aperçu (pour `traffic:delay`).
 */
const REFRESH_MS = 45_000;
const ALERT_RANGE_M = 15_000;
const NEAR_M = 1000;

/** Sous-échantillonne le tracé à partir de l'index `from` (≤ 1900 points, pas ≥ 40 m). */
function slice(route: Route, cum: number[], from: number): { coords: LngLat[]; offset: number } {
  const start = Math.max(0, Math.min(from, route.coords.length - 2));
  const remaining = cum[cum.length - 1] - cum[start];
  const step = Math.max(40, remaining / 1900);
  const out: LngLat[] = [route.coords[start]];
  let lastD = cum[start];
  for (let i = start + 1; i < route.coords.length; i++) {
    if (cum[i] - lastD >= step || i === route.coords.length - 1) { out.push(route.coords[i]); lastD = cum[i]; }
  }
  return { coords: out, offset: cum[start] };
}

export function startDriveTraffic(): () => void {
  let cumFor: { id: string; cum: number[] } | null = null;
  let timer = 0;
  let inflight = false;
  let lastQuery = 0;
  const alerted = new Set<string>();

  const cum = (r: Route) => {
    if (cumFor?.id !== r.id) cumFor = { id: r.id, cum: cumulativeDistances(r.coords) };
    return cumFor.cum;
  };
  const activeRoute = () => { const s = core(); return s.routes[s.activeRoute] ?? null; };

  async function query() {
    const s = core();
    const route = activeRoute();
    if (!route || route.coords.length < 2 || (s.mode !== "drive" && s.mode !== "preview")) return;
    if (inflight) return;
    inflight = true;
    lastQuery = Date.now();
    try {
      const c = cum(route);
      const from = s.mode === "drive" ? Math.max(0, (s.progress?.shapeIndex ?? 0) - 1) : 0;
      const { coords, offset } = slice(route, c, from);
      const res = await fetchAlong(coords);
      if (activeRoute()?.id !== route.id) return;
      const runs: RouteRun[] = res.runs.map((r) => ({
        ...r,
        from: offset + r.from,
        to: offset + r.to,
        start: pointAlong(route.coords, c, offset + r.from),
      }));
      traffic().set({ route: { routeId: route.id, runs, at: Date.now() } });
      update();
    } catch {
      // serveur injoignable : on garde l'ancienne estimation si elle est récente
      const r = traffic().route;
      if (r && Date.now() - r.at > 3 * 60_000) traffic().set({ route: null, ahead: null });
    } finally {
      inflight = false;
    }
  }

  /** Recalcule « devant moi » à chaque position (sans réinterroger le serveur). */
  function update() {
    const s = core();
    const route = activeRoute();
    const info = traffic().route;
    if (!route || !info || info.routeId !== route.id) { traffic().set({ ahead: null }); return; }
    const c = cum(route);
    let here = 0;
    if (s.mode === "drive" && s.position) {
      here = snapToLine(s.position.coord, route.coords, c, Math.max(0, (s.progress?.shapeIndex ?? 0) - 3)).along;
    }
    let delay = 0;
    let next: (RouteRun & { distance: number }) | null = null;
    for (const r of info.runs) {
      if (r.to <= here) continue;
      const part = r.from >= here ? 1 : (r.to - here) / Math.max(1, r.to - r.from);
      delay += r.delay * part;
      if (!next && (r.level === "jam" || r.delay >= 90)) next = { ...r, distance: Math.max(0, r.from - here) };
    }
    traffic().set({ ahead: { delay: Math.round(delay), next } });
    emit("traffic:delay", { routeId: route.id, delay: Math.round(delay), nextJam: next?.distance ?? null });

    if (s.mode !== "drive" || !next || next.distance > ALERT_RANGE_M) return;
    const key = `traffic-${next.start[0].toFixed(3)}-${next.start[1].toFixed(3)}`;
    const words = next.level === "jam" ? "Bouchon" : "Ralentissement";
    const min = Math.max(1, Math.round(next.delay / 60));
    const say = (id: string) => emit("drive:alert", {
      id, kind: "traffic", tone: "warn", distance: Math.round(next!.distance),
      text: next!.distance < 150 ? `${words} ici, ~${min} min de retard` : `${words} dans ${formatDistance(next!.distance)}, ~${min} min de retard`,
    });
    if (!alerted.has(key)) {
      alerted.add(key);
      say(key);
      if (next.distance <= NEAR_M) alerted.add(`${key}-near`);
    } else if (next.distance <= NEAR_M && !alerted.has(`${key}-near`)) {
      alerted.add(`${key}-near`);
      say(`${key}-near`);
    }
  }

  const schedule = () => {
    window.clearInterval(timer);
    const s = core();
    if (s.mode === "drive") timer = window.setInterval(query, REFRESH_MS);
  };

  let tickThrottle = 0;
  const offs = [
    on("drive:start", () => { alerted.clear(); query(); schedule(); }),
    on("drive:rerouted", () => { query(); }),
    on("drive:stop", () => { window.clearInterval(timer); traffic().set({ route: null, ahead: null }); }),
    on("geo:tick", () => {
      const now = Date.now();
      if (now - tickThrottle < 2000) return;
      tickThrottle = now;
      if (core().mode === "drive") update();
    }),
    // itinéraire changé (aperçu, choix d'une alternative, recalcul) ou changement de mode
    useCore.subscribe((s, prev) => {
      if (s.mode !== prev.mode) schedule();
      const changed = s.routes !== prev.routes || s.activeRoute !== prev.activeRoute || s.mode !== prev.mode;
      if (!changed) return;
      if (s.mode === "browse" || !s.routes.length) { traffic().set({ route: null, ahead: null }); return; }
      query();
    }),
  ];

  // le trafic a changé dans la zone (diffusé par le serveur) → on réinterroge, sans s'emballer
  const onUpdate = () => { if (core().mode === "drive" && Date.now() - lastQuery > 15_000) query(); };
  window.addEventListener("osamaps-traffic-update", onUpdate);

  return () => { offs.forEach((o) => o()); window.clearInterval(timer); window.removeEventListener("osamaps-traffic-update", onUpdate); };
}

/** Utilisé par la couche carte pour prévenir qu'une mise à jour socket est arrivée. */
export const notifyTrafficUpdate = () => window.dispatchEvent(new Event("osamaps-traffic-update"));

