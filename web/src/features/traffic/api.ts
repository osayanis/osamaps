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

export type EventKind = "closure" | "accident" | "slow" | "obstacle" | "conditions" | "works" | "lanes";

export interface EventProps {
  id: string;
  kind: EventKind;
  title: string;
  road: string | null;
  description: string | null;
  where: string | null;
  source: string | null;
  severity: string | null;
  end: string | null;
}

export interface EventFeature {
  type: "Feature";
  geometry: { type: "Point"; coordinates: LngLat };
  properties: EventProps;
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

export const fetchEvents = (b: Bbox) =>
  api<{ type: "FeatureCollection"; features: EventFeature[] }>(`traffic/events?bbox=${q(b)}`);

export const fetchAlong = (coords: LngLat[]) =>
  api<AlongResult>("traffic/along", { method: "POST", body: JSON.stringify({ coords }) });
