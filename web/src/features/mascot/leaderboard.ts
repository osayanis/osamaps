import { api } from "../../core/services";
import { deviceId, nickname } from "../../core/identity";
import { useMascot, weekKey } from "./engine";

export interface Board { week: string; top: { name: string; points: number; me?: boolean }[]; rank: number | null; total: number }

/**
 * Classement hebdo (opt-in) : envoie seulement le pseudo et les points de la semaine.
 * L'identifiant d'appareil sert à ne compter qu'une ligne par personne ; le serveur ne garde
 * qu'une empreinte (sha-256) et ne le renvoie jamais.
 */
export async function syncBoard(): Promise<Board | null> {
  const s = useMascot.getState();
  if (!s.settings.leaderboard) return null;
  const wk = weekKey();
  const points = s.week.key === wk ? s.week.points : 0;
  try {
    return await api<Board>("mascot/score", {
      method: "POST",
      body: JSON.stringify({ id: deviceId(), name: nickname(), points, week: wk }),
    });
  } catch {
    return null;
  }
}

export async function leaveBoard() {
  try { await api("mascot/leave", { method: "POST", body: JSON.stringify({ id: deviceId() }) }); } catch { /* hors ligne */ }
}
