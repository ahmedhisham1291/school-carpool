// Privacy and security hardening (Prompt 12). Fake data only. Run: npm test.
import { strict as assert } from "node:assert";
import { isRetained, keepForClosedParent, participantsOf, planTripRetention, type AccountState } from "../src/privacy/trip_retention";
import { adminDecideDeviceCheck } from "../src/privacy/devices";
import { accessReason as accessReasonOf } from "../src/privacy/photos";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import {
  continueDeletion,
  deleteAccount,
  deletionRefusal,
  DeletionError,
  IMMEDIATE_TARGETS,
  immediateSteps,
  newClosedAccount,
  NOT_DELETED,
  pathFor,
  PURGE_TARGETS,
  purgeSteps,
  SUBCOLLECTIONS,
  type ClosedAccount,
  type DeletionRunner,
  type FlowStep,
  type PurgeStep,
  type Target,
  type WalletLock,
} from "../src/privacy/account_deletion";
import { ABUSE_THRESHOLDS, countActivity, counterId, HOUR_MS, noteActivity, type AbuseCounter, type AbuseStore } from "../src/privacy/abuse";
import {
  confirmNewDevice,
  DeviceError,
  deviceCheckPending,
  deviceSelfiePath,
  gateRefusal,
  planSignIn,
  recordSignIn,
  sessionKey,
  signOutDevice,
  touchDevice,
  type DeviceAccount,
  type DeviceDeps,
  type DeviceRecord,
  type DeviceStore,
  type Platform,
  type SignInPlan,
  type SignOutReason,
} from "../src/privacy/devices";
import { anonymiseBalance, anonymiseCarpool, anonymiseRun, anonymiseSwap, anonymiseTrip, DELETED_ID, initialOf } from "../src/privacy/anonymise";
import { buildExport, redact } from "../src/privacy/export";
import { runRetention, type RetentionReport, type RetentionStore } from "../src/privacy/jobs";
import { accessReason, selfieArchivePath, thumbOwner, thumbPath } from "../src/privacy/photos";
import { consentViews, needsAdmin, withdrawEffect } from "../src/privacy/requests";
import {
  AFTER_CLOSURE_DAYS,
  chatPurgeAt,
  DATA_TYPES,
  DAY_MS,
  type DataTypeId,
  isDue,
  purgeAfterClosure,
  RETENTION,
  routeArchivePurgeAt,
  rule,
} from "../src/privacy/retention";
import { dropThumb, ensureThumb, SOURCE_GENERATION } from "../src/privacy/thumbs";
import { archivePath, decodePolyline, downsample, encodePolyline, packArchive, unpackArchive, type TrackPoint } from "../src/privacy/route_archive";
import type { OutboxEvent } from "../src/notifications/model";

const NOW = Date.UTC(2026, 10, 14, 8);

// --------------------------------------------------------------------------
// Retention schedule
// --------------------------------------------------------------------------

describe("retention schedule", () => {
  it("has one rule per data type, and the dates of the owner's decision", () => {
    assert.deepEqual(RETENTION.map((r) => r.id), [...DATA_TYPES]);
    assert.equal(rule("idPhotos").days, 365);
    assert.equal(rule("idPhotos").from, "accountClosed");
    assert.equal(rule("trips").from, "accountClosed");
    assert.equal(rule("routeArchive").days, 365);
    assert.equal(rule("chat").from, "chatEnd");
    assert.ok(rule("liveLocation").days !== null && (rule("liveLocation").days ?? 99) <= 1, "live points within 24 hours");
    assert.equal(rule("wallet").enforcedBy[0], "kept", "transfer records: as the law requires");
  });

  it("dates: one year after closure, after the run and after the chat ended", () => {
    assert.equal(purgeAfterClosure(NOW), NOW + 365 * DAY_MS);
    assert.equal(AFTER_CLOSURE_DAYS, 365);
    assert.equal(routeArchivePurgeAt(NOW), NOW + 365 * DAY_MS);
    assert.equal(chatPurgeAt(NOW), NOW + 365 * DAY_MS);
    assert.equal(isDue(null, NOW), false);
    assert.equal(isDue(NOW, NOW), true);
    assert.equal(isDue(NOW + 1, NOW), false);
  });
});

// --------------------------------------------------------------------------
// Route archive
// --------------------------------------------------------------------------

function track(seconds: number, everyS = 5): TrackPoint[] {
  const out: TrackPoint[] = [];
  for (let s = 0; s <= seconds; s += everyS) out.push({ lat: 30.0444 + s * 1e-5, lng: 31.2357 - s * 2e-5, atMs: NOW + s * 1000 });
  return out;
}

