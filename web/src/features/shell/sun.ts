/**
 * Lever / coucher du soleil calculés localement (algorithme NOAA simplifié, précision ~1 min),
 * pour le style de carte « auto ». Aucun appel réseau.
 */
const rad = Math.PI / 180;

/** Renvoie les heures (Date) de lever et de coucher pour `date` à la position donnée, ou null
 *  pendant la nuit polaire / le jour polaire. */
export function sunTimes(date: Date, lat: number, lng: number): { sunrise: Date; sunset: Date } | null {
  // jour julien à midi UTC
  const day = Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate());
  const jd = day / 86400000 + 2440587.5;
  const n = Math.round(jd - 2451545.0 + 0.0008 - lng / 360);
  const jStar = n - lng / 360; // midi solaire moyen
  const M = (357.5291 + 0.98560028 * jStar) % 360;
  const C = 1.9148 * Math.sin(M * rad) + 0.02 * Math.sin(2 * M * rad) + 0.0003 * Math.sin(3 * M * rad);
  const lambda = (M + C + 180 + 102.9372) % 360;
  const jTransit = 2451545.0 + jStar + 0.0053 * Math.sin(M * rad) - 0.0069 * Math.sin(2 * lambda * rad);
  const decl = Math.asin(Math.sin(lambda * rad) * Math.sin(23.4397 * rad));
  // -0.833° : réfraction + rayon du disque solaire
  const cosH = (Math.sin(-0.833 * rad) - Math.sin(lat * rad) * Math.sin(decl)) / (Math.cos(lat * rad) * Math.cos(decl));
  if (cosH < -1 || cosH > 1) return null;
  const H = Math.acos(cosH) / rad;
  const toDate = (j: number) => new Date((j - 2440587.5) * 86400000);
  return { sunrise: toDate(jTransit - H / 360), sunset: toDate(jTransit + H / 360) };
}

/** Fait-il jour à `now` à cette position ? (nuit polaire → false, jour polaire → true) */
export function isDaytime(now: Date, lat: number, lng: number): boolean {
  const t = sunTimes(now, lat, lng);
  if (!t) {
    // été dans l'hémisphère de la position → jour polaire
    const m = now.getUTCMonth();
    const summerNorth = m >= 3 && m <= 8;
    return lat >= 0 ? summerNorth : !summerNorth;
  }
  return now >= t.sunrise && now < t.sunset;
}
