// Signalements de la communauté (police, accident, bouchon, danger, travaux, route fermée, météo).
//
// HTTP (préfixe /maps/api) :
//   POST /reports                 { deviceId, type, sub?, lng, lat, heading?, pseudo? }  → { report, merged }
//   GET  /reports?bbox=w,s,e,n    → { reports: [...] }
//   POST /reports/:id/vote        { deviceId, vote: "still" | "gone" }                 → { report | null, removed }
// Socket.io :
//   client → "reports:watch"  { tiles: ["10/x/y", …] }   rejoint les zones visibles (tuiles z10, 30 max)
//   client → "reports:hello"  { deviceId }                reçoit "reports:thanks" quand on confirme SES signalements
//   serveur → "reports:new" | "reports:update" (report)   "reports:remove" ({ id })   "reports:thanks" ({ id, type, amount })
//
// Vie privée : aucune IP n'est stockée (la limite par IP vit en mémoire, avec une empreinte salée), les
// identifiants d'appareil sont stockés sous forme d'empreinte salée, la position est celle du signalement
// (arrondie à ~1 m), jamais celle d'un utilisateur.
//
// Loi française : pas de « radars ». Les contrôles s'appellent « Police ». Les signalements de police
// peuvent être masqués par zone (arrêté préfectoral, art. L130-11 du code de la route) : liste dans
// data/reports-police-mask.json — vide par défaut — au format
//   [{ "name": "…", "bbox": [w, s, e, n], "until": 1767225600000 }]   (until facultatif, en ms)
import { createHash, randomBytes } from "node:crypto";
import { HttpError } from "../lib/router.js";

/** Catalogue : durée de vie (min), sous-types autorisés. */
export const TYPES = {
  police: { ttl: 60, subs: [] },
  accident: { ttl: 45, subs: [] },
  jam: { ttl: 30, subs: ["moderate", "heavy", "standstill"] },
  hazard: { ttl: 45, subs: ["object", "vehicle", "pothole", "animal", "pedestrian"] },
  works: { ttl: 3 * 24 * 60, subs: [] },
  closure: { ttl: 12 * 60, subs: [] },
  weather: { ttl: 3 * 60, subs: ["ice", "fog", "flood", "snow"] },
};
/** Sous-types plus éphémères. */
const SUB_TTL = { animal: 20, pedestrian: 20, pothole: 7 * 24 * 60 };

const MERGE_DISTANCE = 150; // m
const MERGE_HEADING = 60; // degrés
const GONE_THRESHOLD = 2; // poids cumulé de « plus là » pour retirer
const MAX_LIFETIME_FACTOR = 4; // un signalement vit au plus 4 × sa durée de vie de base
const TILE_Z = 10;
const MAX_TILES = 30;

const now = () => Date.now();
const round = (n, d = 5) => Math.round(n * 10 ** d) / 10 ** d;

/** Tuile slippy z10 d'un point → "10/x/y". */
export function tileOf(lng, lat, z = TILE_Z) {
  const n = 2 ** z;
  const x = Math.floor(((lng + 180) / 360) * n);
  const r = (Math.max(-85, Math.min(85, lat)) * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2) * n);
  return `${z}/${Math.min(n - 1, Math.max(0, x))}/${Math.min(n - 1, Math.max(0, y))}`;
}

function distance(a, b) {
  const R = 6371008.8, rad = Math.PI / 180;
  const dLat = (b[1] - a[1]) * rad, dLng = (b[0] - a[0]) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * rad) * Math.cos(b[1] * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(h));
}
const angleDiff = (a, b) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };

// ——— validation ———
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function vDevice(v) {
  if (typeof v !== "string" || !UUID.test(v)) throw new HttpError(400, "appareil invalide");
  return v.toLowerCase();
}
function vNum(v, min, max, what) {
  if (typeof v !== "number" || !Number.isFinite(v) || v < min || v > max) throw new HttpError(400, `${what} invalide`);
  return v;
}
function vPseudo(v) {
  if (v == null || v === "") return "";
  if (typeof v !== "string") throw new HttpError(400, "pseudo invalide");
  // pas de caractères de contrôle ni de chevrons ; 30 caractères max
  return v.replace(/[\u0000-\u001f\u007f<>]/g, "").replace(/\s+/g, " ").trim().slice(0, 30);
}
function vBbox(s) {
  const p = typeof s === "string" ? s.split(",").map(Number) : [];
  if (p.length !== 4 || p.some((n) => !Number.isFinite(n))) throw new HttpError(400, "bbox invalide (w,s,e,n)");
  const [w, so, e, n] = p;
  if (w < -180 || e > 180 || so < -90 || n > 90 || w >= e || so >= n) throw new HttpError(400, "bbox invalide");
  if (e - w > 4 || n - so > 4) throw new HttpError(400, "zone trop grande");
  return p;
}

