import { useEffect } from "react";
import { titleOf } from "./catalog";
import { Icon, KindDisc } from "./Icon";
import { useReports, vote } from "./state";

const ASK_MS = 9000;

/** « Toujours là ? » en conduite (slot hud) : gros boutons Oui / Non, disparaît tout seul. */
export function AskCard() {
  const ask = useReports((s) => s.ask);
  const r = useReports((s) => (s.ask ? s.items[s.ask.id] : undefined));

  useEffect(() => {
    if (!ask) return;
    const t = window.setTimeout(() => useReports.setState((s) => (s.ask?.id === ask.id ? { ask: null } : s)), Math.max(0, ask.at + ASK_MS - Date.now()));
    return () => window.clearTimeout(t);
  }, [ask]);

  if (!ask || !r) return null;
  return (
    <div className="reports-ask glass" role="dialog" aria-label="Toujours là ?">
      <div className="reports-ask-top">
        <KindDisc kind={r.type} sub={r.sub} size={44} />
        <div>
          <strong>{titleOf(r.type, r.sub)}</strong>
          <span>Toujours là ?</span>
        </div>
      </div>
      <div className="reports-ask-actions">
        <button className="pill reports-big" onClick={() => void vote(r.id, "still")}><Icon name="check" size={22} />Oui</button>
        <button className="pill secondary reports-big" onClick={() => void vote(r.id, "gone")}><Icon name="x" size={22} />Non</button>
      </div>
      <i className="reports-ask-timer" key={ask.id} style={{ animationDuration: `${Math.max(0, ask.at + ASK_MS - Date.now())}ms` }} />
    </div>
  );
}
