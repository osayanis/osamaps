import type { ReactNode } from "react";
import { core, useCore } from "../../core/store";
import { emit } from "../../core/bus";
import { distance, formatDistance } from "../../core/geometry";
import { useAlong, type StationPanelData } from "./state";
import { ENERGY_LABEL, FUELS, useAlongPrefs, type FuelKey } from "./prefs";
import { ago, euros, isFresh, openState, price3 } from "./format";
import { medianPrice, rankOnRoute } from "./suggest";
import { addAsStop, currentAlong } from "./controller";
import { hour, weatherIcon, weatherLabel, type WeatherPoint } from "./weather";
import { IconBolt, IconChevron, IconClose, IconFuel, IconGo, IconPlus, IconWarn, WeatherGlyph } from "./icons";
import type { EvStation, FuelStation } from "./api";

/** Conteneur commun des panneaux du module. */
function Panel({ title, kicker, detail, icon, children, onClose }: { title: string; kicker?: string; detail?: ReactNode; icon: ReactNode; children: ReactNode; onClose?: () => void }) {
  const close = onClose ?? (() => core().openPanel(null));
  return (
    <section className="along-sheet glass" aria-label={title}>
      <div className="along-handle" aria-hidden="true"><span /></div>
      <header className="along-head">
        <div className="along-badge">{icon}</div>
        <div className="along-titles">
          {kicker && <div className="along-kicker">{kicker}</div>}
          <h2 className="along-title">{title}</h2>
          {detail && <div className="along-detail">{detail}</div>}
        </div>
        <button className="along-close" onClick={close} aria-label="Fermer"><IconClose size={18} /></button>
      </header>
      {children}
    </section>
  );
}

const fromMe = (lng: number, lat: number) => {
  const p = core().position?.coord;
  return p ? formatDistance(distance(p, [lng, lat])) : null;
};

// ——— fiche station ————————————————————————————————————————————————————————

export function StationSheet() {
  const panel = useCore((s) => s.panel);
  const data = useCore((s) => s.panelData) as StationPanelData | null;
  const mode = useCore((s) => s.mode);
  if (panel !== "station" || !data) return null;
  return data.kind === "fuel" ? <FuelCard s={data.station} mode={mode} /> : <EvCard s={data.station} mode={mode} />;
}

function Actions({ name, lng, lat, mode }: { name: string; lng: number; lat: number; mode: string }) {
  return (
    <div className="along-actions">
      <button className="pill along-go" onClick={() => { core().openPanel(null); emit("place:go", { name, lng, lat }); }}>
        <IconGo size={18} /> Y aller
      </button>
      {mode !== "browse" && (
        <button className="pill secondary along-go" onClick={() => addAsStop(name, lng, lat)}>
          <IconPlus size={18} /> Ajouter comme arrêt
        </button>
      )}
    </div>
  );
}

function FuelCard({ s, mode }: { s: FuelStation; mode: string }) {
  const mine = useAlongPrefs((p) => p.energy);
  const open = openState(s);
  const dist = fromMe(s.lng, s.lat);
  const now = Date.now();
  const name = `Station ${s.city}`;
  const sub = [s.address, s.cp && `${s.cp} ${s.city}`].filter(Boolean).join(", ");
  const routeInfo = s.along != null && mode !== "browse" ? `à ${formatDistance(Math.max(0, s.along - currentAlong()))} sur le trajet${s.offset ? ` · ${formatDistance(s.offset)} du tracé` : ""}` : dist && `à ${dist}`;
  return (
    <Panel icon={<IconFuel size={20} />} kicker={s.highway ? "Station d'autoroute" : "Station-service"} title={name} detail={sub}>
      <div className="along-meta">
        <span className={`along-dot-state ${open.open === true ? "is-open" : open.open === false ? "is-closed" : ""}`} aria-hidden="true" />
        <span>{open.text}</span>
        {routeInfo && <><span className="along-sep">·</span><span>{routeInfo}</span></>}
      </div>
      <ul className="along-prices">
        {FUELS.filter((f) => s.prices[f] || s.shortage.includes(f)).map((f) => {
          const pr = s.prices[f];
          const out = s.shortage.includes(f);
          const fresh = pr && isFresh(pr.maj, now);
          return (
            <li key={f} className={`along-price${f === mine ? " is-mine" : ""}${!fresh || out ? " is-stale" : ""}`}>
              <span className="along-price-name">{ENERGY_LABEL[f]}</span>
              <span className="along-price-value">{out ? "Rupture" : pr ? `${price3(pr.p)} €` : "—"}</span>
              <span className="along-price-age">{out ? "temporaire" : pr ? ago(pr.maj, now) : ""}</span>
            </li>
          );
        })}
      </ul>
      <Actions name={name} lng={s.lng} lat={s.lat} mode={mode} />
      <p className="along-source">Prix officiels déclarés par la station (prix-carburants.gouv.fr).</p>
    </Panel>
  );
}

