// Classement hebdomadaire de la mascotte (opt-in côté client).
// On ne garde que : empreinte sha-256 de l'identifiant d'appareil (jamais renvoyée), pseudo, points
// de la semaine en cours. Les semaines passées sont effacées. Aucune IP, aucune position.
//   POST /mascot/score { id, name, points, week } → { week, top: [{ name, points, me? }], rank, total }
//   POST /mascot/leave { id }                     → { ok: true }
//   GET  /mascot/leaderboard                      → { week, top, total }
// Apparence de la mascotte (éditeur « Ma mascotte »), pour que les amis la voient :
//   POST /mascot/look { id, code, look }   → { ok: true }   (le code ami appartient au premier appareil qui l'envoie)
//   GET  /mascot/looks?codes=123456,654321 → { looks: { "123456": { body, hat, glasses, face, neck, ride, name } } }
// On garde : code ami (6 chiffres, déjà connu des amis), empreinte de l'identifiant, apparence. Rien d'autre.
import { createHash } from "node:crypto";
import { HttpError } from "../lib/router.js";

const MAX_WEEK_POINTS = 50_000;
const TOP = 20;

export function weekKey(d = new Date()) {
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  const n = Math.ceil(((t - y0) / 86400000 + 1) / 7);
  return `${t.getUTCFullYear()}-W${String(n).padStart(2, "0")}`;
}

const hash = (id) => createHash("sha256").update(`osamaps-mascot:${id}`).digest("hex").slice(0, 32);

function cleanName(v) {
  if (typeof v !== "string") return "";
  // pas de caractères de contrôle, espaces resserrés, 20 caractères
  return v.replace(/[\u0000-\u001f\u007f<>]/g, "").replace(/\s+/g, " ").trim().slice(0, 20);
}

function checkId(id) {
  if (typeof id !== "string" || id.length < 8 || id.length > 64 || !/^[\w-]+$/.test(id)) throw new HttpError(400, "identifiant invalide");
  return hash(id);
}

/** Valeurs permises (mêmes listes que ios/…/MascotLook.swift et web/…/look.ts). */
export const LOOK = {
  body: ["creme", "nuage", "peche", "bonbon", "citron", "menthe", "ciel", "lavande"],
  hat: ["none", "casquette", "bonnet", "beret", "chapeau", "chantier", "couronne"],
  glasses: ["none", "soleil", "rondes", "aviateur", "carrees"],
  face: ["doux", "rieur", "malin", "timide", "cool"],
  neck: ["none", "noeud", "echarpe", "bandana", "cravate", "medaille"],
  ride: ["nuit", "glacier", "rouge", "orange", "soleil", "sapin", "ocean", "prune"],
};

export function cleanLook(v) {
  if (!v || typeof v !== "object") throw new HttpError(400, "apparence invalide");
  const out = {};
  for (const [k, allowed] of Object.entries(LOOK)) out[k] = allowed.includes(v[k]) ? v[k] : allowed[0];
  out.name = cleanName(v.name).slice(0, 16);
  return out;
}

const CODE = /^\d{6}$/;
const MAX_LOOKS = 50_000;

export async function register({ route, store, log }) {
  const col = await store.collection("mascot-weekly", { week: weekKey(), entries: {} });

  const current = () => {
    const wk = weekKey();
    if (col.data.week !== wk) { col.data = { week: wk, entries: {} }; log("mascot : nouvelle semaine", wk); }
    return col.data;
  };

  const ranking = (me) => {
    const d = current();
    const rows = Object.entries(d.entries)
      .map(([h, e]) => ({ h, name: e.name || "Conducteur anonyme", points: e.points }))
      .sort((a, b) => b.points - a.points);
    const rank = me ? rows.findIndex((r) => r.h === me) + 1 || null : null;
    return {
      week: d.week,
      top: rows.slice(0, TOP).map((r) => (me && r.h === me ? { name: r.name, points: r.points, me: true } : { name: r.name, points: r.points })),
      rank,
      total: rows.length,
    };
  };

  route.post("/mascot/score", ({ body }) => {
    if (!body || typeof body !== "object") throw new HttpError(400, "corps manquant");
    const h = checkId(body.id);
    const points = Number(body.points);
    if (!Number.isFinite(points) || points < 0) throw new HttpError(400, "points invalides");
    const d = current();
    if (body.week !== d.week) return ranking(h);              // horloge décalée : on ne compte pas
    const prev = d.entries[h];
    d.entries[h] = {
      name: cleanName(body.name),
      // les points d'une semaine ne font que monter (pas de remise à zéro par un client)
      points: Math.max(prev?.points ?? 0, Math.min(MAX_WEEK_POINTS, Math.round(points))),
      t: Date.now(),
    };
    col.save();
    return ranking(h);
  }, { limit: 12 });

  route.post("/mascot/leave", ({ body }) => {
    const h = checkId(body?.id);
    const d = current();
    if (d.entries[h]) { delete d.entries[h]; col.save(); }
    return { ok: true };
  }, { limit: 12 });

  route.get("/mascot/leaderboard", () => {
    const { week, top, total } = ranking(null);
    return { week, top, total };
  }, { limit: 30 });

  // --- apparence ---
  const looks = await store.collection("mascot-looks", {});

  route.post("/mascot/look", ({ body }) => {
    if (!body || typeof body !== "object") throw new HttpError(400, "corps manquant");
    const h = checkId(body.id);
    const code = String(body.code ?? "");
    if (!CODE.test(code)) throw new HttpError(400, "code invalide");
    const prev = looks.data[code];
    if (prev && prev.h !== h) throw new HttpError(403, "code déjà utilisé");
    if (!prev && Object.keys(looks.data).length >= MAX_LOOKS) throw new HttpError(503, "plus de place");
    looks.data[code] = { h, look: cleanLook(body.look), t: Date.now() };
    looks.save();
    return { ok: true };
  }, { limit: 20 });

  route.get("/mascot/looks", ({ query }) => {
    const codes = String(query?.codes ?? "").split(",").map((c) => c.trim()).filter((c) => CODE.test(c)).slice(0, 50);
    const out = {};
    for (const c of codes) { const e = looks.data[c]; if (e) out[c] = e.look; }
    return { looks: out };
  }, { limit: 60 });
}
