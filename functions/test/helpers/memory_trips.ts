import type { LatLng } from "../../src/maps/geo";
import type { OutboxEvent } from "../../src/notifications/model";
import type { RunRecord } from "../../src/schedule/model";
import type {
  CarpoolPlace,
  HandoverEntry,
  TripAccount,
  TripChange,
  TripFiles,
  TripReport,
  TripStore,
} from "../../src/trips/flow";
import type { CarCard, ContactStatus, EmergencyContact, EtaRecord, HandoverAdult, TripCheck, TripPoint, TripRecord, TripStops } from "../../src/trips/model";

const clone = <T>(v: T): T => (v === undefined ? v : (JSON.parse(JSON.stringify(v)) as T));

/** In-memory TripStore for the unit tests (same contract as FirestoreTripStore). */
export class MemoryTripStore implements TripStore {
  accounts = new Map<string, TripAccount>();
  runs = new Map<string, RunRecord>();
  places = new Map<string, CarpoolPlace>();
  members = new Map<string, string[]>();
  cars = new Map<string, CarCard>();
  handovers = new Map<string, { ownerUid: string; adults: HandoverEntry[] }>();
  children = new Map<string, { ownerUid: string; status: string }>();
  homes = new Map<string, LatLng>();
  school: LatLng | null = { lat: 30.0, lng: 31.3 };
  trips = new Map<string, TripRecord>();
  stops = new Map<string, TripStops>();
  points = new Map<string, Array<TripPoint & { expiresAtMs: number }>>();
  etas = new Map<string, Map<string, EtaRecord>>();
  checks = new Map<string, TripCheck>();
  contacts = new Map<string, EmergencyContact>();
  emergencies: Array<{ carpoolId: string; id: string; point: LatLng | null; expiresAtMs: number; driverUid: string }> = [];
  events: OutboxEvent[] = [];
  reports: Array<TripReport & { atMs: number }> = [];
  paused = new Map<string, string>();
  limits = new Map<string, number>();

