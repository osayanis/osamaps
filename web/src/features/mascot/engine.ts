import { create } from "zustand";
import { core, useCore, type Position } from "../../core/store";
import { emit, on } from "../../core/bus";
import { distance } from "../../core/geometry";
import { loadLocal, saveLocal } from "../../core/identity";
import { simulated } from "../../core/geo";
import { BADGES, POINTS, badgeById, levelOf } from "./data";
import type { Accessory, Arms, Mood } from "./Mascot";

/**
 * Le cerveau de la mascotte : points, niveaux, badges, accessoires, statistiques de trajet,
 * humeur en direct et petits messages. Tout est local (clés « osamaps.mascot.* »).
 */

export interface Trip {
  id: string;
  start: number;
  end: number;
  /** mètres */
  distance: number;
  /** secondes (départ → arrivée) */
  duration: number;
  /** secondes en mouvement */
  moving: number;
  avgKmh: number;
  maxKmh: number;
  stops: number;
  points: number;
  arrived: boolean;
  destination?: string;
  badges: string[];
  levelUp?: { level: number; name: string };
}

export interface Settings {
  animations: boolean;
  talk: boolean;
  /** Participer au classement hebdo (pseudo + points de la semaine), opt-in. */
  leaderboard: boolean;
}

interface Saved {
  points: number;
  /** mètres cumulés */
  totalDistance: number;
  trips: number;
  badges: Record<string, number>;
  /** Anciens accessoires (avant l'éditeur) : relus une fois pour la première apparence, voir look.ts. */
  equipped: Accessory[];
  history: Trip[];
  reports: number;
  confirmed: number;
  votes: number;
  destinations: string[];
  days: string[];
  week: { key: string; points: number };
  settings: Settings;
  lastTalk: number;
}

const DEFAULT: Saved = {
  points: 0, totalDistance: 0, trips: 0, badges: {}, equipped: [], history: [], reports: 0, confirmed: 0, votes: 0,
  destinations: [], days: [], week: { key: "", points: 0 },
  settings: { animations: true, talk: true, leaderboard: false }, lastTalk: 0,
};

interface Live {
  mood: Mood;
  arms: Arms;
  hop: number;
  sleeping: boolean;
  moving: boolean;
}

interface MascotState extends Saved {
  live: Live;
  /** trajet en cours (null hors conduite) */
  trip: Tracker | null;
}

interface Tracker {
  start: number;
  distance: number;
  moving: number;
  maxSpeed: number;
  stops: number;
  stoppedSince: number | null;
  countedStop: boolean;
  last: { coord: [number, number]; time: number } | null;
  earned: number;
  destination?: string;
  destKey?: string;
  pauseTold: boolean;
  startLevel: number;
}

function loadSaved(): Saved {
  const s = loadLocal<Partial<Saved>>("mascot.state", {});
  return { ...DEFAULT, ...s, settings: { ...DEFAULT.settings, ...(s.settings ?? {}) }, week: s.week ?? DEFAULT.week };
}

export const useMascot = create<MascotState>(() => ({
  ...loadSaved(),
  live: { mood: "calm", arms: "rest", hop: 0, sleeping: false, moving: false },
  trip: null,
}));

const st = () => useMascot.getState();

function persist() {
  const s = st();
  const out: Saved = {
    points: s.points, totalDistance: s.totalDistance, trips: s.trips, badges: s.badges, equipped: s.equipped,
    history: s.history, reports: s.reports, confirmed: s.confirmed, votes: s.votes, destinations: s.destinations, days: s.days,
    week: s.week, settings: s.settings, lastTalk: s.lastTalk,
  };
  saveLocal("mascot.state", out);
}

function patch(p: Partial<MascotState>) {
  useMascot.setState(p);
  persist();
}

function setLive(p: Partial<Live>) {
  useMascot.setState((s) => ({ live: { ...s.live, ...p } }));
}

/* ───────────── semaine, jours ───────────── */

