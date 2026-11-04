import maplibregl from "maplibre-gl";
import { core, useCore, type Route, type Position, type LngLat } from "../../core/store";
import { usePrefs, prefs } from "../../core/prefs";
import { on, emit, type BusEvents } from "../../core/bus";
import { speak, setMuted } from "../../core/voice";
import { cumulativeDistances, snapToLine, distance } from "../../core/geometry";
import { guide, setGuide, initialGuide, useGuide, useGuidePrefs, type GuideAlert } from "./state";
import { action, capitalize, kindOf, isArrive, mainStreet, spokenDistance, withArticle } from "./maneuvers";

/**
 * Le moteur du guidage : à chaque position, accroche au tracé, calcule la progression,
 * déclenche les annonces vocales, détecte la sortie de route, l'arrivée et les excès de vitesse.
 * Aucun rendu ici : le HUD et la barre du bas lisent `useGuide` et `core.progress`.
 */

interface RouteCtx { route: Route; cum: number[]; total: number }

let ctx: RouteCtx | null = null;
let lastSeg = 0;
let lastPos: Position | null = null;
let speedMs = 0;
let odometer = 0;
let tripStart = { time: 0, odo: 0 };
/** Annonces déjà faites : index de manœuvre → étape la plus proche annoncée. */
let announced = new Map<number, number>();
/** Manœuvres pour lesquelles « Continuez pendant… » a déjà été dit. */
let continued = new Set<number>();
let off = { count: 0, since: 0 };
let lastRecompute = 0;
let recomputeTimer = 0;
let arriveTimer = 0;
let overviewTimer = 0;
let lastLimit: number | null = null;
const spokenAlerts = new Set<string>();

/* ---------- voix ---------- */

function say(text: string, priority = false) {
  if (!prefs().voice) return;
  speak(text, { priority });
}

/** Petit bip discret (WebAudio), une fois par dépassement. */
let audio: AudioContext | null = null;
function beep() {
  try {
    const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    audio ??= new Ctor();
    void audio.resume();
    const t = audio.currentTime;
    for (const [i, freq] of [[0, 880], [1, 1175]] as const) {
      const osc = audio.createOscillator();
      const gain = audio.createGain();
      osc.type = "sine";
      osc.frequency.value = freq;
      const start = t + i * 0.16;
      gain.gain.setValueAtTime(0, start);
      gain.gain.linearRampToValueAtTime(0.12, start + 0.015);
      gain.gain.exponentialRampToValueAtTime(0.0001, start + 0.13);
      osc.connect(gain).connect(audio.destination);
      osc.start(start);
      osc.stop(start + 0.15);
    }
  } catch { /* pas d'audio : tant pis */ }
}

/* ---------- seuils d'annonce selon la vitesse ---------- */

/** Étapes (m) avant la manœuvre ; la dernière, « maintenant », dépend de la vitesse. */
function stagesFor(speed: number): number[] {
  const kmh = speed * 3.6;
  const now = Math.max(25, Math.min(120, speed * 3));
  if (kmh > 75) return [2000, 800, 250, now];
  if (kmh > 45) return [800, 300, now];
  return [400, 100, now];
}

/* ---------- itinéraire courant ---------- */

function activeRoute(): Route | null {
  const { routes, activeRoute: i } = core();
  return routes[i] ?? null;
}

function loadRoute(route: Route) {
  const cum = cumulativeDistances(route.coords);
  ctx = { route, cum, total: cum[cum.length - 1] ?? 0 };
  lastSeg = 0;
  announced = new Map();
  continued = new Set();
  off = { count: 0, since: 0 };
  lastLimit = null;
  window.clearTimeout(recomputeTimer);
  setGuide({ routeId: route.id, recalculating: false, along: 0, nextIndex: Math.min(1, route.maneuvers.length - 1), distToNext: 0 });
}

/**
 * Accrochage limité à une fenêtre devant la dernière position (≈ 2 km + 30 s de route) : évite de
 * sauter sur une portion parallèle plus loin dans l'itinéraire à cause du bruit GPS.
 */
