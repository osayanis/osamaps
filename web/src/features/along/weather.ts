import { EXTERNAL } from "../../core/services";
import type { LngLat, Route } from "../../core/store";
import { along, cumulativeDistances } from "../../core/geometry";

/** Météo prévue à l'heure de passage en quelques points du tracé (Open-Meteo, sans clé). */
export interface WeatherPoint {
  /** Fraction du trajet (0 = départ, 1 = arrivée). */
  at: number;
  /** Mètres depuis le départ. */
  along: number;
  coord: LngLat;
  /** Heure de passage prévue (ms). */
  time: number;
  temp: number;
  /** mm sur l'heure. */
  precip: number;
  /** cm sur l'heure. */
  snow: number;
  code: number;
  /** Probabilité de précipitations (%), si fournie. */
  prob: number | null;
}
export interface WeatherHazard {
  kind: "snow" | "ice" | "storm" | "rain" | "fog";
  /** Pour l'aperçu : « Risque de verglas vers 15:30 (0 °C) ». */
  text: string;
  /** Pour l'alerte de conduite (le guidage ajoute « dans 12 km ») : « Risque de verglas ». */
  short: string;
  point: WeatherPoint;
  tone: "warn" | "danger";
}
export interface RouteWeather {
  routeId: string;
  points: WeatherPoint[];
  /** Météo actuelle à l'arrivée. */
  arrivalNow: { temp: number; code: number; precip: number } | null;
  hazard: WeatherHazard | null;
  fetchedAt: number;
}

interface OmLocation {
  current?: { temperature_2m: number; weather_code: number; precipitation: number };
  hourly: { time: number[]; temperature_2m: number[]; precipitation: number[]; snowfall: number[]; weather_code: number[]; precipitation_probability?: (number | null)[] };
}

/** Fractions échantillonnées : départ, milieu, arrivée (+ quarts si le trajet dépasse 80 km). */
function fractions(distance: number) {
  return distance > 80_000 ? [0, 0.25, 0.5, 0.75, 1] : [0, 0.5, 1];
}

export async function fetchRouteWeather(route: Route, departAt = Date.now(), signal?: AbortSignal): Promise<RouteWeather> {
  const cum = cumulativeDistances(route.coords);
  const total = cum[cum.length - 1] || route.distance;
  const pts = fractions(total).map((f) => {
    const d = total * f;
    return { at: f, along: d, coord: along(route.coords, cum, d), time: departAt + route.duration * 1000 * f };
  });
  const q = new URLSearchParams({
    latitude: pts.map((p) => p.coord[1].toFixed(3)).join(","),
    longitude: pts.map((p) => p.coord[0].toFixed(3)).join(","),
    hourly: "temperature_2m,precipitation,snowfall,weather_code,precipitation_probability",
    current: "temperature_2m,weather_code,precipitation",
    timezone: "UTC",
    timeformat: "unixtime",
    forecast_days: "3",
  });
  const r = await fetch(`${EXTERNAL.weather}?${q}`, { signal });
  if (!r.ok) throw new Error(`météo ${r.status}`);
  const raw = await r.json();
  const locs: OmLocation[] = Array.isArray(raw) ? raw : [raw];
  const points: WeatherPoint[] = pts.map((p, i) => {
    const h = locs[i]?.hourly;
    if (!h?.time?.length) throw new Error("météo incomplète");
    // l'heure dont le début est le plus proche de l'heure de passage
    let k = 0, best = Infinity;
    h.time.forEach((t, j) => { const d = Math.abs(t * 1000 + 1800_000 - p.time); if (d < best) { best = d; k = j; } });
    return {
      ...p, temp: h.temperature_2m[k], precip: h.precipitation[k] ?? 0, snow: h.snowfall[k] ?? 0,
      code: h.weather_code[k] ?? 0, prob: h.precipitation_probability?.[k] ?? null,
    };
  });
  const cur = locs[locs.length - 1]?.current;
  return {
    routeId: route.id, points,
    arrivalNow: cur ? { temp: cur.temperature_2m, code: cur.weather_code, precip: cur.precipitation } : null,
    hazard: findHazard(points), fetchedAt: Date.now(),
  };
}

/** Codes WMO utilisés par Open-Meteo. */
const SNOW = [71, 73, 75, 77, 85, 86];
const FREEZING = [56, 57, 66, 67];
const STORM = [95, 96, 99];
const HEAVY_RAIN = [65, 82];
const FOG = [45, 48];

/** Le danger le plus sérieux du trajet (neige / verglas > orage > forte pluie > brouillard). */
export function findHazard(points: WeatherPoint[]): WeatherHazard | null {
  const where = (p: WeatherPoint) => p.at === 0 ? "au départ" : p.at === 1 ? "à l'arrivée" : `vers ${hour(p.time)}`;
  const found: WeatherHazard[] = [];
  for (const p of points) {
    const wet = p.precip >= 0.2 || (p.prob ?? 0) >= 60;
    if (FREEZING.includes(p.code) || (p.temp <= 1 && wet && !SNOW.includes(p.code))) found.push({ kind: "ice", tone: "danger", point: p, short: "Risque de verglas", text: `Risque de verglas ${where(p)} (${Math.round(p.temp)} °C)` });
    else if (SNOW.includes(p.code) || p.snow >= 0.2) found.push({ kind: "snow", tone: "danger", point: p, short: "Neige sur la route", text: `Neige prévue ${where(p)}` });
    else if (STORM.includes(p.code)) found.push({ kind: "storm", tone: "warn", point: p, short: "Orages sur la route", text: `Orages prévus ${where(p)}` });
    else if (HEAVY_RAIN.includes(p.code) || p.precip >= 4) found.push({ kind: "rain", tone: "warn", point: p, short: "Forte pluie sur la route", text: `Forte pluie prévue ${where(p)}` });
    else if (FOG.includes(p.code)) found.push({ kind: "fog", tone: "warn", point: p, short: "Brouillard sur la route", text: `Brouillard prévu ${where(p)}` });
  }
  const rank = { ice: 0, snow: 1, storm: 2, rain: 3, fog: 4 } as const;
  return found.sort((a, b) => rank[a.kind] - rank[b.kind] || a.point.at - b.point.at)[0] ?? null;
}

export const hour = (t: number) => new Date(t).toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });

/** Libellé court d'un code météo WMO. */
export function weatherLabel(code: number): string {
  if (code === 0) return "Ciel dégagé";
  if (code <= 2) return "Quelques nuages";
  if (code === 3) return "Couvert";
  if (FOG.includes(code)) return "Brouillard";
  if (code >= 51 && code <= 55) return "Bruine";
  if (FREEZING.includes(code)) return "Pluie verglaçante";
  if (code >= 61 && code <= 63) return "Pluie";
  if (code === 65) return "Forte pluie";
  if (SNOW.includes(code)) return "Neige";
  if (code >= 80 && code <= 82) return code === 82 ? "Fortes averses" : "Averses";
  if (STORM.includes(code)) return "Orage";
  return "—";
}

/** Famille d'icône pour un code WMO. */
export function weatherIcon(code: number): "sun" | "cloud" | "rain" | "snow" | "storm" | "fog" {
  if (code <= 1) return "sun";
  if (code <= 3) return "cloud";
  if (FOG.includes(code)) return "fog";
  if (SNOW.includes(code)) return "snow";
  if (STORM.includes(code)) return "storm";
  return code >= 51 ? "rain" : "cloud";
}
