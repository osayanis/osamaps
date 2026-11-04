import { useCore } from "../../core/store";
import { formatDistance, formatDuration } from "../../core/geometry";
import { useGuide, type GuideAlert } from "./state";
import { thenManeuverIndex, finishArrival } from "./engine";
import { kindOf, mainStreet, roundaboutExit, roundaboutExitTarget, shortLabel, waypointName, isArrive, ordinalShort } from "./maneuvers";
import { ManeuverIcon, LaneIcon, AlertIcon, IconFlag, IconReroute } from "./icons";

/** HUD de conduite (slot "hud") : prochaine manœuvre, « puis », alertes, vitesse. */
export function GuidanceHud() {
  const route = useCore((s) => s.routes[s.activeRoute]);
  const recalculating = useGuide((s) => s.recalculating);
  const arrived = useGuide((s) => s.arrived);
  return (
    <div className="guidance-hud">
      {arrived ? <ArrivalCard /> : recalculating ? <RecalcCard /> : route ? <ManeuverCard /> : null}
      {!arrived && <Alerts />}
      {!arrived && <SpeedWidget />}
    </div>
  );
}

function ManeuverCard() {
  const route = useCore((s) => s.routes[s.activeRoute]);
  const nextIndex = useGuide((s) => s.nextIndex);
  const distToNext = useGuide((s) => s.distToNext);
  const nowThreshold = useGuide((s) => s.nowThreshold);
  const along = useGuide((s) => s.along);
  const destName = useCore((s) => s.destination?.name);
  if (!route?.maneuvers.length) return null;
  const idx = Math.min(nextIndex, route.maneuvers.length - 1);
  const m = route.maneuvers[idx];
  const kind = kindOf(m);
  const exit = kind === "roundabout" ? roundaboutExit(m) : null;
  // avant la première position accrochée, on montre la distance depuis le départ
  const dist = along === 0 && distToNext === 0 ? m.shapeIndex > 0 ? route.maneuvers[0].length : 0 : distToNext;
  const street = kind === "roundabout"
    ? (roundaboutExitTarget(m)?.name ?? mainStreet(m))
    : kind === "waypoint" ? waypointName(m) : mainStreet(m);
  const label = isArrive(kind) ? destName || shortLabel(m) : street || shortLabel(m);
  const sub = kind === "roundabout" && exit ? `${ordinalShort(exit)} sortie` : isArrive(kind) && kind !== "arrive" ? shortLabel(m) : null;
  const imminent = dist <= nowThreshold && !isArrive(kind);
  const thenIdx = thenManeuverIndex(route, idx, dist);
  const then = thenIdx != null ? route.maneuvers[thenIdx] : null;
  const lanes = m.lanes?.length ? m.lanes : null;

  return (
    <>
      <div key={`${route.id}-${idx}`} className={`guidance-card glass${imminent ? " is-now" : ""}`} role="status" aria-live="polite">
        <div className="guidance-main">
          <div className="guidance-arrow"><ManeuverIcon kind={kind} exit={exit} size={68} /></div>
          <div className="guidance-text">
            <div className="guidance-dist">{formatDistance(dist)}</div>
            <div className="guidance-street">{sub ? <><b>{sub}</b> · {label}</> : label}</div>
          </div>
        </div>
        {lanes && (
          <div className="guidance-lanes" aria-label="Voies conseillées">
            {lanes.map((l, i) => <LaneIcon key={i} directions={l.directions} valid={l.valid} />)}
          </div>
        )}
      </div>
      {then && (
        <div className="guidance-then glass">
          <span>Puis</span>
          <ManeuverIcon kind={kindOf(then)} exit={roundaboutExit(then)} size={26} />
          {mainStreet(then) && <span className="guidance-then-street">{mainStreet(then)}</span>}
        </div>
      )}
    </>
  );
}

function RecalcCard() {
  return (
    <div className="guidance-card glass guidance-recalc" role="status">
      <div className="guidance-main">
        <div className="guidance-arrow guidance-spin"><IconReroute size={40} /></div>
        <div className="guidance-text">
          <div className="guidance-street-big">Nouvel itinéraire…</div>
          <div className="guidance-street">Recalcul depuis votre position</div>
        </div>
      </div>
    </div>
  );
}

function ArrivalCard() {
  const a = useGuide((s) => s.arrived)!;
  return (
    <div className="guidance-card glass guidance-arrival" role="status">
      <div className="guidance-main">
        <div className="guidance-arrow guidance-ok"><IconFlag size={40} /></div>
        <div className="guidance-text">
          <div className="guidance-street-big">Vous voilà à destination</div>
          <div className="guidance-street">{a.name}{a.side ? ` · sur votre ${a.side === "right" ? "droite" : "gauche"}` : ""}</div>
          <div className="guidance-trip">{formatDuration(a.tripTime)} · {formatDistance(a.tripDistance)} parcourus</div>
        </div>
      </div>
      <button className="pill guidance-finish" onClick={finishArrival}>Terminer</button>
    </div>
  );
}

function Alerts() {
  const alerts = useGuide((s) => s.alerts);
  if (!alerts.length) return null;
  return (
    <>
      {alerts.slice(0, 2).map((a) => <AlertBanner key={a.id} a={a} />)}
    </>
  );
}

function AlertBanner({ a }: { a: GuideAlert }) {
  const police = /police|gendarm/i.test(a.kind);
  const tone = police ? "police" : a.tone;
  return (
    <div className={`guidance-alert glass tone-${tone}`} role="alert">
      <span className="guidance-alert-icon"><AlertIcon kind={a.kind} size={22} /></span>
      <span className="guidance-alert-text">{a.text}</span>
      {a.baseDistance > 0 && <span className="guidance-alert-dist">{a.remaining <= 20 ? "ici" : formatDistance(a.remaining)}</span>}
    </div>
  );
}

function SpeedWidget() {
  const kmh = useGuide((s) => s.speedKmh);
  const limit = useGuide((s) => s.limitKmh);
  const speeding = useGuide((s) => s.speeding);
  return (
    <div className="guidance-speed" aria-label="Vitesse">
      <div className={`guidance-speedo${speeding ? " is-over" : ""}`}>
        <b>{kmh ?? "–"}</b>
        <span>km/h</span>
      </div>
      {limit != null && (
        <div className={`guidance-limit${limit >= 100 ? " is-wide" : ""}`} aria-label={`Limitation ${limit} km/h`}><b>{limit}</b></div>
      )}
    </div>
  );
}
