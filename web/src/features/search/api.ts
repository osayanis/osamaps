import { EXTERNAL } from "../../core/services";
import { distance } from "../../core/geometry";
import type { LngLat } from "../../core/store";
import type { Category } from "./categories";

/**
 * Accès aux géocodeurs gratuits : Base Adresse Nationale / IGN (adresses françaises) et Photon
 * (lieux et POI OpenStreetMap, monde). Tout passe par un petit cache mémoire et des requêtes
 * annulables : la barre de recherche ne lance qu'une salve (≤ 3 requêtes) par frappe stabilisée.
 */
export interface SearchResult {
  id: string;
  name: string;
  detail: string;
  coord: LngLat;
  /** Famille d'icône : address, street, city, poi, fuel, food, shop, … */
  kind: string;
  /** Libellé de type affiché (« Boulangerie », « Ville »…). */
  typeLabel?: string;
  source: "ban" | "photon" | "local" | "coords";
  /** Pertinence de la source (0..1). */
  rel: number;
  /** Score final (calculé au classement). */
  score?: number;
}

/* ------------------------------------------------------------------ cache + fetch ------------ */

const cache = new Map<string, { t: number; data: unknown }>();
const TTL = 10 * 60_000;

async function getJson<T>(url: string, signal?: AbortSignal): Promise<T> {
  const hit = cache.get(url);
  if (hit && Date.now() - hit.t < TTL) return hit.data as T;
  const r = await fetch(url, { signal, headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  const data = (await r.json()) as T;
  cache.set(url, { t: Date.now(), data });
  if (cache.size > 150) cache.delete(cache.keys().next().value as string);
  return data;
}

/* ------------------------------------------------------------------ texte -------------------- */

export function norm(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

/** Correspondance texte 0..1 entre la requête et un libellé. */
function textMatch(q: string, name: string, detail: string): number {
  const nq = norm(q);
  const nn = norm(name);
  if (!nq) return 0;
  if (nn === nq) return 1;
  const tokens = nq.split(" ");
  const hay = `${nn} ${norm(detail)}`;
  const words = hay.split(" ");
  let found = 0;
  for (const t of tokens) if (words.some((w) => w.startsWith(t))) found++;
  let s = (found / tokens.length) * 0.75;
  if (nn.startsWith(nq)) s += 0.2;
  else if (nn.includes(nq)) s += 0.1;
  return Math.min(1, s);
}

/* ------------------------------------------------------------------ types OSM → libellés ----- */

const OSM_LABELS: Record<string, [string, string]> = {
  // osm_value : [libellé, famille d'icône]
  fuel: ["Station-service", "fuel"],
  charging_station: ["Borne de recharge", "charge"],
  parking: ["Parking", "parking"],
  parking_space: ["Parking", "parking"],
  restaurant: ["Restaurant", "food"],
  fast_food: ["Restauration rapide", "food"],
  cafe: ["Café", "cafe"],
  bar: ["Bar", "cafe"],
  pub: ["Bar", "cafe"],
  bakery: ["Boulangerie", "bakery"],
  pharmacy: ["Pharmacie", "pharmacy"],
  hospital: ["Hôpital", "health"],
  clinic: ["Clinique", "health"],
  doctors: ["Médecin", "health"],
  supermarket: ["Supermarché", "shop"],
  convenience: ["Supérette", "shop"],
  mall: ["Centre commercial", "shop"],
  toilets: ["Toilettes", "toilets"],
  station: ["Gare", "train"],
  halt: ["Gare", "train"],
  bus_station: ["Gare routière", "bus"],
  bus_stop: ["Arrêt de bus", "bus"],
  school: ["École", "poi"],
  college: ["Collège", "poi"],
  university: ["Université", "poi"],
  townhall: ["Mairie", "poi"],
  police: ["Police", "poi"],
  post_office: ["Bureau de poste", "poi"],
  bank: ["Banque", "poi"],
  atm: ["Distributeur", "poi"],
  hotel: ["Hôtel", "poi"],
  museum: ["Musée", "poi"],
  cinema: ["Cinéma", "poi"],
  park: ["Parc", "park"],
  city: ["Ville", "city"],
  town: ["Ville", "city"],
  village: ["Village", "city"],
  hamlet: ["Hameau", "city"],
  suburb: ["Quartier", "city"],
  locality: ["Lieu-dit", "city"],
  residential: ["Rue", "street"],
  primary: ["Route", "street"],
  secondary: ["Route", "street"],
  tertiary: ["Route", "street"],
  unclassified: ["Route", "street"],
  service: ["Voie", "street"],
  motorway: ["Autoroute", "street"],
  trunk: ["Voie rapide", "street"],
  pedestrian: ["Rue piétonne", "street"],
  living_street: ["Rue", "street"],
};

/** Types Photon trop bruyants pour la recherche libre. */
const NOISE = new Set(["bus_stop", "platform", "construction", "city_block", "works", "yes", "gas", "stop_position", "proposed"]);

export function osmLabel(key: string | undefined, value: string | undefined): [string | undefined, string] {
  if (value && OSM_LABELS[value]) return OSM_LABELS[value];
  if (key === "highway") return ["Route", "street"];
  if (key === "place") return ["Lieu", "city"];
  if (key === "boundary") return ["Commune", "city"];
  if (key === "shop") return ["Commerce", "shop"];
  if (key === "amenity" || key === "tourism" || key === "leisure") return [undefined, "poi"];
  return [undefined, "poi"];
}

/* ------------------------------------------------------------------ BAN / IGN ---------------- */

interface BanFeature {
  geometry: { coordinates: [number, number] };
  properties: {
    label: string; name: string; type: string; score: number; city?: string; postcode?: string;
    context?: string; id?: string; housenumber?: string; street?: string;
  };
}

const BAN_TYPES: Record<string, [string, string]> = {
  housenumber: ["Adresse", "address"],
  street: ["Rue", "street"],
  locality: ["Lieu-dit", "city"],
  municipality: ["Commune", "city"],
};

function banToResult(f: BanFeature): SearchResult {
  const p = f.properties;
  const [typeLabel, kind] = BAN_TYPES[p.type] ?? ["Adresse", "address"];
  const dept = p.context?.split(",")[1]?.trim();
  const detail = p.type === "municipality"
    ? [p.postcode, dept].filter(Boolean).join(" · ")
    : [p.postcode, p.city].filter(Boolean).join(" ");
  return {
    id: `ban:${p.id ?? p.label}`,
    name: p.name || p.label,
    detail,
    coord: f.geometry.coordinates,
    kind,
    typeLabel,
    source: "ban",
    rel: p.score ?? 0.5,
  };
}

async function searchBan(q: string, near: LngLat | null, signal: AbortSignal): Promise<SearchResult[]> {
  if (q.length < 3) return [];
  const u = new URL(`${EXTERNAL.geocodeFr}/search`);
  u.searchParams.set("q", q.slice(0, 200));
  u.searchParams.set("limit", "6");
  u.searchParams.set("autocomplete", "1");
  if (near) { u.searchParams.set("lat", near[1].toFixed(4)); u.searchParams.set("lon", near[0].toFixed(4)); }
  const d = await getJson<{ features?: BanFeature[] }>(u.toString(), signal);
  return (d.features ?? []).map(banToResult);
}

export async function reverseBan(c: LngLat, signal?: AbortSignal): Promise<{ name: string; detail: string } | null> {
  const u = `${EXTERNAL.geocodeFr}/reverse?lat=${c[1].toFixed(6)}&lon=${c[0].toFixed(6)}&limit=1`;
  const d = await getJson<{ features?: BanFeature[] }>(u, signal);
  const f = d.features?.[0];
  if (!f) return null;
  const p = f.properties;
  // trop loin du point demandé : l'adresse ne veut plus rien dire
  if (distance(c, f.geometry.coordinates) > 250) return null;
  return { name: p.name || p.label, detail: [p.postcode, p.city].filter(Boolean).join(" ") };
}

/* ------------------------------------------------------------------ Photon ------------------- */

interface PhotonFeature {
  geometry: { coordinates: [number, number] };
  properties: {
    osm_type?: string; osm_id?: number; osm_key?: string; osm_value?: string; type?: string;
    name?: string; housenumber?: string; street?: string; city?: string; locality?: string; district?: string;
    postcode?: string; county?: string; state?: string; country?: string; countrycode?: string;
  };
}

function photonToResult(f: PhotonFeature, rank: number): SearchResult | null {
  const p = f.properties;
  const street = p.street ? [p.housenumber, p.street].filter(Boolean).join(" ") : "";
  const name = p.name || street;
  if (!name) return null;
  const [typeLabel, kind] = osmLabel(p.osm_key, p.osm_value);
  const place = p.city || p.locality || p.district || p.county;
  const detailParts = [p.name && street ? street : "", place, p.countrycode && p.countrycode !== "FR" ? p.country : ""];
  return {
    id: `osm:${p.osm_type ?? ""}${p.osm_id ?? `${f.geometry.coordinates.join(",")}`}`,
    name,
    detail: detailParts.filter(Boolean).join(", "),
    coord: f.geometry.coordinates,
    kind,
    typeLabel,
    source: "photon",
    rel: Math.max(0.3, 0.9 - rank * 0.06),
  };
}

function photonUrl(params: Record<string, string>) {
  const u = new URL(`${EXTERNAL.photon}/api`);
  u.searchParams.set("lang", "fr");
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, v);
  return u.toString();
}

async function searchPhoton(q: string, near: LngLat | null, local: boolean, signal: AbortSignal): Promise<SearchResult[]> {
  const params: Record<string, string> = { q: q.slice(0, 200), limit: local ? "8" : "6" };
  if (near) {
    params.lat = near[1].toFixed(4);
    params.lon = near[0].toFixed(4);
    // ≈ 40 km autour : fait remonter le Leclerc du coin plutôt que celui de l'autre bout de la France
    if (local) params.bbox = [near[0] - 0.5, near[1] - 0.35, near[0] + 0.5, near[1] + 0.35].map((n) => n.toFixed(3)).join(",");
  }
  const d = await getJson<{ features?: PhotonFeature[] }>(photonUrl(params), signal);
  return (d.features ?? [])
    // les limites administratives doublonnent les communes (et l'arrondissement « Vichy » est à 20 km de la ville)
    .filter((f) => !NOISE.has(f.properties.osm_value ?? "") && f.properties.osm_key !== "boundary")
    .map((f, i) => photonToResult(f, i))
    .filter((r): r is SearchResult => !!r);
}

export async function reversePhoton(c: LngLat, signal?: AbortSignal): Promise<{ name: string; detail: string } | null> {
  const u = `${EXTERNAL.photon}/reverse?lat=${c[1].toFixed(6)}&lon=${c[0].toFixed(6)}&lang=fr&limit=1`;
  const d = await getJson<{ features?: PhotonFeature[] }>(u, signal);
  const f = d.features?.[0];
  if (!f) return null;
  const r = photonToResult(f, 0);
  return r ? { name: r.name, detail: r.detail } : null;
}

/** Adresse lisible d'un point : IGN d'abord (précis en France), Photon sinon. */
export async function reverseGeocode(c: LngLat, signal?: AbortSignal) {
  try {
    const a = await reverseBan(c, signal);
    if (a) return a;
  } catch (e) {
    if ((e as Error).name === "AbortError") throw e;
  }
  return reversePhoton(c, signal);
}

/* ------------------------------------------------------------------ recherche combinée ------- */

/** « 46.12, 3.42 » ou « 46,12 3,42 » → coordonnées. */
export function parseCoords(q: string): LngLat | null {
  const m = q.trim().match(/^(-?\d{1,2}(?:[.,]\d+)?)\s*[,; ]\s*(-?\d{1,3}(?:[.,]\d+)?)$/);
  if (!m) return null;
  const lat = Number(m[1].replace(",", ".")), lng = Number(m[2].replace(",", "."));
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return null;
  return [lng, lat];
}

/** Doublon : même nom (ou presque) et à moins de 150 m, ou quasiment au même point. */
function isDup(a: SearchResult, b: SearchResult) {
  const d = distance(a.coord, b.coord);
  if (d < 25) return true;
  const same = norm(a.name) === norm(b.name);
  // une même commune : centre BAN (mairie) et centre OSM peuvent être à quelques km
  if (same && a.kind === "city" && b.kind === "city") return d < 8000;
  // une même rue : point BAN (milieu de voie) et tracé OSM peuvent différer de quelques centaines de mètres
  if (same && a.kind === "street" && b.kind === "street") return d < 800;
  return d < 150 && same;
}

export function rank(q: string, list: SearchResult[], near: LngLat | null): SearchResult[] {
  for (const r of list) {
    const tm = textMatch(q, r.name, r.detail);
    let prox = 0;
    if (near) {
      const km = distance(near, r.coord) / 1000;
      prox = 1 / (1 + km / 15);
    }
    // une commune qui porte exactement le nom tapé passe devant tout
    const cityBonus = r.kind === "city" && norm(r.name) === norm(q) ? 0.25 : 0;
    r.score = tm * 0.55 + r.rel * 0.2 + prox * 0.25 + cityBonus;
  }
  const sorted = [...list].sort((a, b) => (b.score ?? 0) - (a.score ?? 0));
  const out: SearchResult[] = [];
  for (const r of sorted) {
    const dupIndex = out.findIndex((o) => isDup(o, r));
    if (dupIndex === -1) out.push(r);
    // on garde le libellé le plus riche (le POI Photon plutôt que l'adresse brute, par ex.)
    else if (!out[dupIndex].typeLabel && r.typeLabel) out[dupIndex] = { ...r, score: out[dupIndex].score };
  }
  return out.slice(0, 12);
}

/**
 * Recherche libre : BAN (adresses) + Photon local (40 km) + Photon monde, en parallèle.
 * Une source en panne n'empêche pas les autres de répondre.
 */
export async function searchPlaces(q: string, near: LngLat | null, signal: AbortSignal): Promise<SearchResult[]> {
  const settled = await Promise.allSettled([
    searchBan(q, near, signal),
    near ? searchPhoton(q, near, true, signal) : Promise.resolve([]),
    searchPhoton(q, near, false, signal),
  ]);
  if (signal.aborted) throw new DOMException("annulé", "AbortError");
  const ok = settled.filter((s): s is PromiseFulfilledResult<SearchResult[]> => s.status === "fulfilled");
  if (!ok.length) throw new Error("Recherche indisponible");
  return rank(q, ok.flatMap((s) => s.value), near);
}

/* ------------------------------------------------------------------ autour de moi ------------ */

/**
 * POI d'une catégorie autour d'un point (Photon, filtre `include=osm.<clé>.<valeur>`, sans texte).
 * Le cache est indexé sur une grille d'≈ 1 km : se déplacer un peu ne relance pas de requête.
 */
export async function searchNearby(cat: Category, center: LngLat, signal?: AbortSignal): Promise<SearchResult[]> {
  const params = {
    include: cat.include.join(","),
    lat: (Math.round(center[1] * 100) / 100).toFixed(2),
    lon: (Math.round(center[0] * 100) / 100).toFixed(2),
    limit: "30",
  };
  const d = await getJson<{ features?: PhotonFeature[] }>(photonUrl(params), signal);
  const list = (d.features ?? [])
    .map((f, i) => photonToResult(f, i))
    .filter((r): r is SearchResult => !!r)
    .map((r) => ({ ...r, name: r.name || cat.label, typeLabel: r.typeLabel ?? cat.single }));
  // dédoublonnage (une station = parfois un nœud ET un bâtiment)
  const out: SearchResult[] = [];
  for (const r of list.sort((a, b) => distance(center, a.coord) - distance(center, b.coord))) {
    if (!out.some((o) => isDup(o, r))) out.push(r);
  }
  return out.filter((r) => distance(center, r.coord) < cat.maxKm * 1000).slice(0, 20);
}
