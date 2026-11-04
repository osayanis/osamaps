import { create } from "zustand";
import { getSocket, BASE } from "../../core/services";
import { deviceId, friendCode, nickname, setNickname, loadLocal, saveLocal } from "../../core/identity";
import { core, useCore, type LngLat } from "../../core/store";
import { usePrefs } from "../../core/prefs";
import { emit, on } from "../../core/bus";
import { distance } from "../../core/geometry";

/**
 * Amis & partage — client temps réel.
 * L'appareil s'identifie auprès du serveur avec deviceId + un secret local (jamais montré) : personne
 * ne peut se faire passer pour un autre deviceId. Les amis sont désignés par un identifiant public (pid).
 */

export interface FriendLoc {
  lng: number;
  lat: number;
  heading: number | null;
  speed: number | null;
  /** Présent s'il conduit ; `to`/`eta` seulement s'il accepte de montrer sa destination. */
  drive: { to: string | null; eta: number | null } | null;
  t: number;
}
export interface Friend { pid: string; name: string; code: string; online: boolean; loc: FriendLoc | null }
export interface Request { pid: string; name?: string; code: string }
export interface SharedTrip { token: string; url: string; expiresAt: number; watchers: number }

interface FriendsState {
  status: "off" | "connecting" | "ready" | "error";
  error: string | null;
  me: { pid: string; code: string; name: string } | null;
  friends: Friend[];
  incoming: Request[];
  outgoing: Request[];
  trip: SharedTrip | null;
  /** Montrer ma destination + heure d'arrivée à mes amis (opt-in). */
  showDest: boolean;
  set: (p: Partial<FriendsState>) => void;
}

export const useFriends = create<FriendsState>((set) => ({
  status: "off",
  error: null,
  me: null,
  friends: [],
  incoming: [],
  outgoing: [],
  trip: null,
  showDest: loadLocal("friends.showDest", false),
  set: (p) => set(p),
}));
const st = () => useFriends.getState();

const params = new URLSearchParams(location.search);
/** Jeton de la vue « suivre un trajet » (?suivre=…), lu une fois au chargement. */
export const followToken = (() => {
  const t = params.get("suivre");
  return t && /^[0-9a-f-]{36}$/i.test(t) ? t.toLowerCase() : null;
})();
/** Code d'invitation (?ami=123456), lu une fois au chargement. */
export const inviteCode = (() => {
  const c = (params.get("ami") ?? "").replace(/\D/g, "");
  return /^\d{6}$/.test(c) ? c : null;
})();

/** Secret local (généré une fois). En navigation privée, il ne vit que le temps de la page. */
let secretCache: string | null = null;
function secret(): string {
  if (secretCache) return secretCache;
  let s = loadLocal<string | null>("friends.secret", null);
  if (!s || !/^[A-Za-z0-9_-]{32,128}$/.test(s)) {
    s = (crypto.randomUUID() + crypto.randomUUID()).replace(/-/g, "");
    saveLocal("friends.secret", s);
  }
  return (secretCache = s);
}
const myDevice = deviceId();

export const inviteUrl = (code: string) => `${location.origin}${BASE}?ami=${code}`;
export const followUrl = (token: string) => `${location.origin}${BASE}?suivre=${token}`;

type Ack<T = object> = { ok: boolean; error?: string } & Partial<T>;
function call<T = object>(event: string, payload: unknown): Promise<Ack<T>> {
  return new Promise((resolve) => {
    const s = getSocket();
    const timer = window.setTimeout(() => resolve({ ok: false, error: "Le serveur ne répond pas." } as Ack<T>), 8000);
    s.emit(event, payload, (r: Ack<T>) => { window.clearTimeout(timer); resolve(r ?? ({ ok: false } as Ack<T>)); });
  });
}

