import { io, type Socket } from "socket.io-client";

/** Préfixe de l'app (« /maps/ » en production, servi par Nginx). */
export const BASE = import.meta.env.BASE_URL;

/** Appel à l'API du serveur OsaMaps (`server/`) : `api("reports?bbox=…")` → /maps/api/reports?bbox=… */
export async function api<T = unknown>(path: string, init?: RequestInit): Promise<T> {
  const r = await fetch(`${BASE}api/${path}`, {
    ...init,
    headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text().catch(() => "")}`);
  return r.json() as Promise<T>;
}

/** Services externes gratuits, vérifiés le 4 nov. 2026. Respecte leur usage raisonnable (cache, debounce). */
export const EXTERNAL = {
  /** Style de carte vectorielle (OpenFreeMap, sans clé). Aussi : liberty, bright, positron. */
  styleDark: "https://tiles.openfreemap.org/styles/dark",
  styleLight: "https://tiles.openfreemap.org/styles/liberty",
  /** Itinéraires (Valhalla public FOSSGIS) : POST JSON { locations, costing:"auto", language:"fr-FR", alternates } */
  valhalla: "https://valhalla1.openstreetmap.de",
  /** Géocodage France (IGN / Base Adresse Nationale) : /search?q=…&lat=…&lon=…&limit=… ; /reverse?lat=…&lon=… */
  geocodeFr: "https://data.geopf.fr/geocodage",
  /** Géocodage monde + POI (Photon / OSM) : /api?q=…&lat=…&lon=…&lang=fr */
  photon: "https://photon.komoot.io",
  /** Prix des carburants (données publiques) — passer par le serveur (/maps/api/fuel) pour le cache. */
  fuel: "https://data.economie.gouv.fr/api/explore/v2.1/catalog/datasets/prix-des-carburants-en-france-flux-instantane-v2/records",
  /** Météo (Open-Meteo, sans clé). */
  weather: "https://api.open-meteo.com/v1/forecast",
  /** Requêtes OSM (Overpass) : POIs, limites de vitesse, bornes. À utiliser avec parcimonie. */
  overpass: "https://overpass-api.de/api/interpreter",
} as const;

let socket: Socket | null = null;

/** Connexion temps réel unique au serveur OsaMaps (signalements, trafic, amis). */
export function getSocket(): Socket {
  if (!socket) {
    socket = io({ path: `${BASE}socket.io`, transports: ["websocket", "polling"] });
  }
  return socket;
}
