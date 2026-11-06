import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useCore, type Route } from "../../core/store";
import { usePrefs, VEHICLE_LABELS, type Vehicle } from "../../core/prefs";
import { bansApply, bansBetween, idfBans, idfPassages } from "./truck";
import { formatDistance, formatDuration, formatEta } from "../../core/geometry";
import { useRouting, routing, localStamp, formatStamp, placeFrom, type DepartChoice } from "./state";
import { addStop, cancelPreview, computePreview, moveStop, removeStop, selectRoute, setDepart, startDrive } from "./controller";
import { searchPlaces, type Hit } from "./geocode";
import { IconCheck, IconClock, IconClose, IconDown, IconFerry, IconGo, IconHighway, IconPin, IconPlus, IconRetry, IconSearch, IconToll, IconUp } from "./icons";

/** Panneau d'aperçu : visible en mode "preview" quand aucun autre panneau n'est ouvert. */
export function RoutingSheet() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const visible = mode === "preview" && panel === null;
  useEffect(() => { if (!visible) routing().set({ sheetHeight: 0 }); }, [visible]);
  return visible ? <PreviewSheet /> : null;
}

function PreviewSheet() {
  const root = useRef<HTMLDivElement>(null);
  const destination = useCore((s) => s.destination);
  const routes = useCore((s) => s.routes);
  const activeRoute = useCore((s) => s.activeRoute);
  const { status, error, retryable, section, stops, depart, meta } = useRouting();
  const avoidTolls = usePrefs((s) => s.avoidTolls);
  const avoidHighways = usePrefs((s) => s.avoidHighways);
  const setPref = usePrefs((s) => s.setPref);
  const vehicle = usePrefs((s) => s.vehicle);
  const truck = vehicle.kind !== "car";

  // hauteur du panneau → marges du cadrage de la carte
  useLayoutEffect(() => {
    const el = root.current;
    if (!el) return;
    const ro = new ResizeObserver(() => routing().set({ sheetHeight: Math.round(el.getBoundingClientRect().height) }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Échap = annuler
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === "Escape" && !(e.target instanceof HTMLInputElement)) cancelPreview(); };
    window.addEventListener("keydown", k);
    return () => window.removeEventListener("keydown", k);
  }, []);

  const fastest = routes.length ? Math.min(...routes.map((r) => r.duration)) : 0;
  const active = routes[activeRoute];
  const toggle = (s: "depart" | "stops") => routing().set({ section: section === s ? null : s, pickOnMap: false });

  return (
    <section ref={root} className="routing-sheet glass" aria-label="Aperçu de l'itinéraire">
      <div className="routing-grab" aria-hidden="true" />
      <header className="routing-head">
        <div className="routing-head-text">
          <span className="routing-eyebrow">{truck ? `${VEHICLE_LABELS[vehicle.kind].label} · ` : ""}{stops.length ? `Via ${stops.length} étape${stops.length > 1 ? "s" : ""}, vers` : "Itinéraire vers"}</span>
          <h2 className="routing-title">{destination?.name ?? "Destination"}</h2>
        </div>
        <button className="routing-close" onClick={cancelPreview} aria-label="Annuler l'itinéraire"><IconClose /></button>
      </header>

      <div className="routing-body">
        {status === "loading" && !routes.length && <Skeleton />}
        {status === "error" && (
          <div className="routing-error card" role="alert">
            <p>{error}</p>
            {retryable && <button className="pill secondary" onClick={computePreview}><IconRetry /> Réessayer</button>}
          </div>
        )}
        {truck && active && !section && <TruckNotices route={active} vehicle={vehicle} depart={depart} departAt={meta[active.id]?.departAt} />}
        {routes.length > 0 && (
          <div className={`routing-cards${status === "loading" ? " is-busy" : ""}`} role="radiogroup" aria-label="Itinéraires proposés">
            {routes.map((r, i) => (
              <RouteCard key={r.id} route={r} index={i} active={i === activeRoute} fastest={fastest} multiple={routes.length > 1}
                arriveAt={meta[r.id]?.arriveAt} departAt={meta[r.id]?.departAt} depart={depart} />
            ))}
            {depart && routes.length === 1 && <p className="routing-note">Avec une heure choisie, une seule proposition est calculée.</p>}
            {stops.length > 0 && routes.length === 1 && !depart && <p className="routing-note">Avec des étapes, une seule proposition est calculée.</p>}
          </div>
        )}

        {section === "depart" && <DepartPanel depart={depart} />}
        {section === "stops" && <StopsPanel />}
      </div>

      <div className="routing-chips" role="toolbar" aria-label="Options">
        <button className={`routing-chip${avoidTolls ? " is-on" : ""}`} aria-pressed={avoidTolls} onClick={() => setPref("avoidTolls", !avoidTolls)}>
          {avoidTolls ? <IconCheck /> : <IconToll />} Sans péage
        </button>
        <button className={`routing-chip${avoidHighways ? " is-on" : ""}`} aria-pressed={avoidHighways} onClick={() => setPref("avoidHighways", !avoidHighways)}>
          {avoidHighways ? <IconCheck /> : <IconHighway />} Sans autoroute
        </button>
        <button className={`routing-chip${depart ? " is-on" : ""}${section === "depart" ? " is-open" : ""}`} aria-expanded={section === "depart"} onClick={() => toggle("depart")}>
          <IconClock /> {depart ? `${depart.type === 1 ? "Départ" : "Arrivée"} ${formatStamp(depart.value)}` : "Partir plus tard"}
        </button>
        <button className={`routing-chip${stops.length ? " is-on" : ""}${section === "stops" ? " is-open" : ""}`} aria-expanded={section === "stops"} onClick={() => toggle("stops")}>
          <IconPlus /> {stops.length ? `Étapes (${stops.length})` : "Ajouter un arrêt"}
        </button>
      </div>

      <footer className="routing-foot">
        <button className="pill routing-go" disabled={!active || status === "loading"} onClick={startDrive}>
          <IconGo /> {status === "loading" ? "Calcul en cours…" : depart ? "Démarrer maintenant" : "C'est parti"}
        </button>
      </footer>
    </section>
  );
}

