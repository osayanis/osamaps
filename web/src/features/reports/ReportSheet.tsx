import { useEffect, useRef, useState } from "react";
import { useCore, core, type LngLat } from "../../core/store";
import { distance, formatDistance, formatDuration } from "../../core/geometry";
import { emit } from "../../core/bus";
import { ago, KIND_ORDER, KINDS, titleOf, type Kind } from "./catalog";
import { Icon, KindDisc } from "./Icon";
import { closeOwn, DETAIL, PANEL, type PanelData } from "./ReportButton";
import { sendReport, useReports, vote } from "./state";

const UNDO_MS = 5000;

/** Panneau du bas : « Signaler » (tuiles) ou fiche d'un signalement. */
export function ReportSheet() {
  const panel = useCore((s) => s.panel);
  if (panel === PANEL) return <ReportPanel />;
  if (panel === DETAIL) return <ReportDetail />;
  return null;
}

interface Pending { kind: Kind; sub: string | null; coord: LngLat; heading: number | null; at: number }

/** Touche 1 : bouton Signaler. Touche 2 : une tuile → envoi après 5 s (annulable, précisable). */
function ReportPanel() {
  const drive = useCore((s) => s.mode === "drive");
  const [pending, setPending] = useState<Pending | null>(null);
  const timer = useRef<number>();
  const live = useRef<Pending | null>(null);
  live.current = pending;
  // si le panneau est fermé par ailleurs pendant le délai, le signalement part quand même
  useEffect(() => () => {
    const p = live.current;
    if (p) { live.current = null; void sendReport(p.kind, p.sub, p.coord, p.heading); }
  }, []);

  const pick = (kind: Kind) => {
    const pos = core().position;
    if (!pos) { emit("toast", { text: "Position inconnue : impossible de signaler", tone: "warn" }); return; }
    // position et cap AU MOMENT de l'appui
    setPending({ kind, sub: null, coord: pos.coord, heading: pos.heading, at: Date.now() });
  };

  const send = (p: Pending) => {
    window.clearTimeout(timer.current);
    live.current = null;
    setPending(null);
    closeOwn();
    void sendReport(p.kind, p.sub, p.coord, p.heading);
  };

  useEffect(() => {
    if (!pending) return;
    window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => send(pending), Math.max(0, pending.at + UNDO_MS - Date.now()));
    return () => window.clearTimeout(timer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [pending]);

  return (
    <section className={`reports-sheet glass${drive ? " is-drive" : ""}`} aria-label="Signaler">
      {!pending ? (
        <>
          <header className="reports-head">
            <h2>Signaler</h2>
            <button className="reports-close" aria-label="Fermer" onClick={closeOwn}><Icon name="close" size={20} /></button>
          </header>
          <div className="reports-grid">
            {KIND_ORDER.map((k) => (
              <button key={k} className="reports-tile" onClick={() => pick(k)}>
                <KindDisc kind={k} size={drive ? 50 : 46} />
                <span>{KINDS[k].label}</span>
              </button>
            ))}
            <button className="reports-tile is-muted" onClick={closeOwn}>
              <span className="reports-disc is-ghost" style={{ width: drive ? 50 : 46, height: drive ? 50 : 46 }}><Icon name="close" size={22} /></span>
              <span>Fermer</span>
            </button>
          </div>
        </>
      ) : (
        <div className="reports-pending">
          <div className="reports-pending-top">
            <KindDisc kind={pending.kind} sub={pending.sub} size={56} />
            <div>
              <strong>{titleOf(pending.kind, pending.sub)}</strong>
              <span>Envoi dans quelques secondes…</span>
            </div>
          </div>
          <div className="reports-countdown"><i key={pending.at} style={{ animationDuration: `${UNDO_MS}ms` }} /></div>
          {KINDS[pending.kind].subs.length > 0 && (
            <div className="reports-subs" role="group" aria-label="Préciser (facultatif)">
              {KINDS[pending.kind].subs.map((s) => (
                <button
                  key={s.id}
                  className={`reports-chip${pending.sub === s.id ? " is-on" : ""}`}
                  aria-pressed={pending.sub === s.id}
                  onClick={() => setPending({ ...pending, sub: pending.sub === s.id ? null : s.id })}
                >{s.label}</button>
              ))}
            </div>
          )}
          <div className="reports-actions">
            <button className="pill secondary reports-big" onClick={() => { window.clearTimeout(timer.current); live.current = null; setPending(null); }}>Annuler</button>
            <button className="pill reports-big" onClick={() => send(pending)}>Envoyer</button>
          </div>
        </div>
      )}
    </section>
  );
}

/** Fiche d'un signalement (clic sur un marqueur). */
function ReportDetail() {
  const id = useCore((s) => (s.panelData as PanelData | null)?.id ?? "");
  const position = useCore((s) => s.position);
  const drive = useCore((s) => s.mode === "drive");
  const r = useReports((s) => s.items[id]);
  const mine = useReports((s) => !!s.mine[id]);
  const voted = useReports((s) => s.voted[id]);
  const [, tick] = useState(0);
  useEffect(() => { const t = window.setInterval(() => tick((n) => n + 1), 30_000); return () => window.clearInterval(t); }, []);

  if (!r) {
    return (
      <section className="reports-sheet glass" aria-label="Signalement">
        <header className="reports-head">
          <h2>Ce signalement n'existe plus</h2>
          <button className="reports-close" aria-label="Fermer" onClick={closeOwn}><Icon name="close" size={20} /></button>
        </header>
      </section>
    );
  }
  const d = position ? distance(position.coord, [r.lng, r.lat]) : null;
  const who = mine ? "par toi" : r.by ? `par ${r.by}` : "par un membre Osa";
  return (
    <section className={`reports-sheet glass${drive ? " is-drive" : ""}`} aria-label="Signalement">
      <header className="reports-detail-head">
        <KindDisc kind={r.type} sub={r.sub} size={52} />
        <div className="reports-detail-title">
          <h2>{titleOf(r.type, r.sub)}</h2>
          <span>{ago(r.createdAt).replace(/^./, (c) => c.toUpperCase())} · {who}</span>
        </div>
        <button className="reports-close" aria-label="Fermer" onClick={closeOwn}><Icon name="close" size={20} /></button>
      </header>
      <div className="reports-stats">
        <div><b>{r.confirmations}</b><span>{r.confirmations > 1 ? "confirmations" : "confirmation"}</span></div>
        {d != null && <div><b>{formatDistance(d)}</b><span>de toi</span></div>}
        <div><b>{formatDuration(Math.max(60, (r.expiresAt - Date.now()) / 1000))}</b><span>encore visible</span></div>
      </div>
      {mine ? (
        <div className="reports-actions">
          <p className="reports-note">Tu l'as signalé. C'est fini ?</p>
          <button className="pill secondary reports-big" onClick={() => { void vote(r.id, "gone"); closeOwn(); }}>Plus là, retirer</button>
        </div>
      ) : voted ? (
        <p className="reports-note is-center"><Icon name="check" size={18} /> Merci, c'est noté</p>
      ) : (
        <div className="reports-actions">
          <button className="pill reports-big" onClick={() => void vote(r.id, "still")}><Icon name="check" size={20} />Toujours là</button>
          <button className="pill secondary reports-big" onClick={() => void vote(r.id, "gone")}><Icon name="x" size={20} />Plus là</button>
        </div>
      )}
    </section>
  );
}