interface StatePayload { me: FriendsState["me"]; friends: Friend[]; incoming: Request[]; outgoing: Request[] }
let prevIncoming: string[] = [];
function applyState(s: StatePayload, notify = false) {
  if (s.me?.code) saveLocal("friends.code", s.me.code);
  if (notify) {
    const known = new Set(prevIncoming);
    for (const r of s.incoming) if (!known.has(r.pid)) emit("toast", { text: `${r.name ?? "Quelqu'un"} veut t'ajouter en ami`, tone: "info" });
  }
  prevIncoming = s.incoming.map((r) => r.pid);
  st().set({ me: s.me, friends: s.friends, incoming: s.incoming, outgoing: s.outgoing });
}

async function hello() {
  st().set({ status: "connecting", error: null });
  const r = await call<StatePayload>("friends:hello", {
    deviceId: myDevice,
    secret: secret(),
    name: nickname(),
    code: loadLocal<string | null>("friends.code", null) ?? friendCode(),
  });
  if (!r.ok) { st().set({ status: "error", error: r.error ?? "Connexion impossible." }); return; }
  applyState(r as StatePayload);
  st().set({ status: "ready" });
  lastSent = 0;
  sendLocation(true);
}

// --- actions ---------------------------------------------------------------------------------
export async function rename(name: string) {
  setNickname(name);
  if (st().status === "ready") await call("friends:rename", { name: name.trim().slice(0, 30) });
}
export async function addFriend(code: string): Promise<string | null> {
  const r = await call<{ accepted: boolean; pending: boolean }>("friends:add", { code: code.replace(/\s/g, "") });
  if (!r.ok) return r.error ?? "Impossible d'envoyer la demande.";
  emit("toast", { text: r.accepted ? "Vous êtes maintenant amis" : "Demande envoyée", tone: "good" });
  return null;
}
export async function respond(pid: string, accept: boolean) {
  const r = await call("friends:respond", { pid, accept });
  if (!r.ok) emit("toast", { text: r.error ?? "Action impossible", tone: "warn" });
  else if (accept) emit("toast", { text: "Ami ajouté", tone: "good" });
}
export async function removeFriend(pid: string) {
  const r = await call("friends:remove", { pid });
  if (!r.ok) emit("toast", { text: r.error ?? "Action impossible", tone: "warn" });
}
/** « Supprimer mes données » : tout est effacé côté serveur, puis côté appareil. */
export async function deleteMyData(): Promise<boolean> {
  if (st().trip) await stopTrip();
  const r = await call("friends:delete", {});
  if (!r.ok) { emit("toast", { text: r.error ?? "Suppression impossible", tone: "warn" }); return false; }
  usePrefs.getState().setPref("shareLocation", false);
  for (const k of ["friends.secret", "friends.code", "friends.showDest"]) {
    try { localStorage.removeItem(`osamaps.${k}`); } catch { /* rien */ }
  }
  secretCache = null;
  st().set({ me: null, friends: [], incoming: [], outgoing: [], trip: null, showDest: false });
  emit("toast", { text: "Tes données d'amis ont été supprimées", tone: "good" });
  void hello(); // nouvel enregistrement, vierge (nouveau secret, nouveau code possible)
  return true;
}
export function setShowDest(v: boolean) {
  saveLocal("friends.showDest", v);
  st().set({ showDest: v });
  lastSent = 0;
  sendLocation(true);
}

// --- position en direct ----------------------------------------------------------------------
let lastSent = 0;
let lastCoord: LngLat | null = null;

/** ETA (horodatage ms) de la conduite en cours, depuis core.progress ou l'itinéraire actif. */
export function myEta(): number | null {
  const { mode, progress, routes, activeRoute } = core();
  if (mode !== "drive") return null;
  const s = progress?.remainingTime ?? routes[activeRoute]?.duration;
  return s == null ? null : Date.now() + s * 1000;
}
function myRemaining(): number | null {
  const { progress, routes, activeRoute } = core();
  return progress?.remainingDistance ?? routes[activeRoute]?.distance ?? null;
}

