import { useEffect, useState } from "react";
import { core, useCore, type LngLat } from "../../core/store";
import { emit } from "../../core/bus";
import { distance } from "../../core/geometry";
import { Icon } from "./icons";
import { ago, distanceLabel } from "./format";
import { Sheet } from "./Sheet";
import { goTo, openPlace, parkCar, removeRecent, startPicking, useSearch, type Saved } from "./state";

/** Suggestion contextuelle selon l'heure et l'endroit (« Rentrer à la maison » le soir…). */
function useSuggestion(pos: LngLat | null, home: Saved | null, work: Saved | null, car: Saved | null) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => { const t = window.setInterval(() => setNow(new Date()), 60_000); return () => window.clearInterval(t); }, []);
  if (!pos) return null;
  const h = now.getHours();
  const weekday = now.getDay() >= 1 && now.getDay() <= 5;
  const far = (p: Saved | null, m: number) => !!p && distance(pos, p.coord) > m;
  if (home && far(home, 500) && (h >= 16 || h < 3)) return { place: home, title: "Rentrer à la maison", icon: "home" };
  if (work && far(work, 500) && weekday && h >= 6 && h < 11) return { place: work, title: "Aller au travail", icon: "work" };
  if (car && car.time && Date.now() - car.time < 36 * 3600_000 && far(car, 150) && !far(car, 5000)) {
    return { place: car, title: "Retourner à ma voiture", icon: "car" };
  }
  return null;
}

export function Home() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const position = useCore((s) => s.position);
  const { home, work, car, favorites, recents, focused, expanded, set } = useSearch();
  const pos = position?.coord ?? null;
  const suggestion = useSuggestion(pos, home, work, car);

  if (mode !== "browse" || panel !== null || focused) return null;

  const tile = (key: string, icon: string, label: string, sub: string | null, onClick: () => void, opts: { empty?: boolean; accent?: boolean } = {}) => (
    <button key={key} className={`home-tile${opts.empty ? " is-empty" : ""}`} onClick={onClick}>
      <span className="home-tile-icon"><Icon name={icon} size={22} /></span>
      <span className="home-tile-label">{label}</span>
      <span className="home-tile-sub">{sub ?? " "}</span>
    </button>
  );

  const parkHere = () => {
    if (!pos) return emit("toast", { text: "Position inconnue pour le moment", tone: "warn" });
    parkCar(pos);
    emit("toast", { text: "Position de la voiture enregistrée", tone: "good" });
  };

  return (
    <Sheet
      className={`search-home${expanded ? " is-expanded" : ""}`}
      onExpand={(up) => set({ expanded: up === null ? !expanded : up })}
      ariaLabel="Accueil"
    >
      {suggestion && (
        <div className="home-suggest">
          <span className="home-suggest-icon"><Icon name={suggestion.icon} size={20} /></span>
          <button className="home-suggest-text" onClick={() => openPlace({ ...suggestion.place, from: "home" })}>
            <span className="home-suggest-title">{suggestion.title}</span>
            <span className="home-suggest-sub">
              {[distanceLabel(pos, suggestion.place.coord), suggestion.place.detail ?? suggestion.place.name].filter(Boolean).join(" · ")}
            </span>
          </button>
          <button className="pill home-suggest-go" onClick={() => goTo(suggestion.place)}>Y aller</button>
        </div>
      )}

      <div className="home-tiles" role="list">
        {home
          ? tile("home", "home", "Maison", distanceLabel(pos, home.coord), () => goTo(home))
          : tile("home", "home", "Maison", "Définir", () => startPicking("home"), { empty: true })}
        {work
          ? tile("work", "work", "Travail", distanceLabel(pos, work.coord), () => goTo(work))
          : tile("work", "work", "Travail", "Définir", () => startPicking("work"), { empty: true })}
        {car
          ? tile("car", "car", "Ma voiture", car.time ? ago(car.time) : distanceLabel(pos, car.coord), () => openPlace({ ...car, from: "home" }))
          : tile("car", "car", "Garer ici", "Ma voiture", parkHere, { empty: true })}
        {favorites.map((f) => tile(f.id, "star", f.name, distanceLabel(pos, f.coord), () => openPlace({ ...f, from: "home" })))}
        {tile("add", "plus", "Ajouter", "un favori", () => startPicking("favorite"), { empty: true })}
      </div>

      {expanded && (
        <div className="home-recents">
          <div className="search-section">Récents</div>
          {recents.length === 0 && <p className="home-note">Vos dernières destinations apparaîtront ici.</p>}
          {recents.slice(0, 8).map((r) => (
            <div key={r.id + r.time} className="search-row" onClick={() => openPlace({ ...r, from: "home" })}>
              <span className="search-row-icon"><Icon name="clock" size={18} /></span>
              <span className="search-row-text">
                <span className="search-row-title">{r.name}</span>
                {r.detail && <span className="search-row-sub">{r.detail}</span>}
              </span>
              {pos && <span className="search-row-meta">{distanceLabel(pos, r.coord)}</span>}
              <button className="search-row-remove" aria-label={`Retirer ${r.name} des récents`} onClick={(e) => { e.stopPropagation(); removeRecent(r.id); }}>
                <Icon name="x" size={14} />
              </button>
            </div>
          ))}
          <button className="btn-ghost home-settings" onClick={() => core().set({ settingsOpen: true })}>
            Gérer mes lieux
          </button>
        </div>
      )}
    </Sheet>
  );
}
