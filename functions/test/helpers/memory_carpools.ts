import type { AccountInfo, AreaInfo, CarpoolLimitKind, CarpoolStore, CarpoolTx, ChildInfo, PickupPoint, SchoolInfo } from "../../src/carpools/flow";
import {
  consentId,
  membershipId,
  type CarpoolRecord,
  type ConsentRecord,
  type InviteRecord,
  type MemberRecord,
  type MembershipRecord,
  type RequestRecord,
  type VehicleInfo,
  type WantedRecord,
} from "../../src/carpools/model";
import { takeFromWindow, type WindowCounter } from "../../src/maps/limits";

const clone = <T>(v: T): T => structuredClone(v);

/** In-memory CarpoolStore for unit tests. Writes of a transaction apply only when it succeeds. */
export class MemoryCarpoolStore implements CarpoolStore {
  accounts = new Map<string, AccountInfo>();
  children = new Map<string, ChildInfo[]>();
  vehicles = new Map<string, VehicleInfo>();
  schools = new Map<string, SchoolInfo>();
  areas = new Map<string, AreaInfo>();
  driving = new Map<string, string[]>();
  homes = new Map<string, PickupPoint>();
  carpools = new Map<string, CarpoolRecord>();
  memberships = new Map<string, MembershipRecord>();
  /** carpoolId -> uid -> record */
  members = new Map<string, Map<string, MemberRecord>>();
  requests = new Map<string, Map<string, RequestRecord>>();
  consents = new Map<string, Map<string, ConsentRecord>>();
  pickups = new Map<string, Map<string, PickupPoint>>();
  invites = new Map<string, InviteRecord>();
  wanteds = new Map<string, WantedRecord>();
  limits = new Map<string, WindowCounter>();
  private nextId = 1;
  private chain: Promise<unknown> = Promise.resolve();

  private sub<T>(m: Map<string, Map<string, T>>, key: string): Map<string, T> {
    let inner = m.get(key);
    if (!inner) {
      inner = new Map();
      m.set(key, inner);
    }
    return inner;
  }

  transact<T>(fn: (tx: CarpoolTx) => Promise<T>): Promise<T> {
    const run = async (): Promise<T> => {
      const writes: Array<() => void> = [];
      const tx: CarpoolTx = {
        carpool: async (id) => clone(this.carpools.get(id) ?? null),
        membership: async (c, u) => clone(this.memberships.get(membershipId(c, u)) ?? null),
        members: async (c) => clone([...this.sub(this.members, c).values()]),
        consents: async (c) => clone([...this.sub(this.consents, c).values()]),
        requests: async (c) => clone([...this.sub(this.requests, c).values()]),
        putCarpool: (c) => writes.push(() => this.carpools.set(c.id, clone(c))),
        putMembership: (m) => writes.push(() => this.memberships.set(membershipId(m.carpoolId, m.uid), clone(m))),
        putMember: (c, m) => writes.push(() => this.sub(this.members, c).set(m.uid, clone(m))),
        deleteMember: (c, u) => writes.push(() => this.sub(this.members, c).delete(u)),
        putRequest: (c, r) => writes.push(() => this.sub(this.requests, c).set(r.uid, clone(r))),
        deleteRequest: (c, u) => writes.push(() => this.sub(this.requests, c).delete(u)),
        putConsent: (x) => writes.push(() => this.sub(this.consents, x.carpoolId).set(consentId(x.parentUid, x.driverUid), clone(x))),
        deleteConsent: (c, id) => writes.push(() => this.sub(this.consents, c).delete(id)),
        putPickupPoint: (c, u, p) =>
          writes.push(() => {
            if (p) this.sub(this.pickups, c).set(u, clone(p));
            else this.sub(this.pickups, c).delete(u);
          }),
      };
      const result = await fn(tx);
      for (const w of writes) w();
      return result;
    };
    const next = this.chain.then(run, run);
    this.chain = next.catch(() => undefined);
    return next;
  }

  newCarpoolId(): string {
    return `k${this.nextId++}`;
  }

  async account(uid: string) {
    return clone(this.accounts.get(uid) ?? null);
  }

  async approvedChildren(uid: string) {
    return clone(this.children.get(uid) ?? []);
  }

  async vehicle(uid: string) {
    return clone(this.vehicles.get(uid) ?? null);
  }

  async school(id: string) {
    return clone(this.schools.get(id) ?? null);
  }

  async area(id: string) {
    return clone(this.areas.get(id) ?? null);
  }

  async drivingSchoolIds(uid: string) {
    return [...(this.driving.get(uid) ?? [])];
  }

  async home(uid: string) {
    return clone(this.homes.get(uid) ?? null);
  }

  async schoolCarpools(schoolId: string, limit: number) {
    return clone([...this.carpools.values()].filter((c) => c.kind === "school" && c.schoolId === schoolId && c.status === "active").slice(0, limit));
  }

  activityQueries: string[] = [];

  async activityCarpools(prefix: string, limit: number) {
    this.activityQueries.push(prefix);
    return clone(
      [...this.carpools.values()]
        .filter((c) => c.kind === "activity" && c.status === "active" && (c.activity?.geohash ?? "").startsWith(prefix))
        .slice(0, limit),
    );
  }

  async carpoolsById(ids: string[]) {
    return clone(ids.map((id) => this.carpools.get(id)).filter((c): c is CarpoolRecord => c !== undefined));
  }

  async membershipsOf(uid: string) {
    return clone([...this.memberships.values()].filter((m) => m.uid === uid));
  }

  async takeLimit(uid: string, kind: CarpoolLimitKind, nowMs: number, rule: { windowMs: number; max: number }) {
    const key = `${uid}:${kind}`;
    const r = takeFromWindow(this.limits.get(key), nowMs, rule);
    if (r.allowed) this.limits.set(key, r.next);
    return { allowed: r.allowed, retryAfterMs: r.retryAfterMs };
  }

  async invite(code: string) {
    return clone(this.invites.get(code) ?? null);
  }

  async createInvite(invite: InviteRecord) {
    if (this.invites.has(invite.code)) return false;
    this.invites.set(invite.code, clone(invite));
    return true;
  }

  async wanted(uid: string) {
    return clone(this.wanteds.get(uid) ?? null);
  }

  async putWanted(uid: string, w: WantedRecord | null) {
    if (w) this.wanteds.set(uid, clone(w));
    else this.wanteds.delete(uid);
  }

  async wantedForSchool(schoolId: string, limit: number) {
    return clone([...this.wanteds.values()].filter((w) => w.schoolId === schoolId).slice(0, limit));
  }
}
