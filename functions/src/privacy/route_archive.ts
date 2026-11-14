import { gunzipSync, gzipSync } from "node:zlib";

/**
 * Location history (owner decision, 14 Nov 2026): when a run's tracking
 * stops, its live points (deleted within 24 hours) are archived as ONE
 * compressed, down-sampled track: about one point every 30 seconds,
 * encoded as a Google encoded polyline (precision 5, about 1 m) plus the
 * seconds since the start of each point, gzipped. Stored in a Coldline
 * bucket path for 1 year, readable only by admins through a logged reason
 * (safety investigations). Never shown to other parents after the run.
 * Pure; unit-tested. Coordinates are never logged.
 */

export interface TrackPoint {
  lat: number;
  lng: number;
  atMs: number;
}

/** About one point every 30 seconds. */
export const ARCHIVE_INTERVAL_MS = 30_000;
/** A run is at most 4 hours of tracking (trips/model.ts): 480 points at 30 s. Hard cap. */
export const MAX_ARCHIVE_POINTS = 1_000;
export const ARCHIVE_VERSION = 1;

/** Storage path of one run's archive, by the year of its start (Coldline; lifecycle rule). */
export function archivePath(tripId: string, startedAtMs: number): string {
  if (!/^[A-Za-z0-9_-]{1,200}$/.test(tripId)) throw new Error("bad trip id");
  return `routeArchive/${new Date(startedAtMs).getUTCFullYear()}/${tripId}.json.gz`;
}

function valid(p: TrackPoint): boolean {
  return Number.isFinite(p.lat) && Number.isFinite(p.lng) && Number.isFinite(p.atMs) && Math.abs(p.lat) <= 90 && Math.abs(p.lng) <= 180;
}

/**
 * Keeps the first point, then the first point at least [intervalMs] after
 * the last kept one, and always the last point (where tracking stopped).
 * Invalid points are dropped; the result is in time order.
 */
export function downsample(points: readonly TrackPoint[], intervalMs = ARCHIVE_INTERVAL_MS): TrackPoint[] {
  const sorted = points.filter(valid).sort((a, b) => a.atMs - b.atMs);
  if (sorted.length === 0) return [];
  const out: TrackPoint[] = [sorted[0]];
  for (let i = 1; i < sorted.length; i++) {
    if (sorted[i].atMs - out[out.length - 1].atMs >= intervalMs) out.push(sorted[i]);
  }
  const last = sorted[sorted.length - 1];
  if (out[out.length - 1] !== last) out.push(last);
  if (out.length <= MAX_ARCHIVE_POINTS) return out;
  // Longer than any real run: thin evenly, keeping both ends.
  const step = (out.length - 1) / (MAX_ARCHIVE_POINTS - 1);
  return Array.from({ length: MAX_ARCHIVE_POINTS }, (_, i) => out[Math.round(i * step)]);
}

function encodeSigned(value: number): string {
  let v = value < 0 ? ~(value << 1) : value << 1;
  let out = "";
  while (v >= 0x20) {
    out += String.fromCharCode((0x20 | (v & 0x1f)) + 63);
    v >>= 5;
  }
  return out + String.fromCharCode(v + 63);
}

/** Google's encoded polyline algorithm (precision 5). */
export function encodePolyline(points: ReadonlyArray<{ lat: number; lng: number }>): string {
  let lastLat = 0;
  let lastLng = 0;
  let out = "";
  for (const p of points) {
    const lat = Math.round(p.lat * 1e5);
    const lng = Math.round(p.lng * 1e5);
    out += encodeSigned(lat - lastLat) + encodeSigned(lng - lastLng);
    lastLat = lat;
    lastLng = lng;
  }
  return out;
}

export function decodePolyline(encoded: string): Array<{ lat: number; lng: number }> {
  const out: Array<{ lat: number; lng: number }> = [];
  let index = 0;
  let lat = 0;
  let lng = 0;
  const next = (): number => {
    let result = 0;
    let shift = 0;
    let b: number;
    do {
      if (index >= encoded.length) throw new Error("bad polyline");
      b = encoded.charCodeAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    return result & 1 ? ~(result >> 1) : result >> 1;
  };
  while (index < encoded.length) {
    lat += next();
    lng += next();
    out.push({ lat: lat / 1e5, lng: lng / 1e5 });
  }
  return out;
}

export interface RouteArchive {
  v: number;
  tripId: string;
  carpoolId: string;
  driverUid: string;
  startedAtMs: number;
  endedAtMs: number;
  intervalMs: number;
  /** Seconds since [startedAtMs] of each point (same order as the polyline). */
  t: number[];
  polyline: string;
}

export interface ArchiveMeta {
  tripId: string;
  carpoolId: string;
  driverUid: string;
  startedAtMs: number;
  endedAtMs: number;
}

/** The gzipped archive and how many points it holds (0 = nothing to archive). */
export function packArchive(meta: ArchiveMeta, points: readonly TrackPoint[]): { data: Buffer; points: number } {
  const kept = downsample(points);
  const archive: RouteArchive = {
    v: ARCHIVE_VERSION,
    ...meta,
    intervalMs: ARCHIVE_INTERVAL_MS,
    t: kept.map((p) => Math.max(0, Math.round((p.atMs - meta.startedAtMs) / 1000))),
    polyline: encodePolyline(kept),
  };
  return { data: gzipSync(Buffer.from(JSON.stringify(archive), "utf8"), { level: 9 }), points: kept.length };
}

/** Admin view (logged): the archive back as points. */
export function unpackArchive(data: Buffer): { meta: ArchiveMeta; points: TrackPoint[] } {
  const archive = JSON.parse(gunzipSync(data).toString("utf8")) as RouteArchive;
  if (archive.v !== ARCHIVE_VERSION || !Array.isArray(archive.t) || typeof archive.polyline !== "string") throw new Error("bad archive");
  const coords = decodePolyline(archive.polyline);
  if (coords.length !== archive.t.length) throw new Error("bad archive");
  return {
    meta: { tripId: archive.tripId, carpoolId: archive.carpoolId, driverUid: archive.driverUid, startedAtMs: archive.startedAtMs, endedAtMs: archive.endedAtMs },
    points: coords.map((c, i) => ({ ...c, atMs: archive.startedAtMs + archive.t[i] * 1000 })),
  };
}
