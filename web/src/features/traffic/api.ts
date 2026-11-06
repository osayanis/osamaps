import { api } from "../../core/services";
import type { LngLat } from "../../core/store";
import type { Level } from "./state";

export type Bbox = [number, number, number, number];

export interface SegmentProps {
  id: string;
  /** "osa" = contributions OsaMaps ; "dir" = station de mesure Bison Futé / DIR. */
  src: "osa" | "dir";
  level: Level;
  speed: number;
  usual: number | null;
  road?: string | null;
  delay: number;
  n?: number;
}

export interface SegmentFeature {
  type: "Feature";
  geometry: { type: "LineString"; coordinates: LngLat[] };
  properties: SegmentProps;
}

export interface Jam {
  id: string;
  level: Level;
  length: number;
  delay: number;
  speed: number;
  heading: number;
  start: LngLat;
  end: LngLat;
  contributors: number;
}

export type EventKind = "closure" | "accident" | "jam" | "danger" | "flood" | "weather" | "lanes" | "works" | "fuel" | "hotspot";

export interface EventSource { id: string; name: string }

/** Évènement fusionné multi-sources (server/features/events.js). */
export interface EventProps {
  id: string;
  type: EventKind;
  /** 1 info · 2 gêne · 3 forte · 4 critique */
  severity: number;
  title: string;
  description: string | null;
  original: string | null;
  lang: string | null;
  road: string | null;
  direction: string | null;
  lanes: string | null;
  start: string | null;
  end: string | null;
  delay: number | null;
  speed: number | null;
  blocking: boolean;
  confidence: number;
  sources: EventSource[];
  merged: number;
  relatedJam: { id: string; delay: number | null; speed: number | null; distance: number } | null;
  line: LngLat[] | null;
  /** Zoom minimal d'affichage calculé par le serveur selon l'importance (carte « comme Waze »). */
  minZoom?: number;
}

export interface EventFeature {
  type: "Feature";
  geometry: { type: "Point"; coordinates: LngLat };
  properties: EventProps;
}

export interface RouteEventsResult {
  events: (EventProps & { point: LngLat; at: number; length: number; routeDelay: number; alreadyMeasured: boolean })[];
  totalDelay: number;
  length: number;
  at: number;
}

export interface AlongResult {
  runs: { from: number; to: number; level: Level; delay: number; speed: number; sources: string[] }[];
  totalDelay: number;
  length: number;
  at: number;
}

const q = (b: Bbox) => b.map((x) => x.toFixed(4)).join(",");

export const fetchSegments = (b: Bbox) =>
  api<{ type: "FeatureCollection"; features: SegmentFeature[]; jams: Jam[] }>(`traffic?bbox=${q(b)}`);

export const fetchEvents = (b: Bbox, zoom: number) =>
  api<{ type: "FeatureCollection"; features: EventFeature[] }>(`events?bbox=${q(b)}&z=${zoom.toFixed(1)}`);

export const fetchRouteEvents = (coords: LngLat[]) =>
  api<RouteEventsResult>("events/route", { method: "POST", body: JSON.stringify({ coords }) });

export const fetchAlong = (coords: LngLat[]) =>
  api<AlongResult>("traffic/along", { method: "POST", body: JSON.stringify({ coords }) });
