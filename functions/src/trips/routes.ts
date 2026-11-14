import { distanceKm, type LatLng } from "../maps/geo";

/**
 * Arrival times (spec section 6, "Arrival time") through the Routes API,
 * from Cloud Functions only: the server key stays in Secret Manager and
 * the exact stop points never leave the server.
 *
 * COST MODE (docs/COSTS.md): asked only while a run is live, at most once a
 * minute per trip, and ONE request covers every stop still ahead (the
 * stops are intermediate waypoints; each leg's duration is one stop's
 * arrival). Field mask: legs' durations only.
 */

export interface RoutesProvider {
  readonly kind: "fake" | "google";
  /** Seconds per leg: origin -> waypoints[0] -> waypoints[1] ... */
  legs(origin: LatLng, waypoints: LatLng[]): Promise<number[]>;
}

/** Fake (dev and CI): straight line at 25 km/h plus one minute per stop. No key, no cost. */
export class FakeRoutesProvider implements RoutesProvider {
  readonly kind = "fake";

  async legs(origin: LatLng, waypoints: LatLng[]): Promise<number[]> {
    const out: number[] = [];
    let from = origin;
    for (const w of waypoints) {
      out.push(Math.round((distanceKm(from, w) / 25) * 3600) + 60);
      from = w;
    }
    return out;
  }
}

type FetchFn = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

/** Routes API "computeRoutes" (v2), driving, with traffic when [trafficAware]. */
export class GoogleRoutesProvider implements RoutesProvider {
  readonly kind = "google";

  constructor(
    private readonly apiKey: string,
    private readonly trafficAware: boolean,
    private readonly fetchFn: FetchFn = fetch as unknown as FetchFn,
  ) {}

  /** The request body (exported for tests). */
  static body(origin: LatLng, waypoints: LatLng[], trafficAware: boolean): Record<string, unknown> {
    const at = (p: LatLng) => ({ location: { latLng: { latitude: p.lat, longitude: p.lng } } });
    return {
      origin: at(origin),
      destination: at(waypoints[waypoints.length - 1]),
      intermediates: waypoints.slice(0, -1).map(at),
      travelMode: "DRIVE",
      routingPreference: trafficAware ? "TRAFFIC_AWARE" : "TRAFFIC_UNAWARE",
      languageCode: "en",
      units: "METRIC",
    };
  }

  async legs(origin: LatLng, waypoints: LatLng[]): Promise<number[]> {
    if (waypoints.length === 0) return [];
    const response = await this.fetchFn("https://routes.googleapis.com/directions/v2:computeRoutes", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Goog-Api-Key": this.apiKey,
        "X-Goog-FieldMask": "routes.legs.duration",
      },
      body: JSON.stringify(GoogleRoutesProvider.body(origin, waypoints, this.trafficAware)),
    });
    if (!response.ok) throw new Error(`routes failed with ${response.status}`);
    const json = (await response.json()) as { routes?: Array<{ legs?: Array<{ duration?: unknown }> }> };
    const legs = json.routes?.[0]?.legs ?? [];
    return legs.map((l) => {
      const m = typeof l.duration === "string" ? /^(\d+(?:\.\d+)?)s$/.exec(l.duration) : null;
      return m ? Math.round(Number(m[1])) : 0;
    });
  }
}

export function createRoutesProvider(kind: string, appEnv: string, apiKey: () => string, trafficAware: boolean): RoutesProvider {
  if (kind === "google") return new GoogleRoutesProvider(apiKey(), trafficAware);
  if (appEnv === "prod") throw new Error("ROUTES_PROVIDER=fake is not allowed in prod.");
  return new FakeRoutesProvider();
}
