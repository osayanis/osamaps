/**
 * Petit bus d'évènements entre fonctionnalités, pour ne pas créer de dépendances directes.
 * Évènements connus (ajoute les tiens ici, avec leur charge) :
 */
export interface BusEvents {
  /** Une navigation démarre / s'arrête. */
  "drive:start": { routeId: string };
  "drive:stop": { arrived: boolean };
  /** Arrivée à destination. */
  "drive:arrived": { destinationName: string };
  /** L'itinéraire a été recalculé (sortie de route). */
  "drive:rerouted": { routeId: string };
  /** Nouvelle position (déjà dans le store ; pratique pour les calculs à chaque tick). */
  "geo:tick": { lng: number; lat: number; speed: number | null };
  /** Un lieu est choisi comme destination (déclenche le calcul d'itinéraire). */
  "place:go": { name: string; lng: number; lat: number };
  /** Un toast à afficher (le module design l'affiche). */
  toast: { text: string; icon?: string; tone?: "info" | "good" | "warn"; id?: string; duration?: number };
  /** Le conducteur est sorti de l'itinéraire : le module routing recalcule depuis `from`. */
  "route:recompute": { from: [number, number] };
  /** Demande de recentrage / suivi (bouton, raccourci). */
  "map:recenter": Record<string, never>;
  /** Une alerte à annoncer en conduite (signalement devant, zone de danger, bouchon…). */
  "drive:alert": { id: string; kind: string; text: string; distance: number; tone?: "info" | "warn" | "danger" };
  /** Points gagnés (gamification). */
  "points:earn": { amount: number; reason: string };
}

type Handler<T> = (payload: T) => void;
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const handlers = new Map<keyof BusEvents, Set<Handler<any>>>();

export function on<K extends keyof BusEvents>(event: K, fn: Handler<BusEvents[K]>): () => void {
  let set = handlers.get(event);
  if (!set) handlers.set(event, (set = new Set()));
  set.add(fn);
  return () => { set!.delete(fn); };
}

export function emit<K extends keyof BusEvents>(event: K, payload: BusEvents[K]) {
  handlers.get(event)?.forEach((fn) => {
    try { fn(payload); } catch (e) { console.error(`[bus] ${event}`, e); }
  });
}
