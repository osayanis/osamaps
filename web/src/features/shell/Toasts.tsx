import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { useCore } from "../../core/store";
import { useToasts, type Toast } from "./toastStore";
import { useOnline, useTopInset } from "./layout";
import { NAMED_ICONS, IconCheck, IconInfo, IconWarn, IconWifiOff, IconClose } from "./icons";

const GAP = 8;

/**
 * Pile de toasts en haut de l'écran (sous la recherche, ou sous le HUD en conduite), plus la
 * bannière hors ligne. Entrée et sortie par le haut, glisser vers le haut ou sur le côté pour fermer.
 */
export function Toasts() {
  const toasts = useToasts((s) => s.toasts);
  const online = useOnline();
  const mode = useCore((s) => s.mode);
  const top = useTopInset();
  const [heights, setHeights] = useState<Record<number, number>>({});

  let y = 0;
  const placed = toasts.map((t) => {
    const at = y;
    if (!t.leaving) y += (heights[t.key] ?? 60) + GAP;
    return { t, y: at };
  });

  return (
    <div className="shell-toasts" style={{ top }}>
      {!online && (
        <div className="shell-offline glass" role="status">
          <IconWifiOff size={18} />
          <span>
            <b>Pas de réseau</b>
            {mode === "drive"
              ? " — le guidage continue avec l’itinéraire déjà chargé."
              : " — la carte déjà affichée reste utilisable, le reste revient avec le réseau."}
          </span>
        </div>
      )}
      <div className="shell-toast-area" role="status" aria-live="polite">
        {placed.map(({ t, y }) => (
          <ToastItem key={t.key} t={t} y={y}
            onHeight={(h) => setHeights((m) => (m[t.key] === h ? m : { ...m, [t.key]: h }))} />
        ))}
      </div>
    </div>
  );
}

function ToneIcon({ t }: { t: Toast }) {
  const Named = t.icon ? NAMED_ICONS[t.icon] : undefined;
  if (Named) return <Named size={20} />;
  if (t.icon && t.icon.length <= 3) return <span className="shell-toast-glyph">{t.icon}</span>;
  if (t.tone === "good") return <IconCheck size={20} />;
  if (t.tone === "warn") return <IconWarn size={20} />;
  return <IconInfo size={20} />;
}

function ToastItem({ t, y, onHeight }: { t: Toast; y: number; onHeight: (h: number) => void }) {
  const { dismiss, remove } = useToasts.getState();
  const ref = useRef<HTMLDivElement>(null);
  const [drag, setDrag] = useState<{ x: number; y: number } | null>(null);
  const [exit, setExit] = useState<"up" | "left" | "right">("up");
  const [paused, setPaused] = useState(false);
  const start = useRef<{ x: number; y: number; t: number } | null>(null);

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    onHeight(el.offsetHeight);
    const ro = new ResizeObserver(() => onHeight(el.offsetHeight));
    ro.observe(el);
    return () => ro.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // disparition automatique (en pause pendant un appui / survol / onglet caché)
  const remaining = useRef(t.duration);
  useEffect(() => {
    if (t.leaving || paused || t.duration <= 0) return;
    let begin = Date.now();
    let timer = window.setTimeout(() => dismiss(t.key), remaining.current);
    const vis = () => {
      if (document.hidden) { window.clearTimeout(timer); remaining.current -= Date.now() - begin; }
      else { begin = Date.now(); timer = window.setTimeout(() => dismiss(t.key), Math.max(800, remaining.current)); }
    };
    document.addEventListener("visibilitychange", vis);
    return () => {
      window.clearTimeout(timer);
      remaining.current -= Date.now() - begin;
      document.removeEventListener("visibilitychange", vis);
    };
  }, [t.leaving, paused, t.duration, t.key, dismiss]);

  // retrait du DOM après l'animation de sortie
  useEffect(() => {
    if (!t.leaving) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const timer = window.setTimeout(() => remove(t.key), reduce ? 10 : 220);
    return () => window.clearTimeout(timer);
  }, [t.leaving, t.key, remove]);

  const onPointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest("button")) return;
    start.current = { x: e.clientX, y: e.clientY, t: performance.now() };
    setPaused(true);
    (e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
  };
  const onPointerMove = (e: React.PointerEvent) => {
    if (!start.current) return;
    const dx = e.clientX - start.current.x;
    const dy = e.clientY - start.current.y;
    // vers le bas : résistance (on ne tire pas un toast vers le bas)
    setDrag({ x: Math.abs(dx) > Math.abs(dy) ? dx : 0, y: dy < 0 ? dy : dy * 0.15 });
  };
  const onPointerUp = () => {
    const s = start.current;
    start.current = null;
    setPaused(false);
    if (!s || !drag) { setDrag(null); return; }
    const dt = Math.max(1, performance.now() - s.t);
    const fast = Math.hypot(drag.x, drag.y) / dt > 0.5;
    if (drag.y < -28 || (fast && drag.y < -8)) { setExit("up"); dismiss(t.key); }
    else if (Math.abs(drag.x) > 90 || (fast && Math.abs(drag.x) > 20)) { setExit(drag.x > 0 ? "right" : "left"); dismiss(t.key); }
    else setDrag(null);
  };

  const style: React.CSSProperties = { transform: `translateY(${y}px)` };
  const innerStyle: React.CSSProperties | undefined = drag && !t.leaving
    ? { transform: `translate(${drag.x}px, ${drag.y}px)`, transition: "none", opacity: 1 - Math.min(0.6, Math.abs(drag.x) / 300) }
    : drag && t.leaving
      ? ({ "--from-x": `${drag.x}px`, "--from-y": `${drag.y}px` } as React.CSSProperties)
      : undefined;

  return (
    <div className="shell-toast-slot" style={style}>
      <div ref={ref}
        className={`shell-toast glass tone-${t.tone ?? "info"}${t.leaving ? ` leaving exit-${exit}` : ""}`}
        style={innerStyle}
        role={t.tone === "warn" ? "alert" : undefined}
        onPointerDown={onPointerDown} onPointerMove={onPointerMove} onPointerUp={onPointerUp} onPointerCancel={onPointerUp}
        onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(false)}>
        <span className="shell-toast-icon"><ToneIcon t={t} /></span>
        <div className="shell-toast-text">
          <span>{t.text}</span>
          {t.detail && <small>{t.detail}</small>}
          {t.actions && t.actions.length > 0 && (
            <div className="shell-toast-actions">
              {t.actions.map((a) => (
                <button key={a.label} className={a.primary ? "pill shell-toast-btn" : "btn-ghost shell-toast-btn"}
                  onClick={() => { a.run(); dismiss(t.key); }}>
                  {a.label}
                </button>
              ))}
            </div>
          )}
        </div>
        {(t.actions?.length || t.duration <= 0) ? (
          <button className="shell-toast-close" aria-label="Fermer" onClick={() => dismiss(t.key)}><IconClose size={16} /></button>
        ) : null}
      </div>
    </div>
  );
}
