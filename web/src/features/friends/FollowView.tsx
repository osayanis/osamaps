import { useEffect, useRef, useState } from "react";
import maplibregl, { type GeoJSONSource, type Map as MLMap } from "maplibre-gl";
import { create } from "zustand";
import { core, useCore, type LngLat } from "../../core/store";
import { getSocket, BASE } from "../../core/services";
import { emit } from "../../core/bus";
import { snapToLine, formatDistance, bearing } from "../../core/geometry";
import { followToken } from "./store";
import { clock, IconCheck, IconCar } from "./util";

/**
 * Vue lecture seule ouverte par un lien `?suivre=JETON` : la voiture avance en direct, le tracé
 * restant, l'heure d'arrivée, puis « Yanis est arrivé ». Aucune identité n'est demandée au visiteur.
 */
interface TripView {
  token: string;
  name: string;
  dest: { name: string; lng: number; lat: number };
  coords?: LngLat[];
  pos: { lng: number; lat: number; heading: number | null; speed: number | null } | null;
  eta: number | null;
  remaining: number | null;
  arrivedAt: number | null;
  expiresAt: number;
  updated: number;
}
interface FollowState {
  state: "loading" | "live" | "arrived" | "ended" | "error";
  trip: (TripView & { coords: LngLat[] }) | null;
  message: string | null;
  autoCam: boolean;
}
const useFollow = create<FollowState>(() => ({ state: "loading", trip: null, message: null, autoCam: true }));
const set = useFollow.setState;

/** Démarrage de la vue (appelé par init() quand ?suivre= est présent). */
export function initFollow(): () => void {
  if (!followToken) return () => {};
  const token = followToken;
  document.body.classList.add("friends-following");
  core().set({ follow: false });
  const unFollow = useCore.subscribe((s) => { if (s.follow) core().set({ follow: false }); });
  const s = getSocket();

  const merge = (t: Partial<TripView>) => {
    const cur = useFollow.getState().trip;
    const next = { ...(cur ?? {}), ...t, coords: t.coords ?? cur?.coords ?? [] } as TripView & { coords: LngLat[] };
    set({ trip: next });
  };
  const watch = () => {
    s.emit("friends:trip:watch", { token }, (r: { ok: boolean; error?: string; trip?: TripView }) => {
      if (!r?.ok || !r.trip) { set({ state: "error", message: r?.error ?? "Ce lien de suivi a expiré." }); return; }
      merge(r.trip);
      set({ state: r.trip.arrivedAt ? "arrived" : "live" });
    });
  };
  const onUpdate = (t: TripView) => { if (t.token === token) merge(t); };
  const onArrived = (t: TripView) => {
    if (t.token !== token) return;
    merge(t);
    set({ state: "arrived" });
    emit("toast", { text: `${t.name} est bien arrivé`, tone: "good" });
  };
  const onEnded = (p: { token: string; why: string }) => {
    if (p.token !== token) return;
    if (useFollow.getState().state === "arrived" && p.why === "expired") set({ state: "ended", message: "Le lien a expiré." });
    else set({ state: "ended", message: p.why === "expired" ? "Le lien a expiré." : "Le partage du trajet est terminé." });
  };
  s.on("connect", watch);
  s.on("friends:trip:update", onUpdate);
  s.on("friends:trip:arrived", onArrived);
  s.on("friends:trip:ended", onEnded);
  if (s.connected) watch();

  return () => {
    document.body.classList.remove("friends-following");
    unFollow();
    s.emit("friends:trip:unwatch", { token });
    s.off("connect", watch);
    s.off("friends:trip:update", onUpdate);
    s.off("friends:trip:arrived", onArrived);
    s.off("friends:trip:ended", onEnded);
  };
}

/** Le reste du tracé, depuis la voiture. */
function remaining(t: TripView & { coords: LngLat[] }): LngLat[] {
  if (t.arrivedAt) return [];
  if (!t.pos || t.coords.length < 2) return t.coords;
  const p: LngLat = [t.pos.lng, t.pos.lat];
  const snap = snapToLine(p, t.coords);
  return [p, ...t.coords.slice(snap.index + 1)];
}