function EvCard({ s, mode }: { s: EvStation; mode: string }) {
  const dist = fromMe(s.lng, s.lat);
  const routeInfo = s.along != null && mode !== "browse" ? `à ${formatDistance(Math.max(0, s.along - currentAlong()))} sur le trajet` : dist && `à ${dist}`;
  return (
    <Panel icon={<IconBolt size={20} />} kicker="Borne de recharge" title={s.name} detail={s.address}>
      <div className="along-meta">
        <span>{s.operator}</span>
        {s.hours && <><span className="along-sep">·</span><span>{s.hours === "24/7" ? "24 h/24, 7 j/7" : s.hours}</span></>}
        {routeInfo && <><span className="along-sep">·</span><span>{routeInfo}</span></>}
      </div>
      <div className="along-ev-grid">
        <div className="along-ev-cell"><strong>{s.kw ? `${s.kw} kW` : "—"}</strong><small>puissance max</small></div>
        <div className="along-ev-cell"><strong>{s.points || "—"}</strong><small>{s.points > 1 ? "points de charge" : "point de charge"}</small></div>
        <div className="along-ev-cell"><strong>{s.free ? "Gratuit" : "Payant"}</strong><small>recharge</small></div>
      </div>
      {s.plugs.length > 0 && <div className="along-chips">{s.plugs.map((p) => <span key={p} className="along-chip">{p}</span>)}</div>}
      <Actions name={s.name} lng={s.lng} lat={s.lat} mode={mode} />
      <p className="along-source">Base nationale des bornes (IRVE, data.gouv.fr). Disponibilité en temps réel non connue.</p>
    </Panel>
  );
}

// ——— liste des stations du trajet ————————————————————————————————————————

export function FuelListSheet() {
  const panel = useCore((s) => s.panel);
  const route = useAlong((s) => s.route);
  const energy = useAlongPrefs((p) => p.energy);
  if (panel !== "fuel") return null;
  const loading = !route || route.status === "loading";
  if (energy === "ev") {
    const list = (route?.ev ?? []).filter((s) => (s.along ?? 0) >= currentAlong()).sort((a, b) => b.kw - a.kw || (a.along ?? 0) - (b.along ?? 0));
    return (
      <Panel icon={<IconBolt size={20} />} title="Recharge sur le trajet" detail={loading ? "Recherche des bornes…" : `${list.length} lieu${list.length > 1 ? "x" : ""} à moins de 1,5 km du tracé`}>
        <ul className="along-list">
          {list.slice(0, 40).map((s) => (
            <li key={s.id}>
              <button className="along-row" onClick={() => core().openPanel("station", { kind: "ev", station: s })}>
                <span className="along-row-price">{s.kw ? `${s.kw} kW` : "—"}</span>
                <span className="along-row-text"><strong>{s.name}</strong><small>{s.operator} · à {formatDistance((s.along ?? 0) - currentAlong())}</small></span>
                <IconChevron size={18} />
              </button>
            </li>
          ))}
        </ul>
      </Panel>
    );
  }
  const ranked = route ? rankOnRoute(route.fuel, energy, currentAlong()) : [];
  return (
    <Panel icon={<IconFuel size={20} />} title="Carburant sur le trajet"
      detail={loading ? "Recherche des stations…" : `${ENERGY_LABEL[energy]} · ${ranked.length} station${ranked.length > 1 ? "s" : ""} à moins de 1 km du tracé`}>
      {!loading && !ranked.length && <p className="along-empty">Aucun prix récent pour ce carburant le long du trajet.</p>}
      <ul className="along-list">
        {ranked.slice(0, 40).map(({ station: s, price, ahead }, i) => (
          <li key={s.id}>
            <button className="along-row" onClick={() => core().openPanel("station", { kind: "fuel", station: s })}>
              <span className={`along-row-price${i === 0 ? " is-best" : ""}`}>{price3(price)}</span>
              <span className="along-row-text">
                <strong>{s.city}{s.highway ? " · autoroute" : ""}</strong>
                <small>à {formatDistance(ahead)}{s.offset != null && s.offset > 150 ? ` · détour ${formatDistance(s.offset * 2)}` : " · sur la route"}</small>
              </span>
              <IconChevron size={18} />
            </button>
          </li>
        ))}
      </ul>
    </Panel>
  );
}

// ——— météo du trajet ————————————————————————————————————————————————————

const pointName = (p: WeatherPoint) => p.at === 0 ? "Départ" : p.at === 1 ? "Arrivée" : `À ${formatDistance(p.along)}`;