function snapWindow(p: LngLat, c: RouteCtx, from: number) {
  const limit = c.cum[from] + 2000 + speedMs * 30;
  let end = from + 2;
  while (end < c.cum.length && c.cum[end - 1] <= limit) end++;
  const snap = snapToLine(p, c.route.coords.slice(from, end), c.cum.slice(from, end), 0);
  return { ...snap, index: snap.index + from };
}

function nextManeuver(route: Route, seg: number): number {
  const ms = route.maneuvers;
  for (let i = 1; i < ms.length; i++) if (ms[i].shapeIndex > seg) return i;
  return Math.max(0, ms.length - 1);
}

function limitAt(route: Route, seg: number): number | null {
  const list = route.speedLimits;
  if (!list?.length) return null;
  let kmh: number | null = null;
  for (const l of list) { if (l.from <= seg) kmh = l.kmh; else break; }
  return kmh;
}

/* ---------- démarrage / arrêt ---------- */

function startDrive() {
  resetDrive();
  const route = activeRoute();
  if (!route) return;
  loadRoute(route);
  tripStart = { time: Date.now(), odo: odometer };
  const first = route.maneuvers[0];
  const eta = new Date(Date.now() + route.duration * 1000);
  const hh = `${eta.getHours()} h ${String(eta.getMinutes()).padStart(2, "0")}`;
  const lead = first && first.street ? `C'est parti, ${action(first)}.` : "C'est parti.";
  say(`${lead} Arrivée prévue à ${hh}.`, true);
}

function resetDrive() {
  ctx = null;
  lastSeg = 0;
  announced = new Map();
  continued = new Set();
  off = { count: 0, since: 0 };
  spokenAlerts.clear();
  lastLimit = null;
  window.clearTimeout(recomputeTimer);
  window.clearTimeout(arriveTimer);
  window.clearTimeout(overviewTimer);
  setGuide({ ...initialGuide, speedKmh: guide().speedKmh });
}

function stopDrive({ arrived }: BusEvents["drive:stop"]) {
  const wasDriving = core().mode === "drive" || guide().arrived;
  resetDrive();
  if (!wasDriving && !arrived) return;
  core().set({ mode: "browse", progress: null, routes: [], destination: null, panel: null, follow: true });
  const map = core().map;
  if (map) map.easeTo({ pitch: 0, bearing: 0, zoom: Math.min(map.getZoom(), 15.5), duration: 600 });
}

/* ---------- à chaque position ---------- */

