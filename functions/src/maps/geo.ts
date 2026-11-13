import { createHash } from "node:crypto";

/**
 * Geometry for the maps features (F21, F22, F23). Pure functions, no
 * Firebase: unit tested in test/maps.test.ts.
 *
 * Privacy (spec sections 6 and 7): another parent's home is never stored
 * or sent exactly. The server snaps it to the centre of a grid cell of
 * GRID_DEG degrees (about 555 m north-south and 480 m east-west in Cairo,
 * "about 500 m") before it is saved in the public record, and every
 * geohash is computed from that rounded point, never from the exact one.
 */

export interface LatLng {
  lat: number;
  lng: number;
}

/** Grid step in degrees: 0.005 degrees is about 500 m in Egypt. */
export const GRID_DEG = 0.005;

/** Markers move at most this far from the cell centre (inside the cell). */
export const JITTER_MAX_M = 150;

/** Radii a parent can choose on the nearby map, in km. */
export const RADIUS_CHOICES_KM = [1, 2, 3, 5, 10] as const;
export const DEFAULT_RADIUS_KM = 3;

/** Egypt's bounding box (same as the schools list, admin_panel/schools.ts). */
export const EGYPT_BOX = { minLat: 21.5, maxLat: 31.8, minLng: 24.5, maxLng: 37.1 };

const EARTH_RADIUS_KM = 6371.0088;
const METERS_PER_DEG_LAT = 111_320;
const BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz";

export function isValidPoint(value: unknown): value is LatLng {
  const p = value as Partial<LatLng> | null | undefined;
  return (
    typeof p === "object" && p !== null &&
    typeof p.lat === "number" && typeof p.lng === "number" &&
    Number.isFinite(p.lat) && Number.isFinite(p.lng)
  );
}

export function inEgypt(p: LatLng): boolean {
  const b = EGYPT_BOX;
  return p.lat >= b.minLat && p.lat <= b.maxLat && p.lng >= b.minLng && p.lng <= b.maxLng;
}

function round6(x: number): number {
  return Math.round(x * 1e6) / 1e6;
}

/**
 * The centre of the grid cell that holds [p]. Every point of a cell gives
 * the same answer, so the exact point cannot be recovered from it.
 */
export function roundToGrid(p: LatLng): LatLng {
  const cell = (x: number) => (Math.floor(x / GRID_DEG) + 0.5) * GRID_DEG;
  return { lat: round6(cell(p.lat)), lng: round6(cell(p.lng)) };
}

/** Great-circle distance in km. */
export function distanceKm(a: LatLng, b: LatLng): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Standard base-32 geohash. */
export function encodeGeohash(p: LatLng, precision: number): string {
  let latMin = -90, latMax = 90, lngMin = -180, lngMax = 180;
  let hash = "";
  let bit = 0;
  let ch = 0;
  let even = true;
  while (hash.length < precision) {
    if (even) {
      const mid = (lngMin + lngMax) / 2;
      if (p.lng >= mid) { ch = (ch << 1) | 1; lngMin = mid; } else { ch <<= 1; lngMax = mid; }
    } else {
      const mid = (latMin + latMax) / 2;
      if (p.lat >= mid) { ch = (ch << 1) | 1; latMin = mid; } else { ch <<= 1; latMax = mid; }
    }
    even = !even;
    if (++bit === 5) {
      hash += BASE32[ch];
      bit = 0;
      ch = 0;
    }
  }
  return hash;
}

/** Height and width in degrees of a geohash cell of [precision]. */
export function geohashCellDeg(precision: number): { lat: number; lng: number } {
  const bits = precision * 5;
  const lngBits = Math.ceil(bits / 2);
  const latBits = Math.floor(bits / 2);
  return { lat: 180 / 2 ** latBits, lng: 360 / 2 ** lngBits };
}

/** Precision stored in the public record (of the rounded point). */
export const STORED_GEOHASH_PRECISION = 7;

/** At most this many range queries per search (one per geohash cell). */
export const MAX_RANGES = 9;

/**
 * Geohash prefixes whose cells together cover the circle of [radiusKm]
 * around [center]: the finest precision that needs at most MAX_RANGES
 * cells. Each prefix h is one range query [h, h + "~"]. Results still need
 * the distance check (cells reach past the circle).
 */
export function geohashCoverPrefixes(center: LatLng, radiusKm: number): string[] {
  const dLat = (radiusKm * 1000) / METERS_PER_DEG_LAT;
  const dLng = dLat / Math.max(0.01, Math.cos((center.lat * Math.PI) / 180));
  const box = { minLat: center.lat - dLat, maxLat: center.lat + dLat, minLng: center.lng - dLng, maxLng: center.lng + dLng };
  for (let precision = 6; precision >= 1; precision--) {
    const cell = geohashCellDeg(precision);
    const prefixes = new Set<string>();
    // Half-cell steps never skip a cell; the far edges are added explicitly.
    const lats: number[] = [];
    for (let lat = box.minLat; lat < box.maxLat; lat += cell.lat / 2) lats.push(lat);
    lats.push(box.maxLat);
    const lngs: number[] = [];
    for (let lng = box.minLng; lng < box.maxLng; lng += cell.lng / 2) lngs.push(lng);
    lngs.push(box.maxLng);
    let tooMany = false;
    for (const lat of lats) {
      for (const lng of lngs) {
        prefixes.add(encodeGeohash({ lat, lng }, precision));
        if (prefixes.size > MAX_RANGES) { tooMany = true; break; }
      }
      if (tooMany) break;
    }
    if (!tooMany) return [...prefixes].sort();
  }
  return [encodeGeohash(center, 1)];
}

/**
 * A fixed offset of at most JITTER_MAX_M for one parent, so markers of the
 * same cell do not sit on top of each other. It is derived from the uid
 * only (the same every time, so repeated searches cannot average it away)
 * and stays inside the rounded cell. It hides nothing more than the
 * rounding already does.
 */
export function jitterFor(uid: string, rounded: LatLng): LatLng {
  const digest = createHash("sha256").update(`map-jitter:${uid}`).digest();
  const angle = (digest.readUInt16BE(0) / 65536) * 2 * Math.PI;
  const meters = (digest.readUInt16BE(2) / 65536) * JITTER_MAX_M;
  const dLat = (meters * Math.cos(angle)) / METERS_PER_DEG_LAT;
  const dLng = (meters * Math.sin(angle)) / (METERS_PER_DEG_LAT * Math.max(0.01, Math.cos((rounded.lat * Math.PI) / 180)));
  return { lat: round6(rounded.lat + dLat), lng: round6(rounded.lng + dLng) };
}
