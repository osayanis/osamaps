import { useCore } from "../../core/store";
import type { EventKind, EventProps, SegmentProps } from "./api";
import { EVENT_TONE, EventIcon, GaugeIcon } from "./icons";

const LEVEL_LABEL = { ok: "Fluide", slow: "Ralenti", jam: "Bouchon" } as const;
const LEVEL_TONE = { ok: "--ok", slow: "--slow", jam: "--jam" } as const;

function until(iso: string | null | undefined) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  const sameDay = d.toDateString() === new Date().toDateString();
  const time = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });
  return sameDay ? `Jusqu'à ${time}` : `Jusqu'au ${d.toLocaleDateString("fr-FR", { day: "numeric", month: "long" })} à ${time}`;
}

/** Slot "sheet" : fiche d'un évènement officiel ou d'un tronçon touché sur la carte. */
export function TrafficSheet() {
  const panel = useCore((s) => s.panel);
  const data = useCore((s) => s.panelData);
  const openPanel = useCore((s) => s.openPanel);
  if (panel !== "traffic-event" && panel !== "traffic-segment") return null;
  const close = () => openPanel(null);

  if (panel === "traffic-event") {
    const e = data as EventProps;
    const tone = EVENT_TONE[e.kind as EventKind] ?? "--danger";
    const end = until(e.end);
    return (
      <section className="traffic-sheet glass" aria-label={e.title}>
        <header className="traffic-sheet-head">
          <span className="traffic-sheet-badge" style={{ color: `var(${tone})` }}><EventIcon kind={e.kind as EventKind} size={22} /></span>
          <div className="traffic-sheet-titles">
            <h3>{e.title}</h3>
            {e.road && <p>{e.road}</p>}
          </div>
          <button className="btn-ghost" onClick={close}>Fermer</button>
        </header>
        {e.where && <p className="traffic-sheet-line">{e.where}</p>}
        {e.description && <p className="traffic-sheet-line traffic-sheet-dim">{e.description}</p>}
        <footer className="traffic-sheet-foot">
          {end && <span>{end}</span>}
          <span>Bison Futé{e.source ? ` · ${e.source}` : ""}</span>
        </footer>
      </section>
    );
  }

  const s = data as SegmentProps;
  const level = (s.level ?? "ok") as keyof typeof LEVEL_LABEL;
  return (
    <section className="traffic-sheet glass" aria-label={LEVEL_LABEL[level]}>
      <header className="traffic-sheet-head">
        <span className="traffic-sheet-badge" style={{ color: `var(${LEVEL_TONE[level]})` }}><GaugeIcon size={22} /></span>
        <div className="traffic-sheet-titles">
          <h3>{LEVEL_LABEL[level]} · {s.speed} km/h</h3>
          <p>
            {s.usual ? `Habituellement ${s.usual} km/h` : "Vitesse habituelle encore inconnue"}
            {s.road ? ` · ${s.road}` : ""}
          </p>
        </div>
        <button className="btn-ghost" onClick={close}>Fermer</button>
      </header>
      <footer className="traffic-sheet-foot">
        <span>{s.src === "dir" ? "Mesure d'une station Bison Futé / DIR" : `Contributions anonymes OsaMaps${s.n ? ` (${s.n} véhicule${s.n > 1 ? "s" : ""})` : ""}`}</span>
      </footer>
    </section>
  );
}