export function WeatherSheet() {
  const panel = useCore((s) => s.panel);
  const w = useAlong((s) => s.weather);
  const status = useAlong((s) => s.weatherStatus);
  if (panel !== "weather") return null;
  return (
    <Panel icon={<WeatherGlyph kind={w ? weatherIcon(w.points[0].code) : "cloud"} size={20} />} title="Météo sur le trajet"
      detail={status === "loading" ? "Prévisions en cours…" : status === "error" ? "Prévisions indisponibles pour le moment." : "Prévue à l'heure où tu passeras."}>
      {w?.hazard && (
        <div className={`along-hazard tone-${w.hazard.tone}`}><IconWarn size={18} /> {w.hazard.text}</div>
      )}
      {w && (
        <ul className="along-wx">
          {w.points.map((p) => (
            <li key={p.at} className="along-wx-row">
              <span className="along-wx-time">{hour(p.time)}</span>
              <span className="along-wx-icon"><WeatherGlyph kind={weatherIcon(p.code)} /></span>
              <span className="along-wx-text"><strong>{pointName(p)}</strong><small>{weatherLabel(p.code)}{p.precip >= 0.1 ? ` · ${p.precip.toFixed(1).replace(".", ",")} mm/h` : ""}</small></span>
              <span className="along-wx-temp">{Math.round(p.temp)}°</span>
            </li>
          ))}
        </ul>
      )}
      {w?.arrivalNow && (
        <p className="along-wx-now">En ce moment à l'arrivée : {Math.round(w.arrivalNow.temp)} °C, {weatherLabel(w.arrivalNow.code).toLowerCase()}.</p>
      )}
      <p className="along-source">Prévisions Open-Meteo.</p>
    </Panel>
  );
}

// ——— bandeau discret au-dessus de l'aperçu d'itinéraire ——————————————————

export function PreviewStrip() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const routes = useCore((s) => s.routes);
  const active = useCore((s) => s.activeRoute);
  const w = useAlong((s) => s.weather);
  const st = useAlong((s) => s.route);
  const nearby = useAlong((s) => s.nearbyFuel);
  const { energy, consumption, evConsumption } = useAlongPrefs();
  const route = routes[active];
  if (mode !== "preview" || panel !== null || !route) return null;

  const wx = w && w.routeId === route.id ? w : null;
  const stations = st && st.routeId === route.id && st.status === "ready" ? st : null;
  const km = route.distance / 1000;

  let fuelLine: ReactNode = null;
  let cost: string | null = null;
  if (energy === "ev") {
    cost = `≈ ${Math.round((km * evConsumption) / 100)} kWh`;
    if (stations) {
      const fast = stations.ev.filter((s) => s.kw >= 50).length;
      fuelLine = stations.ev.length ? <>{stations.ev.length} bornes sur le trajet{fast ? <>, dont <b>{fast} rapides</b></> : null}</> : "Aucune borne à moins de 1,5 km du trajet";
    }
  } else if (stations) {
    const best = rankOnRoute(stations.fuel, energy as FuelKey)[0];
    const avg = medianPrice(stations.fuel, energy) ?? medianPrice(nearby, energy);
    if (avg) cost = `≈ ${euros((km * consumption * avg) / 100)}`;
    fuelLine = best
      ? <>Le moins cher : <b>{price3(best.price)} €</b> à {formatDistance(best.ahead)}</>
      : `Pas de prix récent en ${ENERGY_LABEL[energy]} sur le trajet`;
  }

  const temps = wx ? wx.points.map((p) => Math.round(p.temp)) : [];
  const costLine = energy === "ev"
    ? <>Énergie du trajet <b>{cost}</b> · {String(evConsumption).replace(".", ",")} kWh/100 km</>
    : <>Coût du trajet <b>{cost}</b> · {String(consumption).replace(".", ",")} L/100 km</>;
  return (
    <div className="along-strip glass" role="group" aria-label="Sur le trajet">
      {wx && (
        <button className={`along-strip-row${wx.hazard ? ` tone-${wx.hazard.tone}` : ""}`} onClick={() => core().openPanel("weather")}>
          <span className="along-strip-icon">{wx.hazard ? <IconWarn size={18} /> : <WeatherGlyph kind={weatherIcon(wx.points[wx.points.length - 1].code)} />}</span>
          <span className="along-strip-text">
            {wx.hazard ? wx.hazard.text : <>{weatherLabel(wx.points[wx.points.length - 1].code)} à l'arrivée · {temps[0]}° → {temps[temps.length - 1]}°</>}
          </span>
          <IconChevron size={16} />
        </button>
      )}
      {(fuelLine || cost) && (
        <button className="along-strip-row is-two" onClick={() => core().openPanel("fuel")}>
          <span className="along-strip-icon">{energy === "ev" ? <IconBolt size={18} /> : <IconFuel size={18} />}</span>
          <span className="along-strip-text">
            <span className="along-strip-main">{fuelLine ?? "Recherche des stations du trajet…"}</span>
            {cost && <span className="along-strip-sub">{costLine}</span>}
          </span>
          <IconChevron size={16} />
        </button>
      )}
    </div>
  );
}

/**
 * Une seule entrée par slot et par module (le shell utilise l'id du module comme clé React) :
 * le bandeau d'aperçu et les trois panneaux passent donc par ce composant.
 */
export function AlongSheets() {
  return (
    <>
      <PreviewStrip />
      <StationSheet />
      <FuelListSheet />
      <WeatherSheet />
    </>
  );
}
