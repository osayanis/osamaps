/**
 * Évènement de bus propre au module trafic, déclaré par augmentation de module (sans toucher à
 * core/bus.ts). Les modules d'itinéraire / d'ETA peuvent l'écouter : `on("traffic:delay", …)`.
 * À remonter dans core/bus.ts si d'autres s'en servent.
 */
declare module "../../core/bus" {
  interface BusEvents {
    /** Retard de trafic estimé sur l'itinéraire actif (s), et distance du prochain bouchon (m) ou null. */
    "traffic:delay": { routeId: string; delay: number; nextJam: number | null };
  }
}
export {};
