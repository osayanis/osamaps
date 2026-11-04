import { useTraffic } from "./state";
import { TrafficLightIcon } from "./icons";

/** Slot "rail" : afficher / masquer le trafic. */
export function TrafficButton() {
  const visible = useTraffic((s) => s.visible);
  const setVisible = useTraffic((s) => s.setVisible);
  return (
    <button
      className={`round traffic-rail${visible ? " is-on" : ""}`}
      aria-pressed={visible}
      aria-label={visible ? "Masquer le trafic" : "Afficher le trafic"}
      title={visible ? "Masquer le trafic" : "Afficher le trafic"}
      onClick={() => setVisible(!visible)}
    >
      <TrafficLightIcon />
    </button>
  );
}
