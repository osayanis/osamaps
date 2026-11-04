import { useEffect, useState, useSyncExternalStore } from "react";
import { useCore } from "../../core/store";

/**
 * Mise en page : sur grand écran (≥ 900 px) ou téléphone en paysage, le panneau du bas devient un
 * panneau latéral gauche. Le shell pose la classe `osa-side` sur <html> (sinon `osa-stack`) ;
 * tout le CSS correspondant est dans shell.css (aucune modification des styles communs).
 * Les modules peuvent s'en servir : `html.osa-side .monmodule-… { … }`.
 */
const SIDE_QUERY = "(min-width: 900px), (orientation: landscape) and (max-height: 520px) and (min-width: 600px)";

function subscribeSide(cb: () => void) {
  const mq = window.matchMedia(SIDE_QUERY);
  mq.addEventListener("change", cb);
  return () => mq.removeEventListener("change", cb);
}
const getSide = () => window.matchMedia(SIDE_QUERY).matches;

export function useSideLayout(): boolean {
  return useSyncExternalStore(subscribeSide, getSide, () => false);
}

/** Pose/retire la classe sur <html>. Appelé une fois par init(). */
export function startLayoutClass(): () => void {
  const html = document.documentElement;
  const apply = () => {
    const side = getSide();
    html.classList.toggle("osa-side", side);
    html.classList.toggle("osa-stack", !side);
  };
  apply();
  const unsub = subscribeSide(apply);
  return () => { unsub(); html.classList.remove("osa-side", "osa-stack"); };
}

/** En ligne / hors ligne. */
function subscribeOnline(cb: () => void) {
  window.addEventListener("online", cb);
  window.addEventListener("offline", cb);
  return () => { window.removeEventListener("online", cb); window.removeEventListener("offline", cb); };
}
export function useOnline(): boolean {
  return useSyncExternalStore(subscribeOnline, () => navigator.onLine, () => true);
}

/** Marge de sécurité en haut (encoche), mesurée avec une sonde CSS env(). */
export function safeTop(): number {
  const probe = document.createElement("div");
  probe.style.cssText = "position:fixed;top:0;left:0;width:0;visibility:hidden;pointer-events:none;height:env(safe-area-inset-top, 0px)";
  document.body.appendChild(probe);
  const h = probe.getBoundingClientRect().height;
  probe.remove();
  return h;
}

/**
 * Hauteur occupée en haut de l'écran par la recherche (slot top) ou le HUD de conduite (slot hud),
 * pour poser les toasts juste dessous sans rien masquer. Mesurée en direct (ResizeObserver).
 */
export function useTopInset(): number {
  const mode = useCore((s) => s.mode);
  const side = useSideLayout();
  const [inset, setInset] = useState(12);
  useEffect(() => {
    const measure = () => {
      const safe = safeTop();
      if (side) { setInset(12 + safe); return; }
      const el = document.querySelector<HTMLElement>(mode === "drive" ? ".slot-hud" : ".slot-top");
      const r = el?.getBoundingClientRect();
      setInset(r && r.height > 0 ? Math.round(r.bottom + 8) : 12 + safe);
    };
    measure();
    const ro = new ResizeObserver(measure);
    const watch = () => document.querySelectorAll(".slot-top, .slot-hud").forEach((n) => ro.observe(n));
    watch();
    // les slots apparaissent/disparaissent selon le mode : on réobserve un peu après
    const t = window.setTimeout(() => { watch(); measure(); }, 120);
    window.addEventListener("resize", measure);
    return () => { ro.disconnect(); window.clearTimeout(t); window.removeEventListener("resize", measure); };
  }, [mode, side]);
  return inset;
}