const SRC = "friends-follow";
function ensureLayers(map: MLMap) {
  if (map.getSource(SRC)) return;
  map.addSource(SRC, { type: "geojson", data: { type: "FeatureCollection", features: [] } });
  map.addLayer({ id: "friends-follow-casing", type: "line", source: SRC, layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": "#000", "line-opacity": 0.5, "line-width": 10 } });
  map.addLayer({ id: "friends-follow-line", type: "line", source: SRC, layout: { "line-cap": "round", "line-join": "round" }, paint: { "line-color": "#fff", "line-width": 6 } });
}

/** Calque de carte de la vue suivre (slot "map"). */
export function FollowLayer() {
  const map = useCore((s) => s.map);
  const trip = useFollow((s) => s.trip);
  const autoCam = useFollow((s) => s.autoCam);
  const car = useRef<{ marker: maplibregl.Marker; el: HTMLDivElement; from: LngLat; to: LngLat; t0: number; heading: number } | null>(null);
  const dest = useRef<maplibregl.Marker | null>(null);
  const fitted = useRef(false);

  // tracé + calques (remis après un changement de style)
  useEffect(() => {
    if (!map || !followToken) return;
    const draw = () => {
      ensureLayers(map);
      const t = useFollow.getState().trip;
      const line = t ? remaining(t) : [];
      (map.getSource(SRC) as GeoJSONSource).setData({
        type: "FeatureCollection",
        features: line.length > 1 ? [{ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: line } }] : [],
      });
    };
    draw();
    const unsub = useFollow.subscribe((s, prev) => { if (s.trip !== prev.trip) draw(); });
    map.on("style.load", draw);
    const stop = (e: { originalEvent?: unknown }) => { if (e.originalEvent) set({ autoCam: false }); };
    map.on("dragstart", stop);
    return () => {
      unsub();
      map.off("style.load", draw);
      map.off("dragstart", stop);
      for (const id of ["friends-follow-line", "friends-follow-casing"]) if (map.getLayer(id)) map.removeLayer(id);
      if (map.getSource(SRC)) map.removeSource(SRC);
    };
  }, [map]);

  // voiture (animée entre deux positions) + destination
  useEffect(() => {
    if (!map || !trip) return;
    const p: LngLat | null = trip.pos ? [trip.pos.lng, trip.pos.lat] : null;
    if (!dest.current) {
      const el = document.createElement("div");
      el.className = "friends-follow-dest";
      el.innerHTML = `<span class="friends-follow-pin"></span>`;
      dest.current = new maplibregl.Marker({ element: el, anchor: "bottom" }).setLngLat([trip.dest.lng, trip.dest.lat]).addTo(map);
    }
    if (!p) return;
    if (!car.current) {
      const el = document.createElement("div");
      el.className = "friends-follow-car";
      el.innerHTML = `<svg width="22" height="22" viewBox="0 0 24 24"><path d="M12 2.5 19.5 21 12 16.8 4.5 21z" fill="currentColor"/></svg>`;
      const marker = new maplibregl.Marker({ element: el, anchor: "center" }).setLngLat(p).addTo(map);
      car.current = { marker, el, from: p, to: p, t0: performance.now(), heading: trip.pos?.heading ?? 0 };
    } else {
      const c = car.current;
      const cur = c.marker.getLngLat();
      c.from = [cur.lng, cur.lat];
      c.to = p;
      c.t0 = performance.now();
      c.heading = trip.pos?.heading ?? (c.from[0] !== p[0] || c.from[1] !== p[1] ? bearing(c.from, p) : c.heading);
    }
    car.current.el.classList.toggle("is-arrived", !!trip.arrivedAt);
    dest.current.getElement().style.display = trip.arrivedAt ? "none" : "";
  }, [map, trip]);

  // animation continue (≈ 2 s entre deux mises à jour du conducteur)
  useEffect(() => {
    if (!map) return;
    let raf = 0;
    const tick = () => {
      const c = car.current;
      if (c) {
        const k = Math.min(1, (performance.now() - c.t0) / 1900);
        c.marker.setLngLat([c.from[0] + (c.to[0] - c.from[0]) * k, c.from[1] + (c.to[1] - c.from[1]) * k]);
        const svg = c.el.firstElementChild as HTMLElement | null;
        if (svg) svg.style.transform = `rotate(${c.heading - map.getBearing()}deg)`;
      }
      raf = requestAnimationFrame(tick);
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [map]);

  // caméra : cadre la voiture et le reste du trajet, tant que le visiteur ne bouge pas la carte
  useEffect(() => {
    if (!map || !trip || !autoCam) return;
    const pts: LngLat[] = [...remaining(trip), [trip.dest.lng, trip.dest.lat]];
    if (trip.pos) pts.push([trip.pos.lng, trip.pos.lat]);
    const b = pts.reduce((bb, q) => bb.extend(q), new maplibregl.LngLatBounds(pts[0], pts[0]));
    map.fitBounds(b, { padding: { top: 110, bottom: 260, left: 48, right: 48 }, maxZoom: 15.5, duration: fitted.current ? 900 : 0, bearing: 0, pitch: 0 });
    fitted.current = true;
  }, [map, trip, autoCam]);

  useEffect(() => () => { car.current?.marker.remove(); dest.current?.remove(); car.current = null; dest.current = null; }, []);
  return null;
}

/** Interface de la vue suivre (slot "overlay"). */
export function FollowOverlay() {
  const { state, trip, message, autoCam } = useFollow();
  const [, force] = useState(0);
  useEffect(() => { const i = window.setInterval(() => force((x) => x + 1), 15_000); return () => window.clearInterval(i); }, []);
  if (!followToken) return null;
  const name = trip?.name ?? "Ton ami";
  const stale = trip && !trip.arrivedAt && Date.now() - trip.updated > 90_000;

  return (
    <div className="friends-follow">
      <div className="friends-follow-top glass">
        <span className={`friends-live-dot${state === "live" && !stale ? "" : " is-off"}`} aria-hidden="true" />
        <span>{state === "loading" ? "Chargement du trajet…" : trip ? `Trajet de ${name}` : "Suivi de trajet"}</span>
        {state === "live" && <span className="friends-follow-tag">en direct</span>}
      </div>

      {!autoCam && trip && (
        <button className="pill friends-follow-recenter" onClick={() => set({ autoCam: true })}>Recentrer</button>
      )}

      <div className="friends-follow-card glass" role="status" aria-live="polite">
        {state === "loading" && <p className="friends-muted">Connexion…</p>}

        {state === "error" && (
          <>
            <h2>Lien indisponible</h2>
            <p className="friends-muted">{message}</p>
            <a className="pill" href={BASE}>Ouvrir OsaMaps</a>
          </>
        )}

        {trip && (state === "live" || state === "arrived" || state === "ended") && (
          <>
            {state === "arrived" ? (
              <div className="friends-follow-arrived">
                <span className="friends-follow-check"><IconCheck size={22} /></span>
                <div>
                  <h2>{name} est arrivé</h2>
                  <p className="friends-muted">À {trip.dest.name}{trip.arrivedAt ? ` · ${clock(trip.arrivedAt)}` : ""}</p>
                </div>
              </div>
            ) : (
              <>
                <p className="friends-label"><IconCar size={16} /> {name} est en route vers</p>
                <h2 className="friends-follow-dest-name">{trip.dest.name}</h2>
                <div className="friends-follow-stats">
                  <div><span className="friends-label">Arrivée</span><strong>{trip.eta ? clock(trip.eta) : "—"}</strong></div>
                  <div><span className="friends-label">Reste</span><strong>{trip.remaining != null ? formatDistance(trip.remaining) : "—"}</strong></div>
                </div>
                {stale && <p className="friends-muted">Dernière position il y a {Math.round((Date.now() - trip.updated) / 60_000)} min</p>}
              </>
            )}
            {state === "ended" && <p className="friends-muted">{message}</p>}
            <p className="friends-follow-foot">Lecture seule · expire 30 min après l'arrivée</p>
          </>
        )}
      </div>
    </div>
  );
}