function sendLocation(force = false) {
  if (followToken || st().status !== "ready" || !usePrefs.getState().shareLocation) return;
  const { position, mode, destination } = core();
  if (!position) return;
  const t = Date.now();
  const moved = lastCoord ? distance(lastCoord, position.coord) : Infinity;
  // au plus toutes les 4 s, et seulement si on a bougé de 15 m (ou toutes les 60 s pour rester visible)
  if (!force && (t - lastSent < 4000 || (moved < 15 && t - lastSent < 60_000))) return;
  lastSent = t;
  lastCoord = position.coord;
  const driving = mode === "drive";
  getSocket().emit("friends:loc", {
    lng: position.coord[0],
    lat: position.coord[1],
    heading: position.heading,
    speed: position.speed,
    drive: driving ? (st().showDest ? { to: destination?.name ?? null, eta: myEta() } : { to: null, eta: null }) : null,
  });
}

// --- partage de trajet -----------------------------------------------------------------------
/** Tracé allégé (≤ 400 points) à partir de l'endroit où l'on est sur l'itinéraire. */
function remainingCoords(): LngLat[] | null {
  const { routes, activeRoute, progress } = core();
  const r = routes[activeRoute];
  if (!r || r.coords.length < 2) return null;
  const rest = r.coords.slice(Math.max(0, (progress?.shapeIndex ?? 0)));
  if (rest.length < 2) return null;
  const step = Math.ceil(rest.length / 400);
  const out = rest.filter((_, i) => i % step === 0);
  if (out[out.length - 1] !== rest[rest.length - 1]) out.push(rest[rest.length - 1]);
  return out.map(([x, y]) => [Math.round(x * 1e5) / 1e5, Math.round(y * 1e5) / 1e5]);
}
function posPayload() {
  const p = core().position;
  return p ? { lng: p.coord[0], lat: p.coord[1], heading: p.heading, speed: p.speed } : undefined;
}

export async function startTrip(): Promise<SharedTrip | null> {
  if (st().trip) return st().trip;
  const { destination, mode } = core();
  const coords = remainingCoords();
  if (mode !== "drive" || !destination || !coords) {
    emit("toast", { text: "Lance d'abord un itinéraire", tone: "warn" });
    return null;
  }
  if (st().status !== "ready") { emit("toast", { text: "Pas de connexion au serveur", tone: "warn" }); return null; }
  const r = await call<{ token: string; expiresAt: number }>("friends:trip:start", {
    dest: { name: destination.name, lng: destination.coord[0], lat: destination.coord[1] },
    coords,
    pos: posPayload(),
    eta: myEta(),
    remaining: myRemaining(),
  });
  if (!r.ok || !r.token) { emit("toast", { text: r.error ?? "Partage impossible", tone: "warn" }); return null; }
  const trip = { token: r.token, url: followUrl(r.token), expiresAt: r.expiresAt ?? 0, watchers: 0 };
  st().set({ trip });
  lastTripSent = Date.now();
  return trip;
}

export async function stopTrip() {
  const trip = st().trip;
  if (!trip) return;
  st().set({ trip: null });
  await call("friends:trip:stop", { token: trip.token });
}

let lastTripSent = 0;
function sendTrip(withCoords = false) {
  const trip = st().trip;
  if (!trip) return;
  const t = Date.now();
  if (!withCoords && t - lastTripSent < 2000) return;
  lastTripSent = t;
  void call<{ watchers: number }>("friends:trip:update", {
    token: trip.token,
    pos: posPayload(),
    eta: myEta(),
    remaining: myRemaining(),
    ...(withCoords ? { coords: remainingCoords() ?? undefined } : {}),
  }).then((r) => {
    const cur = st().trip;
    if (r.ok && cur?.token === trip.token && typeof r.watchers === "number" && r.watchers !== cur.watchers) st().set({ trip: { ...cur, watchers: r.watchers } });
    if (!r.ok && r.error === "Trajet introuvable." && cur?.token === trip.token) st().set({ trip: null });
  });
}

