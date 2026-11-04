import { formatDistance } from "../../core/geometry";
import { useTraffic } from "./state";

/**
 * Slot "hud" : « +5 min de trafic » sur l'itinéraire actif, seulement s'il y a un vrai retard
 * (≥ 1 min). Ne remplace pas l'ETA des autres modules : c'est un complément.
 */
export function TrafficDelay() {
  const ahead = useTraffic((s) => s.ahead);
  if (!ahead || ahead.delay < 60) return null;
  const min = Math.round(ahead.delay / 60);
  const next = ahead.next;
  const level = next?.level === "jam" ? "jam" : "slow";
  return (
    <div className={`traffic-hud glass traffic-${level}`} role="status" aria-live="polite">
      <span className="traffic-hud-dot" aria-hidden />
      <span className="traffic-hud-main">+{min} min de trafic</span>
      {next && next.distance > 50 && (
        <span className="traffic-hud-sub">
          {next.level === "jam" ? "bouchon" : "ralenti"} dans {formatDistance(next.distance)}
        </span>
      )}
    </div>
  );
}
