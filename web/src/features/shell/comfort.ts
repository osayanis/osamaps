import { useCore, core } from "../../core/store";
import { emit, on } from "../../core/bus";
import { prefs } from "../../core/prefs";
import { haptic } from "./haptics";
import { toast } from "./toastStore";

/**
 * Confort de conduite : écran toujours allumé en conduite, retours haptiques automatiques,
 * annonce du retour du réseau, raccourcis clavier sur ordinateur.
 */

// ——— Wake Lock : l'écran ne s'éteint pas pendant la conduite ————————————————————————
interface WakeLockSentinelLike { release: () => Promise<void>; released: boolean; addEventListener: (t: "release", f: () => void) => void }

export function startWakeLock(): () => void {
  const wl = (navigator as unknown as { wakeLock?: { request: (t: "screen") => Promise<WakeLockSentinelLike> } }).wakeLock;
  if (!wl) return () => {};
  let sentinel: WakeLockSentinelLike | null = null;
  let wanted = false;

  const acquire = async () => {
    if (!wanted || document.hidden || (sentinel && !sentinel.released)) return;
    try {
      sentinel = await wl.request("screen");
      sentinel.addEventListener("release", () => { sentinel = null; });
    } catch { /* refusé (batterie faible, onglet en arrière-plan) */ }
  };
  const release = () => { sentinel?.release().catch(() => {}); sentinel = null; };

  const sync = (driving: boolean) => {
    wanted = driving;
    if (driving) void acquire(); else release();
  };
  sync(core().mode === "drive");
  const unsub = useCore.subscribe((s, p) => { if (s.mode !== p.mode) sync(s.mode === "drive"); });
  // le verrou saute quand l'onglet passe en arrière-plan : on le reprend au retour
  const vis = () => { if (!document.hidden) void acquire(); };
  document.addEventListener("visibilitychange", vis);
  return () => { unsub(); document.removeEventListener("visibilitychange", vis); release(); };
}

// ——— Haptique et réseau, branchés sur les évènements existants ——————————————————————
export function startComfortEvents(): () => void {
  const offs = [
    on("drive:alert", (a) => { if (a.tone === "warn" || a.tone === "danger") haptic("warn"); }),
    on("drive:arrived", () => haptic("success")),
    on("drive:start", () => haptic("tap")),
  ];
  const offline = () => haptic("error");
  const online = () => toast({ id: "shell-online", text: "De retour en ligne", icon: "online", tone: "good", duration: 2500 });
  window.addEventListener("offline", offline);
  window.addEventListener("online", online);
  return () => {
    offs.forEach((f) => f());
    window.removeEventListener("offline", offline);
    window.removeEventListener("online", online);
  };
}

// ——— Raccourcis clavier (ordinateur) ———————————————————————————————————————————————
/**
 *   /  ou  ⌘K / Ctrl+K   ouvrir la recherche → évènement fenêtre « osamaps:search »
 *                        (le module search l'écoute et met le focus sur son champ ; s'il ne fait
 *                        pas `preventDefault()`, le shell met le focus sur le premier champ du slot top)
 *   R                    recentrer (emit "map:recenter")
 *   Échap                fermer : réglages, sinon le panneau ouvert, sinon quitter le champ actif
 * Désactivés tant que l'accueil est affiché, et pendant la saisie (sauf Échap et ⌘K).
 */
export const SEARCH_EVENT = "osamaps:search";

function isTyping(el: EventTarget | null) {
  const n = el as HTMLElement | null;
  return !!n && (n.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(n.tagName));
}

export function startKeyboard(): () => void {
  const onKey = (e: KeyboardEvent) => {
    if (!prefs().onboarded || e.defaultPrevented) return;
    const typing = isTyping(e.target);
    const k = e.key;

    if ((e.metaKey || e.ctrlKey) && k.toLowerCase() === "k") {
      e.preventDefault();
      openSearch();
      return;
    }
    if (k === "Escape") {
      const s = core();
      if (s.settingsOpen) { s.set({ settingsOpen: false }); e.preventDefault(); return; }
      if (typing) { (e.target as HTMLElement).blur(); return; }
      if (s.panel) { s.openPanel(null); e.preventDefault(); }
      return;
    }
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
    if (k === "/") { e.preventDefault(); openSearch(); return; }
    if (k === "r" || k === "R") {
      if (core().settingsOpen) return;
      emit("map:recenter", {});
    }
  };
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}

function openSearch() {
  const s = core();
  if (s.settingsOpen) s.set({ settingsOpen: false });
  if (s.mode === "drive") return; // pas de recherche plein écran en conduite (slot top masqué)
  const ev = new CustomEvent(SEARCH_EVENT, { cancelable: true });
  window.dispatchEvent(ev);
  if (ev.defaultPrevented) return;
  // personne n'a pris la main : on met le focus sur le premier champ de la recherche
  window.setTimeout(() => document.querySelector<HTMLInputElement>(".slot-top input, .slot-top [contenteditable]")?.focus(), 0);
}
