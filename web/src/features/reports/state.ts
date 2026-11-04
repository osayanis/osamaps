import { create } from "zustand";
import { api, getSocket } from "../../core/services";
import { deviceId, loadLocal, nickname, saveLocal } from "../../core/identity";
import { emit } from "../../core/bus";
import { core, type LngLat } from "../../core/store";
import { KIND_ORDER, KINDS, titleOf, type Kind, type Report } from "./catalog";

/**
 * État local du module : signalements connus (zone visible), les miens, mes votes, réglages.
 * Temps réel : on rejoint les tuiles z10 visibles (rooms socket « rpt:10/x/y » côté serveur).
 */
export type Vote = "still" | "gone";

export interface ReportsSettings {
  /** Types dont on reçoit les alertes en conduite. */
  alerts: Record<Kind, boolean>;
  /** Proposer « Toujours là ? » en passant à côté. */
  ask: boolean;
}

const defaultSettings: ReportsSettings = {
  alerts: Object.fromEntries(KIND_ORDER.map((k) => [k, true])) as Record<Kind, boolean>,
  ask: true,
};

/** Question « Toujours là ? » en cours (affichée dans le hud). */
export interface Ask { id: string; at: number }

interface ReportsState {
  items: Record<string, Report>;
  /** id → expiration : mes signalements. */
  mine: Record<string, number>;
  /** id → vote : mes votes. */
  voted: Record<string, Vote>;
  settings: ReportsSettings;
  ask: Ask | null;
  upsert: (r: Report) => void;
  remove: (id: string) => void;
  setSettings: (p: Partial<ReportsSettings>) => void;
}

const stored = loadLocal<Partial<ReportsSettings>>("reports.settings", {});

export const useReports = create<ReportsState>((set) => ({
  items: {},
  mine: loadLocal("reports.mine", {}),
  voted: loadLocal("reports.voted", {}),
  settings: { ...defaultSettings, ...stored, alerts: { ...defaultSettings.alerts, ...(stored.alerts ?? {}) } },
  ask: null,
  upsert: (r) => set((s) => (r.expiresAt > Date.now() ? { items: { ...s.items, [r.id]: r } } : s)),
  remove: (id) => set((s) => {
    if (!s.items[id]) return s;
    const items = { ...s.items };
    delete items[id];
    return { items, ask: s.ask?.id === id ? null : s.ask };
  }),
  setSettings: (p) => set((s) => {
    const settings = { ...s.settings, ...p };
    saveLocal("reports.settings", settings);
    return { settings };
  }),
}));

export const reports = () => useReports.getState();

// ——— tuiles z10 (mêmes calculs que le serveur) ———
const Z = 10;
const tileX = (lng: number) => Math.floor(((lng + 180) / 360) * 2 ** Z);
const tileY = (lat: number) => {
  const r = (Math.max(-85, Math.min(85, lat)) * Math.PI) / 180;
  return Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * 2 ** Z);
};

/** Tuiles couvrant une zone (30 max, les plus proches du centre d'abord). */
export function tilesFor(w: number, s: number, e: number, n: number): string[] {
  const x0 = tileX(w), x1 = tileX(e), y0 = tileY(n), y1 = tileY(s);
  const cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
  const out: { t: string; d: number }[] = [];
  for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) out.push({ t: `${Z}/${x}/${y}`, d: (x - cx) ** 2 + (y - cy) ** 2 });
  return out.sort((a, b) => a.d - b.d).slice(0, 30).map((o) => o.t);
}

// ——— réseau ———
let watched: string[] = [];
/** Dernière zone chargée (le temps réel la tient à jour : on ne recharge qu'en sortant de la zone). */
let loaded: { w: number; s: number; e: number; n: number; at: number } | null = null;

/** Charge les signalements d'une zone et rejoint ses tuiles temps réel. */
export async function watchArea(w: number, s: number, e: number, n: number, around?: LngLat | null) {
  // la position compte toujours (en conduite, la carte ne montre que la route devant)
  if (around) {
    w = Math.min(w, around[0] - 0.03); e = Math.max(e, around[0] + 0.03);
    s = Math.min(s, around[1] - 0.02); n = Math.max(n, around[1] + 0.02);
  }
  // on borne à 4° (limite serveur), centré
  const cx = (w + e) / 2, cy = (s + n) / 2;
  w = Math.max(-180, Math.max(w, cx - 1.95)); e = Math.min(180, Math.min(e, cx + 1.95));
  s = Math.max(-85, Math.max(s, cy - 1.95)); n = Math.min(85, Math.min(n, cy + 1.95));

  const tiles = tilesFor(w, s, e, n);
  if (tiles.join() !== watched.join()) {
    watched = tiles;
    getSocket().emit("reports:watch", { tiles });
  }
  const L = loaded;
  if (L && w >= L.w && e <= L.e && s >= L.s && n <= L.n && Date.now() - L.at < 120_000) return;
  // on charge un peu plus large que demandé, pour ne pas recharger à chaque déplacement
  const mx = Math.min(0.5, (e - w) * 0.5), my = Math.min(0.5, (n - s) * 0.5);
  w = Math.max(-180, w - mx); e = Math.min(180, e + mx); s = Math.max(-85, s - my); n = Math.min(85, n + my);
  if (e - w > 3.98) { const c = (w + e) / 2; w = c - 1.99; e = c + 1.99; }
  if (n - s > 3.98) { const c = (s + n) / 2; s = c - 1.99; n = c + 1.99; }
  loaded = { w, s, e, n, at: Date.now() };
  const bbox = [w, s, e, n].map((v) => v.toFixed(4)).join(",");
  try {
    const { reports: list } = await api<{ reports: Report[] }>(`reports?bbox=${bbox}`);
    const { items } = reports();
    const next = { ...items };
    // remplace ce qui est dans la zone, garde le reste
    for (const r of Object.values(items)) if (r.lng >= w && r.lng <= e && r.lat >= s && r.lat <= n) delete next[r.id];
    for (const r of list) next[r.id] = r;
    useReports.setState({ items: next });
  } catch { loaded = null; /* hors ligne : on réessaiera au prochain déplacement */ }
}

