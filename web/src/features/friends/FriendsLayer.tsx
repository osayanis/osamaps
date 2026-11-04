import { useEffect, useRef } from "react";
import maplibregl from "maplibre-gl";
import { useCore } from "../../core/store";
import { useFriends, followToken, type Friend } from "./store";
import { initials, clock } from "./util";

/**
 * Marqueurs des amis qui partagent leur position : pastille avec initiales, flèche de cap,
 * étiquette « Léa · 18 h 42 » s'il conduit. Marqueurs DOM : ils survivent au changement de style.
 */
export function FriendsLayer() {
  const map = useCore((s) => s.map);
  const friends = useFriends((s) => s.friends);
  const markers = useRef(new Map<string, { marker: maplibregl.Marker; el: HTMLDivElement; heading: number | null }>());

  // orienter les flèches quand la carte tourne
  useEffect(() => {
    if (!map) return;
    const rotate = () => {
      const b = map.getBearing();
      for (const m of markers.current.values()) {
        const arrow = m.el.querySelector<HTMLElement>(".friends-marker-cap");
        if (arrow && m.heading != null) arrow.style.transform = `rotate(${m.heading - b}deg)`;
      }
    };
    map.on("rotate", rotate);
    return () => { map.off("rotate", rotate); };
  }, [map]);

  useEffect(() => {
    if (!map || followToken) return;
    const seen = new Set<string>();
    for (const f of friends) {
      if (!f.loc) continue;
      seen.add(f.pid);
      let m = markers.current.get(f.pid);
      if (!m) {
        const el = document.createElement("div");
        el.className = "friends-marker";
        el.setAttribute("role", "button");
        el.addEventListener("click", (e) => { e.stopPropagation(); useCore.getState().openPanel("friend", { pid: f.pid }); });
        const marker = new maplibregl.Marker({ element: el, anchor: "center" }).setLngLat([f.loc.lng, f.loc.lat]).addTo(map);
        m = { marker, el, heading: null };
        markers.current.set(f.pid, m);
      }
      paint(m.el, f, map.getBearing());
      m.heading = f.loc.heading;
      m.marker.setLngLat([f.loc.lng, f.loc.lat]);
    }
    for (const [pid, m] of markers.current) if (!seen.has(pid)) { m.marker.remove(); markers.current.delete(pid); }
  }, [map, friends]);

  useEffect(() => () => { for (const m of markers.current.values()) m.marker.remove(); markers.current.clear(); }, []);
  return null;
}

function paint(el: HTMLDivElement, f: Friend, mapBearing: number) {
  const loc = f.loc!;
  const driving = !!loc.drive;
  const label = loc.drive?.eta ? `${f.name} · ${clock(loc.drive.eta)}` : f.name;
  el.classList.toggle("is-driving", driving);
  el.setAttribute("aria-label", `${f.name}, ${driving ? "en route" : "position partagée"}`);
  const cap = loc.heading != null && (loc.speed ?? 0) > 0.5
    ? `<span class="friends-marker-cap" style="transform:rotate(${loc.heading - mapBearing}deg)"><svg width="44" height="44" viewBox="0 0 44 44"><path d="M22 2l6 9h-12z" fill="currentColor"/></svg></span>`
    : "";
  el.innerHTML = `${cap}<span class="friends-marker-dot">${escape(initials(f.name))}</span><span class="friends-marker-label">${escape(label)}</span>`;
}

const escape = (s: string) => s.replace(/[&<>"']/g, (c) => `&#${c.charCodeAt(0)};`);
