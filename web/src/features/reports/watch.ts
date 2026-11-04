import { emit, on } from "../../core/bus";
import { core, type Route } from "../../core/store";
import { bearing, cumulativeDistances, distance, formatDistance, snapToLine } from "../../core/geometry";
import { KINDS, titleOf } from "./catalog";
import { reports, useReports } from "./state";

/**
 * En conduite : repère les signalements DEVANT sur l'itinéraire actif (≤ 1,5 km, même sens) et
 * émet `drive:alert` (le module guidance affiche et annonce). Deux étapes par signalement, même id :
 * en entrant à ≤ 1,5 km, puis à ≤ 300 m. En passant à côté, propose « Toujours là ? ».
 */
const AHEAD_MAX = 1500;
const NEAR = 300;
const ON_ROUTE = 45; // m entre le signalement et le tracé
const SAME_WAY = 70; // degrés

const angleDiff = (a: number, b: number) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };

let cache: { id: string; cum: number[] } | null = null;
const cumOf = (r: Route) => {
  if (cache?.id !== r.id) cache = { id: r.id, cum: cumulativeDistances(r.coords) };
  return cache.cum;
};

/** id → étape déjà annoncée (1 = 1,5 km, 2 = 300 m). */
const alerted = new Map<string, number>();
/** id → on est passé à moins de 60 m (en attente de s'éloigner pour demander). */
const near = new Set<string>();
const asked = new Set<string>();

export function startDriveWatch() {
  let last = 0;
  const offTick = on("geo:tick", () => {
    const t = performance.now();
    if (t - last < 900) return;
    last = t;
    try { tick(); } catch (e) { console.error("[reports] veille conduite", e); }
  });
  const offStop = on("drive:stop", () => { alerted.clear(); near.clear(); useReports.setState({ ask: null }); });
  return () => { offTick(); offStop(); };
}

function tick() {
  const { mode, position, routes, activeRoute, progress } = core();
  if (mode !== "drive" || !position) return;
  const me = position.coord;
  const { items, settings, mine, voted, ask } = reports();
  const list = Object.values(items).filter((r) => distance(me, [r.lng, r.lat]) < AHEAD_MAX + 300);

  // ——— alertes le long de l'itinéraire ———
  const route = routes[activeRoute];
  if (route && route.coords.length > 1) {
    const cum = cumOf(route);
    const from = Math.max(0, (progress?.shapeIndex ?? 0) - 2);
    const mine2 = snapToLine(me, route.coords, cum, from);
    // fenêtre : 200 m derrière → 1,7 km devant
    let i0 = mine2.index, i1 = mine2.index + 1;
    while (i0 > 0 && mine2.along - cum[i0] < 200) i0--;
    while (i1 < route.coords.length - 1 && cum[i1] - mine2.along < AHEAD_MAX + 200) i1++;
    const coords = route.coords.slice(i0, i1 + 1);
    const c = cum.slice(i0, i1 + 1);
    for (const r of list) {
      if (!settings.alerts[r.type]) continue;
      const s = snapToLine([r.lng, r.lat], coords, c);
      if (s.offset > ON_ROUTE) continue;
      const k = Math.min(coords.length - 1, s.index + 1);
      if (r.heading != null && k > s.index && angleDiff(r.heading, bearing(coords[s.index], coords[k])) > SAME_WAY) continue;
      const ahead = s.along - mine2.along;
      if (ahead <= 15 || ahead > AHEAD_MAX) continue;
      const stage = ahead <= NEAR ? 2 : 1;
      if ((alerted.get(r.id) ?? 0) >= stage) continue;
      alerted.set(r.id, stage);
      emit("drive:alert", {
        id: `report:${r.id}`,
        kind: r.type,
        text: `${titleOf(r.type, r.sub)} dans ${formatDistance(ahead)}`,
        distance: Math.round(ahead),
        tone: KINDS[r.type].tone,
      });
    }
  }

  // ——— « Toujours là ? » en passant à côté (avec ou sans itinéraire) ———
  if (!reports().settings.ask) return;
  for (const r of list) {
    if (mine[r.id] || voted[r.id] || asked.has(r.id)) continue;
    const d = distance(me, [r.lng, r.lat]);
    if (d < 60) {
      // même sens que nous (si on le sait), sinon c'est l'autre voie
      if (r.heading != null && position.heading != null && angleDiff(r.heading, position.heading) > SAME_WAY) continue;
      near.add(r.id);
    } else if (near.has(r.id) && d > 90) {
      near.delete(r.id);
      asked.add(r.id);
      if (!ask) useReports.setState({ ask: { id: r.id, at: Date.now() } });
    }
  }
}

/** Pour les tests : oublie ce qui a été annoncé. */
export function resetDriveWatch() { alerted.clear(); near.clear(); asked.clear(); }
