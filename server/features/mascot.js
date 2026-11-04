// Classement hebdomadaire de la mascotte (opt-in côté client).
// On ne garde que : empreinte sha-256 de l'identifiant d'appareil (jamais renvoyée), pseudo, points
// de la semaine en cours. Les semaines passées sont effacées. Aucune IP, aucune position.
//   POST /mascot/score { id, name, points, week } → { week, top: [{ name, points, me? }], rank, total }
//   POST /mascot/leave { id }                     → { ok: true }
//   GET  /mascot/leaderboard                      → { week, top, total }
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
}