function onPosition(pos: Position) {
  // compteur kilométrique et vitesse (même hors conduite : le compteur reste juste)
  if (lastPos) {
    const d = distance(lastPos.coord, pos.coord);
    const dt = (pos.time - lastPos.time) / 1000;
    if (d < 500) odometer += d;
    const measured = pos.speed ?? (dt > 0.4 && d < 500 ? d / dt : null);
    if (measured != null) speedMs = speedMs ? speedMs * 0.4 + measured * 0.6 : measured;
  } else if (pos.speed != null) speedMs = pos.speed;
  lastPos = pos;

  const { mode } = core();
  if (mode !== "drive") return;

  const route = activeRoute();
  if (!route || route.coords.length < 2) return;
  if (!ctx || ctx.route.id !== route.id) {
    loadRoute(route);
  }
  const c = ctx!;
  const g = guide();
  const kmh = Math.round(speedMs * 3.6);

  updateAlerts();
  updateSpeed(route, kmh);
  if (g.arrived) return;

  // accrochage : d'abord près de la dernière position connue, puis tout le tracé si on s'en écarte
  let snap = snapWindow(pos.coord, c, Math.max(0, lastSeg - 3));
  const accuracy = pos.accuracy ?? 10;
  const tolerance = Math.max(40, Math.min(accuracy * 1.5, 120));
  if (snap.offset > tolerance && lastSeg > 3) {
    const full = snapToLine(pos.coord, route.coords, c.cum, 0);
    if (full.offset < snap.offset) snap = full;
  }

  // sortie de route
  if (snap.offset > tolerance) {
    if (!off.count) off.since = pos.time;
    off.count++;
    if (off.count >= 3 && pos.time - off.since >= 2500) offRoute(pos.coord);
    return;
  }
  off = { count: 0, since: 0 };
  if (g.recalculating) setGuide({ recalculating: false });

  lastSeg = snap.index;
  const along = snap.along;
  const remainingDistance = Math.max(0, c.total - along);
  const ms = route.maneuvers;
  const next = nextManeuver(route, snap.index);
  const prev = Math.max(0, next - 1);
  const sNext = Math.min(ms[next]?.shapeIndex ?? c.cum.length - 1, c.cum.length - 1);
  const sPrev = Math.min(ms[prev]?.shapeIndex ?? 0, c.cum.length - 1);
  const distToNext = Math.max(0, c.cum[sNext] - along);

  // temps restant : temps Valhalla des manœuvres restantes, au prorata dans la manœuvre en cours
  const segLen = c.cum[sNext] - c.cum[sPrev];
  const frac = segLen > 0 ? Math.min(1, Math.max(0, distToNext / segLen)) : 0;
  let remainingTime = (ms[prev]?.time ?? 0) * frac;
  for (let j = next; j < ms.length; j++) remainingTime += ms[j].time;
  const sumTimes = ms.reduce((s, m) => s + (m.time || 0), 0);
  if (!sumTimes) remainingTime = c.total > 0 ? route.duration * (remainingDistance / c.total) : 0;

  core().set({ progress: { shapeIndex: snap.index, maneuverIndex: next, remainingDistance, remainingTime } });
  const stages = stagesFor(Math.max(speedMs, 8));
  setGuide({ along, nextIndex: next, distToNext, nowThreshold: stages[stages.length - 1] });

  // arrivée : près de la destination, ou au bout du tracé
  const dest: LngLat = core().destination?.coord ?? route.coords[route.coords.length - 1];
  const toDest = distance(pos.coord, dest);
  if ((toDest < 30 && remainingDistance < 150) || remainingDistance < 15) { arrive(route); return; }

  announce(route, next, distToNext, stages);
}

function announce(route: Route, next: number, dist: number, stages: number[]) {
  const ms = route.maneuvers;
  const m = ms[next];
  if (!m) return;
  const kind = kindOf(m);
  // étape la plus proche atteinte
  let reached = -1;
  for (let i = 0; i < stages.length; i++) if (dist <= stages[i]) reached = i;
  if (reached < 0) {
    // juste après une manœuvre, si la suivante est loin : « Continuez sur la N 7 pendant 12 kilomètres »
    if (dist > 3000 && !continued.has(next)) {
      continued.add(next);
      const road = mainStreet(ms[next - 1]);
      say(`Continuez${road ? ` sur ${withArticle(road)}` : ""} pendant ${spokenDistance(dist)}.`);
    }
    return;
  }
  const done = announced.get(next) ?? -1;
  if (reached <= done) return;

  const isNow = reached === stages.length - 1;
  // la sortie d'un rond-point n'est dite qu'au dernier moment (l'entrée l'a déjà annoncée)
  if (kind === "roundabout-exit" && !isNow) { announced.set(next, reached); return; }
  // l'arrivée « maintenant » est dite par arrive()
  if (isArrive(kind) && isNow) { announced.set(next, reached); return; }

  let text = isNow ? capitalize(action(m)) : `Dans ${spokenDistance(dist)}, ${action(m)}`;
  // « puis » : la manœuvre suivante arrive tout de suite après
  const after = ms[next + 1];
  if (after && reached >= stages.length - 2 && ctx) {
    const gap = ctx.cum[Math.min(after.shapeIndex, ctx.cum.length - 1)] - ctx.cum[Math.min(m.shapeIndex, ctx.cum.length - 1)];
    const afterKind = kindOf(after);
    if (gap < 150 && afterKind !== "roundabout-exit" && kind !== "roundabout") {
      text += `, puis ${isArrive(afterKind) ? "vous serez à destination" : action(after)}`;
    }
  }
  say(`${text}.`);

  // étapes « déjà couvertes » : on ne répète pas 100 m après avoir dit 120 m
  let covered = reached;
  for (let i = reached + 1; i < stages.length - 1; i++) if (stages[i] >= dist * 0.7) covered = i;
  announced.set(next, covered);
}

