import { create } from "zustand";
import { core, type LngLat } from "../../core/store";
import { emit } from "../../core/bus";
import { distance } from "../../core/geometry";
import { loadLocal, saveLocal } from "../../core/identity";
import type { SearchResult } from "./api";

/** Un lieu enregistré (maison, travail, favori, récent, voiture). */
export interface Saved {
  id: string;
  name: string;
  detail?: string;
  coord: LngLat;
  kind?: string;
  typeLabel?: string;
  /** Horodatage (récents : dernière utilisation ; voiture : heure de stationnement). */
  time?: number;
}

/** Données du panneau "place" (fiche lieu). D'autres modules peuvent ouvrir ce panneau avec un `Place` du core. */
export interface PlaceData extends Saved {
  /** D'où vient la fiche (pour le bouton retour). */
  from?: "list" | "search" | "map" | "link" | "home";
  /** Adresse à compléter par géocodage inverse (appui long, lien partagé). */
  needsAddress?: boolean;
}

export type PickTarget = "home" | "work" | "favorite";

interface CategoryState {
  id: string;
  center: LngLat;
  results: SearchResult[];
  loading: boolean;
  error: string | null;
}

interface SearchState {
  home: Saved | null;
  work: Saved | null;
  favorites: Saved[];
  recents: Saved[];
  car: Saved | null;

  query: string;
  focused: boolean;
  picking: PickTarget | null;
  category: CategoryState | null;
  /** Accueil déplié (récents visibles). */
  expanded: boolean;

  set: (p: Partial<SearchState>) => void;
}

const K = {
  home: "search.home",
  work: "search.work",
  favorites: "search.favorites",
  recents: "search.recents",
  car: "search.car",
} as const;

export const useSearch = create<SearchState>((set) => ({
  home: loadLocal<Saved | null>(K.home, null),
  work: loadLocal<Saved | null>(K.work, null),
  favorites: loadLocal<Saved[]>(K.favorites, []),
  recents: loadLocal<Saved[]>(K.recents, []),
  car: loadLocal<Saved | null>(K.car, null),
  query: "",
  focused: false,
  picking: null,
  category: null,
  expanded: false,
  set: (p) => set(p),
}));

export const search = () => useSearch.getState();

// persistance : seules les données « lieux » sont écrites, à chaque changement
useSearch.subscribe((s, prev) => {
  if (s.home !== prev.home) saveLocal(K.home, s.home);
  if (s.work !== prev.work) saveLocal(K.work, s.work);
  if (s.favorites !== prev.favorites) saveLocal(K.favorites, s.favorites);
  if (s.recents !== prev.recents) saveLocal(K.recents, s.recents);
  if (s.car !== prev.car) saveLocal(K.car, s.car);
});

/* ------------------------------------------------------------------ helpers ----------------- */

const near = (a: LngLat, b: LngLat, m = 60) => distance(a, b) < m;

function clean(p: Saved): Saved {
  return {
    id: p.id,
    name: p.name.slice(0, 120),
    detail: p.detail?.slice(0, 160),
    coord: [Number(p.coord[0].toFixed(6)), Number(p.coord[1].toFixed(6))],
    kind: p.kind,
    typeLabel: p.typeLabel,
  };
}

export function addRecent(p: Saved) {
  const s = search();
  const item = { ...clean(p), time: Date.now() };
  const rest = s.recents.filter((r) => !near(r.coord, item.coord));
  s.set({ recents: [item, ...rest].slice(0, 20) });
}

export function removeRecent(id: string) {
  const s = search();
  s.set({ recents: s.recents.filter((r) => r.id !== id) });
}

export function clearRecents() {
  search().set({ recents: [] });
}

export function isFavorite(c: LngLat) {
  return search().favorites.some((f) => near(f.coord, c, 30));
}

export function toggleFavorite(p: Saved): boolean {
  const s = search();
  if (isFavorite(p.coord)) {
    s.set({ favorites: s.favorites.filter((f) => !near(f.coord, p.coord, 30)) });
    return false;
  }
  s.set({ favorites: [...s.favorites, { ...clean(p), id: `fav:${Date.now().toString(36)}` }].slice(0, 40) });
  return true;
}

export function renameFavorite(id: string, name: string) {
  const s = search();
  const n = name.trim().slice(0, 60);
  if (!n) return;
  s.set({ favorites: s.favorites.map((f) => (f.id === id ? { ...f, name: n } : f)) });
}

export function removeFavorite(id: string) {
  const s = search();
  s.set({ favorites: s.favorites.filter((f) => f.id !== id) });
}

export function setShortcut(which: "home" | "work", p: Saved | null) {
  search().set({ [which]: p ? { ...clean(p), id: which, kind: which } : null } as Partial<SearchState>);
}

export function parkCar(coord: LngLat, detail?: string) {
  search().set({ car: { id: "car", name: "Ma voiture", detail, coord, kind: "car", time: Date.now() } });
}

export function forgetCar() {
  search().set({ car: null });
}

/* ------------------------------------------------------------------ actions ----------------- */

/** Ouvre la fiche d'un lieu et centre la carte dessus (au-dessus du panneau). */
export function openPlace(p: PlaceData) {
  search().set({ focused: false });
  core().openPanel("place", p);
  flyTo(p.coord);
}

export function flyTo(c: LngLat, zoom?: number) {
  const map = core().map;
  if (!map) return;
  core().set({ follow: false });
  map.easeTo({
    center: c,
    zoom: zoom ?? Math.max(map.getZoom(), 15),
    padding: { top: 80, bottom: Math.round(window.innerHeight * 0.38), left: 0, right: 0 },
    duration: 650,
  });
}

/** Choisit ce lieu comme destination : le module routing calcule et passe en aperçu. */
export function goTo(p: Saved) {
  const s = search();
  if (p.kind !== "home" && p.kind !== "work" && p.kind !== "car") addRecent(p);
  s.set({ category: null, focused: false, query: "", picking: null });
  core().openPanel(null);
  emit("place:go", { name: p.name, lng: p.coord[0], lat: p.coord[1] });
}

/** Mode « choisir un lieu » (définir Maison / Travail / ajouter un favori) : la recherche s'ouvre. */
export function startPicking(target: PickTarget) {
  core().set({ settingsOpen: false });
  core().openPanel(null);
  search().set({ picking: target, focused: true, query: "", category: null });
}

/** Termine le mode « choisir » avec ce lieu. */
export function completePick(p: Saved) {
  const s = search();
  const t = s.picking;
  if (!t) return;
  if (t === "favorite") {
    if (!isFavorite(p.coord)) toggleFavorite(p);
    emit("toast", { text: `« ${p.name} » ajouté aux favoris`, tone: "good" });
  } else {
    setShortcut(t, p);
    emit("toast", { text: t === "home" ? "Adresse de la maison enregistrée" : "Adresse du travail enregistrée", tone: "good" });
  }
  s.set({ picking: null, focused: false, query: "" });
}

export const PICK_LABEL: Record<PickTarget, string> = {
  home: "Adresse de la maison",
  work: "Adresse du travail",
  favorite: "Ajouter un favori",
};
