import { create } from "zustand";
import { on, type BusEvents } from "../../core/bus";
import { haptic } from "./haptics";

/**
 * File des toasts. Les autres modules passent par le bus :
 *   emit("toast", { text: "Signalement envoyé", icon: "check", tone: "good" })
 * Champs facultatifs acceptés en plus (pas encore typés dans core/bus.ts — voir rapport) :
 *   id        — remplace un toast déjà affiché avec le même id (pas de doublons)
 *   duration  — durée d'affichage en ms (défaut 3,5 s ; 5 s pour tone "warn")
 * `icon` : un nom de NAMED_ICONS (check, info, warn, offline, route, users, flag, pin, speed…).
 */
export interface ToastAction { label: string; run: () => void; primary?: boolean }
export interface Toast {
  key: number;
  /** Horodatage de création (ms). */
  at: number;
  id?: string;
  text: string;
  detail?: string;
  icon?: string;
  tone?: "info" | "good" | "warn";
  duration: number;
  actions?: ToastAction[];
  leaving?: boolean;
  /** Mise en avant (installation, mise à jour) : ne disparaît pas tout seul si duration = 0. */
  sticky?: boolean;
}

interface ToastState {
  toasts: Toast[];
  push: (t: Omit<Toast, "key" | "duration" | "at"> & { duration?: number }) => number;
  dismiss: (key: number) => void;
  remove: (key: number) => void;
}

let seq = 0;
const MAX = 3;

export const useToasts = create<ToastState>((set, get) => ({
  toasts: [],
  push: (t) => {
    const duration = t.duration ?? (t.actions?.length ? 8000 : t.tone === "warn" ? 5000 : 3500);
    const key = ++seq;
    const at = Date.now();
    const toast: Toast = { ...t, key, at, duration };
    const list = get().toasts.filter((x) => !x.leaving);
    // même id, ou même texte affiché il y a moins de 2 s → on remplace au lieu d'empiler
    const dup = list.find((x) => (t.id && x.id === t.id) || (!t.id && x.text === t.text && at - x.at < 2000));
    let next = get().toasts.map((x) => (dup && x.key === dup.key ? { ...x, leaving: true } : x));
    next = [toast, ...next];
    // au-delà de MAX visibles, les plus anciens s'en vont
    const visible = next.filter((x) => !x.leaving);
    if (visible.length > MAX) {
      const drop = new Set(visible.slice(MAX).map((x) => x.key));
      next = next.map((x) => (drop.has(x.key) ? { ...x, leaving: true } : x));
    }
    set({ toasts: next });
    return key;
  },
  dismiss: (key) => set({ toasts: get().toasts.map((x) => (x.key === key ? { ...x, leaving: true } : x)) }),
  remove: (key) => set({ toasts: get().toasts.filter((x) => x.key !== key) }),
}));

export const toast = (t: Parameters<ToastState["push"]>[0]) => useToasts.getState().push(t);

/** Branche le bus : emit("toast", …) → pile de toasts. */
export function listenToasts(): () => void {
  return on("toast", (p: BusEvents["toast"] & { id?: unknown; duration?: unknown }) => {
    if (!p || typeof p.text !== "string" || !p.text.trim()) return;
    if (p.tone === "warn") haptic("warn");
    toast({
      text: p.text.slice(0, 160),
      icon: typeof p.icon === "string" ? p.icon : undefined,
      tone: p.tone,
      id: typeof p.id === "string" ? p.id : undefined,
      duration: typeof p.duration === "number" ? Math.min(Math.max(p.duration, 1500), 20000) : undefined,
    });
  });
}
