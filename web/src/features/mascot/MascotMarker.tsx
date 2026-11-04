import { useShallow } from "zustand/react/shallow";
import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import maplibregl from "maplibre-gl";
import { useCore, core } from "../../core/store";
import { Mascot } from "./Mascot";
import { poke, useMascot, wornAccessories } from "./engine";
import { reducedMotion } from "./motion";

/**
 * « Ma position » sur la carte : la mascotte (debout, ou dans sa petite voiture quand on roule),
 * posée sur un disque de précision discret et une flèche au sol orientée selon le cap.
 * Deux marqueurs HTML : le sol (couché sur la carte, tourne avec elle) et la mascotte (toujours
 * droite face à l'écran ; son visage regarde dans le sens de la marche).
 * Entre deux positions, tout est interpolé (pas de saut).
 */
const BODY = 40;                      // largeur du corps en px (exploration)
const BODY_DRIVE = 48;                // un peu plus grande en conduite (lisible d'un coup d'œil)

export function MascotMarker() {
  const map = useCore((s) => s.map);
  const hasPos = useCore((s) => s.position != null);
  const mode = useCore((s) => s.mode);
  const live = useMascot((s) => s.live);
  const worn = useMascot(useShallow(wornAccessories));
  const animations = useMascot((s) => s.settings.animations);
  const [look, setLook] = useState({ x: 0, y: 0 });

  const pinEl = useMemo(() => {
    const d = document.createElement("div");
    d.className = "mascot-pin";
    return d;
  }, []);
  const groundEl = useMemo(() => {
    const d = document.createElement("div");
    d.className = "mascot-ground";
    // faisceau : un secteur de ±32° qui s'estompe, plus large que la mascotte pour rester visible
    d.innerHTML =
      '<div class="mascot-halo"></div>' +
      '<svg class="mascot-cone" viewBox="-100 -100 200 200" aria-hidden="true">' +
      '<defs><radialGradient id="mascot-beam" cx="0" cy="0" r="74" gradientUnits="userSpaceOnUse">' +
      '<stop offset="0.25" stop-color="#fff" stop-opacity="0.34"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></radialGradient></defs>' +
      '<path d="M0 0 L-39.2 -62.8 A74 74 0 0 1 39.2 -62.8 Z" fill="url(#mascot-beam)"/></svg>';
    return d;
  }, []);

  const shown = useRef<{ lng: number; lat: number; heading: number | null } | null>(null);
  const anim = useRef<{ from: [number, number]; to: [number, number]; h0: number | null; h1: number | null; t0: number; dur: number } | null>(null);
  const raf = useRef(0);
  const lastUpdate = useRef(0);

  useEffect(() => {
    if (!map || !hasPos) return;
    const pin = new maplibregl.Marker({ element: pinEl, anchor: "bottom", offset: [0, 4], rotationAlignment: "viewport", pitchAlignment: "viewport" });
    const ground = new maplibregl.Marker({ element: groundEl, anchor: "center", rotationAlignment: "map", pitchAlignment: "map" });
    const halo = groundEl.querySelector<HTMLDivElement>(".mascot-halo")!;
    const cone = groundEl.querySelector<SVGElement>(".mascot-cone")!;

    const p0 = core().position!;
    shown.current = { lng: p0.coord[0], lat: p0.coord[1], heading: p0.heading };
    ground.setLngLat(p0.coord).addTo(map);
    pin.setLngLat(p0.coord).addTo(map);

    const sizeHalo = () => {
      const p = core().position;
      const s = shown.current;
      if (!p || !s) return;
      const mpp = (40075016.686 * Math.cos((s.lat * Math.PI) / 180)) / (512 * 2 ** map.getZoom());
      const r = p.accuracy ? Math.min(220, p.accuracy / mpp) : 0;
      halo.style.opacity = r > 22 ? "1" : "0";
      halo.style.transform = `scale(${Math.max(0.01, r / 100)})`;
    };

    const updateLook = () => {
      const h = shown.current?.heading;
      if (h == null) { setLook((l) => (l.x || l.y ? { x: 0, y: 0 } : l)); return; }
      const rel = ((h - map.getBearing()) * Math.PI) / 180;
      const x = Math.round(Math.sin(rel) * 10) / 10;
      const y = Math.round(-Math.cos(rel) * 0.7 * 10) / 10;
      setLook((l) => (l.x === x && l.y === y ? l : { x, y }));
    };

    const apply = () => {
      const s = shown.current!;
      pin.setLngLat([s.lng, s.lat]);
      ground.setLngLat([s.lng, s.lat]);
      if (s.heading != null) { ground.setRotation(s.heading); cone.style.opacity = "1"; } else cone.style.opacity = "0";
    };
    apply();
    sizeHalo();
    updateLook();

    const step = (now: number) => {
      const a = anim.current;
      if (!a) return;
      const t = Math.min(1, (now - a.t0) / a.dur);
      const s = shown.current!;
      s.lng = a.from[0] + (a.to[0] - a.from[0]) * t;
      s.lat = a.from[1] + (a.to[1] - a.from[1]) * t;
      if (a.h1 == null) s.heading = a.h0;
      else if (a.h0 == null) s.heading = a.h1;
      else {
        const d = ((a.h1 - a.h0 + 540) % 360) - 180;           // le plus court chemin
        s.heading = (a.h0 + d * Math.min(1, t * 1.6) + 360) % 360;
      }
      apply();
      updateLook();
      if (t < 1) raf.current = requestAnimationFrame(step);
      else anim.current = null;
    };

    const unsub = useCore.subscribe((st, prev) => {
      const p = st.position;
      if (!p || p === prev.position) return;
      const now = performance.now();
      const s = shown.current!;
      const gap = now - (lastUpdate.current || now - 1000);
      lastUpdate.current = now;
      const far = Math.abs(p.coord[0] - s.lng) > 0.05 || Math.abs(p.coord[1] - s.lat) > 0.05;
      cancelAnimationFrame(raf.current);
      if (far || reducedMotion()) {
        // grand saut (premier fix GPS, téléportation de test) : pas d'animation
        shown.current = { lng: p.coord[0], lat: p.coord[1], heading: p.heading ?? s.heading };
        anim.current = null;
        apply(); updateLook(); sizeHalo();
        return;
      }
      anim.current = {
        from: [s.lng, s.lat], to: p.coord, h0: s.heading, h1: p.heading ?? s.heading, t0: now,
        dur: Math.max(200, Math.min(1200, gap)),
      };
      raf.current = requestAnimationFrame(step);
      sizeHalo();
    });

    map.on("zoom", sizeHalo);
    map.on("rotate", updateLook);
    return () => {
      unsub();
      cancelAnimationFrame(raf.current);
      map.off("zoom", sizeHalo);
      map.off("rotate", updateLook);
      pin.remove();
      ground.remove();
    };
  }, [map, hasPos, pinEl, groundEl]);

  useEffect(() => {
    const onClick = () => { if (core().mode !== "drive") poke(); };
    pinEl.addEventListener("click", onClick);
    return () => pinEl.removeEventListener("click", onClick);
  }, [pinEl]);

  if (!map || !hasPos) return null;
  const driving = mode === "drive";
  const inKart = driving || live.moving;
  return createPortal(
    <div className={`mascot-pin-inner${live.sleeping ? " is-sleeping" : ""}`} title="Ma position">
      <Mascot
        size={driving ? BODY_DRIVE : BODY}
        mood={live.sleeping ? "sleepy" : live.mood}
        arms={live.arms}
        look={live.sleeping ? { x: 0, y: 0.3 } : look}
        hop={live.hop}
        kart={inKart}
        bounce={animations && live.moving && !live.sleeping}
        accessories={worn}
      />
      {live.sleeping && (
        <svg className="mascot-zzz" viewBox="0 0 30 34" aria-hidden="true">
          <text x="2" y="30">z</text>
          <text x="11" y="20">z</text>
          <text x="19" y="10">z</text>
        </svg>
      )}
    </div>,
    pinEl,
  );
}
