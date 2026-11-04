import { create } from "zustand";
import { BASE } from "../../core/services";
import { core } from "../../core/store";
import { loadLocal, saveLocal } from "../../core/identity";
import { prefs } from "../../core/prefs";
import { toast } from "./toastStore";

/**
 * PWA : service worker (public/sw.js), avis de mise à jour, invitation à installer.
 *
 * Le service worker n'est enregistré qu'en production (`npm run build` + `vite preview` pour
 * tester) : en dev, Vite sert des modules qui changent à chaque sauvegarde. En dev, un éventuel
 * ancien service worker est désinscrit.
 */

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

interface PwaState {
  /** Chrome/Edge/Android : l'invite d'installation native est disponible. */
  installEvent: BeforeInstallPromptEvent | null;
  /** Déjà lancée comme app installée. */
  standalone: boolean;
  /** iPhone / iPad dans Safari (pas d'invite native : instructions Partager → Sur l'écran d'accueil). */
  ios: boolean;
  set: (p: Partial<PwaState>) => void;
}

const isStandalone = () =>
  window.matchMedia("(display-mode: standalone)").matches ||
  (navigator as unknown as { standalone?: boolean }).standalone === true;
const isIos = () =>
  /iPhone|iPad|iPod/.test(navigator.userAgent) ||
  (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1); // iPadOS se fait passer pour un Mac

export const usePwa = create<PwaState>((set) => ({
  installEvent: null,
  standalone: isStandalone(),
  ios: isIos(),
  set: (p) => set(p),
}));

/** Lance l'installation (Chrome/Android) ou affiche les instructions iOS. */
export async function installApp() {
  const { installEvent, ios } = usePwa.getState();
  if (installEvent) {
    await installEvent.prompt();
    const { outcome } = await installEvent.userChoice.catch(() => ({ outcome: "dismissed" as const }));
    usePwa.getState().set({ installEvent: null });
    if (outcome === "accepted") toast({ text: "OsaMaps est installé", icon: "check", tone: "good" });
    return;
  }
  if (ios) showIosHelp();
}

function showIosHelp() {
  toast({
    id: "shell-install",
    text: "Installer OsaMaps sur l’iPhone",
    detail: "Dans Safari, touche Partager puis « Sur l’écran d’accueil ».",
    icon: "share",
    duration: 12000,
  });
}

/** Peut-on proposer l'installation ici ? */
export function canInstall(s = usePwa.getState()) {
  return !s.standalone && (s.installEvent != null || s.ios);
}

/** Invitation discrète, une fois : après 45 s d'utilisation, hors conduite, pas plus d'une fois
 *  toutes les 2 semaines, et plus jamais après deux refus. */
function scheduleInvite(): () => void {
  const t = window.setTimeout(function tryInvite() {
    const s = usePwa.getState();
    const seen = loadLocal<{ at: number; count: number }>("shell.installInvite", { at: 0, count: 0 });
    if (!canInstall(s) || seen.count >= 2 || Date.now() - seen.at < 14 * 86400_000) return;
    if (!prefs().onboarded || core().mode === "drive" || core().settingsOpen) {
      window.setTimeout(tryInvite, 30_000);
      return;
    }
    saveLocal("shell.installInvite", { at: Date.now(), count: seen.count + 1 });
    toast({
      id: "shell-install",
      text: "Installer OsaMaps",
      detail: s.ios ? "Plein écran, lancé depuis l’écran d’accueil comme une vraie app." : "Plein écran, et ça s’ouvre comme une vraie app.",
      icon: "download",
      duration: 12000,
      actions: [
        { label: "Plus tard", run: () => {} },
        { label: s.ios ? "Comment ?" : "Installer", primary: true, run: () => { void installApp(); } },
      ],
    });
  }, 45_000);
  return () => window.clearTimeout(t);
}

/** Démarre tout ce qui concerne la PWA. Appelé par init(). */
export function startPwa(): () => void {
  const onPrompt = (e: Event) => {
    e.preventDefault(); // on garde l'invite pour notre propre bouton, plus discret
    usePwa.getState().set({ installEvent: e as BeforeInstallPromptEvent });
  };
  const onInstalled = () => usePwa.getState().set({ installEvent: null, standalone: true });
  window.addEventListener("beforeinstallprompt", onPrompt);
  window.addEventListener("appinstalled", onInstalled);
  const stopInvite = scheduleInvite();
  registerServiceWorker();
  return () => {
    window.removeEventListener("beforeinstallprompt", onPrompt);
    window.removeEventListener("appinstalled", onInstalled);
    stopInvite();
  };
}

let registered = false;

function registerServiceWorker() {
  if (!("serviceWorker" in navigator) || registered) return;
  registered = true;
  if (import.meta.env.DEV) {
    navigator.serviceWorker.getRegistrations().then((rs) => rs.forEach((r) => r.unregister())).catch(() => {});
    return;
  }
  // le service worker prévient quand il a trouvé une nouvelle version de l'app en arrière-plan
  navigator.serviceWorker.addEventListener("message", (e) => {
    if (e.data?.type === "osamaps:update") announceUpdate();
  });
  // …et s'il l'a trouvée avant que la page n'écoute, il répond à ce bonjour
  navigator.serviceWorker.ready.then(() => navigator.serviceWorker.controller?.postMessage({ type: "osamaps:hello" })).catch(() => {});
  navigator.serviceWorker.register(`${BASE}sw.js`, { scope: BASE }).then((reg) => {
    // revérifie sw.js de temps en temps quand l'app reste ouverte longtemps
    window.setInterval(() => { reg.update().catch(() => {}); }, 60 * 60_000);
  }).catch((e) => console.warn("[shell] service worker", e));
}

let announced = false;
function announceUpdate() {
  if (announced) return;
  announced = true;
  const show = () => toast({
    id: "shell-update",
    text: "Nouvelle version d’OsaMaps",
    icon: "refresh",
    duration: 0,
    actions: [{ label: "Recharger", primary: true, run: () => location.reload() }],
  });
  // pas pendant une conduite : on attend l'arrêt pour ne pas distraire
  if (core().mode !== "drive") { show(); return; }
  const t = window.setInterval(() => { if (core().mode !== "drive") { window.clearInterval(t); show(); } }, 10_000);
}

/** Efface toutes les données locales d'OsaMaps (réglages, identité, caches) puis recharge. */
export async function wipeLocalData() {
  try {
    const keys: string[] = [];
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && k.startsWith("osamaps")) keys.push(k);
    }
    keys.forEach((k) => localStorage.removeItem(k));
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const k = sessionStorage.key(i);
      if (k && k.startsWith("osamaps")) sessionStorage.removeItem(k);
    }
  } catch { /* stockage bloqué */ }
  try {
    if ("caches" in window) {
      const names = await caches.keys();
      await Promise.all(names.filter((n) => n.startsWith("osamaps")).map((n) => caches.delete(n)));
    }
  } catch { /* ignore */ }
  location.replace(BASE);
}
