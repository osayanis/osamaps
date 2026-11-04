import { create } from "zustand";
import { core, useCore, type LngLat, type Route } from "../../core/store";
import { emit, on } from "../../core/bus";
import { cumulativeDistances, formatDistance } from "../../core/geometry";
import { fetchPoiTiles, fetchZfe, fetchZones, tileKey } from "./data";
import {
  buildSegIndex, dangerIntervals, findCurves, poisAlong, snapWindow, zfeCrossings,
  type Curve, type DangerInterval, type RoutePoi, type SegIndex, type ZfeCrossing,
} from "./analysis";
import { critairForbidden, safetySettings, CRITAIR_LABEL } from "./settings";

/**
 * Le « moteur » sécurité : analyse l'itinéraire actif (zones de danger, ZFE, virages, passages à
 * niveau, écoles), puis à chaque position en conduite émet des `drive:alert` (une seule fois par
 * élément) et tient à jour l'état affiché par le HUD.
 */
interface SafetyState {
  routeId: string | null;
  coords: LngLat[];
  cum: number[];
  dangers: DangerInterval[];
  curves: Curve[];
  pois: RoutePoi[];
  zfe: ZfeCrossing[];
  /** Zone de danger dans laquelle on roule (null sinon). */
  inside: DangerInterval | null;
  along: number;
  zonesError: string | null;
  zfeError: string | null;
}

export const useSafety = create<SafetyState>(() => ({
  routeId: null, coords: [], cum: [], dangers: [], curves: [], pois: [], zfe: [], inside: null, along: 0,
  zonesError: null, zfeError: null,
}));
const S = () => useSafety.getState();

let ix: SegIndex | null = null;
let hint = 0;
const alerted = new Set<string>();

function alert(id: string, kind: string, text: string, distance: number, tone: "info" | "warn" | "danger") {
  if (alerted.has(id)) return;
  alerted.add(id);
  emit("drive:alert", { id, kind, text, distance: Math.max(0, Math.round(distance)), tone });
}

// ------------------------------------------------------------------ analyse de l'itinéraire

function routeBBox(coords: LngLat[], pad = 0.03): [number, number, number, number] {
  let w = 180, s = 90, e = -180, n = -90;
  for (const [x, y] of coords) { w = Math.min(w, x); e = Math.max(e, x); s = Math.min(s, y); n = Math.max(n, y); }
  return [w - pad, s - pad, e + pad, n + pad];
}

/** Découpe une grande boîte en morceaux acceptés par le serveur (≤ 14°). */
function splitBBox([w, s, e, n]: [number, number, number, number]) {
  const out: [number, number, number, number][] = [];
  for (let x = w; x < e; x += 12) for (let y = s; y < n; y += 12) out.push([x, y, Math.min(e, x + 12), Math.min(n, y + 12)]);
  return out;
}

async function analyze(route: Route | undefined) {
  if (!route || route.coords.length < 2) {
    ix = null;
    useSafety.setState({ routeId: null, coords: [], cum: [], dangers: [], curves: [], pois: [], zfe: [], inside: null });
    return;
  }
  if (S().routeId === route.id) return;
  const cum = cumulativeDistances(route.coords);
  ix = buildSegIndex(route.coords, cum);
  hint = 0;
  useSafety.setState({ routeId: route.id, coords: route.coords, cum, dangers: [], pois: [], zfe: [], inside: null, along: 0, curves: findCurves(route, cum) });
  const myIx = ix;

  // données serveur (avec nouvelles tentatives si le serveur vient de démarrer ou est injoignable)
  const loadZones = (attempt: number) =>
    Promise.all(splitBBox(routeBBox(route.coords)).map(fetchZones))
      .then((rs) => {
        if (ix !== myIx) return;
        const err = rs.find((r) => !r.available)?.error ?? null;
        useSafety.setState({ dangers: dangerIntervals(myIx, rs.flatMap((r) => r.zones)), zonesError: err });
        if (err && attempt < 5) window.setTimeout(() => ix === myIx && loadZones(attempt + 1), 30000);
      })
      .catch((e) => {
        useSafety.setState({ zonesError: String(e.message || e) });
        if (attempt < 5) window.setTimeout(() => ix === myIx && loadZones(attempt + 1), 30000);
      });
  const loadZfe = (attempt: number) =>
    fetchZfe()
      .then((r) => {
        if (ix !== myIx) return;
        useSafety.setState({ zfe: zfeCrossings(route.coords, cum, r.features), zfeError: r.available ? null : r.error });
        if (!r.available && attempt < 5) window.setTimeout(() => ix === myIx && loadZfe(attempt + 1), 30000);
      })
      .catch((e) => {
        useSafety.setState({ zfeError: String(e.message || e) });
        if (attempt < 5) window.setTimeout(() => ix === myIx && loadZfe(attempt + 1), 30000);
      });
  loadZones(0);
  loadZfe(0);

  refreshPois(0);
}

