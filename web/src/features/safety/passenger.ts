import { create } from "zustand";
import { core, useCore } from "../../core/store";
import { emit, on } from "../../core/bus";
import { safetySettings } from "./settings";

/**
 * Mode « passager » : si le véhicule roule (> 15 km/h) et qu'on commence à taper (recherche,
 * saisie…), on demande une fois par trajet « Tu es passager ? ».
 *
 * UTILITAIRE POUR LES AUTRES MODULES (sans importer ce dossier) — deux façons équivalentes :
 *
 *   // 1. via window.osamaps (disponible après le démarrage)
 *   const r = await window.osamaps.safety.passengerCheck();   // "stopped" | "passenger" | "driver"
 *
 *   // 2. via un évènement DOM (aucune dépendance, marche même si le module safety est absent :
 *   //    sans réponse, considérer « stopped »)
 *   window.dispatchEvent(new CustomEvent("osamaps:passenger-check", { detail: { reply: (r) => … } }));
 *
 * Réponses : "stopped" (à l'arrêt ou < 15 km/h, ou réglage désactivé : rien à demander),
 * "passenger" (l'utilisateur confirme qu'il est passager pour ce trajet), "driver" (il conduit :
 * mieux vaut ne pas ouvrir de saisie). La question n'est posée qu'une fois par trajet ; ensuite la
 * réponse mémorisée est renvoyée directement.
 *
 * En plus, ce module surveille tout seul le focus des champs texte de l'app (focusin) : les modules
 * n'ont rien à faire pour profiter de la protection de base.
 */
export type PassengerAnswer = "stopped" | "passenger" | "driver";

export const usePassenger = create<{ open: boolean }>(() => ({ open: false }));

const SPEED_MIN = 15 / 3.6;
let answer: "passenger" | "driver" | null = null;
let waiters: ((r: PassengerAnswer) => void)[] = [];
let stoppedSince = 0;

function moving() {
  return (core().position?.speed ?? 0) > SPEED_MIN;
}

export function passengerCheck(): Promise<PassengerAnswer> {
  if (!safetySettings().passenger || !moving()) return Promise.resolve("stopped");
  if (answer) return Promise.resolve(answer);
  return new Promise((resolve) => {
    waiters.push(resolve);
    usePassenger.setState({ open: true });
  });
}

/** Appelé par l'overlay. */
export function answerPassenger(r: "passenger" | "driver") {
  answer = r;
  usePassenger.setState({ open: false });
  const w = waiters;
  waiters = [];
  w.forEach((f) => f(r));
}

function resetTrip() {
  answer = null;
}

function isTextField(el: EventTarget | null): el is HTMLInputElement | HTMLTextAreaElement {
  if (!(el instanceof HTMLElement)) return false;
  if (el.closest(".safety-passenger")) return false;
  if (el instanceof HTMLTextAreaElement) return true;
  if (el instanceof HTMLInputElement) return ["text", "search", "email", "url", "tel", ""].includes(el.type);
  return el.isContentEditable;
}

export function startPassengerWatch() {
  const offs: (() => void)[] = [];

  const onFocus = (e: FocusEvent) => {
    const el = e.target;
    if (!isTextField(el) || answer === "passenger" || !safetySettings().passenger || !moving()) return;
    if (answer === "driver") return; // déjà demandé pendant ce trajet : on ne harcèle pas
    el.blur(); // pas de saisie pendant que la question est posée
    passengerCheck().then((r) => {
      if (r === "passenger") el.focus();
      else if (r === "driver") emit("toast", { text: "D'accord, garde les yeux sur la route : la saisie attendra l'arrêt.", tone: "info" });
    });
  };
  document.addEventListener("focusin", onFocus);
  offs.push(() => document.removeEventListener("focusin", onFocus));

  const onEvent = (e: Event) => {
    const reply = (e as CustomEvent<{ reply?: (r: PassengerAnswer) => void }>).detail?.reply;
    passengerCheck().then((r) => reply?.(r));
  };
  window.addEventListener("osamaps:passenger-check", onEvent);
  offs.push(() => window.removeEventListener("osamaps:passenger-check", onEvent));

  // nouveau trajet : début de navigation, ou arrêt de plus de 5 minutes
  offs.push(useCore.subscribe((s, prev) => { if (s.mode === "drive" && prev.mode !== "drive") resetTrip(); }));
  offs.push(on("geo:tick", ({ speed }) => {
    if ((speed ?? 0) < 1) {
      stoppedSince ||= Date.now();
      if (Date.now() - stoppedSince > 5 * 60000) resetTrip();
    } else stoppedSince = 0;
  }));

  const w = window as unknown as { osamaps?: Record<string, unknown> };
  if (w.osamaps) w.osamaps.safety = { ...(w.osamaps.safety as object), passengerCheck };

  return () => offs.forEach((f) => f());
}
