import { useEffect, useState } from "react";
import { core, useCore, type LngLat } from "../../core/store";
import { emit } from "../../core/bus";
import { reverseGeocode } from "./api";
import { Icon } from "./icons";
import { ago, directionTo, fmtCoord, kindIcon } from "./format";
import { closeCategory } from "./nearby";
import { shareLink, shareUrl, externalApps } from "./share";
import {
  forgetCar, goTo, setShortcut, toggleFavorite, useSearch, type PlaceData,
} from "./state";
import { Sheet } from "./Sheet";

/** Normalise ce qu'un module a pu mettre dans panelData (PlaceData, Place du core, {name,lng,lat}). */
export function toPlaceData(d: unknown): PlaceData | null {
  if (!d || typeof d !== "object") return null;
  const o = d as Record<string, unknown>;
  let coord: LngLat | null = null;
  if (Array.isArray(o.coord) && o.coord.length === 2) coord = [Number(o.coord[0]), Number(o.coord[1])];
  else if (typeof o.lng === "number" && typeof o.lat === "number") coord = [o.lng, o.lat];
  if (!coord || !coord.every(Number.isFinite)) return null;
  return {
    id: typeof o.id === "string" ? o.id : `pt:${coord.join(",")}`,
    name: typeof o.name === "string" && o.name ? o.name : "Point sur la carte",
    detail: typeof o.detail === "string" ? o.detail : undefined,
    coord,
    kind: typeof o.kind === "string" ? o.kind : undefined,
    typeLabel: typeof o.typeLabel === "string" ? o.typeLabel : undefined,
    time: typeof o.time === "number" ? o.time : undefined,
    from: o.from as PlaceData["from"],
    needsAddress: !!o.needsAddress || !o.detail,
  };
}

export function PlaceSheet() {
  const panel = useCore((s) => s.panel);
  const panelData = useCore((s) => s.panelData);
  if (panel !== "place") return null;
  const p = toPlaceData(panelData);
  if (!p) return null;
  return <PlaceCard key={p.id + p.coord.join(",")} place={p} />;
}