function offRoute(from: LngLat) {
  const now = Date.now();
  if (now - lastRecompute < 12000) return;
  lastRecompute = now;
  setGuide({ recalculating: true });
  say("Recalcul de l'itinéraire.", true);
  emit("route:recompute", { from });
  window.clearTimeout(recomputeTimer);
  // sans nouvel itinéraire au bout de 15 s, on réessaiera à la prochaine position hors tracé
  recomputeTimer = window.setTimeout(() => setGuide({ recalculating: false }), 15000);
}

function arrive(route: Route) {
  const last = route.maneuvers[route.maneuvers.length - 1];
  const kind = last ? kindOf(last) : "arrive";
  const side = kind === "arrive-right" ? "right" : kind === "arrive-left" ? "left" : null;
  const name = core().destination?.name ?? "votre destination";
  setGuide({
    arrived: { name, side, tripTime: (Date.now() - tripStart.time) / 1000, tripDistance: odometer - tripStart.odo },
    distToNext: 0,
  });
  core().set({ progress: { shapeIndex: route.coords.length - 1, maneuverIndex: route.maneuvers.length - 1, remainingDistance: 0, remainingTime: 0 } });
  say(`Vous voilà à destination${side ? `, elle est sur votre ${side === "right" ? "droite" : "gauche"}` : ""}.`, true);
  emit("drive:arrived", { destinationName: name });
  window.clearTimeout(arriveTimer);
  arriveTimer = window.setTimeout(() => {
    if (guide().arrived) emit("drive:stop", { arrived: true });
  }, 6000);
}

/* ---------- vitesse ---------- */

function updateSpeed(route: Route, kmh: number) {
  const limit = limitAt(route, lastSeg);
  const tol = prefs().speedTolerance;
  const g = guide();
  let speeding = g.speeding;
  if (limit != null) {
    if (!speeding && kmh > limit + tol) {
      speeding = true;
      if (useGuidePrefs.getState().speedBeep) beep();
    } else if (speeding && kmh <= limit + tol - 2) speeding = false;
  } else speeding = false;

  if (limit !== lastLimit) {
    if (limit != null && lastLimit != null && useGuidePrefs.getState().speedVoice) say(`Limitation à ${limit}.`);
    lastLimit = limit;
  }
  if (g.speedKmh !== kmh || g.limitKmh !== limit || g.speeding !== speeding) setGuide({ speedKmh: kmh, limitKmh: limit, speeding });
}

/* ---------- alertes ---------- */

function onAlert(a: BusEvents["drive:alert"]) {
  if (core().mode !== "drive" || !a?.id) return;
  const tone = a.tone ?? "info";
  const distanceM = Math.max(0, Number(a.distance) || 0);
  const item: GuideAlert = { id: a.id, kind: a.kind || "danger", text: a.text || "Attention", tone, baseDistance: distanceM, baseOdo: odometer, remaining: distanceM, receivedAt: Date.now() };
  const alerts = guide().alerts.filter((x) => x.id !== a.id);
  alerts.push(item);
  alerts.sort((x, y) => x.remaining - y.remaining);
  setGuide({ alerts });
  if (!spokenAlerts.has(a.id)) {
    spokenAlerts.add(a.id);
    const t = a.text.replace(/\.$/, "");
    say(distanceM >= 60 ? `Attention, ${t.charAt(0).toLowerCase() + t.slice(1)}, dans ${spokenDistance(distanceM)}.` : `Attention, ${t.charAt(0).toLowerCase() + t.slice(1)}.`);
  }
}

