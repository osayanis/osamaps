// Amis & partage : identité d'appareil, demandes d'amis, position en direct (mémoire seulement),
// partage de trajet par lien temporaire (?suivre=JETON), « bien arrivé ».
//
// Vie privée :
//  - on ne garde sur disque que : empreinte du secret, identifiant public, code ami, pseudo, liste
//    d'amis et demandes. Jamais de position, jamais d'IP (l'IP ne sert qu'à une limite de débit
//    en mémoire, oubliée après une heure).
//  - les positions et les trajets partagés vivent en mémoire et expirent tout seuls.
//  - les deviceId ne sortent jamais du serveur : les amis se voient par un identifiant public (pid).
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import { HttpError } from "../lib/router.js";

const LOC_TTL = 5 * 60_000;            // une position sans mise à jour depuis 5 min disparaît
const TRIP_AFTER_ARRIVAL = 30 * 60_000; // lien valable 30 min après l'arrivée
const TRIP_IDLE = 20 * 60_000;          // trajet sans nouvelle depuis 20 min : terminé
const TRIP_MAX = 12 * 3600_000;         // aucun lien ne vit plus de 12 h
const DEVICE_TTL = 365 * 86400_000;     // appareil inactif depuis un an : oublié
const MAX_FRIENDS = 200;
const MAX_INCOMING = 50;
const MAX_ROUTE_POINTS = 1000;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SECRET = /^[A-Za-z0-9_-]{32,128}$/;
const CODE = /^\d{6}$/;

const sha = (s) => createHash("sha256").update(s).digest();
const now = () => Date.now();

/** Nettoie un texte libre : string, sans caractères de contrôle, longueur bornée. */
function text(v, max) {
  if (typeof v !== "string") return null;
  // eslint-disable-next-line no-control-regex
  const s = v.replace(/[\u0000-\u001f\u007f<>]/g, "").replace(/\s+/g, " ").trim().slice(0, max);
  return s || null;
}
const num = (v, min, max) => (typeof v === "number" && Number.isFinite(v) && v >= min && v <= max ? v : null);
const round = (v, d = 5) => Math.round(v * 10 ** d) / 10 ** d;

function point(p) {
  if (!p || typeof p !== "object") return null;
  const lng = num(p.lng, -180, 180), lat = num(p.lat, -90, 90);
  return lng == null || lat == null ? null : { lng: round(lng), lat: round(lat) };
}

/** Limiteur « n évènements par fenêtre » par clé (mémoire seulement). */
function limiter(max, windowMs) {
  const hits = new Map();
  const fn = (key) => {
    const t = now();
    const h = (hits.get(key) || []).filter((x) => t - x < windowMs);
    if (h.length >= max) { hits.set(key, h); return false; }
    h.push(t); hits.set(key, h);
    return true;
  };
  fn.prune = () => { const t = now(); for (const [k, v] of hits) if (!v.some((x) => t - x < windowMs)) hits.delete(k); };
  fn.forget = (key) => hits.delete(key);
  return fn;
}

