import { BASE } from "../../core/services";
import type { LngLat } from "../../core/store";
import type { Saved } from "./state";

/** Lien partageable : https://osalabs.fr/maps/?lieu=46.12780,3.42580,Vichy */
export function shareUrl(p: Saved): string {
  const name = p.name.replace(/,/g, " ").slice(0, 80);
  return `${location.origin}${BASE}?lieu=${p.coord[1].toFixed(5)},${p.coord[0].toFixed(5)},${encodeURIComponent(name)}`;
}

export async function shareLink(p: Saved): Promise<"shared" | "copied" | "cancelled" | "failed"> {
  const url = shareUrl(p);
  const text = [p.name, p.detail].filter(Boolean).join(", ");
  if (navigator.share) {
    try { await navigator.share({ title: p.name, text, url }); return "shared"; }
    catch (e) { if ((e as Error).name === "AbortError") return "cancelled"; }
  }
  try { await navigator.clipboard.writeText(url); return "copied"; }
  catch { return "failed"; }
}

/** Lit `?lieu=lat,lng,nom` (nom facultatif). */
export function parseLieuParam(search = location.search): { coord: LngLat; name?: string } | null {
  const raw = new URLSearchParams(search).get("lieu");
  if (!raw) return null;
  const [la, ln, ...rest] = raw.split(",");
  const lat = Number(la), lng = Number(ln);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return null;
  const name = rest.join(",").trim().slice(0, 80);
  return { coord: [lng, lat], name: name || undefined };
}

/** Retire `lieu` de l'URL (on garde ?sim=… etc.) pour qu'un rechargement ne rouvre pas la fiche. */
export function dropLieuParam() {
  const u = new URL(location.href);
  if (!u.searchParams.has("lieu")) return;
  u.searchParams.delete("lieu");
  history.replaceState(history.state, "", u.pathname + (u.search ? u.search : "") + u.hash);
}

/** Ouvrir le lieu dans une autre application de navigation. */
export function externalApps(p: Saved) {
  const [lng, lat] = p.coord;
  const ll = `${lat.toFixed(6)},${lng.toFixed(6)}`;
  const label = encodeURIComponent(p.name);
  const apps = [
    { id: "waze", label: "Waze", href: `https://waze.com/ul?ll=${ll}&navigate=yes` },
    { id: "google", label: "Google Maps", href: `https://www.google.com/maps/dir/?api=1&destination=${ll}` },
    { id: "apple", label: "Plans (Apple)", href: `https://maps.apple.com/?daddr=${ll}&q=${label}` },
  ];
  // Android : le lien geo: propose toutes les applis installées
  if (/Android/i.test(navigator.userAgent)) apps.push({ id: "geo", label: "Autre application…", href: `geo:${ll}?q=${ll}(${label})` });
  return apps;
}