export function weekKey(d = new Date()): string {
  // semaine ISO 8601 (« 2026-W45 »)
  const t = new Date(Date.UTC(d.getFullYear(), d.getMonth(), d.getDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  const n = Math.ceil(((t.getTime() - y0.getTime()) / 86400000 + 1) / 7);
  return `${t.getUTCFullYear()}-W${String(n).padStart(2, "0")}`;
}
const dayKey = (d = new Date()) => `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;

/* ───────────── points, badges, accessoires ───────────── */

const driving = () => core().mode === "drive";
let pendingLevelToast: string | null = null;

/** Ajoute des points ; renvoie le nouveau niveau s'il a changé. */
function addPoints(n: number): { level: number; name: string } | null {
  if (!(n > 0)) return null;
  const s = st();
  const before = levelOf(s.points).level;
  const wk = weekKey();
  const week = s.week.key === wk ? { key: wk, points: s.week.points + n } : { key: wk, points: n };
  const points = s.points + Math.round(n);
  patch({ points, week });
  if (s.trip) useMascot.setState({ trip: { ...st().trip!, earned: st().trip!.earned + Math.round(n) } });
  const after = levelOf(points);
  if (after.level > before) {
    const text = `Niveau ${after.level} : ${after.name} !`;
    if (driving()) pendingLevelToast = text; else say(text, "good", true);
    return { level: after.level, name: after.name };
  }
  return null;
}

/** Vérifie les badges ; renvoie les nouveaux. */
function checkBadges(ctx: { trip?: Trip } = {}): string[] {
  const s = st();
  const got = new Set(Object.keys(s.badges));
  const earned: string[] = [];
  const grant = (id: string, cond: boolean) => { if (cond && !got.has(id)) { earned.push(id); got.add(id); } };
  const km = s.totalDistance / 1000;
  const t = ctx.trip;
  grant("premier-trajet", s.trips >= 1);
  grant("10-trajets", s.trips >= 10);
  grant("100-km", km >= 100);
  grant("1000-km", km >= 1000);
  grant("signaleur", s.reports >= 10);
  grant("confirme", s.confirmed >= 10);
  grant("entraide", s.votes >= 10);
  grant("explorateur", s.destinations.length >= 10);
  grant("fidele", s.days.length >= 7);
  if (t) {
    const h0 = new Date(t.start).getHours(), h1 = new Date(t.end).getHours();
    const night = (h: number) => h >= 22 || h < 5;
    grant("marathon", t.distance >= 100_000);
    grant("nuit", t.distance >= 1000 && (night(h0) || night(h1)));
    grant("matinal", t.distance >= 1000 && h0 >= 5 && h0 < 7);
  }
  if (earned.length) {
    const badges = { ...st().badges };
    for (const id of earned) badges[id] = Date.now();
    patch({ badges });
    addPoints(earned.length * POINTS.badge);
    if (!t) for (const id of earned) say(`Nouveau badge : ${badgeById(id)?.name} !`, "good", true);
  }
  return earned;
}

export function setSetting<K extends keyof Settings>(k: K, v: Settings[K]) {
  patch({ settings: { ...st().settings, [k]: v } });
}

/* ───────────── humeur en direct ───────────── */

let moodTimer = 0;
function react(mood: Mood, arms: Arms, ms: number) {
  window.clearTimeout(moodTimer);
  setLive({ mood, arms, hop: st().live.hop + 1, sleeping: false });
  moodTimer = window.setTimeout(() => setLive({ mood: "calm", arms: "rest" }), ms);
}
export function poke() {
  lastMove = Date.now();
  react("happy", "wave", 1400);
}

/* ───────────── la mascotte parle (rarement) ───────────── */

const COOLDOWN = 20 * 60_000;
function say(text: string, tone: "info" | "good" | "warn" = "info", force = false) {
  const s = st();
  if (!s.settings.talk) return;
  const now = Date.now();
  if (!force && now - s.lastTalk < COOLDOWN) return;
  patch({ lastTalk: now });
  emit("toast", { text, icon: "mascot", tone });
}

const HELLO = ["Bonne route !", "C'est parti, bonne route !", "En route ! Je surveille la carte."];
const pick = <T,>(a: readonly T[]) => a[Math.floor(Math.random() * a.length)];

/* ───────────── statistiques de trajet ───────────── */

function startTrip() {
  const dest = core().destination;
  useMascot.setState({
    trip: {
      start: Date.now(), distance: 0, moving: 0, maxSpeed: 0, stops: 0, stoppedSince: null, countedStop: false,
      last: null, earned: 0, destination: dest?.name,
      destKey: dest ? `${dest.coord[0].toFixed(2)},${dest.coord[1].toFixed(2)}` : undefined, pauseTold: false,
      startLevel: levelOf(st().points).level,
    },
  });
  // seulement avant de rouler, une fois de temps en temps
  const sp = core().position?.speed ?? 0;
  if (sp < 2 && Math.random() < 0.6) say(pick(HELLO));
}

/** Une nouvelle position pendant la conduite. */
function trackPosition(p: Position) {
  const t = st().trip;
  if (!t) return;
  const now = p.time || Date.now();
  const next: Tracker = { ...t };
  if (t.last) {
    const dt = (now - t.last.time) / 1000;
    const d = distance(t.last.coord, p.coord);
    if (dt > 0) {
      const computed = d / dt / SPEEDUP;
      // vrais sauts GPS ignorés : téléportation (> 2 km d'un coup) ou vitesse absurde avec un fix imprécis
      const imprecise = p.accuracy == null || p.accuracy > 30;
      if (d > 2000 || (computed > 70 && d > 50 && imprecise)) { next.last = { coord: p.coord, time: now }; useMascot.setState({ trip: next }); return; }
      let speed = p.speed ?? computed;
      if (speed > 70) speed = Math.min(computed, 70);
      next.distance += d;
      if (speed > 1.2) {
        next.moving += dt * SPEEDUP;
        next.stoppedSince = null;
        next.countedStop = false;
      } else if (next.distance > 100) {
        next.stoppedSince ??= now;
        if (!next.countedStop && now - next.stoppedSince > 20_000) { next.stops += 1; next.countedStop = true; }
      }
      next.maxSpeed = Math.max(next.maxSpeed, Math.min(speed, 70));
    }
  }
  next.last = { coord: p.coord, time: now };
  // pause conseillée après 2 h de route (une fois)
  if (!next.pauseTold && now - next.start > 2 * 3600_000) {
    next.pauseTold = true;
    say("Ça fait deux heures que tu roules : pense à faire une pause.", "info", true);
  }
  useMascot.setState({ trip: next });
}

let arrivedName: string | null = null;

/** Simulateur accéléré (?sim=90&speedup=4) : on remet les durées à l'échelle pour des stats cohérentes. */
const SPEEDUP = simulated ? Math.max(1, Number(new URLSearchParams(location.search).get("speedup")) || 1) : 1;

function endTrip(arrived: boolean): Trip | null {
  const t = st().trip;
  useMascot.setState({ trip: null });
  if (!t) return null;
  const end = Math.max(Date.now(), t.last?.time ?? 0);
  const duration = Math.max(1, ((end - t.start) / 1000) * SPEEDUP);
  if (!arrived && t.distance < 300) return null;           // fausse alerte : on n'enregistre rien

  const s = st();
  const days = s.days.includes(dayKey()) ? s.days : [...s.days, dayKey()].slice(-60);
  const destinations = arrived && t.destKey && !s.destinations.includes(t.destKey)
    ? [...s.destinations, t.destKey].slice(-200) : s.destinations;
  patch({ totalDistance: s.totalDistance + t.distance, trips: s.trips + (arrived ? 1 : 0), days, destinations });

  const before = t.earned;
  let levelUp = addPoints(Math.floor(t.distance / 1000) * POINTS.perKm + (arrived ? POINTS.arrived : 0));
  const trip: Trip = {
    id: String(t.start), start: t.start, end, distance: t.distance, duration, moving: t.moving,
    avgKmh: (t.distance / duration) * 3.6, maxKmh: t.maxSpeed * 3.6, stops: t.stops, points: 0, arrived,
    destination: arrivedName ?? t.destination, badges: [],
  };
  trip.badges = checkBadges({ trip });
  const lvl1 = levelOf(st().points);
  // niveau gagné pendant le trajet (signalements, km, badges) : affiché dans le résumé
  if (lvl1.level > t.startLevel) levelUp = { level: lvl1.level, name: lvl1.name };
  if (levelUp) trip.levelUp = levelUp;
  if (levelUp && arrived) pendingLevelToast = null;      // le résumé le dit déjà
  // points du trajet = km + arrivée + badges + ce que les autres modules ont donné pendant le trajet
  trip.points = before + (st().points - s.points);
  patch({ history: [trip, ...st().history].slice(0, 20) });
  arrivedName = null;
  return trip;
}

/* ───────────── sommeil : à l'arrêt prolongé ───────────── */

let lastMove = Date.now();
let lastCoord: [number, number] | null = null;
const SLEEP_AFTER = 60_000;

function watchMovement(p: Position) {
  const moved = lastCoord ? distance(lastCoord, p.coord) > 4 : false;
  const fast = (p.speed ?? 0) > 0.8;
  if (moved || fast) {
    lastMove = Date.now();
    if (st().live.sleeping) setLive({ sleeping: false, mood: "calm" });
  }
  lastCoord = p.coord;
  const moving = fast || moved;
  if (moving !== st().live.moving) setLive({ moving });
}

/* ───────────── démarrage du module ───────────── */

export function initMascot() {
  const offs: (() => void)[] = [];
  offs.push(on("drive:start", () => { startTrip(); lastMove = Date.now(); setLive({ sleeping: false }); }));
  offs.push(on("drive:alert", () => react("excited", "rest", 1600)));
  offs.push(on("drive:arrived", ({ destinationName }) => {
    arrivedName = destinationName || null;
    react("happy", "up", 4000);
    // certains modules n'émettent pas drive:stop juste après l'arrivée : on clôt ici
    finish(true);
  }));
  offs.push(on("drive:stop", ({ arrived }) => finish(arrived)));
  offs.push(on("points:earn", ({ amount, reason }) => {
    const n = Math.max(0, Math.min(POINTS.maxEvent, Math.round(Number(amount) || 0)));
    const r = String(reason ?? "");
    // reasons du module reports : « Ton signalement est confirmé » (contient aussi « signal » : confirm d'abord),
    // « Signalement : Police »…, « Vote : toujours là / plus là » (voter sur le signalement d'un autre)
    if (/confirm/i.test(r)) patch({ confirmed: st().confirmed + 1 });
    else if (/^vote/i.test(r)) patch({ votes: st().votes + 1 });
    else if (/signal|report/i.test(r)) patch({ reports: st().reports + 1 });
    addPoints(n);
    if (!driving()) checkBadges();
    else badgeCheckLater = true;
  }));
  offs.push(useCore.subscribe((s, prev) => {
    if (s.position && s.position !== prev.position) {
      watchMovement(s.position);
      if (st().trip) trackPosition(s.position);
    }
    // fin de conduite sans évènement drive:stop (sécurité)
    if (prev.mode === "drive" && s.mode !== "drive" && st().trip) finish(false);
    // messages retenus pendant la conduite
    if (prev.mode === "drive" && s.mode !== "drive") {
      if (pendingLevelToast) { say(pendingLevelToast, "good", true); pendingLevelToast = null; }
      if (badgeCheckLater) { badgeCheckLater = false; checkBadges(); }
    }
  }));
  const timer = window.setInterval(() => {
    if (!st().live.sleeping && Date.now() - lastMove > SLEEP_AFTER) setLive({ sleeping: true, mood: "sleepy", arms: "rest" });
  }, 5000);
  offs.push(() => window.clearInterval(timer));

  // accès de test headless : window.osamaps.mascot
  const w = window as unknown as { osamaps?: Record<string, unknown> };
  if (w.osamaps) w.osamaps.mascot = { state: st, sleep: () => setLive({ sleeping: true, mood: "sleepy" }), poke, demoTrip, addPoints };
  return () => offs.forEach((f) => f());
}

let badgeCheckLater = false;
let finishing = false;
function finish(arrived: boolean) {
  if (finishing || !st().trip) return;
  finishing = true;
  try {
    const trip = endTrip(arrived);
    if (trip && trip.arrived) {
      // laisse les autres modules fermer leurs panneaux, puis ouvre le résumé
      window.setTimeout(() => core().openPanel("trip-summary", trip), 700);
    }
  } finally {
    finishing = false;
  }
}

/** Pour les tests : un faux trajet terminé de `km` kilomètres. */
function demoTrip(km = 12.4, minutes = 17, destination = "Vichy") {
  const end = Date.now();
  const start = end - minutes * 60_000;
  useMascot.setState({
    trip: {
      start, distance: km * 1000, moving: minutes * 52, maxSpeed: 24.7, stops: 2, stoppedSince: null, countedStop: false,
      last: null, earned: 0, destination, destKey: `demo-${destination}`, pauseTold: true, startLevel: levelOf(st().points).level,
    },
  });
  arrivedName = destination;
  react("happy", "up", 4000);
  finish(true);
}

export const ALL_BADGES = BADGES;