function updateAlerts() {
  const list = guide().alerts;
  if (!list.length) return;
  const now = Date.now();
  const next = list
    .map((a) => ({ ...a, remaining: a.baseDistance - (odometer - a.baseOdo) }))
    // dépassée (30 m derrière), ou trop vieille (5 min ; 25 s pour une alerte sans distance)
    .filter((a) => a.remaining > -30 && now - a.receivedAt < (a.baseDistance > 0 ? 300000 : 25000));
  setGuide({ alerts: next });
}

/* ---------- vue d'ensemble ---------- */

export function showOverview() {
  const map = core().map;
  const route = activeRoute();
  if (!map || !route) return;
  const from = Math.max(0, core().progress?.shapeIndex ?? 0);
  const pts = route.coords.slice(from);
  const pos = core().position?.coord;
  if (pos) pts.push(pos);
  if (!pts.length) return;
  const b = new maplibregl.LngLatBounds(pts[0], pts[0]);
  for (const p of pts) b.extend(p);
  core().set({ follow: false });
  setGuide({ overview: true });
  map.fitBounds(b, { padding: { top: 210, bottom: 200, left: 48, right: 48 }, bearing: 0, pitch: 0, duration: 700, maxZoom: 16 });
  window.clearTimeout(overviewTimer);
  overviewTimer = window.setTimeout(resumeFollow, 10000);
}

export function resumeFollow() {
  window.clearTimeout(overviewTimer);
  setGuide({ overview: false });
  core().set({ follow: true });
  emit("map:recenter", {});
}

export function stopGuidance() {
  emit("drive:stop", { arrived: false });
}

export function finishArrival() {
  emit("drive:stop", { arrived: true });
}

/** Coupe / remet la voix (préférence partagée + muet de core/voice gardés d'accord). */
export function toggleVoice() {
  usePrefs.getState().setPref("voice", !prefs().voice);
}

/* ---------- branchement ---------- */

export function initGuidance(): () => void {
  setMuted(!prefs().voice);
  const offs: (() => void)[] = [];
  offs.push(usePrefs.subscribe((s, p) => { if (s.voice !== p.voice) setMuted(!s.voice); }));
  offs.push(useCore.subscribe((s, p) => {
    if (s.mode === "drive" && p.mode !== "drive") startDrive();
    else if (s.mode !== "drive" && p.mode === "drive" && !guide().arrived) resetDrive();
    if (s.position && s.position !== p.position) onPosition(s.position);
    // un recentrage par un autre bouton met fin à la vue d'ensemble
    if (s.follow && !p.follow && guide().overview) { window.clearTimeout(overviewTimer); setGuide({ overview: false }); }
  }));
  offs.push(on("drive:stop", stopDrive));
  offs.push(on("drive:alert", onAlert));
  offs.push(on("drive:rerouted", () => { setGuide({ recalculating: false }); }));
  // déjà en conduite au chargement (rechargement à chaud)
  if (core().mode === "drive") startDrive();
  return () => {
    offs.forEach((f) => f());
    resetDrive();
  };
}

/** Pour le HUD : la manœuvre « puis » si elle suit de près la prochaine. */
export function thenManeuverIndex(route: Route, next: number, distToNext: number): number | null {
  const ms = route.maneuvers;
  const after = ms[next + 1];
  if (!after || !ctx || ctx.route.id !== route.id) return null;
  const m = ms[next];
  const gap = ctx.cum[Math.min(after.shapeIndex, ctx.cum.length - 1)] - ctx.cum[Math.min(m.shapeIndex, ctx.cum.length - 1)];
  if (kindOf(m) === "roundabout" && kindOf(after) === "roundabout-exit") return null;
  return gap < 250 && distToNext < 1200 ? next + 1 : null;
}

export { useGuide };