/** Tuiles (zoom 12) couvrant les `ahead` prochains mètres du tracé. */
let poiTimer = 0;
async function refreshPois(fromAlong: number, ahead = 15000) {
  const st = safetySettings();
  if (!st.levelCrossings && !st.schools) return;
  const myIx = ix;
  if (!myIx) return;
  const { coords, cum } = myIx;
  const keys = new Set<string>();
  let j = 1;
  for (let d = fromAlong; d <= Math.min(cum[cum.length - 1], fromAlong + ahead); d += 400) {
    while (j < cum.length - 1 && cum[j] < d) j++;
    const t = (d - cum[j - 1]) / (cum[j] - cum[j - 1] || 1);
    const a = coords[j - 1], b = coords[j];
    keys.add(tileKey([a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t]));
  }
  const tiles = await fetchPoiTiles([...keys]);
  if (ix !== myIx) return;
  const lc: LngLat[] = [], sc: LngLat[] = [];
  tiles.forEach((t) => { lc.push(...t.lc); sc.push(...t.sc); });
  const found = poisAlong(myIx, lc, sc);
  // fusionne avec ce qu'on connaît déjà (tuiles précédentes)
  const known = new Map(S().pois.map((p) => [p.id, p]));
  found.forEach((p) => known.set(p.id, p));
  useSafety.setState({ pois: [...known.values()].sort((a, b) => a.along - b.along) });
}

// ------------------------------------------------------------------ alertes en conduite

