import { useCore } from "../../core/store";
import type { EventProps, SegmentProps } from "./api";
import { EVENT_LABEL, EVENT_TONE, EventIcon, GaugeIcon } from "./icons";

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

function since(iso: string | null | undefined) {
  if (!iso) return null;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  return d.toDateString() === new Date().toDateString()
    ? `Depuis ${d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" })}`
    : `Depuis le ${d.toLocaleDateString("fr-FR", { day: "numeric", month: "long" })}`;
}

const LANG = { de: "allemand", nl: "néerlandais", es: "espagnol", ca: "catalan" } as Record<string, string>;

function facts(e: EventProps) {
  const out: string[] = [];
  if (e.lanes && e.lanes !== e.title) out.push(e.lanes);
  const d = e.delay ?? e.relatedJam?.delay;
  if (d && d >= 60) out.push(`~${Math.round(d / 60)} min de retard`);
  if (e.speed && e.type === "jam") out.push(`${e.speed} km/h`);
  if (e.relatedJam && e.type !== "jam") out.push("Bouchon lié");
  const u = until(e.end);
  if (u) out.push(u);
  else if (["accident", "danger", "jam"].includes(e.type)) { const s = since(e.start); if (s) out.push(s); }
  return out;
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
    const tone = EVENT_TONE[e.type] ?? "--danger";
    const sub = [e.road, e.direction].filter(Boolean).join(" · ") || EVENT_LABEL[e.type];
    const c = e.confidence ?? 0.5;
    const steps = c >= 0.85 ? 3 : c >= 0.6 ? 2 : 1;
    const label = c >= 0.85 ? "élevée" : c >= 0.6 ? "moyenne" : "faible";
    const sources = e.sources ?? [];
    const f = facts(e);
    return (
      <section className="traffic-sheet glass" aria-label={e.title}>
        <header className="traffic-sheet-head">
          <span className="traffic-sheet-badge" style={{ color: `var(${tone})` }}><EventIcon kind={e.type} size={22} /></span>
          <div className="traffic-sheet-titles">
            <h3>{e.title}</h3>
            <p>{sub}</p>
          </div>
          <button className="btn-ghost" onClick={close}>Fermer</button>
        </header>
        {e.description && <p className="traffic-sheet-line">{e.description}</p>}
        {f.length > 0 && <div className="traffic-facts">{f.map((x) => <span key={x} className="traffic-fact">{x}</span>)}</div>}
        {e.original && (
          <details className="traffic-original">
            <summary>{e.lang && LANG[e.lang] ? `Message d'origine (${LANG[e.lang]})` : "Détails de la source"}</summary>
            <p className="traffic-sheet-dim">{e.original}</p>
          </details>
        )}
        <div className="traffic-conf" aria-label={`Confiance ${label}`}>
          <span className="traffic-conf-bars" aria-hidden>{[0, 1, 2].map((i) => <i key={i} className={i < steps ? "on" : ""} />)}</span>
          <span>Confiance {label}{sources.length > 1 ? ` · ${sources.length} sources concordantes` : ""}</span>
        </div>
        <footer className="traffic-sheet-foot"><span>{sources.map((x) => x.name).join(" · ") || "Source inconnue"}</span></footer>
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
