/** Puces « autour de moi » : catégorie → filtres Photon (`include=osm.<clé>.<valeur>`). */
export interface Category {
  id: string;
  label: string;
  /** Libellé au singulier pour la fiche (« Station-service »). */
  single: string;
  icon: string;
  include: string[];
  /** Rayon max affiché (km). */
  maxKm: number;
}

export const CATEGORIES: Category[] = [
  { id: "fuel", label: "Essence", single: "Station-service", icon: "fuel", include: ["osm.amenity.fuel"], maxKm: 25 },
  { id: "charge", label: "Recharge", single: "Borne de recharge", icon: "charge", include: ["osm.amenity.charging_station"], maxKm: 60 },
  { id: "parking", label: "Parking", single: "Parking", icon: "parking", include: ["osm.amenity.parking"], maxKm: 10 },
  { id: "food", label: "Restos", single: "Restaurant", icon: "food", include: ["osm.amenity.restaurant", "osm.amenity.fast_food"], maxKm: 20 },
  { id: "bakery", label: "Boulangerie", single: "Boulangerie", icon: "bakery", include: ["osm.shop.bakery"], maxKm: 15 },
  { id: "cafe", label: "Cafés", single: "Café", icon: "cafe", include: ["osm.amenity.cafe"], maxKm: 15 },
  { id: "pharmacy", label: "Pharmacie", single: "Pharmacie", icon: "pharmacy", include: ["osm.amenity.pharmacy"], maxKm: 20 },
  { id: "shop", label: "Supermarché", single: "Supermarché", icon: "shop", include: ["osm.shop.supermarket"], maxKm: 20 },
  { id: "toilets", label: "Toilettes", single: "Toilettes", icon: "toilets", include: ["osm.amenity.toilets"], maxKm: 30 },
  { id: "health", label: "Hôpital", single: "Hôpital", icon: "health", include: ["osm.amenity.hospital"], maxKm: 60 },
];

export const categoryById = (id: string) => CATEGORIES.find((c) => c.id === id);
