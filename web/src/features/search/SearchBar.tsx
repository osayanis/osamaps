import { useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { core, useCore } from "../../core/store";
import { parseCoords, searchPlaces, norm, type SearchResult } from "./api";
import { CATEGORIES } from "./categories";
import { closeCategory, runCategory } from "./nearby";
import { Icon } from "./icons";
import { distanceLabel, kindIcon } from "./format";
import {
  PICK_LABEL, addRecent, completePick, goTo, openPlace, removeRecent, useSearch, type Saved,
} from "./state";

/** Une ligne de la liste (résultat distant, lieu enregistré ou action). */
interface Row {
  key: string;
  icon: string;
  title: string;
  sub?: string;
  /** Badge à droite (distance). */
  meta?: string | null;
  tone?: "accent";
  place?: Saved;
  /** Raccourci : départ direct sans fiche (Maison, Travail). */
  direct?: boolean;
  action?: () => void;
  removable?: boolean;
}

type Status = "idle" | "loading" | "done" | "error";

export function SearchBar() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const position = useCore((s) => s.position);
  const { query, focused, picking, category, home, work, favorites, recents, set } = useSearch();
  const input = useRef<HTMLInputElement>(null);
  const [results, setResults] = useState<SearchResult[]>([]);
  const [status, setStatus] = useState<Status>("idle");
  const [active, setActive] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);

  // recherche distante : debounce 320 ms, annulation de la requête précédente
  useEffect(() => {
    const q = query.trim();
    if (q.length < 3 || parseCoords(q)) { setResults([]); setStatus("idle"); return; }
    setStatus("loading");
    const ctrl = new AbortController();
    const t = window.setTimeout(async () => {
      try {
        const near = core().position?.coord ?? null;
        const r = await searchPlaces(q, near, ctrl.signal);
        setResults(r);
        setStatus("done");
      } catch (e) {
        if ((e as Error).name !== "AbortError") setStatus("error");
      }
    }, 320);
    return () => { ctrl.abort(); window.clearTimeout(t); };
  }, [query]);

  useEffect(() => { if (focused) input.current?.focus(); }, [focused, picking]);
  useEffect(() => setActive(0), [query, results]);

  const rows = useMemo<Row[]>(() => {
    const q = query.trim();
    const pos = position?.coord ?? null;
    const out: Row[] = [];
    const saved = (p: Saved, icon: string, sub?: string, extra: Partial<Row> = {}): Row => ({
      key: `${icon}:${p.id}`, icon, title: p.name, sub: sub ?? p.detail, meta: distanceLabel(pos, p.coord), place: p, ...extra,
    });

    if (!q) {
      if (picking && pos) {
        out.push({
          key: "here", icon: "locate", title: "Ma position actuelle", sub: "Utiliser l'endroit où je suis", tone: "accent",
          place: { id: "here", name: picking === "favorite" ? "Position enregistrée" : "Ma position", coord: pos, kind: "address" },
        });
      }
      if (!picking) {
        if (home) out.push(saved(home, "home", home.detail ?? home.name, { title: "Maison", direct: true }));
        if (work) out.push(saved(work, "work", work.detail ?? work.name, { title: "Travail", direct: true }));
      }
      for (const r of recents.slice(0, 8)) out.push(saved(r, "clock", r.detail, { removable: true }));
      return out;
    }

    const coords = parseCoords(q);
    if (coords) {
      out.push({
        key: "coords", icon: "locate", title: `${coords[1].toFixed(5)}, ${coords[0].toFixed(5)}`, sub: "Coordonnées GPS",
        meta: distanceLabel(pos, coords),
        place: { id: `pt:${coords.join(",")}`, name: "Point GPS", coord: coords, kind: "coords" },
      });
      return out;
    }

    // lieux enregistrés qui correspondent (en tête, comme « Maison » quand on tape « mai »)
    const nq = norm(q);
    const match = (s: string) => norm(s).split(" ").some((w) => w.startsWith(nq)) || norm(s).includes(nq);
    const local: Row[] = [];
    if (home && (match("maison") || match(home.name))) local.push(saved(home, "home", home.detail ?? home.name, { title: "Maison", direct: !picking }));
    if (work && (match("travail") || match(work.name))) local.push(saved(work, "work", work.detail ?? work.name, { title: "Travail", direct: !picking }));
    for (const f of favorites) if (match(f.name) || match(f.detail ?? "")) local.push(saved(f, "star"));
    for (const r of recents) if (match(r.name)) local.push(saved(r, "clock"));
    const localTop = local.slice(0, 3);
    out.push(...localTop);

    for (const r of results) {
      if (localTop.some((l) => l.place && l.place.name === r.name && Math.abs(l.place.coord[0] - r.coord[0]) < 0.001)) continue;
      out.push({
        key: r.id, icon: kindIcon(r.kind), title: r.name,
        sub: [r.typeLabel, r.detail].filter(Boolean).join(" · "),
        meta: distanceLabel(pos, r.coord),
        place: { id: r.id, name: r.name, detail: r.detail, coord: r.coord, kind: r.kind, typeLabel: r.typeLabel },
      });
    }
    return out;
  }, [query, results, position?.coord, home, work, favorites, recents, picking]);

  if (mode !== "browse") return null;

  const close = () => {
    set({ focused: false, picking: null });
    input.current?.blur();
  };

  const choose = (row: Row) => {
    if (row.action) return row.action();
    const p = row.place;
    if (!p) return;
    if (picking) return completePick(p);
    if (row.direct) return goTo(p);
    if (row.icon !== "clock") addRecent(p);
    set({ query: row.icon === "clock" ? query : query || p.name });
    openPlace({ ...p, from: "search" });
    input.current?.blur();
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "ArrowDown") { e.preventDefault(); setActive((a) => Math.min(rows.length - 1, a + 1)); scrollActive(1); }
    else if (e.key === "ArrowUp") { e.preventDefault(); setActive((a) => Math.max(0, a - 1)); scrollActive(-1); }
    else if (e.key === "Enter") { e.preventDefault(); const r = rows[active] ?? rows[0]; if (r) choose(r); }
    else if (e.key === "Escape") { e.preventDefault(); if (query) set({ query: "" }); else close(); }
  };

  const scrollActive = (dir: number) => {
    requestAnimationFrame(() => {
      const el = listRef.current?.querySelector<HTMLElement>(`[data-i="${Math.max(0, Math.min(rows.length - 1, active + dir))}"]`);
      el?.scrollIntoView({ block: "nearest" });
    });
  };

  const showChips = !focused && (panel === null || panel === "search-results");
  const q = query.trim();

  return (
    <div className={`search-root${focused ? " is-focused" : ""}`}>
      <div className="search-bar glass" role="search">
        <button
          className="search-lead"
          aria-label={focused ? "Fermer la recherche" : "Rechercher"}
          onClick={() => (focused ? close() : set({ focused: true }))}
          tabIndex={focused ? 0 : -1}
        >
          <Icon name={focused ? "back" : "search"} size={20} />
        </button>
        <input
          ref={input}
          className="search-input"
          type="search"
          inputMode="search"
          enterKeyHint="search"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
          placeholder={picking ? PICK_LABEL[picking] : "Où allez-vous ?"}
          aria-label="Rechercher un lieu ou une adresse"
          aria-expanded={focused}
          aria-controls="search-list"
          aria-activedescendant={focused && rows[active] ? `search-row-${active}` : undefined}
          role="combobox"
          value={query}
          onChange={(e) => set({ query: e.target.value })}
          onFocus={() => { if (!focused) set({ focused: true }); }}
          onKeyDown={onKey}
        />
        {query && (
          <button className="search-clear" aria-label="Effacer" onClick={() => { set({ query: "" }); input.current?.focus(); }}>
            <Icon name="x" size={18} />
          </button>
        )}
        {focused && !query && (
          <button className="search-cancel" onClick={close}>Annuler</button>
        )}
        {status === "loading" && focused && <span className="search-progress" aria-hidden="true" />}
      </div>

      {showChips && (
        <div className="search-chips" role="toolbar" aria-label="Chercher autour">
          {CATEGORIES.map((c) => {
            const on = category?.id === c.id;
            return (
              <button
                key={c.id}
                className={`search-chip${on ? " is-on" : ""}`}
                aria-pressed={on}
                onClick={() => (on ? closeCategory() : runCategory(c.id))}
              >
                <Icon name={c.icon} size={16} />
                {c.label}
              </button>
            );
          })}
        </div>
      )}

      {focused && (
        <div className="search-panel glass" id="search-list" role="listbox" ref={listRef}>
          {picking && (
            <div className="search-picking">
              <Icon name={picking === "favorite" ? "star" : picking} size={16} />
              <span>{PICK_LABEL[picking]} : cherchez une adresse, ou appui long sur la carte.</span>
            </div>
          )}
          {!q && !rows.length && !picking && (
            <div className="search-empty">
              <Icon name="search" size={22} />
              <p>Cherchez une adresse, un commerce, une ville… ou des coordonnées GPS.</p>
            </div>
          )}
          {!q && rows.some((r) => r.icon === "clock") && <div className="search-section">Récents</div>}
          {rows.map((r, i) => (
            <div
              key={r.key}
              id={`search-row-${i}`}
              data-i={i}
              role="option"
              aria-selected={i === active}
              className={`search-row${i === active ? " is-active" : ""}${r.tone ? " is-accent" : ""}`}
              onMouseEnter={() => setActive(i)}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => choose(r)}
            >
              <span className="search-row-icon"><Icon name={r.icon} size={18} /></span>
              <span className="search-row-text">
                <span className="search-row-title">{r.title}</span>
                {r.sub && <span className="search-row-sub">{r.sub}</span>}
              </span>
              {r.meta && <span className="search-row-meta">{r.meta}</span>}
              {r.removable && r.place && (
                <button
                  className="search-row-remove"
                  aria-label={`Retirer ${r.title} des récents`}
                  onClick={(e) => { e.stopPropagation(); removeRecent(r.place!.id); }}
                >
                  <Icon name="x" size={14} />
                </button>
              )}
            </div>
          ))}
          {q.length > 0 && q.length < 3 && !parseCoords(q) && rows.length === 0 && (
            <div className="search-hint">Encore une lettre ou deux…</div>
          )}
          {status === "loading" && q.length >= 3 && results.length === 0 && (
            <div className="search-skeleton" aria-label="Recherche en cours">
              {[0, 1, 2].map((i) => <div key={i} className="search-skel-row"><span /><span /></div>)}
            </div>
          )}
          {status === "done" && results.length === 0 && rows.length === 0 && (
            <div className="search-hint">Aucun résultat pour « {q} ». Vérifiez l'orthographe ou ajoutez la ville.</div>
          )}
          {status === "error" && (
            <div className="search-hint is-warn">Recherche indisponible pour le moment. Vérifiez la connexion.</div>
          )}
        </div>
      )}
    </div>
  );
}