export async function register({ io, route, store, log }) {
  const db = await store.collection("friends", { devices: {} });
  /** @type {Record<string, {pid:string, secret:string, code:string, name:string, created:number, seen:number, friends:string[], incoming:string[]}>} */
  const devices = db.data.devices;

  const byCode = new Map();
  const byPid = new Map();
  for (const [id, d] of Object.entries(devices)) { byCode.set(d.code, id); byPid.set(d.pid, id); }

  /** Positions en direct : deviceId → { lng, lat, heading, speed, drive, t }. Jamais écrit sur disque. */
  const live = new Map();
  /** Trajets partagés : jeton → { owner, name, dest, coords, pos, eta, remaining, started, updated, arrivedAt, ended } */
  const trips = new Map();
  /** Sockets connectés par appareil (statut « en ligne »). */
  const online = new Map();

  const limits = {
    hello: limiter(10, 60_000),
    newDevice: limiter(20, 3600_000), // par IP, mémoire seulement
    add: limiter(10, 60_000),        // par appareil : évite de deviner les codes
    addIp: limiter(30, 60_000),      // par IP, mémoire seulement
    helloIp: limiter(60, 60_000),
    action: limiter(60, 60_000),
    loc: limiter(40, 60_000),
    trip: limiter(10, 3600_000),
    tripUpdate: limiter(90, 60_000),
    watch: limiter(30, 60_000),
  };

  const room = (id) => `friends:dev:${id}`;
  const tripRoom = (token) => `friends:trip:${token}`;
  const isOnline = (id) => (online.get(id)?.size ?? 0) > 0;

  function newCode() {
    for (let i = 0; i < 50; i++) {
      const c = String(100000 + Math.floor(Math.random() * 900000));
      if (!byCode.has(c)) return c;
    }
    throw new Error("plus de code libre");
  }

  /** Ce qu'un ami voit de moi. */
  function publicOf(id, viewerId) {
    const d = devices[id];
    const l = live.get(id);
    const fresh = l && now() - l.t < LOC_TTL;
    return {
      pid: d.pid,
      name: d.name || "Sans pseudo",
      code: d.code,
      online: isOnline(id),
      loc: fresh && devices[viewerId]?.friends.includes(id) ? locOut(l) : null,
    };
  }
  const locOut = (l) => ({ lng: l.lng, lat: l.lat, heading: l.heading, speed: l.speed, drive: l.drive, t: l.t });

  /** L'état complet de mes amis (envoyé après chaque changement). */
  function stateOf(id) {
    const d = devices[id];
    const outgoing = Object.entries(devices)
      .filter(([, o]) => o.incoming.includes(id))
      .map(([, o]) => ({ pid: o.pid, code: o.code }));
    return {
      me: { pid: d.pid, code: d.code, name: d.name },
      friends: d.friends.filter((f) => devices[f]).map((f) => publicOf(f, id)),
      incoming: d.incoming.filter((f) => devices[f]).map((f) => ({ pid: devices[f].pid, name: devices[f].name || "Sans pseudo", code: devices[f].code })),
      outgoing,
    };
  }
  const pushState = (id) => { if (devices[id]) io.to(room(id)).emit("friends:state", stateOf(id)); };

  function auth(deviceId, secret) {
    const d = devices[deviceId];
    if (!d) return false;
    const a = Buffer.from(d.secret, "hex"), b = sha(secret);
    return a.length === b.length && timingSafeEqual(a, b);
  }

  function unfriend(a, b) {
    if (devices[a]) devices[a].friends = devices[a].friends.filter((x) => x !== b);
    if (devices[b]) devices[b].friends = devices[b].friends.filter((x) => x !== a);
  }

  function deleteDevice(id) {
    const d = devices[id];
    if (!d) return [];
    const touched = new Set(d.friends);
    for (const [oid, o] of Object.entries(devices)) {
      if (o.incoming.includes(id)) { o.incoming = o.incoming.filter((x) => x !== id); touched.add(oid); }
      if (o.friends.includes(id)) { o.friends = o.friends.filter((x) => x !== id); touched.add(oid); }
    }
    for (const [token, t] of trips) if (t.owner === id) endTrip(token, "ended");
    live.delete(id);
    byCode.delete(d.code);
    byPid.delete(d.pid);
    delete devices[id];
    db.save();
    return [...touched];
  }

  function endTrip(token, why) {
    const t = trips.get(token);
    if (!t) return;
    trips.delete(token);
    io.to(tripRoom(token)).emit("friends:trip:ended", { token, why });
    io.in(tripRoom(token)).socketsLeave(tripRoom(token));
  }

  function tripOut(token, t) {
    const owner = devices[t.owner];
    return {
      token,
      name: owner?.name || "Ton ami",
      dest: t.dest,
      coords: t.coords,
      pos: t.pos,
      eta: t.eta,
      remaining: t.remaining,
      arrivedAt: t.arrivedAt,
      expiresAt: tripExpiry(t),
      updated: t.updated,
    };
  }
  const tripExpiry = (t) => Math.min(t.started + TRIP_MAX, t.arrivedAt ? t.arrivedAt + TRIP_AFTER_ARRIVAL : t.updated + TRIP_IDLE);

  // ménage : positions périmées, trajets expirés, appareils oubliés, tables de débit
  const sweep = setInterval(() => {
    const t = now();
    for (const [id, l] of live) {
      if (t - l.t < LOC_TTL) continue;
      live.delete(id);
      const d = devices[id];
      if (d) for (const f of d.friends) io.to(room(f)).emit("friends:gone", { pid: d.pid });
    }
    for (const [token, trip] of trips) if (t > tripExpiry(trip)) endTrip(token, "expired");
    let changed = false;
    for (const [id, d] of Object.entries(devices)) if (t - d.seen > DEVICE_TTL && !isOnline(id)) { deleteDevice(id); changed = true; }
    if (changed) db.save();
    for (const l of Object.values(limits)) l.prune();
  }, 30_000);
  sweep.unref();

  io.on("connection", (socket) => {
    const ip = (socket.handshake.headers["x-forwarded-for"] || socket.handshake.address || "").toString().split(",")[0].trim();
    /** deviceId une fois authentifié. */
    let me = null;
    const key = (k) => `${k}|${socket.id}`;
    const ack = (cb, v) => { if (typeof cb === "function") cb(v); };
    const fail = (cb, error) => ack(cb, { ok: false, error });
    const authed = (cb) => {
      if (!me || !devices[me]) { fail(cb, "non identifié"); return false; }
      return true;
    };

    // --- identité ---------------------------------------------------------------------------
    socket.on("friends:hello", (p, cb) => {
      if (!limits.hello(key("hello")) || !limits.helloIp(`ip|${ip}`)) return fail(cb, "trop de requêtes");
      if (!p || typeof p !== "object" || !UUID.test(String(p.deviceId)) || !SECRET.test(String(p.secret))) return fail(cb, "identité invalide");
      const id = p.deviceId.toLowerCase();
      const name = text(p.name, 30) ?? "";
      if (devices[id]) {
        if (!auth(id, p.secret)) return fail(cb, "secret invalide");
        if (p.name !== undefined && devices[id].name !== name) devices[id].name = name;
      } else {
        if (!limits.newDevice(`new|${ip}`)) return fail(cb, "trop de nouveaux appareils");
        const wanted = CODE.test(String(p.code)) ? p.code : null;
        const code = wanted && !byCode.has(wanted) ? wanted : newCode();
        const pid = randomUUID();
        devices[id] = { pid, secret: sha(p.secret).toString("hex"), code, name, created: now(), seen: now(), friends: [], incoming: [] };
        byCode.set(code, id);
        byPid.set(pid, id);
      }
      if (me && me !== id) { online.get(me)?.delete(socket.id); socket.leave(room(me)); }
      me = id;
      devices[id].seen = now();
      db.save();
      socket.join(room(id));
      const wasOnline = isOnline(id);
      if (!online.has(id)) online.set(id, new Set());
      online.get(id).add(socket.id);
      if (!wasOnline) for (const f of devices[id].friends) pushPresence(f, id);
      ack(cb, { ok: true, ...stateOf(id) });
    });

    function pushPresence(to, id) {
      io.to(room(to)).emit("friends:presence", { pid: devices[id].pid, online: isOnline(id) });
    }

    socket.on("friends:rename", (p, cb) => {
      if (!authed(cb) || !limits.action(key("action"))) return fail(cb, "refusé");
      const name = text(p?.name, 30) ?? "";
      devices[me].name = name;
      db.save();
      pushState(me);
      for (const f of devices[me].friends) pushState(f);
      for (const f of Object.keys(devices)) if (devices[f].incoming.includes(me)) pushState(f);
      ack(cb, { ok: true });
    });

    // --- demandes d'amis ----------------------------------------------------------------------
    socket.on("friends:add", (p, cb) => {
      if (!authed(cb)) return;
      if (!limits.add(`dev|${me}`) || !limits.addIp(`ip|${ip}`)) return fail(cb, "Trop d'essais, réessaie dans une minute.");
      const code = String(p?.code ?? "").replace(/\s/g, "");
      if (!CODE.test(code)) return fail(cb, "Le code fait 6 chiffres.");
      const other = byCode.get(code);
      if (!other) return fail(cb, "Aucun appareil avec ce code.");
      if (other === me) return fail(cb, "C'est ton propre code.");
      const a = devices[me], b = devices[other];
      if (a.friends.includes(other)) return fail(cb, "Vous êtes déjà amis.");
      if (a.friends.length >= MAX_FRIENDS) return fail(cb, "Tu as atteint la limite d'amis.");
      if (a.incoming.includes(other)) {
        // il m'avait déjà demandé : on accepte directement
        a.incoming = a.incoming.filter((x) => x !== other);
        a.friends.push(other); b.friends.push(me);
        db.save(); pushState(me); pushState(other);
        return ack(cb, { ok: true, accepted: true });
      }
      if (b.incoming.includes(me)) return ack(cb, { ok: true, pending: true });
      if (b.incoming.length >= MAX_INCOMING) return fail(cb, "Cette personne a trop de demandes en attente.");
      b.incoming.push(me);
      db.save(); pushState(me); pushState(other);
      ack(cb, { ok: true, pending: true });
    });

    socket.on("friends:respond", (p, cb) => {
      if (!authed(cb) || !limits.action(key("action"))) return fail(cb, "refusé");
      const other = byPid.get(String(p?.pid));
      const d = devices[me];
      if (!other || !d.incoming.includes(other)) return fail(cb, "Demande introuvable.");
      d.incoming = d.incoming.filter((x) => x !== other);
      if (p.accept === true) {
        if (d.friends.length >= MAX_FRIENDS) return fail(cb, "Tu as atteint la limite d'amis.");
        if (!d.friends.includes(other)) d.friends.push(other);
        if (!devices[other].friends.includes(me)) devices[other].friends.push(me);
      }
      db.save(); pushState(me); pushState(other);
      ack(cb, { ok: true });
    });

    /** Retirer un ami OU annuler une demande envoyée. */
    socket.on("friends:remove", (p, cb) => {
      if (!authed(cb) || !limits.action(key("action"))) return fail(cb, "refusé");
      const other = byPid.get(String(p?.pid));
      if (!other) return fail(cb, "Introuvable.");
      unfriend(me, other);
      devices[other].incoming = devices[other].incoming.filter((x) => x !== me);
      db.save(); pushState(me); pushState(other);
      io.to(room(other)).emit("friends:gone", { pid: devices[me].pid });
      io.to(room(me)).emit("friends:gone", { pid: devices[other].pid });
      ack(cb, { ok: true });
    });

    /** « Supprimer mes données » : tout disparaît (appareil, amitiés, demandes, position, trajets). */
    socket.on("friends:delete", (p, cb) => {
      if (!authed(cb)) return;
      const pid = devices[me].pid;
      const touched = deleteDevice(me);
      for (const f of touched) { pushState(f); io.to(room(f)).emit("friends:gone", { pid }); }
      online.get(me)?.delete(socket.id);
      socket.leave(room(me));
      me = null;
      ack(cb, { ok: true });
    });

    // --- position en direct -----------------------------------------------------------------
    socket.on("friends:loc", (p) => {
      if (!me || !devices[me] || !limits.loc(key("loc"))) return;
      const pt = point(p);
      if (!pt) return;
      let drive = null;
      if (p.drive && typeof p.drive === "object") {
        const eta = num(p.drive.eta, now() - 3600_000, now() + 48 * 3600_000);
        drive = { to: text(p.drive.to, 80), eta: eta == null ? null : Math.round(eta) };
      }
      const l = {
        ...pt,
        heading: num(p.heading, 0, 360) == null ? null : Math.round(p.heading),
        speed: num(p.speed, 0, 120) == null ? null : Math.round(p.speed * 10) / 10,
        drive,
        t: now(),
      };
      live.set(me, l);
      const out = { pid: devices[me].pid, ...locOut(l) };
      for (const f of devices[me].friends) io.to(room(f)).emit("friends:loc", out);
    });

    socket.on("friends:loc:stop", () => {
      if (!me || !devices[me]) return;
      live.delete(me);
      for (const f of devices[me].friends) io.to(room(f)).emit("friends:gone", { pid: devices[me].pid });
    });

    // --- partage de trajet ------------------------------------------------------------------
    function routeIn(coords) {
      if (!Array.isArray(coords) || coords.length < 2 || coords.length > MAX_ROUTE_POINTS) return null;
      const out = [];
      for (const c of coords) {
        if (!Array.isArray(c) || c.length !== 2) return null;
        const pt = point({ lng: c[0], lat: c[1] });
        if (!pt) return null;
        out.push([pt.lng, pt.lat]);
      }
      return out;
    }
    function tripFields(p, t) {
      const pos = point(p.pos);
      if (pos) t.pos = { ...pos, heading: num(p.pos.heading, 0, 360), speed: num(p.pos.speed, 0, 120) };
      const eta = num(p.eta, now() - 3600_000, now() + 48 * 3600_000);
      if (eta != null) t.eta = Math.round(eta);
      const rem = num(p.remaining, 0, 5_000_000);
      if (rem != null) t.remaining = Math.round(rem);
      if (p.coords !== undefined) { const c = routeIn(p.coords); if (c) t.coords = c; }
      t.updated = now();
    }
    const ownTrip = (token) => {
      const t = trips.get(String(token));
      return t && t.owner === me ? t : null;
    };

    socket.on("friends:trip:start", (p, cb) => {
      if (!authed(cb)) return;
      if (!limits.trip(key("trip")) || !limits.trip(`dev|${me}`)) return fail(cb, "Trop de partages, réessaie plus tard.");
      const dest = point(p?.dest);
      const coords = routeIn(p?.coords);
      if (!dest || !coords) return fail(cb, "Trajet invalide.");
      // un seul trajet partagé à la fois par appareil
      for (const [tok, t] of trips) if (t.owner === me) endTrip(tok, "replaced");
      const token = randomUUID();
      const t = { owner: me, dest: { ...dest, name: text(p.dest.name, 80) ?? "sa destination" }, coords, pos: null, eta: null, remaining: null, started: now(), updated: now(), arrivedAt: null };
      tripFields(p, t);
      trips.set(token, t);
      ack(cb, { ok: true, token, expiresAt: tripExpiry(t) });
    });

    socket.on("friends:trip:update", (p, cb) => {
      if (!me || !limits.tripUpdate(key("tripUpdate"))) return fail(cb, "refusé");
      const t = ownTrip(p?.token);
      if (!t) return fail(cb, "Trajet introuvable.");
      if (t.arrivedAt) return ack(cb, { ok: true });
      tripFields(p, t);
      const out = tripOut(p.token, t);
      if (p.coords === undefined) delete out.coords; // inutile de renvoyer le tracé à chaque fois
      io.to(tripRoom(p.token)).emit("friends:trip:update", out);
      ack(cb, { ok: true, watchers: io.sockets.adapter.rooms.get(tripRoom(p.token))?.size ?? 0 });
    });

    socket.on("friends:trip:arrived", (p, cb) => {
      if (!me) return fail(cb, "refusé");
      const t = ownTrip(p?.token);
      if (!t) return fail(cb, "Trajet introuvable.");
      if (!t.arrivedAt) {
        t.arrivedAt = now();
        if (t.dest) t.pos = { ...t.pos, lng: t.dest.lng, lat: t.dest.lat };
        t.remaining = 0;
        io.to(tripRoom(p.token)).emit("friends:trip:arrived", tripOut(p.token, t));
      }
      ack(cb, { ok: true });
    });

    socket.on("friends:trip:stop", (p, cb) => {
      if (!me) return fail(cb, "refusé");
      if (!ownTrip(p?.token)) return fail(cb, "Trajet introuvable.");
      endTrip(String(p.token), "stopped");
      ack(cb, { ok: true });
    });

    /** Suivre un trajet : il suffit du jeton (aucune identité demandée). */
    socket.on("friends:trip:watch", (p, cb) => {
      if (!limits.watch(key("watch"))) return fail(cb, "trop de requêtes");
      const token = String(p?.token ?? "");
      const t = UUID.test(token) ? trips.get(token) : null;
      if (!t) return fail(cb, "Ce lien de suivi a expiré ou n'existe pas.");
      socket.join(tripRoom(token));
      ack(cb, { ok: true, trip: tripOut(token, t) });
    });

    socket.on("friends:trip:unwatch", (p) => { socket.leave(tripRoom(String(p?.token ?? ""))); });

    socket.on("disconnect", () => {
      for (const [k, l] of Object.entries(limits)) l.forget(key(k));
      if (!me) return;
      const set = online.get(me);
      set?.delete(socket.id);
      if (set && set.size === 0) {
        online.delete(me);
        if (devices[me]) { devices[me].seen = now(); for (const f of devices[me].friends) pushPresence(f, me); }
      }
    });
  });

  // instantané d'un trajet partagé (pratique hors socket, et pour l'aperçu du lien)
  route.get("/friends/trip/:token", ({ params }) => {
    const t = UUID.test(params.token) ? trips.get(params.token) : null;
    if (!t) throw new HttpError(404, "Ce lien de suivi a expiré ou n'existe pas.");
    return tripOut(params.token, t);
  }, { limit: 30 });

  log(`amis : ${Object.keys(devices).length} appareil(s) connu(s)`);
}