function persistMine() {
  const t = Date.now();
  const { mine, voted, items } = reports();
  const m = Object.fromEntries(Object.entries(mine).filter(([, exp]) => exp > t));
  const v = Object.fromEntries(Object.entries(voted).filter(([id]) => items[id] || m[id]).slice(-300));
  useReports.setState({ mine: m, voted: v });
  saveLocal("reports.mine", m);
  saveLocal("reports.voted", v);
}

/** Envoie un signalement (après le délai d'annulation). */
export async function sendReport(type: Kind, sub: string | null, coord: LngLat, heading: number | null) {
  try {
    const { report, merged } = await api<{ report: Report; merged: boolean }>("reports", {
      method: "POST",
      body: JSON.stringify({
        deviceId: deviceId(), type, sub, lng: coord[0], lat: coord[1],
        heading: heading == null || !Number.isFinite(heading) ? null : ((heading % 360) + 360) % 360,
        pseudo: nickname(),
      }),
    });
    reports().upsert(report);
    if (merged) {
      useReports.setState((s) => ({ voted: { ...s.voted, [report.id]: "still" } }));
      emit("points:earn", { amount: 2, reason: "Signalement confirmé" });
      emit("toast", { text: `Déjà signalé : merci, ta confirmation compte`, tone: "good" });
    } else {
      useReports.setState((s) => ({ mine: { ...s.mine, [report.id]: report.expiresAt } }));
      emit("points:earn", { amount: 5, reason: `Signalement : ${KINDS[type].label}` });
      emit("toast", { text: `Merci ! ${titleOf(type, sub)}`, tone: "good" });
    }
    persistMine();
    return report;
  } catch (e) {
    emit("toast", { text: errorText(e, "Signalement non envoyé, réessaie"), tone: "warn" });
    return null;
  }
}

/** Vote « toujours là » / « plus là ». */
export async function vote(id: string, v: Vote) {
  const { mine, voted } = reports();
  if (voted[id] && !mine[id]) return;
  useReports.setState((s) => ({ voted: { ...s.voted, [id]: v }, ask: s.ask?.id === id ? null : s.ask }));
  try {
    const res = await api<{ report: Report | null; removed: boolean; already?: boolean }>(`reports/${encodeURIComponent(id)}/vote`, {
      method: "POST",
      body: JSON.stringify({ deviceId: deviceId(), vote: v }),
    });
    if (res.removed || !res.report) reports().remove(id);
    else reports().upsert(res.report);
    if (!mine[id] && !res.already) emit("points:earn", { amount: 1, reason: "Merci pour ta confirmation" });
  } catch (e) {
    if (String(e).startsWith("Error: 404")) reports().remove(id);
    else emit("toast", { text: errorText(e, "Vote non envoyé"), tone: "warn" });
  }
  persistMine();
}

function errorText(e: unknown, fallback: string) {
  const m = /\{"error":"([^"]+)"\}/.exec(String(e));
  return m ? m[1].charAt(0).toUpperCase() + m[1].slice(1) : fallback;
}

/** Abonnements socket ; renvoie le nettoyage. */
export function connectRealtime() {
  const socket = getSocket();
  const hello = () => {
    socket.emit("reports:hello", { deviceId: deviceId() });
    if (watched.length) socket.emit("reports:watch", { tiles: watched });
  };
  const onNew = (r: Report) => reports().upsert(r);
  const onRemove = (m: { id: string }) => reports().remove(m.id);
  const onThanks = (m: { id: string; type: Kind; amount: number }) => {
    emit("points:earn", { amount: Math.min(5, m.amount || 2), reason: "Ton signalement est confirmé" });
    if (core().mode !== "drive") emit("toast", { text: `Ton signalement « ${KINDS[m.type]?.label ?? "?"} » a été confirmé`, tone: "good" });
  };
  if (socket.connected) hello();
  socket.on("connect", hello);
  socket.on("reports:new", onNew);
  socket.on("reports:update", onNew);
  socket.on("reports:remove", onRemove);
  socket.on("reports:thanks", onThanks);
  // ménage : expirés
  const timer = window.setInterval(() => {
    const t = Date.now();
    for (const r of Object.values(reports().items)) if (r.expiresAt <= t) reports().remove(r.id);
  }, 30_000);
  return () => {
    socket.off("connect", hello);
    socket.off("reports:new", onNew);
    socket.off("reports:update", onNew);
    socket.off("reports:remove", onRemove);
    socket.off("reports:thanks", onThanks);
    window.clearInterval(timer);
  };
}