/** Partage natif (téléphone) ou copie dans le presse-papiers. */
export async function shareLink(url: string, title: string, textMsg: string) {
  const nav = navigator as Navigator & { share?: (d: ShareData) => Promise<void> };
  if (nav.share) {
    try { await nav.share({ title, text: textMsg, url }); return; } catch (e) { if ((e as Error).name === "AbortError") return; }
  }
  await copy(url);
}
export async function copy(textToCopy: string) {
  try {
    await navigator.clipboard.writeText(textToCopy);
    emit("toast", { text: "Lien copié", tone: "good" });
  } catch {
    emit("toast", { text: textToCopy, tone: "info" });
  }
}

// --- démarrage -------------------------------------------------------------------------------
export function initFriends(): () => void {
  if (followToken) return () => {}; // la vue « suivre » n'enregistre pas d'appareil
  const s = getSocket();
  const offs: (() => void)[] = [];
  const sub = <T,>(ev: string, fn: (p: T) => void) => { s.on(ev, fn); offs.push(() => s.off(ev, fn)); };

  sub("connect", () => void hello());
  sub("disconnect", () => st().set({ status: "off", friends: st().friends.map((f) => ({ ...f, online: false })) }));
  if (s.connected) void hello();

  sub<StatePayload>("friends:state", (p) => applyState(p, true));
  sub<{ pid: string; online: boolean }>("friends:presence", ({ pid, online }) =>
    st().set({ friends: st().friends.map((f) => (f.pid === pid ? { ...f, online } : f)) }));
  sub<FriendLoc & { pid: string }>("friends:loc", ({ pid, ...loc }) =>
    st().set({ friends: st().friends.map((f) => (f.pid === pid ? { ...f, loc } : f)) }));
  sub<{ pid: string }>("friends:gone", ({ pid }) =>
    st().set({ friends: st().friends.map((f) => (f.pid === pid ? { ...f, loc: null } : f)) }));

  offs.push(on("geo:tick", () => { sendLocation(); sendTrip(); }));
  offs.push(on("drive:start", () => { lastSent = 0; sendLocation(true); }));
  offs.push(on("drive:rerouted", () => sendTrip(true)));
  offs.push(on("drive:arrived", () => {
    const trip = st().trip;
    if (trip) {
      void call("friends:trip:arrived", { token: trip.token });
      emit("toast", { text: trip.watchers ? "Tes proches savent que tu es bien arrivé" : "Bien arrivé", tone: "good" });
      st().set({ trip: null });
    }
  }));
  offs.push(on("drive:stop", ({ arrived }) => {
    if (!arrived && st().trip) void stopTrip();
    lastSent = 0;
    sendLocation(true);
  }));
  // activer / couper le partage
  offs.push(usePrefs.subscribe((p, prev) => {
    if (p.shareLocation === prev.shareLocation) return;
    if (p.shareLocation) { lastSent = 0; sendLocation(true); } else if (st().status === "ready") s.emit("friends:loc:stop");
  }));
  // battement : reste visible même immobile (le serveur oublie une position après 5 min)
  const beat = window.setInterval(() => sendLocation(), 60_000);
  offs.push(() => window.clearInterval(beat));
  // positions périmées côté client aussi
  const expire = window.setInterval(() => {
    const t = Date.now();
    if (st().friends.some((f) => f.loc && t - f.loc.t > 5 * 60_000))
      st().set({ friends: st().friends.map((f) => (f.loc && t - f.loc.t > 5 * 60_000 ? { ...f, loc: null } : f)) });
  }, 30_000);
  offs.push(() => window.clearInterval(expire));

  // lien d'invitation ?ami=CODE : on propose d'envoyer la demande
  if (inviteCode) {
    const url = new URL(location.href);
    url.searchParams.delete("ami");
    history.replaceState(null, "", url);
    const open = () => useCore.getState().openPanel("friends-invite", { code: inviteCode });
    if (useCore.getState().mapReady) open();
    else { const u = useCore.subscribe((c) => { if (c.mapReady) { u(); open(); } }); offs.push(u); }
  }
  return () => offs.forEach((f) => f());
}
