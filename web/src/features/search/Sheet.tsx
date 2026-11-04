import { useRef, type ReactNode, type PointerEvent } from "react";

/**
 * Panneau du bas commun au module : poignée, glisser vers le bas pour fermer (ou replier),
 * entrée courte en translateY. Tout le contenu est fourni par l'appelant.
 */
export function Sheet({
  children, className = "", onClose, onExpand, ariaLabel,
}: {
  children: ReactNode;
  className?: string;
  /** Glissé vers le bas au-delà du seuil. */
  onClose?: () => void;
  /** Glissé vers le haut (true), vers le bas (false), ou tap sur la poignée (null = basculer). */
  onExpand?: (up: boolean | null) => void;
  ariaLabel?: string;
}) {
  const el = useRef<HTMLElement>(null);
  const drag = useRef<{ y: number; t: number; dy: number } | null>(null);

  const down = (e: PointerEvent) => {
    drag.current = { y: e.clientY, t: performance.now(), dy: 0 };
    (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
  };
  const move = (e: PointerEvent) => {
    const d = drag.current;
    if (!d || !el.current) return;
    d.dy = e.clientY - d.y;
    // vers le haut : résistance ; vers le bas : suit le doigt
    const y = d.dy > 0 ? d.dy : d.dy * 0.25;
    el.current.style.transition = "none";
    el.current.style.transform = `translateY(${y}px)`;
  };
  const up = () => {
    const d = drag.current;
    drag.current = null;
    if (!d || !el.current) return;
    const v = d.dy / Math.max(1, performance.now() - d.t); // px/ms
    el.current.style.transition = "";
    el.current.style.transform = "";
    if (Math.abs(d.dy) < 6) { onExpand?.(null); return; }
    if (d.dy > 70 || v > 0.6) { if (onExpand) onExpand(false); else onClose?.(); }
    else if (d.dy < -30 || v < -0.4) onExpand?.(true);
  };

  return (
    <section ref={el} className={`search-sheet glass ${className}`} aria-label={ariaLabel}>
      <div
        className="search-handle"
        onPointerDown={down}
        onPointerMove={move}
        onPointerUp={up}
        onPointerCancel={up}
        role="presentation"
      >
        <span />
      </div>
      {children}
    </section>
  );
}
