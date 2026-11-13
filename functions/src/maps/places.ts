import type { LatLng } from "./geo";
import { inEgypt, isValidPoint } from "./geo";
import { MapError } from "./parent_map";

/**
 * Address search for the home picker (F21) through Cloud Functions: the
 * Places API key stays on the server (Secret Manager), searches are rate
 * limited per parent, and place details are cached.
 *
 * COST MODE (docs/COSTS.md): the app waits 400 ms after the last key press,
 * needs 3 letters, and sends one session token per search; the details call
 * ends the session. Details ask only for id, formattedAddress and location
 * (the cheaper "Essentials" fields) and are cached for 30 days (the most
 * Google's terms allow for coordinates). With Essentials details, Google
 * still bills the first autocomplete requests of a session (inside the
 * monthly free calls), so searches are also limited per parent per hour.
 */

export interface PlaceSuggestion {
  placeId: string;
  primary: string;
  secondary: string;
}

export interface PlaceDetails {
  placeId: string;
  label: string;
  location: LatLng;
}

export interface PlacesProvider {
  autocomplete(input: string, sessionToken: string, language: "ar" | "en", near: LatLng | null): Promise<PlaceSuggestion[]>;
  details(placeId: string, sessionToken: string, language: "ar" | "en"): Promise<PlaceDetails | null>;
}

export interface PlaceCache {
  get(key: string, nowMs: number): Promise<PlaceDetails | null>;
  put(key: string, details: PlaceDetails, expiresAtMs: number): Promise<void>;
}

export const PLACE_CACHE_DAYS = 30;
export const MAX_SUGGESTIONS = 5;

const TOKEN = /^[A-Za-z0-9_-]{8,64}$/;
const PLACE_ID = /^[A-Za-z0-9_-]{4,256}$/;

function record(data: unknown): Record<string, unknown> {
  return typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Record<string, unknown>) : {};
}

function language(value: unknown): "ar" | "en" {
  return value === "en" ? "en" : "ar";
}

export function parseAutocomplete(data: unknown): { input: string; sessionToken: string; language: "ar" | "en"; near: LatLng | null } {
  const raw = record(data);
  const input = typeof raw.input === "string" ? raw.input.trim().replace(/\s+/g, " ") : "";
  if (input.length < 3 || input.length > 100) throw new MapError("invalid-request");
  if (typeof raw.sessionToken !== "string" || !TOKEN.test(raw.sessionToken)) throw new MapError("invalid-request");
  const near = isValidPoint(raw.near) && inEgypt(raw.near) ? raw.near : null;
  return { input, sessionToken: raw.sessionToken, language: language(raw.language), near };
}

export function parseDetails(data: unknown): { placeId: string; sessionToken: string; language: "ar" | "en" } {
  const raw = record(data);
  if (typeof raw.placeId !== "string" || !PLACE_ID.test(raw.placeId)) throw new MapError("invalid-request");
  if (typeof raw.sessionToken !== "string" || !TOKEN.test(raw.sessionToken)) throw new MapError("invalid-request");
  return { placeId: raw.placeId, sessionToken: raw.sessionToken, language: language(raw.language) };
}

export async function autocomplete(provider: PlacesProvider, data: unknown): Promise<{ suggestions: PlaceSuggestion[] }> {
  const input = parseAutocomplete(data);
  const suggestions = await provider.autocomplete(input.input, input.sessionToken, input.language, input.near);
  return { suggestions: suggestions.slice(0, MAX_SUGGESTIONS) };
}

/** Details from the cache or the provider. Places outside Egypt are refused. */
export async function placeDetails(
  deps: {
    provider: PlacesProvider;
    cache: PlaceCache;
    now: () => number;
    /** Called before a billed provider call (cache miss): rate limit. */
    beforeProviderCall?: () => Promise<void>;
  },
  data: unknown,
): Promise<PlaceDetails> {
  const input = parseDetails(data);
  const key = `${input.language}_${input.placeId}`.slice(0, 300);
  const cached = await deps.cache.get(key, deps.now());
  if (!cached && deps.beforeProviderCall) await deps.beforeProviderCall();
  const details = cached ?? (await deps.provider.details(input.placeId, input.sessionToken, input.language));
  if (!details || !isValidPoint(details.location)) throw new MapError("invalid-request");
  if (!inEgypt(details.location)) throw new MapError("outside-egypt");
  if (!cached) await deps.cache.put(key, details, deps.now() + PLACE_CACHE_DAYS * 24 * 60 * 60 * 1000);
  return details;
}

// --------------------------------------------------------------------------
// Providers
// --------------------------------------------------------------------------

type Fetch = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

/** Places API (New) over REST. */
export class GooglePlacesProvider implements PlacesProvider {
  constructor(
    private readonly apiKey: string,
    private readonly fetchFn: Fetch = fetch as unknown as Fetch,
  ) {}

