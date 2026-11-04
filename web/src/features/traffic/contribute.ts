import { on } from "../../core/bus";
import { core, type LngLat } from "../../core/store";
import { usePrefs } from "../../core/prefs";
import { getSocket } from "../../core/services";
import { bearing, distance } from "../../core/geometry";
import { traffic } from "./state";

/**
 * Contribution anonyme au trafic (si `prefs.contributeTraffic`).
 *
 * Pendant un trajet, toutes les ~5 s : un segment « position précédente → actuelle », la vitesse
 * et le cap, avec un JETON ALÉATOIRE PROPRE AU TRAJET (pas d'identifiant d'appareil).
 * Vie privée du domicile : un segment ne part que s'il est à plus de 300 m du point de départ
 * ET à plus de 300 m de la position actuelle (on attend de s'être éloigné). À la fin du trajet,
 * ce qui reste en attente (les 300 derniers mètres) est jeté. En conduite, rien non plus à moins
 * de 300 m de la destination.
 *
 * Un trajet commence en conduite, ou en exploration au-delà de 5 km/h. En exploration, rien ne
 * part tant qu'on n'a pas dépassé 30 km/h une fois (sinon piétons et vélos passeraient pour des
 * bouchons). Il se termine à l'arrivée ou après 5 min à l'arrêt hors conduite.
 * Position simulée (?sim) : aucune contribution, sauf `?trafficsim=1` (tests locaux uniquement).
 */
const PING_EVERY_MS = 5000;
const SEND_GAP_MS = 3300;           // le serveur accepte 1 ping / 3 s par connexion
const PRIVACY_M = 300;
const MOVING_MS = 5 / 3.6;          // 5 km/h
const VEHICLE_MS = 30 / 3.6;        // 30 km/h : on est (presque) sûr d'être en voiture
const STOP_END_MS = 5 * 60_000;
const allowSim = new URLSearchParams(location.search).has("trafficsim");

interface Ping { t: string; a: LngLat; b: LngLat; s: number; h: number | null; dt: number; at: number }

interface Trip {
  token: string;
  start: LngLat;
  last: LngLat;
  traveled: number;
  vehicle: boolean;
  lastMove: number;
  pingFrom: LngLat;
  pingAt: number;
  heading: number | null;
  queue: Ping[];
}

function newToken() {
  const b = new Uint8Array(12);
  crypto.getRandomValues(b);
  return Array.from(b, (x) => x.toString(36).padStart(2, "0")).join("").slice(0, 20);
}

export function startContribution(): () => void {
  let trip: Trip | null = null;
  let lastSend = 0;

  const end = () => {
    trip = null; // les segments en attente (300 derniers mètres) sont jetés
    traffic().set({ tripActive: false, sent: 0 });
  };

  const flush = (pos: LngLat, now: number) => {
    if (!trip) return;
    const { destination, mode } = core();
    const keep: Ping[] = [];
    for (const p of trip.queue) {
      // trop près du départ : jeté définitivement
      if (distance(p.a, trip.start) < PRIVACY_M || distance(p.b, trip.start) < PRIVACY_M) continue;
      // trop près de la destination annoncée : jeté
      if (mode === "drive" && destination && distance(p.b, destination.coord) < PRIVACY_M) continue;
      // trop vieux pour servir (fenêtre serveur de 15 min)
      if (now - p.at > 14 * 60_000) continue;
      keep.push(p);
    }
    trip.queue = keep;
    if (!trip.vehicle || trip.traveled < PRIVACY_M) return;
    if (now - lastSend < SEND_GAP_MS) return;
    const next = trip.queue[0];
    // on attend d'être à plus de 300 m du segment (au cas où le trajet s'arrêterait ici)
    if (!next || distance(next.a, pos) < PRIVACY_M || distance(next.b, pos) < PRIVACY_M) return;
    trip.queue.shift();
    const { at, ...payload } = next;
    getSocket().emit("traffic:ping", { ...payload, ago: Math.round((now - at) / 1000) });
    lastSend = now;
    traffic().set({ sent: traffic().sent + 1 });
  };

  const offTick = on("geo:tick", () => {
    const pos = core().position;
    if (!pos) return;
    if (!usePrefs.getState().contributeTraffic || (pos.simulated && !allowSim)) { if (trip) end(); return; }
    if (pos.accuracy != null && pos.accuracy > 60) return; // GPS trop imprécis
    const now = Date.now();
    const mode = core().mode;
    const speed = pos.speed ?? 0;

    if (!trip) {
      if (mode !== "drive" && speed < MOVING_MS) return;
      trip = {
        token: newToken(), start: pos.coord, last: pos.coord, traveled: 0, vehicle: mode === "drive" || speed >= VEHICLE_MS,
        lastMove: now, pingFrom: pos.coord, pingAt: now, heading: pos.heading, queue: [],
      };
      traffic().set({ tripActive: true, sent: 0 });
      return;
    }

    trip.traveled += distance(trip.last, pos.coord);
    trip.last = pos.coord;
    if (speed >= MOVING_MS) trip.lastMove = now;
    if (speed >= VEHICLE_MS || mode === "drive") trip.vehicle = true;
    if (pos.heading != null) trip.heading = pos.heading;
    if (mode !== "drive" && now - trip.lastMove > STOP_END_MS) { end(); return; }

    if (now - trip.pingAt >= PING_EVERY_MS) {
      const dt = (now - trip.pingAt) / 1000;
      if (dt <= 30) {
        const d = distance(trip.pingFrom, pos.coord);
        const h = d > 5 ? bearing(trip.pingFrom, pos.coord) : trip.heading;
        const s = pos.speed != null && pos.speed >= 0 ? pos.speed : d / dt;
        if (h != null && s <= 70) {
          trip.queue.push({ t: trip.token, a: trip.pingFrom, b: pos.coord, s: Math.round(s * 10) / 10, h: Math.round(h * 10) / 10, dt: Math.round(dt * 10) / 10, at: now });
          if (trip.queue.length > 240) trip.queue.shift();
        }
      }
      trip.pingFrom = pos.coord;
      trip.pingAt = now;
    }
    flush(pos.coord, now);
  });

  const offStop = on("drive:stop", ({ arrived }) => { if (arrived) end(); });
  const offArrived = on("drive:arrived", () => end());
  const offPrefs = usePrefs.subscribe((s, prev) => { if (prev.contributeTraffic && !s.contributeTraffic) end(); });

  return () => { offTick(); offStop(); offArrived(); offPrefs(); };
}