/** Petite fenêtre glissante en mémoire : `allow(clé, max, ms)`. */
function limiter() {
  const hits = new Map();
  setInterval(() => { const t = now(); for (const [k, v] of hits) if (!v.length || t - v[v.length - 1] > 3_600_000) hits.delete(k); }, 300_000).unref();
  return (key, max, ms) => {
    const t = now();
    const h = (hits.get(key) || []).filter((x) => t - x < ms);
    if (h.length >= max) { hits.set(key, h); return false; }
    h.push(t); hits.set(key, h);
    return true;
  };
}

export async function register({ io, route, store, log }) {
  const col = await store.collection("reports", { salt: randomBytes(16).toString("hex"), items: [] });
  if (!col.data.salt || !Array.isArray(col.data.items)) col.data = { salt: randomBytes(16).toString("hex"), items: [] };
  const rep = await store.collection("reports-reputation", {});
  const mask = await store.collection("reports-police-mask", []);
  const salt = col.data.salt;
  const hash = (s) => createHash("sha256").update(salt + s).digest("hex").slice(0, 24);
  const allow = limiter();

  /** Poids d'un appareil : 1 → 3 selon ses signalements confirmés (et moins s'il est souvent démenti). */
  const weightOf = (dev) => {
    const r = rep.data[dev];
    if (!r) return 1;
    return Math.max(0.5, Math.min(3, 1 + r.confirmed / 5 - r.denied / 10));
  };
  const bumpRep = (dev, field) => {
    const r = (rep.data[dev] ??= { reports: 0, confirmed: 0, denied: 0 });
    r[field] += 1;
    rep.save();
  };

  const masked = (r) => {
    if (r.type !== "police" || !Array.isArray(mask.data)) return false;
    const t = now();
    return mask.data.some((z) => Array.isArray(z?.bbox) && (!z.until || z.until > t)
      && r.lng >= z.bbox[0] && r.lng <= z.bbox[2] && r.lat >= z.bbox[1] && r.lat <= z.bbox[3]);
  };

  /** Ce qu'on montre au public (jamais d'identifiant d'appareil). */
  const pub = (r) => ({
    id: r.id, type: r.type, sub: r.sub, lng: r.lng, lat: r.lat, heading: r.heading,
    createdAt: r.createdAt, updatedAt: r.updatedAt, expiresAt: r.expiresAt,
    by: r.pseudo, confirmations: r.confirmations, denials: r.denials,
  });

  const items = () => col.data.items;
  const byId = (id) => items().find((r) => r.id === id);
  const broadcast = (event, r) => { if (!masked(r)) io.to(`rpt:${tileOf(r.lng, r.lat)}`).emit(event, event === "reports:remove" ? { id: r.id } : pub(r)); };
  const removeReport = (r, why) => {
    col.data.items = items().filter((x) => x !== r);
    col.save();
    broadcast("reports:remove", r);
    log("signalement retiré", r.id, r.type, why);
  };
  const baseTtl = (r) => (SUB_TTL[r.sub] ?? TYPES[r.type].ttl) * 60_000;
  const extend = (r) => {
    const t = now();
    r.expiresAt = Math.min(r.createdAt + baseTtl(r) * MAX_LIFETIME_FACTOR, Math.max(r.expiresAt, t + baseTtl(r)));
    r.updatedAt = t;
  };

  // ménage des signalements expirés
  setInterval(() => {
    const t = now();
    for (const r of items().filter((x) => x.expiresAt <= t)) removeReport(r, "expiré");
  }, 30_000).unref();

  // ——— POST /reports ———
  route.post("/reports", ({ body, ip }) => {
    if (!body || typeof body !== "object") throw new HttpError(400, "corps invalide");
    const device = hash(vDevice(body.deviceId));
    const type = body.type;
    if (typeof type !== "string" || !Object.hasOwn(TYPES, type)) throw new HttpError(400, "type invalide");
    let sub = body.sub ?? null;
    if (sub !== null && (typeof sub !== "string" || !TYPES[type].subs.includes(sub))) throw new HttpError(400, "sous-type invalide");
    const lng = round(vNum(body.lng, -180, 180, "longitude"));
    const lat = round(vNum(body.lat, -85, 85, "latitude"));
    const heading = body.heading == null ? null : Math.round(vNum(body.heading, 0, 360, "cap")) % 360;
    const pseudo = vPseudo(body.pseudo);

    // limites : 8 signalements / 10 min par appareil, 20 / 10 min par adresse (empreinte en mémoire seulement)
    if (!allow(`d:${device}`, 8, 600_000)) throw new HttpError(429, "doucement : trop de signalements");
    if (!allow(`i:${hash(ip)}`, 20, 600_000)) throw new HttpError(429, "trop de signalements depuis ce réseau");

    // doublon proche (même type, < 150 m, même sens) → on le confirme au lieu d'en créer un autre
    const t = now();
    const dup = items().find((r) => r.type === type && r.expiresAt > t
      && distance([r.lng, r.lat], [lng, lat]) < MERGE_DISTANCE
      && (r.heading == null || heading == null || angleDiff(r.heading, heading) < MERGE_HEADING));
    if (dup) {
      if (dup.device !== device && !dup.voters[device]) {
        dup.voters[device] = "still";
        dup.confirmations += 1;
        dup.gone = Math.max(0, dup.gone - weightOf(device));
        if (sub && !dup.sub) dup.sub = sub;
        // un bouchon qui empire : on garde le niveau le plus récent
        if (sub && type === "jam") dup.sub = sub;
        extend(dup);
        bumpRep(dup.device, "confirmed");
        io.to(`rdev:${dup.device}`).emit("reports:thanks", { id: dup.id, type: dup.type, amount: 2 });
        col.save();
        broadcast("reports:update", dup);
      }
      return { report: pub(dup), merged: true };
    }

    const r = {
      id: randomBytes(6).toString("base64url"),
      type, sub, lng, lat, heading, pseudo, device,
      createdAt: t, updatedAt: t, expiresAt: 0,
      confirmations: 0, denials: 0, gone: 0,
      weight: weightOf(device),
      voters: {},
    };
    r.expiresAt = t + baseTtl(r);
    items().push(r);
    if (items().length > 20_000) items().splice(0, items().length - 20_000); // garde-fou
    bumpRep(device, "reports");
    col.save();
    broadcast("reports:new", r);
    log("signalement", r.id, type, sub ?? "");
    return { report: pub(r), merged: false };
  }, { limit: 20 });

  // ——— GET /reports?bbox= ———
  route.get("/reports", ({ query }) => {
    const [w, s, e, n] = vBbox(query.bbox);
    const t = now();
    const out = items()
      .filter((r) => r.expiresAt > t && r.lng >= w && r.lng <= e && r.lat >= s && r.lat <= n && !masked(r))
      .slice(-500)
      .map(pub);
    return { reports: out, serverTime: t };
  }, { limit: 120 });

  // ——— POST /reports/:id/vote ———
  route.post("/reports/:id/vote", ({ body, params, ip }) => {
    if (!body || typeof body !== "object") throw new HttpError(400, "corps invalide");
    if (!/^[A-Za-z0-9_-]{6,16}$/.test(params.id)) throw new HttpError(400, "id invalide");
    const device = hash(vDevice(body.deviceId));
    const vote = body.vote;
    if (vote !== "still" && vote !== "gone") throw new HttpError(400, "vote invalide");
    if (!allow(`v:${device}`, 40, 600_000)) throw new HttpError(429, "trop de votes");
    if (!allow(`vi:${hash(ip)}`, 120, 600_000)) throw new HttpError(429, "trop de votes depuis ce réseau");
    const r = byId(params.id);
    if (!r || r.expiresAt <= now()) throw new HttpError(404, "ce signalement n'existe plus");

    // l'auteur qui dit « plus là » retire son propre signalement
    if (r.device === device) {
      if (vote === "gone") { removeReport(r, "retiré par l'auteur"); return { report: null, removed: true }; }
      extend(r); col.save(); broadcast("reports:update", r);
      return { report: pub(r), removed: false };
    }
    if (r.voters[device]) return { report: pub(r), removed: false, already: true };
    r.voters[device] = vote;
    const w = weightOf(device);
    if (vote === "still") {
      r.confirmations += 1;
      r.gone = Math.max(0, r.gone - w);
      extend(r);
      bumpRep(r.device, "confirmed");
      io.to(`rdev:${r.device}`).emit("reports:thanks", { id: r.id, type: r.type, amount: 2 });
    } else {
      r.denials += 1;
      r.gone += w;
      r.updatedAt = now();
      if (r.gone >= GONE_THRESHOLD) {
        if (r.confirmations === 0) bumpRep(r.device, "denied");
        removeReport(r, "plus là");
        return { report: null, removed: true };
      }
    }
    col.save();
    broadcast("reports:update", r);
    return { report: pub(r), removed: false };
  }, { limit: 60 });

  // ——— temps réel : zones ———
  const TILE_RE = /^10\/\d{1,4}\/\d{1,4}$/;
  io.on("connection", (socket) => {
    socket.on("reports:watch", (msg) => {
      const tiles = Array.isArray(msg?.tiles) ? msg.tiles.filter((t) => typeof t === "string" && TILE_RE.test(t)).slice(0, MAX_TILES) : [];
      const want = new Set(tiles.map((t) => `rpt:${t}`));
      for (const room of socket.rooms) if (room.startsWith("rpt:") && !want.has(room)) socket.leave(room);
      for (const room of want) socket.join(room);
    });
    socket.on("reports:hello", (msg) => {
      if (typeof msg?.deviceId !== "string" || !UUID.test(msg.deviceId)) return;
      for (const room of socket.rooms) if (room.startsWith("rdev:")) socket.leave(room);
      socket.join(`rdev:${hash(msg.deviceId.toLowerCase())}`);
    });
  });
}