  async autocomplete(input: string, sessionToken: string, lang: "ar" | "en", near: LatLng | null): Promise<PlaceSuggestion[]> {
    const body: Record<string, unknown> = { input, sessionToken, languageCode: lang, includedRegionCodes: ["eg"] };
    if (near) body.locationBias = { circle: { center: { latitude: near.lat, longitude: near.lng }, radius: 30000 } };
    const response = await this.fetchFn("https://places.googleapis.com/v1/places:autocomplete", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": this.apiKey,
        "X-Goog-FieldMask": "suggestions.placePrediction.placeId,suggestions.placePrediction.structuredFormat",
      },
      body: JSON.stringify(body),
    });
    if (!response.ok) throw new Error(`places autocomplete failed with ${response.status}`);
    const json = record(await response.json());
    const suggestions = Array.isArray(json.suggestions) ? json.suggestions : [];
    const out: PlaceSuggestion[] = [];
    for (const s of suggestions) {
      const p = record(record(s).placePrediction);
      const f = record(p.structuredFormat);
      const primary = record(f.mainText).text;
      const secondary = record(f.secondaryText).text;
      if (typeof p.placeId === "string" && typeof primary === "string") {
        out.push({ placeId: p.placeId, primary, secondary: typeof secondary === "string" ? secondary : "" });
      }
    }
    return out;
  }

  async details(placeId: string, sessionToken: string, lang: "ar" | "en"): Promise<PlaceDetails | null> {
    const query = `languageCode=${lang}&regionCode=eg&sessionToken=${encodeURIComponent(sessionToken)}`;
    const response = await this.fetchFn(`https://places.googleapis.com/v1/places/${encodeURIComponent(placeId)}?${query}`, {
      method: "GET",
      headers: { "X-Goog-Api-Key": this.apiKey, "X-Goog-FieldMask": "id,formattedAddress,location" },
    });
    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`place details failed with ${response.status}`);
    const json = record(await response.json());
    const loc = record(json.location);
    if (typeof loc.latitude !== "number" || typeof loc.longitude !== "number") return null;
    return {
      placeId,
      label: typeof json.formattedAddress === "string" ? json.formattedAddress : "",
      location: { lat: loc.latitude, lng: loc.longitude },
    };
  }
}

/** Fake places for dev and CI (PLACES_PROVIDER=fake): no key, no cost. */
export const FAKE_PLACES: ReadonlyArray<PlaceDetails & { ar: string; en: string; areaAr: string; areaEn: string }> = [
  { placeId: "fake-maadi", ar: "شارع 9، المعادي", en: "Road 9, Maadi", areaAr: "القاهرة", areaEn: "Cairo", label: "", location: { lat: 29.9602, lng: 31.2569 } },
  { placeId: "fake-zamalek", ar: "شارع 26 يوليو، الزمالك", en: "26th of July St, Zamalek", areaAr: "القاهرة", areaEn: "Cairo", label: "", location: { lat: 30.0626, lng: 31.2197 } },
  { placeId: "fake-heliopolis", ar: "شارع الثورة، مصر الجديدة", en: "El Thawra St, Heliopolis", areaAr: "القاهرة", areaEn: "Cairo", label: "", location: { lat: 30.0911, lng: 31.3226 } },
  { placeId: "fake-dokki", ar: "شارع التحرير، الدقي", en: "Tahrir St, Dokki", areaAr: "الجيزة", areaEn: "Giza", label: "", location: { lat: 30.0384, lng: 31.2101 } },
  { placeId: "fake-tagamoa", ar: "التجمع الخامس", en: "Fifth Settlement", areaAr: "القاهرة الجديدة", areaEn: "New Cairo", label: "", location: { lat: 30.0074, lng: 31.4913 } },
  { placeId: "fake-sheikhzayed", ar: "الشيخ زايد", en: "Sheikh Zayed", areaAr: "الجيزة", areaEn: "Giza", label: "", location: { lat: 30.0444, lng: 30.9762 } },
  { placeId: "fake-smouha", ar: "سموحة", en: "Smouha", areaAr: "الإسكندرية", areaEn: "Alexandria", label: "", location: { lat: 31.2156, lng: 29.9553 } },
];

export class FakePlacesProvider implements PlacesProvider {
  async autocomplete(input: string, _token: string, lang: "ar" | "en", _near: LatLng | null): Promise<PlaceSuggestion[]> {
    const q = input.toLowerCase();
    return FAKE_PLACES.filter((p) => `${p.ar} ${p.en} ${p.areaAr} ${p.areaEn}`.toLowerCase().includes(q)).map((p) => ({
      placeId: p.placeId,
      primary: lang === "ar" ? p.ar : p.en,
      secondary: lang === "ar" ? p.areaAr : p.areaEn,
    }));
  }

  async details(placeId: string, _token: string, lang: "ar" | "en"): Promise<PlaceDetails | null> {
    const p = FAKE_PLACES.find((x) => x.placeId === placeId);
    if (!p) return null;
    return {
      placeId,
      label: lang === "ar" ? `${p.ar}، ${p.areaAr}` : `${p.en}, ${p.areaEn}`,
      location: p.location,
    };
  }
}
