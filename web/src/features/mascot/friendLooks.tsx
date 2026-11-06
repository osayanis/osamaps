import { useEffect } from "react";
import { create } from "zustand";
import { flushSync } from "react-dom";
import { createRoot } from "react-dom/client";
import { api } from "../../core/services";
import { cleanLook, type Look } from "./look";
import { Mascot } from "./Mascot";

/**
 * Les apparences des amis (`GET /mascot/looks?pids=…`), pour le module friends : liste, fiche, carte.
 * `faces` : la tête déjà dessinée en SVG (texte), pour les marqueurs DOM de la carte.
 */
interface FriendLooks {
  looks: Record<string, Look>;
  faces: Record<string, string>;
}

export const useFriendLooks = create<FriendLooks>(() => ({ looks: {}, faces: {} }));

const asked = new Map<string, number>();
let queue = new Set<string>();
let timer = 0;

/** Demande l'apparence d'un ami (regroupé toutes les 250 ms, au plus une fois toutes les 5 min par ami). */
export function wantFriendLook(pid: string | undefined) {
  if (!pid) return;
  const t = asked.get(pid);
  if (t && Date.now() - t < 300_000) return;
  asked.set(pid, Date.now());
  queue.add(pid);
  if (!timer) timer = window.setTimeout(flush, 250);
}

async function flush() {
  timer = 0;
  const pids = [...queue].slice(0, 50);
  queue = new Set([...queue].slice(50));
  if (queue.size) timer = window.setTimeout(flush, 250);
  try {
    const r = await api<{ looks?: Record<string, unknown> }>(`mascot/looks?pids=${pids.map(encodeURIComponent).join(",")}`);
    const looks = { ...useFriendLooks.getState().looks };
    const faces = { ...useFriendLooks.getState().faces };
    for (const [pid, v] of Object.entries(r.looks ?? {})) {
      const look = cleanLook(v);
      if (JSON.stringify(looks[pid]) === JSON.stringify(look)) continue;
      looks[pid] = look;
      faces[pid] = headSvg(look, pid);
    }
    useFriendLooks.setState({ looks, faces });
  } catch {
    for (const p of pids) asked.set(p, Date.now() - 240_000); // on réessaiera dans une minute
  }
}

/** Dessine la tête une fois, hors de l'arbre React, et garde le SVG en texte. */
function headSvg(look: Look, pid: string): string {
  const div = document.createElement("div");
  const root = createRoot(div, { identifierPrefix: `ami${pid.replace(/\W/g, "")}` });
  flushSync(() => root.render(<Mascot crop="head" size={32} style={look} blink={false} />));
  const svg = div.innerHTML;
  root.unmount();
  return svg;
}

/** Apparence connue d'un ami (et la demande au serveur si besoin). */
export function useFriendLook(pid: string | undefined): Look | undefined {
  const look = useFriendLooks((s) => (pid ? s.looks[pid] : undefined));
  useEffect(() => wantFriendLook(pid), [pid]);
  return look;
}