function RouteCard({ route, index, active, fastest, multiple, arriveAt, departAt, depart }: {
  route: Route; index: number; active: boolean; fastest: number; multiple: boolean;
  arriveAt?: string; departAt?: string; depart: DepartChoice | null;
}) {
  const delta = Math.round((route.duration - fastest) / 60);
  const isFastest = multiple && delta <= 0;
  let when: string;
  if (depart && arriveAt && departAt) when = depart.type === 1 ? `arrivée ${formatStamp(arriveAt)}` : `départ ${formatStamp(departAt)}`;
  else when = `arrivée ${formatEta(route.duration)}`;
  return (
    <button role="radio" aria-checked={active} className={`routing-card${active ? " is-active" : ""}`} onClick={() => selectRoute(index)}>
      <span className="routing-card-top">
        <span className="routing-dur">{formatDuration(route.duration)}</span>
        {isFastest && <span className="routing-badge">Le plus rapide</span>}
        {multiple && !isFastest && <span className="routing-delta">+{formatDuration(route.duration - fastest)}</span>}
        <span className="routing-tags">
          {route.flags?.toll && <span className="routing-tag" title="Péages"><IconToll /> Péages</span>}
          {route.flags?.ferry && <span className="routing-tag" title="Ferry"><IconFerry /> Ferry</span>}
        </span>
      </span>
      <span className="routing-card-sub">
        {formatDistance(route.distance)}{route.summary ? ` · ${route.summary}` : ""} · {when}
      </span>
    </button>
  );
}

function Skeleton() {
  return (
    <div className="routing-cards" aria-busy="true" aria-label="Calcul de l'itinéraire">
      <div className="routing-card routing-skel"><span /><span /></div>
      <div className="routing-card routing-skel is-faint"><span /><span /></div>
    </div>
  );
}

// ——— partir plus tard ————————————————————————————————————————————————