function PlaceCard({ place }: { place: PlaceData }) {
  const position = useCore((s) => s.position);
  const favorites = useSearch((s) => s.favorites);
  const home = useSearch((s) => s.home);
  const work = useSearch((s) => s.work);
  const [addr, setAddr] = useState<{ name: string; detail: string } | null>(null);
  const [addrState, setAddrState] = useState<"idle" | "loading" | "none">(place.needsAddress ? "loading" : "idle");
  const [menu, setMenu] = useState<null | "gps" | "more">(null);

  // adresse lisible pour un point « nu » (appui long, lien partagé, POI sans rue)
  useEffect(() => {
    if (!place.needsAddress) return;
    const ctrl = new AbortController();
    reverseGeocode(place.coord, ctrl.signal)
      .then((a) => { setAddr(a); setAddrState(a ? "idle" : "none"); })
      .catch((e) => { if ((e as Error).name !== "AbortError") setAddrState("none"); });
    return () => ctrl.abort();
  }, [place.coord, place.needsAddress]);

  const isPoint = place.name === "Point sur la carte" || place.kind === "map";
  const name = isPoint && addr ? addr.name : place.name;
  const detail = place.detail || (addr ? (isPoint ? addr.detail : [addr.name, addr.detail].filter(Boolean).join(", ")) : undefined);
  const full = { ...place, name, detail };
  const fav = favorites.some((f) => Math.abs(f.coord[0] - place.coord[0]) < 3e-4 && Math.abs(f.coord[1] - place.coord[1]) < 3e-4);
  const dir = position ? directionTo(position.coord, place.coord) : null;
  const isCar = place.kind === "car";
  const isHome = place.kind === "home", isWork = place.kind === "work";

  const close = () => {
    if (place.from === "list" && useSearch.getState().category) core().openPanel("search-results");
    else { core().openPanel(null); if (place.from !== "list") closeCategory(); }
  };

  const onFav = () => {
    const now = toggleFavorite(full);
    emit("toast", { text: now ? "Ajouté aux favoris" : "Retiré des favoris", tone: now ? "good" : "info" });
  };

  const onShare = async () => {
    const res = await shareLink(full);
    if (res === "copied") emit("toast", { text: "Lien copié", tone: "good" });
    else if (res === "failed") emit("toast", { text: "Impossible de partager ce lieu", tone: "warn" });
  };

  const copyCoords = async () => {
    try { await navigator.clipboard.writeText(fmtCoord(place.coord)); emit("toast", { text: "Coordonnées copiées", tone: "good" }); }
    catch { /* presse-papiers refusé */ }
  };

  const label = isCar ? "Stationnement" : isHome ? "Maison" : isWork ? "Travail" : place.typeLabel ?? (isPoint ? "Point sur la carte" : undefined);

  return (
    <Sheet className="search-place" onClose={close} ariaLabel={`Fiche : ${name}`}>
      <div className="place-head">
        <span className="place-badge"><Icon name={isCar ? "car" : kindIcon(place.kind)} size={20} /></span>
        <div className="place-titles">
          {label && <div className="place-type">{label}</div>}
          <h2 className="place-name">{addrState === "loading" && isPoint ? "Recherche de l'adresse…" : name}</h2>
          {detail ? <div className="place-detail">{detail}</div>
            : addrState === "none" ? <div className="place-detail">Adresse inconnue</div> : null}
        </div>
        <button className="place-close" aria-label="Fermer la fiche" onClick={close}>
          <Icon name={place.from === "list" ? "back" : "x"} size={18} />
        </button>
      </div>

      <div className="place-facts">
        {dir && (
          <span className="place-fact">
            <Icon name="arrow" size={14} style={{ transform: `rotate(${dir.deg}deg)` }} className="place-arrow" />
            {dir.text}
          </span>
        )}
        {isCar && place.time && <span className="place-fact"><Icon name="clock" size={14} />Garée {ago(place.time)}</span>}
        <button className="place-fact place-coords" onClick={copyCoords} aria-label="Copier les coordonnées">
          <Icon name="copy" size={14} />{fmtCoord(place.coord)}
        </button>
      </div>

      <div className="place-actions">
        <button className="pill place-go" onClick={() => goTo(full)}>
          <Icon name="go" size={18} />
          {isCar ? "Retrouver ma voiture" : "Y aller"}
        </button>
        <div className="place-tools">
          {!isCar && (
            <button className={`place-tool${fav ? " is-on" : ""}`} onClick={onFav} aria-pressed={fav}>
              <Icon name={fav ? "star-filled" : "star"} size={20} />
              <span>{fav ? "Enregistré" : "Favori"}</span>
            </button>
          )}
          <button className="place-tool" onClick={onShare}>
            <Icon name="share" size={20} /><span>Partager</span>
          </button>
          <button className={`place-tool${menu === "gps" ? " is-open" : ""}`} onClick={() => setMenu(menu === "gps" ? null : "gps")} aria-expanded={menu === "gps"}>
            <Icon name="external" size={20} /><span>Autre GPS</span>
          </button>
          {isCar ? (
            <button className="place-tool" onClick={() => { forgetCar(); core().openPanel(null); emit("toast", { text: "Stationnement oublié" }); }}>
              <Icon name="trash" size={20} /><span>Oublier</span>
            </button>
          ) : (
            <button className={`place-tool${menu === "more" ? " is-open" : ""}`} onClick={() => setMenu(menu === "more" ? null : "more")} aria-expanded={menu === "more"}>
              <Icon name="more" size={20} /><span>Plus</span>
            </button>
          )}
        </div>
      </div>

      {menu === "gps" && (
        <div className="place-menu" role="menu">
          {externalApps(full).map((a) => (
            <a key={a.id} className="place-menu-row" role="menuitem" href={a.href} target="_blank" rel="noopener noreferrer">
              <span>{a.label}</span><Icon name="external" size={16} />
            </a>
          ))}
        </div>
      )}
      {menu === "more" && (
        <div className="place-menu" role="menu">
          {!isHome && (
            <button className="place-menu-row" role="menuitem" onClick={() => { setShortcut("home", full); setMenu(null); emit("toast", { text: home ? "Maison mise à jour" : "Maison enregistrée", tone: "good" }); }}>
              <span>{home ? "Remplacer l'adresse de la maison" : "Définir comme Maison"}</span><Icon name="home" size={16} />
            </button>
          )}
          {!isWork && (
            <button className="place-menu-row" role="menuitem" onClick={() => { setShortcut("work", full); setMenu(null); emit("toast", { text: work ? "Travail mis à jour" : "Travail enregistré", tone: "good" }); }}>
              <span>{work ? "Remplacer l'adresse du travail" : "Définir comme Travail"}</span><Icon name="work" size={16} />
            </button>
          )}
          <button className="place-menu-row" role="menuitem" onClick={async () => {
            try { await navigator.clipboard.writeText(shareUrl(full)); emit("toast", { text: "Lien copié", tone: "good" }); } catch { /* refusé */ }
            setMenu(null);
          }}>
            <span>Copier le lien</span><Icon name="copy" size={16} />
          </button>
        </div>
      )}
    </Sheet>
  );
}
