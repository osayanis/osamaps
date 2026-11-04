import type { Feature } from "../../core/registry";
import { core, useCore } from "../../core/store";
import { emit, on } from "../../core/bus";
import { distance } from "../../core/geometry";
import { SearchBar } from "./SearchBar";
import { Home } from "./Home";
import { PlaceSheet } from "./PlaceSheet";
import { CategoryList } from "./CategoryList";
import { MapLayer } from "./MapLayer";
import { SearchSettings } from "./Settings";
import { reverseGeocode } from "./api";
import { dropLieuParam, parseLieuParam } from "./share";
import { addRecent, openPlace, parkCar, search } from "./state";
import "./search.css";

/**
 * Recherche & lieux : barre de recherche (BAN/IGN + Photon), puces « autour de moi », accueil
 * (Maison, Travail, favoris, récents, Ma voiture), fiche lieu (panneau "place"), appui long sur
 * la carte, liens partagés `?lieu=lat,lng,nom`, réglages « Mes lieux ».
 */
function init() {
  const offs: (() => void)[] = [];

  // toute destination choisie (par n'importe quel module) rejoint les récents
  offs.push(on("place:go", ({ name, lng, lat }) => {
    const s = search();
    const c: [number, number] = [lng, lat];
    const last = s.recents[0];
    if (last && last.time && Date.now() - last.time < 3000 && distance(last.coord, c) < 60) return;
    for (const p of [s.home, s.work, s.car]) if (p && distance(p.coord, c) < 60) return;
    addRecent({ id: `go:${lng.toFixed(5)},${lat.toFixed(5)}`, name, coord: c });
  }));

  // arrivée : on retient où la voiture est garée
  offs.push(on("drive:arrived", () => {
    const pos = core().position?.coord;
    if (!pos) return;
    parkCar(pos);
    emit("toast", { text: "Position de la voiture enregistrée", tone: "good" });
    reverseGeocode(pos).then((a) => {
      const car = search().car;
      if (a && car && car.coord === pos) search().set({ car: { ...car, detail: [a.name, a.detail].filter(Boolean).join(", ") } });
    }).catch(() => {});
  }));

  // en quittant l'exploration (aperçu, conduite) : on range la recherche
  offs.push(useCore.subscribe((s, prev) => {
    if (s.mode === prev.mode) return;
    if (s.mode !== "browse") search().set({ focused: false, picking: null });
    else if (prev.mode === "drive") search().set({ category: null });
  }));

  // lien partagé ?lieu=lat,lng,nom : on ouvre la fiche quand la carte est prête
  const lieu = parseLieuParam();
  if (lieu) {
    const open = () => {
      openPlace({
        id: `link:${lieu.coord.join(",")}`,
        name: lieu.name ?? "Point sur la carte",
        coord: lieu.coord,
        kind: lieu.name ? "poi" : "map",
        from: "link",
        needsAddress: true,
      });
      dropLieuParam();
    };
    if (core().mapReady) open();
    else {
      const off = useCore.subscribe((s) => { if (s.mapReady) { off(); open(); } });
      offs.push(off);
    }
  }

  return () => offs.forEach((f) => f());
}

/** Un seul occupant du slot "sheet" par module (le shell indexe les composants par id de module). */
function SearchSheet() {
  return (
    <>
      <Home />
      <PlaceSheet />
      <CategoryList />
    </>
  );
}

export const searchFeature: Feature = {
  id: "search",
  name: "Recherche & lieux",
  init,
  slots: [
    { slot: "top", order: 0, Component: SearchBar },
    { slot: "sheet", order: 10, Component: SearchSheet },
    { slot: "map", order: 20, Component: MapLayer },
    { slot: "settings", order: 10, Component: SearchSettings },
  ],
};

export default searchFeature;