function onTick() {
  const { mode, position } = core();
  const st = S();
  if (mode !== "drive" || !position || !ix || !st.routeId) {
    if (st.inside) useSafety.setState({ inside: null });
    return;
  }
  const snap = snapWindow(position.coord, st.coords, st.cum, hint);
  hint = snap.index;
  const along = snap.along;
  const onRoute = snap.offset < 60;
  const set = safetySettings();
  const speed = position.speed ?? 0;

  // 1. zones de danger : alerte à l'approche / à l'entrée, bandeau tant qu'on y est
  let inside: DangerInterval | null = null;
  if (set.dangerZones && onRoute) {
    for (const z of st.dangers) {
      if (along >= z.start - 250 && along < z.end) {
        alert(`safety-dz-${z.id}-${Math.round(z.start)}`, "danger-zone", "Zone de danger", z.start - along, "warn");
      }
      if (along >= z.start && along < z.end) inside = z;
    }
  }
  if (inside !== st.inside) useSafety.setState({ inside });
  useSafety.setState({ along });
  if (!onRoute) return;

  // 2. virages serrés : seulement si l'on roule vite pour ce rayon (accélération latérale > 3,5 m/s²)
  if (set.curves && speed >= 55 / 3.6) {
    for (const c of st.curves) {
      const d = c.start - along;
      if (d >= 0 && d <= 320 && (speed * speed) / c.radius > 3.5) {
        const label = c.count > 1 ? "Virages serrés" : "Virage serré";
        alert(`safety-curve-${c.id}`, "sharp-curve", `${label} dans ${formatDistance(Math.max(50, Math.round(d / 50) * 50))}`, d, "info");
      }
    }
  }

  // 3. passages à niveau et écoles
  const now = new Date();
  const schoolTime = now.getDay() >= 1 && now.getDay() <= 5 && now.getHours() >= 7 && now.getHours() < 19;
  for (const p of st.pois) {
    const d = p.along - along;
    if (p.kind === "level-crossing" && set.levelCrossings && d >= 0 && d <= 300) {
      alert(`safety-${p.id}`, "level-crossing", `Passage à niveau dans ${formatDistance(Math.max(50, Math.round(d / 50) * 50))}`, d, "info");
    }
    if (p.kind === "school" && set.schools && schoolTime && d >= 0 && d <= 200) {
      alert(`safety-${p.id}`, "school-zone", "Zone école : ralentis", d, "info");
    }
  }

  // 4. ZFE : prévenir 1 km avant l'entrée
  if (set.zfe) {
    for (const z of st.zfe) {
      const d = z.entry - along;
      if (d < 0 || d > 1000 || !z.props.vp) continue;
      const forbidden = critairForbidden(set.critair, z.props.vp);
      if (forbidden === false) continue; // vignette autorisée : rien à dire
      const text = forbidden
        ? `ZFE dans ${formatDistance(d)} : ${CRITAIR_LABEL[set.critair]} non autorisée`
        : `Tu entres dans une ZFE dans ${formatDistance(d)}`;
      alert(`safety-zfe-${z.props.id}-${Math.round(z.entry)}`, "zfe", text, d, forbidden ? "warn" : "info");
    }
  }

  // 5. tuiles de passages à niveau / écoles devant soi (au plus toutes les 20 s)
  if (Date.now() - poiTimer > 20000) {
    poiTimer = Date.now();
    refreshPois(along);
  }
}

// ------------------------------------------------------------------ fatigue de nuit

/**
 * Rappel doux si l'on conduit de nuit (entre 1 h et 5 h) depuis 30 min, puis toutes les heures.
 * Id d'alerte propre (« safety-night-… ») et seuils distincts des pauses classiques (module along).
 */
let nightDriveMs = 0;
let nightReminders = 0;
let lastNightCheck = 0;
export function nightCheck(now = new Date()) {
  const t = now.getTime();
  const dt = lastNightCheck ? Math.max(0, Math.min(t - lastNightCheck, 5 * 60000)) : 0;
  lastNightCheck = t;
  const { mode, position } = core();
  const h = now.getHours();
  const moving = (position?.speed ?? 0) > 2;
  if (mode !== "drive" || h < 1 || h >= 5) { if (mode !== "drive") nightDriveMs = 0; return; }
  if (moving) nightDriveMs += dt;
  const due = 30 * 60000 + nightReminders * 60 * 60000;
  if (safetySettings().night && nightDriveMs >= due) {
    nightReminders++;
    alert(`safety-night-${nightReminders}-${now.toDateString()}`, "night-fatigue", "Il est tard : si la fatigue arrive, offre-toi une pause", 0, "info");
  }
}

// ------------------------------------------------------------------ démarrage

export function startSafetyEngine() {
  const offs: (() => void)[] = [];
  analyze(core().routes[core().activeRoute]);
  offs.push(useCore.subscribe((s, prev) => {
    if (s.routes !== prev.routes || s.activeRoute !== prev.activeRoute) analyze(s.routes[s.activeRoute]);
    if (s.mode === "drive" && prev.mode !== "drive") {
      // nouveau trajet : on peut ré-alerter les mêmes éléments
      alerted.clear();
      nightDriveMs = 0;
      nightReminders = 0;
      lastNightCheck = Date.now();
    }
  }));
  offs.push(on("geo:tick", onTick));
  offs.push(on("drive:rerouted", () => analyze(core().routes[core().activeRoute])));
  const night = window.setInterval(() => nightCheck(), 60000);
  offs.push(() => window.clearInterval(night));
  return () => offs.forEach((f) => f());
}