  async account(uid: string) {
    const a = this.accounts.get(uid);
    return a ? { ...a, drivingPaused: a.drivingPaused || this.paused.has(uid) } : null;
  }
  async run(carpoolId: string, runId: string) {
    return clone(this.runs.get(`${carpoolId}/${runId}`) ?? null);
  }
  async runsOn(carpoolId: string, date: string) {
    return [...this.runs.entries()].filter(([k, r]) => k.startsWith(`${carpoolId}/`) && r.date === date).map(([, r]) => clone(r));
  }
  async carpool(carpoolId: string) {
    return this.places.get(carpoolId) ?? null;
  }
  async isApprovedMember(carpoolId: string, uid: string) {
    return (this.members.get(carpoolId) ?? []).includes(uid);
  }
  async memberUids(carpoolId: string) {
    return [...(this.members.get(carpoolId) ?? [])];
  }
  async car(uid: string) {
    return this.cars.get(uid) ?? null;
  }
  async handover(childIds: string[]) {
    const out = new Map<string, HandoverAdult[]>();
    for (const id of childIds) {
      const h = this.handovers.get(id);
      if (h) out.set(id, h.adults.map((a) => ({ name: a.name, relation: a.relation })));
    }
    return out;
  }
  async stopPoints(_carpoolId: string, parentUids: string[]): Promise<TripStops> {
    const homes: Record<string, LatLng> = {};
    for (const uid of parentUids) {
      const h = this.homes.get(uid);
      if (h) homes[uid] = h;
    }
    return { homes, school: this.school };
  }
  async trip(id: string) {
    return clone(this.trips.get(id) ?? null);
  }
  async tripStops(id: string) {
    return clone(this.stops.get(id) ?? null);
  }
  async mutateTrip<T>(id: string, fn: (trip: TripRecord | null) => TripChange<T>): Promise<T> {
    const change = fn(clone(this.trips.get(id) ?? null));
    if (change.trip) this.trips.set(id, clone(change.trip));
    if (change.stops) this.stops.set(id, clone(change.stops));
    for (const e of change.events) if (!this.events.some((x) => x.id === e.id)) this.events.push(clone(e));
    return change.result;
  }
  async addPoints(id: string, points: TripPoint[], expiresAtMs: number) {
    const list = this.points.get(id) ?? [];
    for (const p of points) list.push({ ...p, expiresAtMs });
    this.points.set(id, list);
  }
  async putEtas(id: string, etas: EtaRecord[]) {
    const m = this.etas.get(id) ?? new Map<string, EtaRecord>();
    for (const e of etas) m.set(e.parentUid, clone(e));
    this.etas.set(id, m);
  }
  async ensureCheck(id: string, check: TripCheck) {
    const c = this.checks.get(id);
    if (c) return clone(c);
    this.checks.set(id, clone(check));
    return check;
  }
  async putCheck(id: string, check: TripCheck) {
    this.checks.set(id, clone(check));
  }
  async liveTripIds() {
    return [...this.trips.values()].filter((t) => t.status !== "ended").map((t) => t.id);
  }
  async liveTripsWithChild(childId: string) {
    return [...this.trips.values()].filter((t) => t.status !== "ended" && t.childIds.includes(childId)).map((t) => t.id);
  }
  async liveTripsOfDriver(uid: string) {
    return [...this.trips.values()].filter((t) => t.status === "active" && t.driverUid === uid).map((t) => t.id);
  }
  async child(childId: string) {
    return this.children.get(childId) ?? null;
  }
  async handoverEntries(childId: string) {
    return clone(this.handovers.get(childId)?.adults ?? []);
  }
  async putHandover(childId: string, ownerUid: string, adults: HandoverEntry[]) {
    this.handovers.set(childId, { ownerUid, adults: clone(adults) });
  }
  async emergencyContact(uid: string) {
    return this.contacts.get(uid) ?? null;
  }
  async putEmergencyContact(uid: string, c: EmergencyContact | null) {
    if (c) this.contacts.set(uid, c);
    else this.contacts.delete(uid);
  }
  async contactByToken(token: string) {
    for (const [uid, contact] of this.contacts) if (contact.token === token) return { uid, contact, parentFirstName: "Mona" };
    return null;
  }
  async setContactStatus(uid: string, status: ContactStatus) {
    const c = this.contacts.get(uid);
    if (c) this.contacts.set(uid, { ...c, status });
  }
  async markContactIntroduced(uid: string) {
    const c = this.contacts.get(uid);
    if (c) this.contacts.set(uid, { ...c, introSent: true });
  }
  async addEmergency(carpoolId: string, e: { driverUid: string; point: LatLng | null; expiresAtMs: number }) {
    const id = `em${this.emergencies.length + 1}`;
    this.emergencies.push({ carpoolId, id, point: e.point, expiresAtMs: e.expiresAtMs, driverUid: e.driverUid });
    return id;
  }
  async addEvents(events: OutboxEvent[]) {
    this.events.push(...clone(events));
  }
  async addReport(report: TripReport, nowMs: number) {
    this.reports.push({ ...report, atMs: nowMs });
  }
  async pauseDriving(uid: string, _nowMs: number, reason: string) {
    this.paused.set(uid, reason);
  }
  async deleteExpired(nowMs: number) {
    let n = 0;
    for (const [id, list] of this.points) {
      const keep = list.filter((p) => p.expiresAtMs > nowMs);
      n += list.length - keep.length;
      this.points.set(id, keep);
    }
    const before = this.emergencies.length;
    this.emergencies = this.emergencies.filter((e) => e.expiresAtMs > nowMs);
    return n + before - this.emergencies.length;
  }
  async takeLimit(uid: string, kind: string, _nowMs: number, rule: { windowMs: number; max: number }) {
    const key = `${uid}/${kind}`;
    const n = (this.limits.get(key) ?? 0) + 1;
    if (n > rule.max) return { allowed: false, retryAfterMs: 1000 };
    this.limits.set(key, n);
    return { allowed: true, retryAfterMs: 0 };
  }
}

/** Files in memory (photos and live selfies). */
export class MemoryTripFiles implements TripFiles {
  files = new Map<string, Buffer>();
  created = new Map<string, number>();
  async list(prefix: string) {
    return [...this.files.keys()].filter((p) => p.startsWith(prefix)).map((path) => ({ path, createdMs: this.created.get(path) ?? 0 }));
  }
  deleted: string[] = [];
  async exists(path: string) {
    return this.files.has(path);
  }
  async read(path: string) {
    const f = this.files.get(path);
    if (!f) throw new Error("no such file");
    return f;
  }
  async delete(path: string) {
    this.files.delete(path);
    this.deleted.push(path);
  }
  async signedReadUrl(path: string, expiresAtMs: number) {
    return `https://signed.example/${path}?e=${expiresAtMs}`;
  }
  async copy(from: string, to: string) {
    const f = this.files.get(from);
    if (!f) throw new Error("no such file");
    this.files.set(to, f);
    this.created.set(to, this.created.get(from) ?? 0);
  }
}
