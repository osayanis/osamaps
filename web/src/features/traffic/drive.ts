import { emit, on } from "../../core/bus";
import { core, useCore, type LngLat, type Route } from "../../core/store";
import { along as pointAlong, cumulativeDistances, formatDistance, snapToLine } from "../../core/geometry";
import { fetchAlong, fetchRouteEvents, type EventKind } from "./api";
import { traffic, type RouteEvent, type RouteRun } from "./state";
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

/** Portée (m) de la 1re annonce et de la 2de (« tout près ») par type ; null = pas d'annonce. */
function alertRange(e: RouteEvent): [number, number] | null {
  if (e.confidence < 0.5) return null;
  switch (e.type) {
    case "closure": return e.blocking ? [30_000, 2_000] : [5_000, 800];
    case "accident": return [10_000, 1_000];
    case "danger": return [3_000, 500];
    case "jam": return e.delay >= 60 ? [10_000, 1_000] : null;
    case "lanes": return e.severity >= 2 ? [5_000, 800] : null;
    case "works": return e.severity >= 2 ? [2_000, 500] : null;
    case "weather": case "flood": return e.severity >= 3 ? [20_000, 0] : null;
    // points noirs : annoncés en conduite plutôt qu'affichés en permanence sur la carte
    case "hotspot": return e.severity >= 3 ? [800, 0] : e.severity >= 2 ? [350, 0] : null;
    default: return null;
  }
}
function alertText(e: RouteEvent, d: number) {
  const where = d < 150 ? "ici" : `dans ${formatDistance(d)}`;
  const road = e.road ? ` sur ${e.road}` : "";
  switch (e.type) {
    case "closure": return e.blocking ? `Route fermée${road} ${where}, prévoyez un détour` : `${e.title} ${where}`;
    case "accident": return `Accident${road} ${where}${e.delay >= 90 ? `, ~${Math.round(e.delay / 60)} min de retard` : ""}`;
    case "weather": case "flood": return `${e.title} sur votre trajet`;
    case "hotspot": return `Section accidentogène ${where}, prudence`;
    case "lanes": return `${e.lanes ?? e.title} ${where}`;
    default: return `${e.title} ${where}`;
  }
}
const alertTone = (e: RouteEvent): "warn" | "danger" =>
  ["closure", "accident", "danger"].includes(e.type) || ((e.type === "weather" || e.type === "flood") && e.severity >= 4) ? "danger" : "warn";

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

  let evInflight = false;
  /** Évènements multi-sources sur l'itinéraire (accidents, fermetures, travaux, vigilances…). */
  async function queryEvents(route: Route) {
    if (evInflight) return;
    evInflight = true;
    try {
      const s = core();
      const c = cum(route);
      const from = s.mode === "drive" ? Math.max(0, (s.progress?.shapeIndex ?? 0) - 1) : 0;
      const { coords, offset } = slice(route, c, from);
      const res = await fetchRouteEvents(coords);
      if (activeRoute()?.id !== route.id) return;
      const events: RouteEvent[] = res.events.map((e) => ({
        id: e.id, type: e.type as EventKind, severity: e.severity, title: e.title, road: e.road, lanes: e.lanes,
        blocking: !!e.blocking, confidence: e.confidence ?? 0.5, from: offset + e.at, to: offset + e.at + e.length, delay: e.routeDelay,
      }));
      traffic().set({ events: { routeId: route.id, events, at: Date.now() } });
      update();
    } catch {
      const r = traffic().events;
      if (r && Date.now() - r.at > 5 * 60_000) traffic().set({ events: null });
    } finally {
      evInflight = false;
    }
  }

  async function query() {
    const s = core();
    const route = activeRoute();
    if (!route || route.coords.length < 2 || (s.mode !== "drive" && s.mode !== "preview")) return;
    queryEvents(route);
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
    const ev = traffic().events;
    const evs = ev && route && ev.routeId === route.id ? ev.events : [];
    const info = traffic().route?.routeId === route?.id ? traffic().route : evs.length && route ? { routeId: route.id, runs: [] as RouteRun[], at: Date.now() } : null;
    if (!route || !info) { traffic().set({ ahead: null }); return; }
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
    // retards des évènements devant (déjà à 0 côté serveur quand le trafic mesuré les compte)
    for (const e of evs) if (e.to >= here) delay += e.delay;
    traffic().set({ ahead: { delay: Math.round(delay), next } });
    if (s.mode === "drive") {
      for (const e of evs) {
        if (e.to < here - 20) continue;
        const range = alertRange(e);
        if (!range) continue;
        const d = Math.max(0, e.from - here);
        if (d > range[0]) continue;
        const key = `events-${e.id}`;
        const say = (id: string) => emit("drive:alert", { id, kind: `traffic-${e.type}`, tone: alertTone(e), distance: Math.round(d), text: alertText(e, d) });
        if (!alerted.has(key)) { alerted.add(key); say(key); if (d <= range[1]) alerted.add(`${key}-near`); }
        else if (range[1] > 0 && d <= range[1] && !alerted.has(`${key}-near`)) { alerted.add(`${key}-near`); say(`${key}-near`); }
      }
    }
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
    on("drive:stop", () => { window.clearInterval(timer); traffic().set({ route: null, events: null, ahead: null }); }),
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
      if (s.mode === "browse" || !s.routes.length) { traffic().set({ route: null, events: null, ahead: null }); return; }
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