describe("route archive", () => {
  it("down-samples to about one point every 30 s, keeps both ends, drops bad points", () => {
    const pts = track(600); // 10 minutes every 5 s = 121 points
    const kept = downsample([...pts, { lat: 999, lng: 0, atMs: NOW }, { lat: Number.NaN, lng: 1, atMs: NOW }]);
    assert.equal(kept.length, 21);
    assert.equal(kept[0].atMs, NOW);
    assert.equal(kept[kept.length - 1].atMs, NOW + 600_000);
    for (let i = 1; i < kept.length; i++) assert.ok(kept[i].atMs - kept[i - 1].atMs >= 30_000);
    // The last point is kept even when it is closer than 30 s.
    const odd = downsample(track(70));
    assert.deepEqual(odd.map((p) => (p.atMs - NOW) / 1000), [0, 30, 60, 70]);
    assert.deepEqual(downsample([]), []);
    // Out of order input is sorted.
    assert.deepEqual(downsample([...track(60)].reverse()).map((p) => (p.atMs - NOW) / 1000), [0, 30, 60]);
  });

  it("encodes Google's polyline (the documented example) and decodes it back", () => {
    const example = [
      { lat: 38.5, lng: -120.2 },
      { lat: 40.7, lng: -120.95 },
      { lat: 43.252, lng: -126.453 },
    ];
    assert.equal(encodePolyline(example), "_p~iF~ps|U_ulLnnqC_mqNvxq`@");
    assert.deepEqual(decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@"), example);
  });

  it("packs one gzipped file that unpacks to the same track within 1 m", () => {
    const meta = { tripId: "k1_2026-11-14_am", carpoolId: "k1", driverUid: "alice", startedAtMs: NOW, endedAtMs: NOW + 3_600_000 };
    const pts = track(3600);
    const { data, points } = packArchive(meta, pts);
    assert.equal(points, 121);
    assert.ok(data.length < 2_000, `compressed: ${data.length} bytes`);
    assert.equal(data[0], 0x1f, "gzip magic");
    const back = unpackArchive(data);
    assert.deepEqual(back.meta, meta);
    assert.equal(back.points.length, 121);
    const kept = downsample(pts);
    back.points.forEach((p, i) => {
      assert.ok(Math.abs(p.lat - kept[i].lat) < 1e-5 && Math.abs(p.lng - kept[i].lng) < 1e-5);
      assert.equal(p.atMs, kept[i].atMs);
    });
    assert.equal(archivePath("k1_2026-11-14_am", NOW), "routeArchive/2026/k1_2026-11-14_am.json.gz");
    assert.throws(() => archivePath("../x", NOW));
  });
});

// --------------------------------------------------------------------------
// Scraping alerts
// --------------------------------------------------------------------------

class MemoryAbuse implements AbuseStore {
  counters = new Map<string, AbuseCounter>();
  alerts: string[] = [];
  fail = false;
  async count(uid: string, kind: (typeof ABUSE_KINDS_T)[number], nowMs: number, count: (c: AbuseCounter | null) => { next: AbuseCounter; alert: boolean }) {
    if (this.fail) throw new Error("down");
    const id = counterId(uid, kind, nowMs);
    const r = count(this.counters.get(id) ?? null);
    this.counters.set(id, r.next);
    if (!r.alert) return null;
    this.alerts.push(id);
    return { id, uid, kind, count: r.next.count, hourStartMs: r.next.hourStartMs, status: "open" as const, createdAtMs: nowMs };
  }
}
const ABUSE_KINDS_T = ["profiles", "chatRequests", "areaSearches", "parentIdLookups"] as const;

describe("scraping alerts", () => {
  it("one alert per account, kind and hour when distinct targets reach the threshold", async () => {
    const store = new MemoryAbuse();
    const max = ABUSE_THRESHOLDS.profiles.max;
    for (let i = 0; i < max - 1; i++) assert.equal(await noteActivity(store, "u1", "profiles", `p${i}`, NOW), null);
    // Re-opening the same profile does not count.
    assert.equal(await noteActivity(store, "u1", "profiles", "p0", NOW), null);
    const alert = await noteActivity(store, "u1", "profiles", `p${max}`, NOW);
    assert.equal(alert?.kind, "profiles");
    assert.equal(alert?.count, max);
    assert.equal(await noteActivity(store, "u1", "profiles", "pX", NOW), null, "once per hour");
    const stored = store.counters.get(counterId("u1", "profiles", NOW))!.keys;
    assert.ok(stored.every((k) => /^[0-9a-f]{16}$/.test(k)) && !stored.includes("p0"), "targets are stored as short hashes, never as given");
    // A new hour starts a new count.
    const next = countActivity(store.counters.get(counterId("u1", "profiles", NOW)) ?? null, "profiles", "p0", NOW + HOUR_MS);
    assert.equal(next.next.count, 1);
    assert.equal(store.alerts.length, 1);
  });

  it("never blocks the parent's call when counting fails", async () => {
    const store = new MemoryAbuse();
    store.fail = true;
    const errors: unknown[] = [];
    assert.equal(await noteActivity(store, "u1", "parentIdLookups", "x", NOW, (e) => errors.push(e)), null);
    assert.equal(errors.length, 1);
  });
});

// --------------------------------------------------------------------------
// Devices and the new-phone rule
// --------------------------------------------------------------------------

const ID_A = "0123456789abcdef0123456789abcdef";
const ID_B = "fedcba9876543210fedcba9876543210";
const HMAC = "test-key";

class MemoryDevices implements DeviceStore {
  accounts = new Map<string, DeviceAccount>();
  list = new Map<string, DeviceRecord[]>();
  checks = new Map<string, { required: boolean; sinceMs: number } | null>();
  logins: string[] = [];
  events: OutboxEvent[] = [];
  reports: Array<[string, string, boolean]> = [];
  async account(uid: string) {
    return this.accounts.get(uid) ?? null;
  }
  async devices(uid: string) {
    return (this.list.get(uid) ?? []).map((d) => ({ ...d }));
  }
  async saveSignIn(uid: string, plan: SignInPlan, check: { required: boolean; sinceMs: number } | null, notice: OutboxEvent | null) {
    const rest = (this.list.get(uid) ?? []).filter((d) => d.key !== plan.device.key).map((d) => (plan.signOut.includes(d.key) ? { ...d, signedOutAtMs: plan.device.lastSignInAtMs, signOutReason: "newDevice" as const } : d));
    this.list.set(uid, [...rest, plan.device]);
    this.logins.push(plan.login.deviceKey);
    if (check) this.checks.set(uid, check);
    if (notice) this.events.push(notice);
  }
  async touch(uid: string, key: string, platform: Platform, nowMs: number, create: boolean) {
    const all = this.list.get(uid) ?? [];
    const found = all.find((d) => d.key === key);
    if (found) found.lastSeenAtMs = nowMs;
    else if (create) all.push({ key, platform, firstSignInAtMs: nowMs, lastSignInAtMs: nowMs, lastSeenAtMs: nowMs, signedOutAtMs: null, signOutReason: null });
    this.list.set(uid, all);
  }
  async markSignedOut(uid: string, keys: string[], reason: SignOutReason, nowMs: number) {
    for (const d of this.list.get(uid) ?? []) if (keys.includes(d.key)) Object.assign(d, { signedOutAtMs: nowMs, signOutReason: reason });
  }
  async setDeviceCheck(uid: string, check: { required: boolean; sinceMs: number } | null) {
    this.checks.set(uid, check);
  }
  async deviceCheck(uid: string) {
    return this.checks.get(uid) ?? null;
  }
  async addReport(uid: string, reason: "new-device-mismatch" | "new-device-unchecked", urgent: boolean) {
    this.reports.push([uid, reason, urgent]);
  }
}

function deviceWorld() {
  const store = new MemoryDevices();
  store.accounts.set("u1", { status: "verified", email: "parent@example.com", language: "ar", hasFaceRef: true });
  const clock = { now: NOW };
  const files = new Map<string, { createdMs: number; data: Buffer }>();
  files.set("faceRefs/u1/selfie.jpg", { createdMs: NOW - DAY_MS, data: Buffer.from("ref") });
  const archived: string[] = [];
  const mails: string[] = [];
  const revoked: string[] = [];
  const face = { result: "match" as "match" | "no_match" | "error" };
  let ids = 0;
  const deps: DeviceDeps = {
    store,
    sessions: { revokeAll: async (uid) => void revoked.push(uid), createToken: async (uid) => `token-${uid}` },
    mailer: { sendNewDeviceEmail: async (_uid, to) => void mails.push(to) },
    files: {
      createdMs: async (p) => files.get(p)?.createdMs ?? null,
      exists: async (p) => files.has(p),
      read: async (p) => files.get(p)?.data ?? Buffer.alloc(0),
      archive: async (p, to) => {
        archived.push(to);
        files.delete(p);
      },
    },
    faces: { matchFace: async () => face.result },
    faceRefPath: (uid) => `faceRefs/${uid}/selfie.jpg`,
    selfieArchivePath: (uid, name) => `selfieArchive/${uid}/${name}`,
    hmacKey: HMAC,
    now: () => clock.now,
    newId: () => `login${++ids}`,
    reportError: () => undefined,
  };
  return { store, deps, clock, files, archived, mails, revoked, face };
}

describe("devices and the new-phone rule", () => {
  it("App Review demo parent: a new phone opens no selfie check, but still signs the old phone out", async () => {
    const w = deviceWorld();
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    w.store.accounts.set("u1", { status: "verified", email: "parent@example.com", language: "ar", hasFaceRef: true, reviewDemo: true });
    const demo = await recordSignIn(w.deps, "u1", ID_B, "ios");
    assert.equal(demo.newDevice, true);
    assert.equal(demo.freshSelfieRequired, false);
    assert.equal(await w.store.deviceCheck("u1"), null);
    assert.deepEqual(w.revoked, ["u1"]);
    // Without the exemption (the window ended) the same sign-in asks for the selfie.
    const n = deviceWorld();
    await recordSignIn(n.deps, "u1", ID_A, "ios");
    n.store.accounts.set("u1", { status: "verified", email: "parent@example.com", language: "ar", hasFaceRef: true, reviewDemo: false });
    assert.equal((await recordSignIn(n.deps, "u1", ID_B, "ios")).freshSelfieRequired, true);
  });

  it("the first phone of an account is trusted; it is listed with a sign-in line", async () => {
    const w = deviceWorld();
    const r = await recordSignIn(w.deps, "u1", ID_A, "ios");
    assert.deepEqual(r, { deviceKey: sessionKey(HMAC, ID_A), newDevice: false, freshSelfieRequired: false });
    assert.equal(w.store.list.get("u1")?.length, 1);
    assert.equal(w.revoked.length, 0);
    assert.ok(!JSON.stringify([...w.store.list.values()]).includes(ID_A), "only a keyed hash of the install ID");
    // Signing in again on the same phone is not new.
    w.clock.now += DAY_MS;
    assert.equal((await recordSignIn(w.deps, "u1", ID_A, "ios")).newDevice, false);
  });

  it("a new phone signs the others out, emails the parent, alerts the old phone and asks for a fresh selfie", async () => {
    const w = deviceWorld();
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    w.clock.now += DAY_MS;
    const r = await recordSignIn(w.deps, "u1", ID_B, "android");
    assert.equal(r.newDevice, true);
    assert.equal(r.freshSelfieRequired, true);
    assert.deepEqual(w.revoked, ["u1"]);
    assert.deepEqual(w.mails, ["parent@example.com"]);
    assert.equal(w.store.events[0].type, "new-device");
    const old = w.store.list.get("u1")?.find((d) => d.key === sessionKey(HMAC, ID_A));
    assert.equal(old?.signOutReason, "newDevice");
    assert.equal(deviceCheckPending({ newDeviceCheck: w.store.checks.get("u1") }), true);
    // The old phone learns it at its next start and signs out.
    assert.deepEqual(await touchDevice(w.deps, "u1", { deviceId: ID_A, platform: "ios" }), { deviceKey: sessionKey(HMAC, ID_A), signedOut: true });
    assert.equal((await touchDevice(w.deps, "u1", { deviceId: ID_B, platform: "android" })).signedOut, false);
  });

  it("an unverified parent on a new phone needs no selfie (no face reference yet)", async () => {
    const w = deviceWorld();
    w.store.accounts.set("u1", { status: "unverified", email: null, language: "en", hasFaceRef: false });
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    const r = await recordSignIn(w.deps, "u1", ID_B, "ios");
    assert.equal(r.newDevice, true);
    assert.equal(r.freshSelfieRequired, false);
    assert.deepEqual(w.mails, [], "no confirmed email: no mail");
  });

  it("plan: a phone signed out before and signing in again is not new", () => {
    const d: DeviceRecord = { key: "s_a", platform: "ios", firstSignInAtMs: 1, lastSignInAtMs: 1, lastSeenAtMs: 1, signedOutAtMs: 5, signOutReason: "user" };
    const p = planSignIn([d], "s_a", "ios", NOW, "l1");
    assert.equal(p.newPhone, false);
    assert.equal(p.device.signedOutAtMs, null);
  });

  it("signs out one phone (never its own) and hands the calling phone a fresh token", async () => {
    const w = deviceWorld();
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    await touchDevice(w.deps, "u1", { deviceId: ID_B, platform: "ios" }); // a pre-Prompt-12 session gets its record
    const target = sessionKey(HMAC, ID_A);
    await assert.rejects(signOutDevice(w.deps, "u1", { deviceId: ID_A, deviceKey: target }), (e: unknown) => e instanceof DeviceError && e.reason === "own-device");
    await assert.rejects(signOutDevice(w.deps, "u1", { deviceId: ID_B, deviceKey: "s_" + "0".repeat(40) }), (e: unknown) => e instanceof DeviceError && e.reason === "not-found");
    assert.deepEqual(await signOutDevice(w.deps, "u1", { deviceId: ID_B, deviceKey: target }), { token: "token-u1" });
    assert.deepEqual(w.revoked, ["u1"]);
    assert.equal((await touchDevice(w.deps, "u1", { deviceId: ID_A })).signedOut, true);
    await assert.rejects(touchDevice(w.deps, "u1", { deviceId: "not-hex" }), DeviceError);
  });

  it("fresh selfie: a match opens chats again; the selfie is kept in the archive", async () => {
    const w = deviceWorld();
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    await recordSignIn(w.deps, "u1", ID_B, "ios");
    await assert.rejects(confirmNewDevice(w.deps, "u1"), (e: unknown) => e instanceof DeviceError && e.reason === "no-selfie");
    w.files.set(deviceSelfiePath("u1"), { createdMs: w.clock.now, data: Buffer.from("live") });
    assert.deepEqual(await confirmNewDevice(w.deps, "u1"), { cleared: true, reviewed: false });
    assert.equal(w.store.checks.get("u1"), null);
    assert.equal(w.archived.length, 1);
    assert.ok(w.archived[0].startsWith("selfieArchive/u1/device_"));
    await assert.rejects(confirmNewDevice(w.deps, "u1"), (e: unknown) => e instanceof DeviceError && e.reason === "no-check");
  });

  it("fresh selfie: a mismatch keeps everything closed (urgent report); no decision passes with a report", async () => {
    const w = deviceWorld();
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    await recordSignIn(w.deps, "u1", ID_B, "ios");
    w.files.set(deviceSelfiePath("u1"), { createdMs: w.clock.now, data: Buffer.from("live") });
    w.face.result = "no_match";
    await assert.rejects(confirmNewDevice(w.deps, "u1"), (e: unknown) => e instanceof DeviceError && e.reason === "selfie-mismatch");
    assert.deepEqual(w.store.reports, [["u1", "new-device-mismatch", true]]);
    assert.equal(w.store.checks.get("u1")?.required, true);
    // FAIL CLOSED: the face check cannot decide (or throws): nothing opens,
    // the admins get a report and compare the kept selfie by hand.
    w.files.set(deviceSelfiePath("u1"), { createdMs: w.clock.now, data: Buffer.from("live") });
    w.face.result = "error";
    await assert.rejects(confirmNewDevice(w.deps, "u1"), (e: unknown) => e instanceof DeviceError && e.reason === "selfie-unchecked");
    assert.deepEqual(w.store.reports[1], ["u1", "new-device-unchecked", true]);
    assert.equal(w.store.checks.get("u1")?.required, true);
    w.files.set(deviceSelfiePath("u1"), { createdMs: w.clock.now, data: Buffer.from("live") });
    w.deps.faces = { matchFace: async () => Promise.reject(new Error("partner down")) };
    await assert.rejects(confirmNewDevice(w.deps, "u1"), (e: unknown) => e instanceof DeviceError && e.reason === "selfie-unchecked");
    assert.equal(w.store.checks.get("u1")?.required, true);
  });

  it("SIM swap: the old phone loses access at once; the new phone opens nothing until the selfie matches", async () => {
    const w = deviceWorld();
    const revokedAt: number[] = [];
    w.deps.sessions = { ...w.deps.sessions, revokeAll: async () => void revokedAt.push(Math.floor(w.clock.now / 1000)) };
    await recordSignIn(w.deps, "u1", ID_A, "ios");
    const oldAuth = Math.floor(w.clock.now / 1000);
    // Someone takes over the number and signs in on another phone a day later.
    w.clock.now += DAY_MS;
    const r = await recordSignIn(w.deps, "u1", ID_B, "android");
    assert.equal(r.freshSelfieRequired, true);
    const newAuth = Math.floor(w.clock.now / 1000) + 1;
    const user = () => ({ newDeviceCheck: w.store.checks.get("u1") ?? null, sessionsValidAfter: revokedAt.at(-1) });
    // The owner's phone: signed out everywhere at once (rules and callables).
    assert.equal(gateRefusal(user(), oldAuth, true), "signed-out");
    assert.equal(gateRefusal(user(), oldAuth, false), "signed-out");
    assert.equal(gateRefusal(user(), null, false), "signed-out", "no sign-in time: refused");
    // The new phone: valid session, but children, carpools, trips, chats, the
    // wallet, export and deletion stay closed.
    assert.equal(gateRefusal(user(), newAuth, true), "device-check");
    assert.equal(gateRefusal(user(), newAuth, false), null, "the selfie screen itself works");
    // A wrong face keeps it closed; the owner's face opens it.
    w.files.set(deviceSelfiePath("u1"), { createdMs: w.clock.now, data: Buffer.from("live") });
    w.face.result = "no_match";
    await assert.rejects(confirmNewDevice(w.deps, "u1"), DeviceError);
    assert.equal(gateRefusal(user(), newAuth, true), "device-check");
    w.files.set(deviceSelfiePath("u1"), { createdMs: w.clock.now, data: Buffer.from("live") });
    w.face.result = "match";
    assert.deepEqual(await confirmNewDevice(w.deps, "u1"), { cleared: true, reviewed: false });
    assert.equal(gateRefusal(user(), newAuth, true), null);
    // A record without the fields (before Prompt 12) refuses nothing.
    assert.equal(gateRefusal({}, null, true), null);
  });
});

// --------------------------------------------------------------------------
// Account deletion cascade
// --------------------------------------------------------------------------

class FakeRunner implements DeletionRunner {
  closedMap = new Map<string, ClosedAccount>();
  ran: string[] = [];
  failing = new Set<string>();
  factsValue = { exists: true, wallet: null as { balance: number; pending: number } | null, drivingNow: false, parentId: "ABCD2345", banned: false };
  walletLog: string[] = [];
  async facts() {
    const { wallet: _wallet, ...rest } = this.factsValue;
    return rest;
  }
  async lockWallet(): Promise<WalletLock | null> {
    if (!this.factsValue.wallet) return null;
    this.walletLog.push("lock");
    return { status: "active", frozenReason: null, frozenAtMs: null, frozenBy: null };
  }
  async walletFacts() {
    this.walletLog.push("facts");
    return { ...this.factsValue.wallet! };
  }
  async unlockWallet() {
    this.walletLog.push("unlock");
  }
  async saveClosed(c: ClosedAccount) {
    this.closedMap.set(c.uid, { ...c, failed: [...c.failed] });
  }
  async closed(uid: string) {
    return this.closedMap.get(uid) ?? null;
  }
  private step(name: string) {
    this.ran.push(name);
    if (this.failing.has(name)) throw new Error(`fail ${name}`);
  }
  async runFlowStep(_uid: string, step: FlowStep) {
    this.step(`flow:${step}`);
  }
  async runTarget(uid: string, target: Target) {
    const t = target.kind === "doc" || target.kind === "subcollection" ? pathFor(target.path, uid) : target.kind === "storage" ? pathFor(target.prefix, uid) : `${target.collection}.${target.field}`;
    this.step(t);
    return 1;
  }
  async runPurgeStep(_uid: string, step: PurgeStep) {
    this.step(`purge:${step}`);
  }
}

/**
 * Top-level collections (indent 4) and users/ subcollections (indent 6
 * inside users) named in firestore.rules.
 */
function rulesCollections(): string[] {
  const rules = readFileSync(join(__dirname, "..", "..", "..", "firestore.rules"), "utf8");
  const out: string[] = [];
  let top = "";
  for (const line of rules.split("\n")) {
    const m = /^( *)match \/([A-Za-z]+)\/\{/.exec(line);
    if (!m) continue;
    if (m[1].length === 4) {
      top = m[2];
      out.push(top);
    } else if (m[1].length === 6) {
      out.push(`${top}/${m[2]}`);
    }
  }
  return out;
}

describe("account deletion", () => {
  it("refuses while money is in the wallet or a transfer is pending, or the parent is driving", () => {
    const base = { exists: true, wallet: null, drivingNow: false };
    assert.equal(deletionRefusal(base), null);
    assert.equal(deletionRefusal({ ...base, wallet: { balance: 0, pending: 0 } }), null);
    assert.equal(deletionRefusal({ ...base, wallet: { balance: 500, pending: 0 } }), "wallet-not-empty");
    assert.equal(deletionRefusal({ ...base, wallet: { balance: 0, pending: 1 } }), "wallet-pending");
    assert.equal(deletionRefusal({ ...base, drivingNow: true }), "driving-now");
    assert.equal(deletionRefusal({ ...base, exists: false }), "no-account");
  });

  it("every collection in firestore.rules is deleted at once, purged after a year, or kept for a stated reason", () => {
    const covered = new Set([...IMMEDIATE_TARGETS, ...PURGE_TARGETS].map((t) => t.collection));
    const found = rulesCollections().filter((c) => !c.includes("/") || c.startsWith("users/"));
    assert.ok(found.length > 40, `parsed ${found.length} collections`);
    const missing = found.filter((c) => !covered.has(c) && NOT_DELETED[c] === undefined);
    assert.deepEqual(missing, []);
  });

  it("every subcollection of a shared record (carpools, trips) says how the parent's data in it ends", () => {
    const nested = rulesCollections().filter((c) => c.includes("/") && !c.startsWith("users/"));
    assert.ok(nested.length >= 10, `parsed ${nested.length} subcollections`);
    assert.deepEqual(nested.filter((c) => SUBCOLLECTIONS[c] === undefined), []);
  });

  it("names left with other parents become initials: trips, past runs, swaps, balances, the carpool card", () => {
    assert.equal(initialOf("Adam"), "A.");
    assert.equal(initialOf("  سارة "), "س.");
    assert.equal(initialOf(""), "");
    // Another driver's trip with the deleted parent's child and someone else's.
    const trip = {
      driverUid: "d1",
      driverFirstName: "Dina",
      viewerUids: ["d1", "u1", "u2"],
      childIds: ["c1", "c2"],
      stops: [
        { childId: "c1", firstName: "Adam", parentUid: "u1", state: "dropped", droppedAtMs: 5, handover: [{ name: "Grandma Mona", relation: "grandparent" }] },
        { childId: "c2", firstName: "Bana", parentUid: "u2", state: "dropped", droppedAtMs: 6, handover: [{ name: "Aunt", relation: "aunt" }] },
      ],
    };
    const t = anonymiseTrip(trip, "u1")!;
    const stops = t.stops as Array<Record<string, unknown>>;
    assert.deepEqual(stops[0], { childId: DELETED_ID, firstName: "A.", parentUid: DELETED_ID, state: "dropped", droppedAtMs: 5, handover: [] });
    assert.deepEqual(stops[1], trip.stops[1], "other children untouched");
    assert.deepEqual(t.viewerUids, ["d1", "u2"]);
    assert.deepEqual(t.childIds, ["c2"]);
    assert.ok(!JSON.stringify(t).includes("Adam") && !JSON.stringify(t).includes("Mona"));
    assert.equal(anonymiseTrip(trip, "u9"), null, "nothing to change");
    // A trip the deleted parent drove: only the driver's initial (purged after a year).
    assert.deepEqual(anonymiseTrip({ ...trip, driverUid: "u1", viewerUids: ["u1"], stops: [] }, "u1"), { driverFirstName: "D." });
    // A past run: riders, absent list and driver.
    const run = {
      driverUid: "u1",
      driverFirstName: "Omar",
      riders: [{ id: "c1", firstName: "Adam", parentUid: "u1" }, { id: "c2", firstName: "Bana", parentUid: "u2" }],
      absent: [{ id: "c3", firstName: "Zein", parentUid: "u1" }],
      swapBy: null,
    };
    assert.deepEqual(anonymiseRun(run, "u1"), {
      riders: [{ id: DELETED_ID, firstName: "A.", parentUid: DELETED_ID }, run.riders[1]],
      absent: [{ id: DELETED_ID, firstName: "Z.", parentUid: DELETED_ID }],
      driverUid: DELETED_ID,
      driverFirstName: "O.",
    });
    assert.deepEqual(anonymiseSwap({ requesterUid: "u1", requesterFirstName: "Omar", acceptedBy: "u2", suggestedUids: ["u1", "u3"] }, "u1"), {
      requesterUid: DELETED_ID,
      requesterFirstName: "O.",
      suggestedUids: ["u3"],
    });
    const bal = anonymiseBalance({ families: { u1: { firstName: "Omar", driven: 4, received: 3, share: 3.5 }, u2: { firstName: "Hoda", driven: 1, received: 2, share: 1.5 } } }, "u1")!;
    const families = bal.families as Record<string, Record<string, unknown>>;
    assert.equal(families.u1, undefined);
    assert.deepEqual(families.u2.firstName, "Hoda");
    const anon = Object.entries(families).find(([k]) => k.startsWith(`${DELETED_ID}_`))!;
    assert.deepEqual(anon[1], { firstName: "O.", driven: 4, received: 3, share: 3.5 }, "the counts stay fair for the others");
    assert.ok(!anon[0].includes("u1"));
    assert.deepEqual(anonymiseCarpool({ creatorUid: "u1", creatorFirstName: "Omar" }, "u1"), { creatorUid: DELETED_ID, creatorFirstName: "O." });
    assert.equal(anonymiseCarpool({ creatorUid: "u2", creatorFirstName: "Hoda" }, "u1"), null);
  });

  it("deletes everything listed at once, the user record last; keeps the ban list and transfers", async () => {
    const r = new FakeRunner();
    const res = await deleteAccount(r, "u1", NOW, () => undefined);
    assert.equal(res.failed, 0);
    assert.equal(res.purgeAtMs, NOW + 365 * DAY_MS);
    assert.deepEqual(r.ran.slice(0, 6), ["flow:trips", "flow:carpools", "flow:anonymise", "flow:chat", "flow:trust", "flow:identity"]);
    assert.ok(r.ran.includes("homes/u1"));
    // F46: the address leaves the place counts before the home is deleted.
    assert.ok(r.ran.includes("flow:places") && r.ran.indexOf("flow:places") < r.ran.indexOf("homes/u1"));
    assert.ok(r.ran.includes("children.ownerUid"));
    assert.ok(r.ran.includes("ratings.rateeUid"));
    assert.ok(r.ran.includes("guardianLinks.guardianUid"));
    assert.ok(r.ran.includes("users/u1/notifications"));
    assert.equal(r.ran[r.ran.length - 1], "flow:auth");
    assert.equal(r.ran[r.ran.length - 2], "users/u1", "the user record goes last before Auth");
    assert.ok(!r.ran.some((s) => s.startsWith("bannedIds") || s.startsWith("transfers") || s.startsWith("reports")));
    assert.ok(!r.ran.some((s) => s.includes("faceRefs") || s.includes("verifications")), "photos wait for the purge");
    assert.deepEqual(r.closedMap.get("u1")?.failed, []);
  });

  it("refuses with money in the wallet before touching anything", async () => {
    const r = new FakeRunner();
    r.factsValue.wallet = { balance: 1, pending: 0 };
    await assert.rejects(deleteAccount(r, "u1", NOW, () => undefined), (e: unknown) => e instanceof DeletionError && e.reason === "wallet-not-empty");
    assert.deepEqual(r.walletLog, ["lock", "facts", "unlock"], "locked first, checked, then opened again");
    assert.deepEqual(r.ran, []);
    assert.equal(r.closedMap.size, 0);
  });

  it("a failed step is recorded, retried by the daily job, and the purge waits for it", async () => {
    const r = new FakeRunner();
    r.failing.add("flow:chat");
    const errors: string[] = [];
    const res = await deleteAccount(r, "u1", NOW, (s) => errors.push(s));
    assert.equal(res.failed, 1);
    assert.deepEqual(errors, ["flow:chat"]);
    assert.deepEqual(r.closedMap.get("u1")?.failed, ["flow:chat"]);
    assert.ok(r.ran.includes("users/u1"), "the other steps still ran");
    // A year later the chat step still fails: no purge yet.
    const later = NOW + 366 * DAY_MS;
    let c = r.closedMap.get("u1")!;
    assert.deepEqual((await continueDeletion(r, c, later, () => undefined)).purged, false);
    // Fixed: the retry succeeds and the purge runs.
    r.failing.clear();
    r.ran = [];
    c = r.closedMap.get("u1")!;
    const done = await continueDeletion(r, c, later, () => undefined);
    assert.equal(done.purged, true);
    assert.ok(r.ran.includes("faceRefs/u1/"));
    assert.ok(r.ran.includes("selfieArchive/u1/"));
    assert.ok(r.ran.includes("verifications.uid"));
    assert.ok(r.ran.includes("purge:trips"));
    assert.ok(r.ran.includes("users/u1/consents"));
    assert.ok(r.ran.includes("purge:chatMessages"));
    assert.equal(r.closedMap.get("u1")?.purgedAtMs, later);
  });

  it("nothing is purged before the year is over", async () => {
    const r = new FakeRunner();
    const c = newClosedAccount("u1", "ABCD2345", false, NOW);
    assert.equal((await continueDeletion(r, c, NOW + 364 * DAY_MS, () => undefined)).purged, false);
    assert.deepEqual(r.ran, []);
    assert.equal(immediateSteps().length, IMMEDIATE_TARGETS.length + 9); // 9 flow steps besides "records" (F46 added "places")
    assert.equal(purgeSteps().length, PURGE_TARGETS.length + 3);
  });
});

// --------------------------------------------------------------------------
// Export
// --------------------------------------------------------------------------

describe("data export", () => {
  it("has a section for every data type, without internal keys; a failing section is listed, not fatal", async () => {
    const file = await buildExport(
      {
        section: async (_uid, id) => {
          if (id === "chat") throw new Error("chat down");
          if (id === "account") return { parentId: "ABCD2345", phone: "+201000000000", nationalIdHash: "abc", deviceKey: "s_x", membership: { relationship: "mother" } };
          if (id === "wallet") return { transfers: [{ id: "t1", amount: 100, walletRef: "w1", partnerRef: "p1" }] };
          return { id };
        },
      },
      "u1",
      NOW,
      () => undefined,
    );
    assert.deepEqual(Object.keys(file.sections), [...DATA_TYPES]);
    assert.deepEqual(file.missing, ["chat"]);
    const account = file.sections.account as Record<string, unknown>;
    assert.equal(account.parentId, "ABCD2345");
    assert.equal(account.phone, "+201000000000", "the parent's own number is theirs");
    assert.equal(account.nationalIdHash, undefined);
    assert.equal(account.deviceKey, undefined);
    assert.deepEqual(account.membership, { relationship: "mother" }, "words ending in -ip are not IPs");
    assert.deepEqual(file.sections.wallet, { transfers: [{ id: "t1", amount: 100, partnerRef: "p1" }] });
    assert.deepEqual(redact({ ip: "1.2.3.4", codeHash: "x", nested: [{ tokenHash: "y", ok: 1 }] }), { nested: [{ ok: 1 }] });
    assert.deepEqual(file.truncated, [], "a source that cuts nothing");
  });

  it("says which sections reached a read limit, so the parent knows the file is partial", async () => {
    const cut = new Set<DataTypeId>();
    const file = await buildExport(
      {
        section: async (_uid, id) => {
          if (id === "chat") cut.add("chat");
          return { id };
        },
        truncated: () => [...cut],
      },
      "u1",
      NOW,
      () => undefined,
    );
    assert.deepEqual(file.truncated, ["chat"]);
    assert.deepEqual(file.missing, []);
  });
});

// --------------------------------------------------------------------------
// Consents and requests
// --------------------------------------------------------------------------

describe("consents", () => {
  it("withdrawing: some switch off, the rest need deletion or removing the children", () => {
    assert.equal(withdrawEffect("whatsapp"), "whatsappOff");
    assert.equal(withdrawEffect("analytics"), "analyticsOff");
    assert.equal(withdrawEffect("showOnMap"), "hiddenFromMap");
    assert.equal(withdrawEffect("walletTerms"), "walletClosed");
    assert.equal(withdrawEffect("childData"), "needsChildRemoval");
    assert.equal(withdrawEffect("face"), "needsDeletion");
    assert.equal(needsAdmin("name"), true);
    assert.equal(needsAdmin("email"), false);
  });

  it("views: the latest record per kind; analytics on by default until switched off", () => {
    const views = consentViews(
      [
        { type: "whatsapp", version: "v1", acceptedAtMs: 1, withdrawnAtMs: null },
        { type: "whatsapp", version: "v1", acceptedAtMs: 5, withdrawnAtMs: 6 },
        { type: "terms", version: "v1", acceptedAtMs: 1, withdrawnAtMs: null },
      ],
      { showOnMap: true, analytics: null },
    );
    const by = Object.fromEntries(views.map((v) => [v.kind, v.active]));
    assert.equal(by.whatsapp, false);
    assert.equal(by.terms, true);
    assert.equal(by.face, false);
    assert.equal(by.analytics, true);
    assert.equal(by.showOnMap, true);
    assert.equal(consentViews([{ type: "analytics", version: "v1", acceptedAtMs: 2, withdrawnAtMs: 3 }], { showOnMap: false, analytics: false }).find((v) => v.kind === "analytics")?.active, false);
  });
});

// --------------------------------------------------------------------------
// Retention job
// --------------------------------------------------------------------------

class MemoryRetention implements RetentionStore {
  closed: ClosedAccount[] = [];
  runs: RetentionReport[] = [];
  alerts: RetentionReport[] = [];
  chats = ["private:a", "private:b"];
  deletedChats: string[] = [];
  failArchives = false;
  async closedAccountsToWork() {
    return this.closed;
  }
  async deleteRouteArchivesDue() {
    if (this.failArchives) throw new Error("storage down");
    return 3;
  }
  frozen: string[] = [];
  async endClosedCarpoolChats(_nowMs: number, _limit: number, freeze: (cid: string) => Promise<void>) {
    await freeze("cp_carpool:c-k9");
    return 1;
  }
  purgedCarpoolsBefore: number[] = [];
  async purgeClosedCarpoolsBefore(before: number) {
    this.purgedCarpoolsBefore.push(before);
    return 2;
  }
  async deleteOrphanTrips() {
    return 1;
  }
  async purgeSettleUps() {
    return 2;
  }
  async endedChatsBefore() {
    return this.chats;
  }
  async deleteChatRecord(cid: string) {
    this.deletedChats.push(cid);
  }
  async clearReportContexts() {
    return 1;
  }
  async deleteTripStopsBefore() {
    return 2;
  }
  async deleteAuditBefore() {
    return 0;
  }
  async deleteExportsBefore() {
    return 4;
  }
  async deleteHandledSecurityAlertsBefore() {
    return 0;
  }
  async saveRun(r: RetentionReport) {
    this.runs.push(r);
  }
  async raiseFailureAlert(r: RetentionReport) {
    this.alerts.push(r);
  }
}

describe("retention job", () => {
  it("runs every task, writes a report, and alerts on failures without stopping", async () => {
    const store = new MemoryRetention();
    const runner = new FakeRunner();
    store.closed = [{ ...newClosedAccount("u1", "ABCD2345", false, NOW - 400 * DAY_MS) }];
    store.failArchives = true;
    const reported: unknown[] = [];
    const deletedChannels: string[] = [];
    const report = await runRetention({
      store,
      runner,
      deleteChannel: async (cid) => {
        if (cid === "private:b") throw new Error("chat 500");
        deletedChannels.push(cid);
      },
      sweepChatPhotos: async () => 0,
      freezeChannel: async (cid) => void store.frozen.push(cid),
      now: () => NOW,
      reportError: (e) => reported.push(e),
    });
    assert.equal(report.tasks.closedAccounts.deleted, 1, "purged after a year");
    assert.ok(runner.ran.includes("faceRefs/u1/"));
    assert.deepEqual(report.tasks.routeArchives, { deleted: 0, failed: 1 });
    assert.deepEqual(report.tasks.chats, { deleted: 1, failed: 1 });
    assert.deepEqual(store.deletedChats, ["private:a"], "a chat whose delete failed keeps its record (retried)");
    assert.deepEqual(report.tasks.exports, { deleted: 4, failed: 0 });
    assert.deepEqual(store.frozen, ["cp_carpool:c-k9"], "a closed carpool's chat is frozen and its year starts");
    assert.deepEqual(report.tasks.closedCarpools, { deleted: 2, failed: 0 });
    assert.deepEqual(report.tasks.orphanTrips, { deleted: 1, failed: 0 });
    assert.deepEqual(report.tasks.settleUps, { deleted: 2, failed: 0 }, "settle-up records past their date (F45)");
    assert.deepEqual(store.purgedCarpoolsBefore, [NOW - 365 * DAY_MS], "closed carpools go 1 year after they closed");
    assert.deepEqual(report.failures.sort(), ["chat:private:b", "routeArchives"]);
    assert.equal(store.runs.length, 1);
    assert.equal(store.alerts.length, 1);
    assert.ok(reported.length >= 3);
  });

  it("a clean run raises no alert", async () => {
    const store = new MemoryRetention();
    store.chats = [];
    const report = await runRetention({ store, runner: new FakeRunner(), deleteChannel: async () => undefined, sweepChatPhotos: async () => 0, freezeChannel: async () => undefined, now: () => NOW, reportError: () => undefined });
    assert.deepEqual(report.failures, []);
    assert.equal(store.alerts.length, 0);
  });
});

// --------------------------------------------------------------------------
// Kept photos: reasons, thumbnails, selfie archive
// --------------------------------------------------------------------------


describe("kept photos", () => {
  it("admins open photos only with a fixed reason code", () => {
    assert.equal(accessReason("investigation"), "investigation");
    assert.equal(accessReason("because"), null);
    assert.equal(accessReason(undefined), null);
  });

  it("thumbnails for kept photos only, under thumbs/{uid} with a hashed name", () => {
    for (const p of ["verification/u1/cases/C1/id_front.jpg", "faceRefs/u1/selfie.jpg", "driverPhotos/u1/photo.jpg", "selfieArchive/u1/run_k1_2026-11-14_am.jpg"]) {
      assert.equal(thumbOwner(p), "u1", p);
      const t = thumbPath(p);
      assert.match(t ?? "", /^thumbs\/u1\/[0-9a-f]{32}\.webp$/);
      assert.ok(!(t ?? "").includes("id_front"), "the original name is not in the path");
    }
    for (const p of ["verification/u1/pending/id_front.jpg", "thumbs/u1/abc.webp", "selfieChecks/u1/x.jpg", "exports/u1/r.json", "routeArchive/2026/t.json.gz"]) {
      assert.equal(thumbPath(p), null, p);
    }
    assert.equal(thumbPath("faceRefs/u1/selfie.jpg"), thumbPath("faceRefs/u1/selfie.jpg"), "stable");
  });

  it("selfie archive paths are checked", () => {
    assert.equal(selfieArchivePath("u1", "phone_1.jpg"), "selfieArchive/u1/phone_1.jpg");
    assert.throws(() => selfieArchivePath("../u1", "x.jpg"));
    assert.throws(() => selfieArchivePath("u1", "x.png"));
  });

  it("a thumbnail is current only for the same version of the photo; it goes when the photo goes", async () => {
    const files = new Map<string, { generation: string; meta: Record<string, string> }>();
    const bucket = {
      file: (name: string) => ({
        exists: async () => [files.has(name)],
        getMetadata: async () => [{ generation: files.get(name)?.generation, metadata: files.get(name)?.meta }],
        delete: async () => void files.delete(name),
      }),
    } as unknown as Parameters<typeof ensureThumb>[0];
    const photo = "faceRefs/u1/selfie.jpg";
    const thumb = thumbPath(photo)!;
    files.set(photo, { generation: "2", meta: {} });
    files.set(thumb, { generation: "9", meta: { [SOURCE_GENERATION]: "2" } });
    assert.equal(await ensureThumb(bucket, photo, "2"), "current");
    assert.equal(await ensureThumb(bucket, "verification/u1/pending/id_front.jpg", "1"), "skipped", "never a pending upload");
    // A new face reference (generation 3): the old thumb is not current (it is remade; sharp is not loaded here).
    await assert.rejects(ensureThumb(bucket, photo, "3"));
    // The photo exists again after an overwrite: its thumb stays.
    assert.equal(await dropThumb(bucket, photo), false);
    assert.ok(files.has(thumb));
    // Deleted (withdrawn case, purge): the thumb goes.
    files.delete(photo);
    assert.equal(await dropThumb(bucket, photo), true);
    assert.ok(!files.has(thumb));
  });
});

// --------------------------------------------------------------------------
// Trips per parent (owner answer 14 Nov 2026, 13:29)
// --------------------------------------------------------------------------

describe("privacy: trips kept per parent, active + 1 year", () => {
  const YEAR = 365 * DAY_MS;
  const trip = () => ({
    driverUid: "d1",
    driverFirstName: "Dina",
    viewerUids: ["d1", "p1", "p2"],
    childIds: ["c1", "c2"],
    stops: [
      { childId: "c1", firstName: "Adam", parentUid: "p1", handover: [{ name: "Gran" }] },
      { childId: "c2", firstName: "Laila", parentUid: "p2", handover: [] },
    ],
  });
  const active: AccountState = { active: true };
  const closed = (ago: number): AccountState => ({ active: false, closedAtMs: NOW - ago });

  it("participants are the driver and the parents on the trip, never 'deleted'", () => {
    assert.deepEqual(participantsOf(trip()).sort(), ["d1", "p1", "p2"]);
    assert.deepEqual(participantsOf({ driverUid: "deleted", stops: [{ parentUid: "deleted" }] }), []);
  });

  it("kept while anyone is active or closed less than a year ago", () => {
    assert.equal(isRetained(active, NOW), true);
    assert.equal(isRetained(closed(YEAR - 1), NOW), true);
    assert.equal(isRetained(closed(YEAR + 1), NOW), false);
    assert.equal(isRetained(undefined, NOW), false);
    assert.equal(isRetained({ active: false, closedAtMs: null }, NOW), false);
    const states = new Map<string, AccountState>([["d1", closed(2 * YEAR)], ["p1", closed(2 * YEAR)], ["p2", active]]);
    const plan = planTripRetention(trip(), states, NOW);
    assert.equal(plan.action, "keep");
  });

  it("a closed carpool's trip is not deleted while one parent is still active; the expired parts become initials", () => {
    const states = new Map<string, AccountState>([["d1", closed(2 * YEAR)], ["p1", closed(YEAR + DAY_MS)], ["p2", active]]);
    const plan = planTripRetention(trip(), states, NOW);
    assert.equal(plan.action, "keep");
    if (plan.action !== "keep" || !plan.change) throw new Error("expected a change");
    assert.equal(plan.change.driverUid, "deleted");
    assert.equal(plan.change.driverFirstName, "D.");
    assert.deepEqual(plan.change.viewerUids, ["p2"]);
    const stops = plan.change.stops as Array<Record<string, unknown>>;
    assert.deepEqual(stops[0], { childId: "deleted", firstName: "A.", parentUid: "deleted", handover: [] });
    assert.equal(stops[1].firstName, "Laila", "the active parent's child keeps the name");
  });

  it("everyone active: nothing changes", () => {
    const states = new Map<string, AccountState>([["d1", active], ["p1", active], ["p2", active]]);
    assert.deepEqual(planTripRetention(trip(), states, NOW), { action: "keep", change: null });
  });

  it("deleted when every participant's year is over (or there is no record)", () => {
    const states = new Map<string, AccountState>([["d1", closed(YEAR + 1)], ["p1", closed(2 * YEAR)]]);
    assert.deepEqual(planTripRetention(trip(), states, NOW), { action: "delete" });
    assert.deepEqual(planTripRetention({ driverUid: "deleted", stops: [] }, new Map(), NOW), { action: "delete" });
  });

  it("a parent anonymised at deletion still counts until their closure + 1 year (review finding 2)", () => {
    // p1 deleted the account 2 months ago: their stop became "deleted" and the trip got keptUntilMs.
    const anonymised = { ...trip(), stops: [{ childId: "deleted", firstName: "A.", parentUid: "deleted", handover: [] }, trip().stops[1]] };
    const change = keepForClosedParent(anonymised, { stops: anonymised.stops }, NOW - 60 * DAY_MS);
    assert.equal(change?.keptUntilMs, NOW - 60 * DAY_MS + YEAR);
    const withKeep = { ...anonymised, ...change };
    // The driver's year is over and p2 closed long ago: still kept for p1's year.
    const states = new Map<string, AccountState>([["d1", closed(YEAR + DAY_MS)], ["p2", closed(2 * YEAR)]]);
    assert.equal(planTripRetention(withKeep, states, NOW).action, "keep");
    assert.equal(planTripRetention(withKeep, states, NOW - 60 * DAY_MS + YEAR + 1).action, "delete");
    // An orphan (nobody left by uid) waits for keptUntilMs too.
    const orphan = { driverUid: "deleted", stops: [], keptUntilMs: NOW + DAY_MS };
    assert.equal(planTripRetention(orphan, new Map(), NOW).action, "keep");
    assert.deepEqual(planTripRetention(orphan, new Map(), NOW + 2 * DAY_MS), { action: "delete" });
    // A later deletion never shortens the time.
    assert.equal(keepForClosedParent({ keptUntilMs: NOW + 5 * YEAR }, { stops: [] }, NOW)?.keptUntilMs, NOW + 5 * YEAR);
    assert.equal(keepForClosedParent({}, null, NOW), null);
  });

  it("a passed keptUntilMs is cleared on a trip kept for active parents", () => {
    const states = new Map<string, AccountState>([["d1", active], ["p1", active], ["p2", active]]);
    assert.deepEqual(planTripRetention({ ...trip(), keptUntilMs: NOW - 1 }, states, NOW), { action: "keep", change: { keptUntilMs: null } });
  });

  it("the account purge (exactly at the year): the driver's trips stay for active parents, go when nobody is left", () => {
    const states = new Map<string, AccountState>([["d1", closed(YEAR)], ["p1", active]]);
    const kept = planTripRetention(trip(), states, NOW, new Set(["d1"]));
    assert.equal(kept.action, "keep");
    const alone = { ...trip(), stops: [{ childId: "deleted", firstName: "A.", parentUid: "deleted", handover: [] }] };
    assert.deepEqual(planTripRetention(alone, states, NOW, new Set(["d1"])), { action: "delete" });
  });
});

// --------------------------------------------------------------------------
// Admin: close an open new-phone check (Prompt 13)
// --------------------------------------------------------------------------

describe("privacy: an admin approves or clears a new-phone check, logged first", () => {
  const isReason = (v: unknown) => accessReasonOf(v) !== null;
  function world(open = true) {
    const order: string[] = [];
    let check: { required: boolean; sinceMs: number } | null = open ? { required: true, sinceMs: NOW } : null;
    const audits: Array<Record<string, unknown>> = [];
    const deps = {
      store: {
        async deviceCheck() {
          return check;
        },
        async setDeviceCheck(_uid: string, c: { required: boolean; sinceMs: number } | null) {
          order.push("set");
          check = c;
        },
      },
      async audit(e: Record<string, unknown>) {
        order.push("audit");
        audits.push(e);
      },
    };
    return { deps, audits, order, check: () => check };
  }

  it("approved after comparing the photos: the data opens again; the audit entry comes first with the reason", async () => {
    const w = world();
    assert.deepEqual(await adminDecideDeviceCheck(w.deps, "admin1", { uid: "u1", reason: "review", outcome: "approved" }, "1.2.3.4", isReason), { cleared: true, outcome: "approved" });
    assert.equal(w.check(), null);
    assert.deepEqual(w.order, ["audit", "set"]);
    assert.equal(w.audits[0].action, "device.check.approved");
    assert.equal(w.audits[0].reasonCode, "review");
    assert.equal(w.audits[0].target, "users/u1");
  });

  it("confirmed another way is logged as such", async () => {
    const w = world();
    await adminDecideDeviceCheck(w.deps, "admin1", { uid: "u1", reason: "parentRequest", outcome: "confirmedOtherWay" }, null, isReason);
    assert.equal(w.audits[0].action, "device.check.confirmedOtherWay");
  });

  it("refused: no reason, an unknown outcome, a bad uid, the admin's own account, or no open check", async () => {
    for (const bad of [{ uid: "u1" }, { uid: "u1", reason: "curious" }, { uid: "u1", reason: "review", outcome: "maybe" }, { uid: "../x", reason: "review" }, { uid: "admin1", reason: "review" }]) {
      const w = world();
      await assert.rejects(adminDecideDeviceCheck(w.deps, "admin1", bad, null, isReason), /invalid-request/, JSON.stringify(bad));
      assert.deepEqual(w.order, [], "nothing changed or logged");
    }
    const none = world(false);
    await assert.rejects(adminDecideDeviceCheck(none.deps, "admin1", { uid: "u1", reason: "review" }, null, isReason), /not-found/);
  });
});