function DepartPanel({ depart }: { depart: DepartChoice | null }) {
  const [type, setType] = useState<1 | 2>(depart?.type ?? 1);
  const [value, setValue] = useState(depart?.value ?? localStamp(new Date(Date.now() + 30 * 60_000)));
  const quick = [15, 30, 60];
  const apply = (t: 1 | 2, v: string) => {
    if (!v) return;
    // une heure passée n'a pas de sens : on remet « maintenant »
    if (new Date(v).getTime() < Date.now() - 60_000) { setDepart(null); return; }
    setDepart({ type: t, value: v });
  };
  return (
    <div className="routing-panel card">
      <div className="routing-seg" role="tablist" aria-label="Type d'heure">
        <button role="tab" aria-selected={type === 1} className={type === 1 ? "is-on" : ""} onClick={() => { setType(1); if (depart) apply(1, value); }}>Partir à</button>
        <button role="tab" aria-selected={type === 2} className={type === 2 ? "is-on" : ""} onClick={() => { setType(2); if (depart) apply(2, value); }}>Arriver à</button>
      </div>
      <div className="routing-quick">
        <button className={`routing-mini${!depart ? " is-on" : ""}`} onClick={() => setDepart(null)}>Maintenant</button>
        {quick.map((m) => (
          <button key={m} className="routing-mini" onClick={() => {
            const v = localStamp(new Date(Date.now() + m * 60_000));
            setValue(v); apply(type, v);
          }}>{m < 60 ? `+${m} min` : `+${m / 60} h`}</button>
        ))}
      </div>
      <label className="routing-field">
        <span>{type === 1 ? "Heure de départ" : "Heure d'arrivée souhaitée"}</span>
        <input type="datetime-local" value={value} min={localStamp(new Date())}
          onChange={(e) => setValue(e.target.value)} onBlur={(e) => apply(type, e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") apply(type, (e.target as HTMLInputElement).value); }} />
      </label>
      <button className="pill secondary routing-apply" onClick={() => apply(type, value)}>Calculer pour cette heure</button>
    </div>
  );
}

// ——— étapes ——————————————————————————————————————————————————————————

function StopsPanel() {
  const stops = useRouting((s) => s.stops);
  const pickOnMap = useRouting((s) => s.pickOnMap);
  const position = useCore((s) => s.position);
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<Hit[]>([]);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (q.trim().length < 3) { setHits([]); return; }
    const ctrl = new AbortController();
    const t = window.setTimeout(async () => {
      setBusy(true);
      try { setHits(await searchPlaces(q, position?.coord, ctrl.signal)); } catch { if (!ctrl.signal.aborted) setHits([]); }
      if (!ctrl.signal.aborted) setBusy(false);
    }, 380);
    return () => { ctrl.abort(); window.clearTimeout(t); };
    // la position bouge sans arrêt : seule la saisie relance la recherche
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  const pick = (h: Hit) => { addStop(placeFrom(h.name, h.coord, h.detail)); setQ(""); setHits([]); };

  return (
    <div className="routing-panel card">
      {stops.length > 0 && (
        <ol className="routing-stops" aria-label="Étapes">
          {stops.map((s, i) => (
            <li key={s.id} className="routing-stop">
              <span className="routing-stop-num" aria-hidden="true">{i + 1}</span>
              <span className="routing-stop-text"><strong>{s.name}</strong>{s.detail && <small>{s.detail}</small>}</span>
              <button className="routing-icon-btn" disabled={i === 0} onClick={() => moveStop(i, -1)} aria-label={`Monter ${s.name}`}><IconUp /></button>
              <button className="routing-icon-btn" disabled={i === stops.length - 1} onClick={() => moveStop(i, 1)} aria-label={`Descendre ${s.name}`}><IconDown /></button>
              <button className="routing-icon-btn" onClick={() => removeStop(i)} aria-label={`Retirer ${s.name}`}><IconClose /></button>
            </li>
          ))}
        </ol>
      )}
      <label className="routing-search">
        <IconSearch />
        <input type="search" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Ajouter une étape (ville, adresse…)"
          enterKeyHint="search" autoComplete="off" aria-label="Rechercher une étape" />
        {busy && <span className="routing-spinner" aria-hidden="true" />}
      </label>
      {hits.length > 0 && (
        <ul className="routing-hits" role="listbox" aria-label="Résultats">
          {hits.map((h, i) => (
            <li key={`${h.coord.join(",")}-${i}`}>
              <button role="option" aria-selected="false" onClick={() => pick(h)}>
                <IconPin /><span><strong>{h.name}</strong>{h.detail && <small>{h.detail}</small>}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
      <button className={`routing-mini routing-map-pick${pickOnMap ? " is-on" : ""}`} onClick={() => routing().set({ pickOnMap: !pickOnMap })}>
        <IconPin /> {pickOnMap ? "Touchez la carte pour poser l'étape…" : "Choisir sur la carte"}
      </button>
    </div>
  );
}

/** Poids lourds : interdictions de circuler (> 7,5 t) et avertissement convoi exceptionnel (couleur danger = état). */
function TruckNotices({ route, vehicle, depart, departAt }: { route: Route; vehicle: Vehicle; depart: DepartChoice | null; departAt?: string }) {
  let start = new Date();
  if (departAt) start = new Date(departAt);
  else if (depart) {
    const d = new Date(depart.value);
    start = depart.type === 1 ? d : new Date(d.getTime() - route.duration * 1000);
  }
  const end = new Date(start.getTime() + route.duration * 1000);
  const now = Date.now();
  const bans = bansApply(vehicle)
    ? [
      ...bansBetween(start, end).filter((b) => !b.regional || route.coords.some(([lng, lat]) => lat > 44.6 && lat < 46.5 && lng > 4.7 && lng < 7.2)),
      ...idfBans(start, idfPassages(route)),
    ]
    : [];
  if (vehicle.kind !== "superheavy" && !bans.length) return null;
  return (
    <div className="routing-truck">
      {vehicle.kind === "superheavy" && (
        <p className="routing-truck-note" role="note">
          Convoi exceptionnel : l'itinéraire réel est celui imposé par ton arrêté préfectoral de transport exceptionnel. OsaMaps n'est qu'une aide.
        </p>
      )}
      {bans.map((b) => (
        <div key={`${b.start.getTime()}-${b.regional ?? ""}`} className="routing-truck-note" role="alert">
          <b>{b.start.getTime() <= now && b.end.getTime() > now ? "Interdiction en cours" : "Interdiction de circuler"}</b>
          <span>{b.regional ? `Sur ${b.regional}, c` : "C"}irculation interdite aux poids lourds de plus de 7,5 t {b.label}. Ton trajet tombe dans cette période (sauf dérogation).</span>
        </div>
      ))}
    </div>
  );
}
