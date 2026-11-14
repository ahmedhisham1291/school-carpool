// Settle up by InstaPay (F45). Fake parents, fake addresses and fake amounts only. Run: npm test.
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import { ALL_ON, FeatureOffError } from "../src/features/model";
import { routeFor, TYPES, WHATSAPP_GROUPS } from "../src/notifications/catalog";
import { TEXTS } from "../src/notifications/texts";
import { redact } from "../src/privacy/export";
import { IMMEDIATE_TARGETS, NOT_DELETED } from "../src/privacy/account_deletion";
import { DATA_TYPES, rule } from "../src/privacy/retention";
import {
  adminListSettleUps,
  contacts,
  createSettleUp,
  eligible,
  getAddressFor,
  getProfile,
  removeAddress,
  reportSettleUp,
  saveAddress,
  settleUpAction,
  type Caller,
  type SettleDeps,
} from "../src/settle_up/flow";
import {
  anonymiseSettleUp,
  applyAction,
  canReport,
  DEFAULT_SETTLE_LIMITS,
  DEFAULT_SETTLE_SETTINGS,
  DELETED_ID,
  isFinal,
  maskIpa,
  MAX_EVENTS,
  MAX_OPEN_PER_PAIR,
  newRecord,
  normalizeIpa,
  noteField,
  NOTE_MAX,
  parseCreate,
  planRetention,
  SETTLE_ACTIONS,
  SETTLE_KEEP_AFTER_CLOSE_MS,
  SettleError,
  settingsFrom,
  settleId,
  type CreateInput,
  type SettleAction,
  type SettleRecord,
  type SettleRole,
  type SettleStatus,
} from "../src/settle_up/model";
import { settleFromDoc, settleToDoc } from "../src/settle_up/store";
import { MemorySettleStore } from "./helpers/memory_settle_up";

// Saturday 14 Nov 2026, 10:00 in Cairo.
const NOW = Date.UTC(2026, 10, 14, 8);
const DAY = 86_400_000;
const EGP = 100;
const ALICE_IPA = "alice.test@instapay";

const as = (uid: string, verifiedClaim = true): Caller => ({ uid, verifiedClaim });

async function rejects(p: Promise<unknown>, reason: string): Promise<void> {
  await assert.rejects(p, (e: unknown) => e instanceof SettleError && e.reason === reason, `expected ${reason}`);
}

let store: MemorySettleStore;
let clock: { now: number };
let deps: SettleDeps;
let seq: number;

/** A fresh request ID, like the app's (16 to 64 letters, digits or hyphens). */
const rid = (): string => `req-${String(++seq).padStart(16, "0")}`;

beforeEach(() => {
  store = new MemorySettleStore();
  clock = { now: NOW };
  seq = 0;
  deps = { store, now: () => clock.now, limits: { ...DEFAULT_SETTLE_LIMITS } };
  store.addParent("alice", "Alice");
  store.addParent("bob", "Bob");
  store.addParent("cara", "Cara");
  store.addParent("dina", "Dina");
  store.addCarpool("k1", ["alice", "bob", "cara"]);
  store.addresses.set("alice", ALICE_IPA);
});

/** Alice (payee) asks Bob (payer) for 150 EGP. */
async function request(over: Record<string, unknown> = {}, caller: Caller = as("alice")): Promise<SettleRecord> {
  const { record } = await createSettleUp(deps, caller, { requestId: rid(), kind: "request", otherUid: "bob", carpoolId: "k1", amount: 150 * EGP, reason: "contribution", ...over });
  return record;
}

const act = (uid: string, id: string, action: SettleAction) => settleUpAction(deps, as(uid), { id, action });

// --------------------------------------------------------------------------
// The principle
// --------------------------------------------------------------------------

describe("settle up: the app never moves, holds or sees money", () => {
  it("the store has no balance, wallet, bank or card operation: only records, addresses and limits", () => {
    const methods = Object.getOwnPropertyNames(MemorySettleStore.prototype);
    for (const m of methods) assert.doesNotMatch(m, /balance|wallet|transfer|card|bank|debit|credit|charge|fee|commission/i, m);
  });

  it("a record holds no bank or card detail and no InstaPay address", async () => {
    const r = await request();
    const doc = settleToDoc(r);
    const keys = Object.keys(doc).join(",");
    assert.doesNotMatch(keys, /address|ipa|iban|card|bank|account|fee|commission/i);
    assert.doesNotMatch(JSON.stringify(doc), /instapay/i, "the address is never copied into the record");
  });

  it("no fee and no commission: the amount recorded is the amount asked", async () => {
    const r = await request({ amount: 12_345 });
    assert.equal(r.amount, 12_345);
    assert.equal(r.currency, "EGP");
  });
});

// --------------------------------------------------------------------------
// InstaPay address
// --------------------------------------------------------------------------

describe("settle up: InstaPay address (name@instapay)", () => {
  it("accepts the form name@instapay, trims and lower-cases it", () => {
    assert.equal(normalizeIpa("mona.ali@instapay"), "mona.ali@instapay");
    assert.equal(normalizeIpa("  Mona.Ali_92@InstaPay "), "mona.ali_92@instapay");
    assert.equal(normalizeIpa("m-1.x@instapay"), "m-1.x@instapay");
    assert.equal(normalizeIpa("abc@instapay"), "abc@instapay");
  });

  it("refuses anything else: no suffix, another suffix, spaces, Arabic, a phone number, a bank account, too short or long", () => {
    for (const bad of [
      "",
      "mona",
      "mona@gmail.com",
      "mona@instapay.com",
      "mona ali@instapay",
      "منى@instapay",
      "@instapay",
      "ab@instapay",
      ".mona@instapay",
      "mona@@instapay",
      "mona@insta",
      "01012345678",
      "EG380019000500000000263180002",
      `${"a".repeat(51)}@instapay`,
      "mona@instapay\nextra",
      "<script>@instapay",
    ]) {
      assert.equal(normalizeIpa(bad), null, JSON.stringify(bad));
    }
    for (const notText of [null, undefined, 5, {}, []]) assert.equal(normalizeIpa(notText), null);
  });

  it("masks an address for display", () => {
    assert.equal(maskIpa("mona.ali@instapay"), "mo…@instapay");
    assert.equal(maskIpa("nothing"), "");
  });

  it("a verified parent saves, reads back, changes and removes their own address", async () => {
    assert.deepEqual(await saveAddress(deps, as("bob"), { address: " Bob.Test@INSTAPAY " }), { address: "bob.test@instapay" });
    assert.equal((await getProfile(deps, as("bob"))).address, "bob.test@instapay");
    await saveAddress(deps, as("bob"), { address: "bob2.test@instapay" });
    assert.equal(store.addresses.get("bob"), "bob2.test@instapay");
    assert.deepEqual(await removeAddress(deps, as("bob")), { removed: true });
    assert.equal((await getProfile(deps, as("bob"))).address, null);
  });

  it("refuses a bad address, an unverified, suspended or banned parent, and too many changes in a day", async () => {
    await rejects(saveAddress(deps, as("bob"), { address: "bob@gmail.com" }), "invalid-address");
    await rejects(saveAddress(deps, as("bob"), {}), "invalid-address");
    await rejects(saveAddress(deps, as("bob"), null), "invalid-request");
    await rejects(saveAddress(deps, as("bob", false), { address: "bob.test@instapay" }), "not-verified");
    store.addParent("una", "Una", { status: "pending" });
    await rejects(saveAddress(deps, as("una"), { address: "una.test@instapay" }), "not-verified");
    store.addParent("sam", "Sam", { status: "suspended" });
    await rejects(saveAddress(deps, as("sam"), { address: "sam.test@instapay" }), "suspended");
    store.addParent("ben", "Ben", { banned: true });
    await rejects(saveAddress(deps, as("ben"), { address: "ben.test@instapay" }), "suspended");
    await rejects(saveAddress(deps, as("ghost"), { address: "ghost.test@instapay" }), "no-account");
    for (let i = 0; i < DEFAULT_SETTLE_LIMITS.addressChangesPerDay; i++) await saveAddress(deps, as("cara"), { address: `cara${i}.test@instapay` });
    await rejects(saveAddress(deps, as("cara"), { address: "cara9.test@instapay" }), "rate-limited");
    clock.now += DAY;
    await saveAddress(deps, as("cara"), { address: "cara9.test@instapay" });
  });

  it("the profile gives the caller's OWN address only, with the limits the form shows", async () => {
    const p = await getProfile(deps, as("bob"));
    assert.equal(p.address, null, "Bob has none; Alice's is not his to see here");
    assert.equal(p.maxAmount, 5_000 * EGP);
    assert.equal(p.reportAfter, 2);
    assert.deepEqual(store.addressReads, ["bob"]);
  });
});

describe("settle up: who sees the address", () => {
  it("only the payer of an OPEN request from that payee", async () => {
    const r = await request();
    assert.deepEqual(await getAddressFor(deps, as("bob"), { id: r.id }), { address: ALICE_IPA });
    // The payee asks for "the address of the record": not allowed (they have their own on their profile).
    await rejects(getAddressFor(deps, as("alice"), { id: r.id }), "not-allowed");
    // Another member of the same carpool: the record does not exist for them.
    await rejects(getAddressFor(deps, as("cara"), { id: r.id }), "not-found");
    await rejects(getAddressFor(deps, as("dina"), { id: r.id }), "not-found");
    await rejects(getAddressFor(deps, as("bob"), { id: "s_unknown" }), "not-found");
    await rejects(getAddressFor(deps, as("ghost"), { id: r.id }), "no-account");
  });

  it("not once it is paid, received, cancelled or declined; again after Not received", async () => {
    const r = await request();
    await act("bob", r.id, "paid");
    await rejects(getAddressFor(deps, as("bob"), { id: r.id }), "invalid-state");
    await act("alice", r.id, "notReceived");
    assert.equal((await getAddressFor(deps, as("bob"), { id: r.id })).address, ALICE_IPA);
    await act("bob", r.id, "paid");
    await act("alice", r.id, "received");
    await rejects(getAddressFor(deps, as("bob"), { id: r.id }), "invalid-state");
    const second = await request();
    await act("alice", second.id, "cancel");
    await rejects(getAddressFor(deps, as("bob"), { id: second.id }), "invalid-state");
  });

  it("a payer cannot use a record they made themselves to read an address", async () => {
    // Bob records "I paid Alice": the record starts as paid, never open for Bob.
    const { record } = await createSettleUp(deps, as("bob"), { requestId: rid(), kind: "paid", otherUid: "alice", carpoolId: "k1", amount: 50 * EGP, reason: "fuel" });
    assert.equal(record.status, "paid");
    await rejects(getAddressFor(deps, as("bob"), { id: record.id }), "invalid-state");
  });

  it("null when the payee removed it; address views are rate limited", async () => {
    const r = await request();
    store.addresses.delete("alice");
    assert.deepEqual(await getAddressFor(deps, as("bob"), { id: r.id }), { address: null });
    store.addresses.set("alice", ALICE_IPA);
    for (let i = 1; i < DEFAULT_SETTLE_LIMITS.addressViewsPerHour; i++) await getAddressFor(deps, as("bob"), { id: r.id });
    await rejects(getAddressFor(deps, as("bob"), { id: r.id }), "rate-limited");
    clock.now += 3_600_000;
    await getAddressFor(deps, as("bob"), { id: r.id });
  });

  it("the address never reaches a notification, the contacts list, the admin view or an error", async () => {
    const r = await request({ note: "week 1" });
    await act("bob", r.id, "paid");
    const everything = JSON.stringify([
      store.events,
      await contacts(deps, as("bob"), {}),
      await adminListSettleUps(deps, "admin1", "alice", "report", null),
      store.audits,
      [...store.records.values()],
    ]);
    assert.doesNotMatch(everything, /instapay/i);
    try {
      await getAddressFor(deps, as("cara"), { id: r.id });
      assert.fail("expected a refusal");
    } catch (e) {
      assert.doesNotMatch(JSON.stringify({ m: (e as Error).message, d: (e as SettleError).details }), /instapay/i);
    }
  });
});

// --------------------------------------------------------------------------
// Create
// --------------------------------------------------------------------------

describe("settle up: creating a record", () => {
  it("a payee asks another verified member of a shared carpool; the payer gets a push event", async () => {
    const r = await request({ note: "  week\n1  " });
    assert.equal(r.status, "open");
    assert.equal(r.createdBy, "payee");
    assert.equal(r.payeeUid, "alice");
    assert.equal(r.payerUid, "bob");
    assert.equal(r.payeeFirstName, "Alice");
    assert.equal(r.payerFirstName, "Bob");
    assert.deepEqual(r.parties, ["alice", "bob"]);
    assert.equal(r.note, "week 1", "one line, trimmed");
    assert.deepEqual(r.events, [{ type: "requested", by: "payee", atMs: NOW }]);
    assert.equal(store.events.length, 1);
    assert.equal(store.events[0].type, "settle-requested");
    assert.deepEqual(store.events[0].recipients, ["bob"]);
    assert.equal(store.events[0].actorUid, "alice");
  });

  it("a payer records a payment first: it waits for the payee's confirmation", async () => {
    const { record, created } = await createSettleUp(deps, as("bob"), { requestId: rid(), kind: "paid", otherUid: "alice", carpoolId: "k1", amount: 75 * EGP, reason: "fuel" });
    assert.equal(created, true);
    assert.equal(record.status, "paid");
    assert.equal(record.createdBy, "payer");
    assert.equal(record.payerUid, "bob");
    assert.equal(record.payeeUid, "alice");
    assert.deepEqual(record.events, [{ type: "recorded", by: "payer", atMs: NOW }]);
    assert.equal(store.events[0].type, "settle-paid");
    assert.deepEqual(store.events[0].recipients, ["alice"]);
    // Bob needs no saved address to record a payment he made.
    assert.equal(store.addresses.has("bob"), false);
    assert.equal((await act("alice", record.id, "received")).record.status, "closed");
  });

  it("idempotent: a retry with the same request ID returns the first record and sends nothing twice", async () => {
    const input = { requestId: rid(), kind: "request", otherUid: "bob", carpoolId: "k1", amount: 150 * EGP, reason: "contribution", note: "w1" };
    const first = await createSettleUp(deps, as("alice"), input);
    const again = await createSettleUp(deps, as("alice"), input);
    assert.equal(first.created, true);
    assert.equal(again.created, false);
    assert.equal(again.record.id, first.record.id);
    assert.equal(store.records.size, 1);
    assert.equal(store.events.length, 1);
    // The retry still answers after the record moved on (a slow network).
    await act("bob", first.record.id, "paid");
    assert.equal((await createSettleUp(deps, as("alice"), input)).record.status, "paid");
    // The same ID with another amount or person is refused, not merged.
    await rejects(createSettleUp(deps, as("alice"), { ...input, amount: 999 * EGP }), "request-reused");
    await rejects(createSettleUp(deps, as("alice"), { ...input, otherUid: "cara" }), "request-reused");
    // Another parent's same request ID is another record.
    assert.notEqual(settleId("alice", input.requestId), settleId("bob", input.requestId));
  });

  it("a retry does not use the daily limit a second time", async () => {
    deps.limits = { ...DEFAULT_SETTLE_LIMITS, requestsPerDay: 1 };
    const input = { requestId: rid(), kind: "request", otherUid: "bob", carpoolId: "k1", amount: 10 * EGP, reason: "other" };
    await createSettleUp(deps, as("alice"), input);
    assert.equal((await createSettleUp(deps, as("alice"), input)).created, false);
    await rejects(request(), "rate-limited");
    clock.now += DAY;
    await request();
  });

  it("the amount: whole piastres from EGP 1 up to the server maximum (default EGP 5,000)", async () => {
    assert.equal((await request({ amount: 1 * EGP })).amount, 100);
    assert.equal((await request({ amount: 5_000 * EGP })).amount, 500_000);
    await rejects(request({ amount: 5_000 * EGP + 1 }), "amount-too-high");
    for (const bad of [0, 99, -500, 10.5, Number.NaN, Number.POSITIVE_INFINITY, "150", null, undefined]) await rejects(request({ amount: bad }), "invalid-amount");
    try {
      await request({ amount: 6_000 * EGP });
      assert.fail("expected a refusal");
    } catch (e) {
      assert.deepEqual((e as SettleError).details, { maxAmount: 500_000 }, "the app can say the limit");
    }
  });

  it("the maximum comes from server settings and changes without a deploy", async () => {
    store.config = { maxAmount: 200 * EGP };
    await rejects(request({ amount: 201 * EGP }), "amount-too-high");
    await request({ amount: 200 * EGP });
    assert.equal((await getProfile(deps, as("alice"))).maxAmount, 200 * EGP);
    // A missing, odd or absurd value is the default.
    assert.deepEqual(settingsFrom(null), DEFAULT_SETTLE_SETTINGS);
    assert.deepEqual(settingsFrom({ maxAmount: "1000" }), DEFAULT_SETTLE_SETTINGS);
    assert.deepEqual(settingsFrom({ maxAmount: 0 }), DEFAULT_SETTLE_SETTINGS);
    assert.deepEqual(settingsFrom({ maxAmount: 10 ** 12 }), DEFAULT_SETTLE_SETTINGS);
    assert.deepEqual(settingsFrom({ maxAmount: 1.5 }), DEFAULT_SETTLE_SETTINGS);
  });

  it("refuses bad input: kind, reason, IDs, a long note, a note that is not text", async () => {
    await rejects(request({ kind: "gift" }), "invalid-request");
    await rejects(request({ reason: "loan" }), "invalid-request");
    await rejects(request({ requestId: "short" }), "invalid-request");
    await rejects(request({ otherUid: "a/b" }), "invalid-request");
    await rejects(request({ carpoolId: "" }), "invalid-request");
    await rejects(request({ note: "x".repeat(NOTE_MAX + 1) }), "invalid-request");
    await rejects(request({ note: 5 }), "invalid-request");
    await rejects(createSettleUp(deps, as("alice"), "nope"), "invalid-request");
    assert.equal(noteField("x".repeat(NOTE_MAX)).length, NOTE_MAX);
    assert.equal(noteField(undefined), "");
    assert.equal(noteField("a\u0000b\tc d"), "a b c d");
    assert.equal(store.records.size, 0);
  });

  it("membership: both must be approved members of that carpool now", async () => {
    await rejects(request({ otherUid: "dina" }), "not-allowed"); // Dina is in no carpool with Alice
    await rejects(request({ carpoolId: "k9" }), "not-allowed"); // no such carpool
    store.addCarpool("k2", ["alice", "dina"]);
    await rejects(request({ otherUid: "dina", carpoolId: "k1" }), "not-allowed"); // the wrong carpool
    await request({ otherUid: "dina", carpoolId: "k2" });
    // Bob left k1: no new request to or from him there.
    store.members.get("k1")?.delete("bob");
    await rejects(request(), "not-allowed");
    await rejects(createSettleUp(deps, as("bob"), { requestId: rid(), kind: "paid", otherUid: "alice", carpoolId: "k1", amount: 10 * EGP, reason: "other" }), "not-allowed");
  });

  it("not to yourself", async () => {
    await rejects(request({ otherUid: "alice" }), "self");
  });

  it("an unverified, suspended or banned parent cannot create; nor can anyone create with them", async () => {
    await rejects(request({}, as("alice", false)), "not-verified");
    store.addParent("una", "Una", { status: "pending" });
    store.addParent("sam", "Sam", { status: "suspended" });
    store.addParent("ben", "Ben", { banned: true });
    store.addCarpool("k3", ["alice", "una", "sam", "ben"]);
    for (const uid of ["una", "sam", "ben"]) store.addresses.set(uid, `${uid}.test@instapay`);
    await rejects(createSettleUp(deps, as("una"), { requestId: rid(), kind: "request", otherUid: "alice", carpoolId: "k3", amount: 10 * EGP, reason: "other" }), "not-verified");
    await rejects(createSettleUp(deps, as("sam"), { requestId: rid(), kind: "request", otherUid: "alice", carpoolId: "k3", amount: 10 * EGP, reason: "other" }), "suspended");
    await rejects(createSettleUp(deps, as("ben"), { requestId: rid(), kind: "paid", otherUid: "alice", carpoolId: "k3", amount: 10 * EGP, reason: "other" }), "suspended");
    for (const other of ["una", "sam", "ben", "ghost"]) await rejects(request({ otherUid: other, carpoolId: "k3" }), "not-allowed");
    assert.equal(eligible(null), false);
    assert.equal(store.records.size, 0);
  });

  it("blocked either way: no request, with the same answer as any other refusal", async () => {
    store.blocks.add("bob_alice");
    await rejects(request(), "not-allowed");
    await rejects(createSettleUp(deps, as("bob"), { requestId: rid(), kind: "paid", otherUid: "alice", carpoolId: "k1", amount: 10 * EGP, reason: "other" }), "not-allowed");
    store.blocks.clear();
    store.blocks.add("alice_bob");
    await rejects(request(), "not-allowed");
  });

  it("a payee needs a saved InstaPay address before asking", async () => {
    await rejects(createSettleUp(deps, as("bob"), { requestId: rid(), kind: "request", otherUid: "alice", carpoolId: "k1", amount: 10 * EGP, reason: "other" }), "no-address");
    await saveAddress(deps, as("bob"), { address: "bob.test@instapay" });
    await createSettleUp(deps, as("bob"), { requestId: rid(), kind: "request", otherUid: "alice", carpoolId: "k1", amount: 10 * EGP, reason: "other" });
  });

  it("limits: requests per day, and unfinished records between one pair", async () => {
    deps.limits = { ...DEFAULT_SETTLE_LIMITS, requestsPerDay: 3 };
    for (let i = 0; i < 3; i++) await request();
    await rejects(request(), "rate-limited");
    await rejects(request({ otherUid: "cara" }), "rate-limited");
    deps.limits = { ...DEFAULT_SETTLE_LIMITS, requestsPerDay: 100 };
    clock.now += DAY;
    for (let i = 3; i < MAX_OPEN_PER_PAIR; i++) await request();
    await rejects(request(), "too-many-open");
    await request({ otherUid: "cara" }); // another pair is fine
    // Finishing one makes room.
    const first = [...store.records.values()].find((r) => r.payerUid === "bob");
    assert.ok(first);
    await act("alice", first.id, "cancel");
    await request();
  });

  it("contacts: the other parents of my carpools, by first name, never an address", async () => {
    store.addCarpool("k2", ["alice", "dina"], { ar: "نادي", en: "Club" });
    const all = (await contacts(deps, as("alice"), null)).contacts;
    assert.deepEqual(all.map((c) => `${c.firstName}@${c.carpoolId}`), ["Bob@k1", "Cara@k1", "Dina@k2"]);
    assert.deepEqual((await contacts(deps, as("alice"), { carpoolId: "k2" })).contacts.map((c) => c.uid), ["dina"]);
    assert.deepEqual(Object.keys(all[0]).sort(), ["carpoolId", "carpoolNameAr", "carpoolNameEn", "firstName", "uid", "verified"]);
    await rejects(contacts(deps, as("alice", false), {}), "not-verified");
  });
});

// --------------------------------------------------------------------------
// State machine
// --------------------------------------------------------------------------

describe("settle up: the state machine", () => {
  const input: CreateInput = { requestId: "req-0000000000000001", kind: "request", otherUid: "bob", carpoolId: "k1", amount: 100 * EGP, reason: "fuel", note: "" };
  const fresh = (status: SettleStatus = "open"): SettleRecord => ({ ...newRecord(input, { uid: "alice", firstName: "Alice" }, { uid: "bob", firstName: "Bob" }, NOW), status });

  // [action, who may, from, to]
  const allowed: Array<[SettleAction, SettleRole, SettleStatus, SettleStatus]> = [
    ["paid", "payer", "open", "paid"],
    ["received", "payee", "paid", "closed"],
    ["notReceived", "payee", "paid", "open"],
    ["cancel", "payee", "open", "cancelled"],
    ["decline", "payer", "open", "declined"],
  ];
  const statuses: SettleStatus[] = ["open", "paid", "closed", "cancelled", "declined"];

  it("exactly five moves exist; every other (action, side, state) is refused", () => {
    let ok = 0;
    for (const action of SETTLE_ACTIONS) {
      for (const role of ["payee", "payer"] as const) {
        for (const from of statuses) {
          const rule = allowed.find(([a, r, f]) => a === action && r === role && f === from);
          if (rule) {
            assert.equal(applyAction(fresh(from), role, action, NOW + 1).status, rule[3], `${role} ${action} from ${from}`);
            ok += 1;
          } else {
            assert.throws(() => applyAction(fresh(from), role, action, NOW + 1), (e: unknown) => e instanceof SettleError && (e.reason === "not-allowed" || e.reason === "invalid-state"), `${role} ${action} from ${from}`);
          }
        }
      }
    }
    assert.equal(ok, 5);
  });

  it("closed, cancelled and declined are final", () => {
    for (const s of ["closed", "cancelled", "declined"] as const) {
      assert.equal(isFinal(s), true);
      for (const action of SETTLE_ACTIONS) for (const role of ["payee", "payer"] as const) assert.throws(() => applyAction(fresh(s), role, action, NOW));
    }
    assert.equal(isFinal("open"), false);
    assert.equal(isFinal("paid"), false);
  });

  it("the history is append-only: every move adds one entry and keeps the earlier ones", () => {
    let r = fresh();
    const seen: string[] = [JSON.stringify(r.events)];
    for (const [role, action] of [["payer", "paid"], ["payee", "notReceived"], ["payer", "paid"], ["payee", "received"]] as const) {
      const next = applyAction(r, role, action, r.updatedAtMs + 1000);
      assert.equal(next.events.length, r.events.length + 1);
      assert.deepEqual(next.events.slice(0, r.events.length), r.events, "earlier entries are untouched");
      assert.equal(JSON.stringify(r.events), seen[seen.length - 1], "the input is not changed in place");
      seen.push(JSON.stringify(next.events));
      r = next;
    }
    assert.deepEqual(r.events.map((e) => `${e.by}:${e.type}`), ["payee:requested", "payer:paid", "payee:not-received", "payer:paid", "payee:received"]);
    assert.equal(r.notReceived, 1);
    assert.equal(r.status, "closed");
    assert.equal(r.closedAtMs, r.updatedAtMs);
    // Amount, people and reason never change.
    assert.equal(r.amount, 100 * EGP);
    assert.equal(r.payeeUid, "alice");
    assert.equal(r.payerUid, "bob");
  });

  it("a record that bounces forever stops accepting moves", () => {
    let r = fresh();
    while (r.events.length < MAX_EVENTS) r = applyAction(r, r.status === "open" ? "payer" : "payee", r.status === "open" ? "paid" : "notReceived", r.updatedAtMs + 1);
    assert.throws(() => applyAction(r, r.status === "open" ? "payer" : "payee", r.status === "open" ? "paid" : "received", NOW), (e: unknown) => e instanceof SettleError && e.reason === "invalid-state");
  });

  it("through the functions: request, I paid, Not received (counted), I paid, Received", async () => {
    const r = await request();
    await rejects(act("alice", r.id, "paid"), "not-allowed"); // the payee cannot mark it paid
    await rejects(act("bob", r.id, "received"), "not-allowed"); // the payer cannot confirm their own payment
    await rejects(act("alice", r.id, "received"), "invalid-state"); // nothing was paid yet
    assert.equal((await act("bob", r.id, "paid")).record.status, "paid");
    await rejects(act("bob", r.id, "paid"), "invalid-state"); // a double tap changes nothing
    await rejects(act("alice", r.id, "cancel"), "invalid-state"); // paid: confirm or say not received
    await rejects(act("bob", r.id, "decline"), "invalid-state");
    const back = (await act("alice", r.id, "notReceived")).record;
    assert.equal(back.status, "open");
    assert.equal(back.notReceived, 1);
    await act("bob", r.id, "paid");
    const done = (await act("alice", r.id, "received")).record;
    assert.equal(done.status, "closed");
    for (const a of SETTLE_ACTIONS) {
      await assert.rejects(act("alice", r.id, a));
      await assert.rejects(act("bob", r.id, a));
    }
    assert.equal(store.records.get(r.id)?.events.length, 5);
  });

  it("the payee cancels an open request; the payer declines one", async () => {
    const a = await request();
    await rejects(act("bob", a.id, "cancel"), "not-allowed");
    assert.equal((await act("alice", a.id, "cancel")).record.status, "cancelled");
    const b = await request();
    await rejects(act("alice", b.id, "decline"), "not-allowed");
    assert.equal((await act("bob", b.id, "decline")).record.status, "declined");
  });

  it("only the two parties: anyone else gets the same answer as for a missing record", async () => {
    const r = await request();
    for (const a of SETTLE_ACTIONS) {
      await rejects(act("cara", r.id, a), "not-found");
      await rejects(act("dina", r.id, a), "not-found");
    }
    await rejects(act("bob", "s_missing", "paid"), "not-found");
    await rejects(settleUpAction(deps, as("bob"), { id: r.id, action: "refund" }), "invalid-request");
    await rejects(settleUpAction(deps, as("ghost"), { id: r.id, action: "paid" }), "no-account");
    assert.equal(store.records.get(r.id)?.status, "open");
  });

  it("a parent who left the carpool, or was suspended since, can still finish existing records", async () => {
    const r = await request();
    store.members.get("k1")?.delete("bob");
    assert.equal((await act("bob", r.id, "paid")).record.status, "paid");
    store.members.get("k1")?.delete("alice");
    store.addParent("alice", "Alice", { status: "suspended" });
    assert.equal((await settleUpAction(deps, as("alice", false), { id: r.id, action: "received" })).record.status, "closed");
  });

  it("changes are rate limited per parent", async () => {
    deps.limits = { ...DEFAULT_SETTLE_LIMITS, changesPerDay: 2 };
    const r = await request();
    await act("bob", r.id, "paid");
    await act("alice", r.id, "notReceived");
    await act("bob", r.id, "paid");
    await rejects(act("bob", r.id, "decline"), "rate-limited");
  });
});

// --------------------------------------------------------------------------
// Notifications
// --------------------------------------------------------------------------

describe("settle up: notifications", () => {
  it("push only: never WhatsApp, no group a parent could switch to WhatsApp", () => {
    for (const type of ["settle-requested", "settle-paid", "settle-updated"] as const) {
      assert.equal(TYPES[type].template, null, type);
      assert.equal(TYPES[type].group, "settleUp");
      assert.equal(TYPES[type].critical, false);
      assert.equal(TYPES[type].urgent, false, "quiet hours are respected");
      assert.equal(routeFor({ type, carpoolId: "k1" }), "/profile/settle-up");
    }
    assert.equal((WHATSAPP_GROUPS as readonly string[]).includes("settleUp"), false);
  });

  it("the text has no amount, name, note or address", () => {
    for (const type of ["settle-requested", "settle-paid", "settle-updated"] as const) {
      for (const lang of ["ar", "en"] as const) {
        const text = `${TEXTS[type][lang].title} ${TEXTS[type][lang].body}`;
        assert.doesNotMatch(text, /\d|EGP|جنيه|instapay|\{/i, `${type} ${lang}`);
      }
    }
  });

  it("the payer hears of a new request, the payee of I paid, the other side of every later change; never the one who acted", async () => {
    const r = await request({ note: "week 1" });
    await act("bob", r.id, "paid");
    await act("alice", r.id, "notReceived");
    await act("bob", r.id, "paid");
    await act("alice", r.id, "received");
    assert.deepEqual(
      store.events.map((e) => `${e.type}>${e.recipients.join(",")}`),
      ["settle-requested>bob", "settle-paid>alice", "settle-updated>bob", "settle-paid>alice", "settle-updated>bob"],
    );
    for (const e of store.events) {
      assert.equal(e.recipients.includes(e.actorUid ?? ""), false);
      // IDs only: nothing of the record travels in the event.
      const body = JSON.stringify(e);
      assert.doesNotMatch(body, /week 1|15000|Alice|Bob|instapay/);
      assert.match(e.id, /^settle_[0-9a-f]{32}$/);
    }
    assert.equal(new Set(store.events.map((e) => e.id)).size, store.events.length, "one event per history entry");
  });

  it("cancel and decline tell the other side", async () => {
    const a = await request();
    await act("alice", a.id, "cancel");
    const b = await request();
    await act("bob", b.id, "decline");
    assert.deepEqual(store.events.filter((e) => e.type === "settle-updated").map((e) => e.recipients[0]), ["bob", "alice"]);
  });
});

// --------------------------------------------------------------------------
// Reports
// --------------------------------------------------------------------------

describe("settle up: reporting a record that keeps bouncing", () => {
  async function bounced(times: number): Promise<SettleRecord> {
    const r = await request();
    for (let i = 0; i < times; i++) {
      await act("bob", r.id, "paid");
      await act("alice", r.id, "notReceived");
    }
    return r;
  }

  it("not before N Not received marks (default 2); then either side, once each, into the reports queue", async () => {
    const r = await bounced(1);
    await rejects(reportSettleUp(deps, as("bob"), { id: r.id }), "report-too-early");
    await act("bob", r.id, "paid");
    await act("alice", r.id, "notReceived");
    assert.deepEqual(await reportSettleUp(deps, as("bob"), { id: r.id, note: "paid twice" }), { reported: true });
    await rejects(reportSettleUp(deps, as("bob"), { id: r.id }), "already-reported");
    await reportSettleUp(deps, as("alice"), { id: r.id });
    assert.deepEqual(
      store.reports.map((x) => [x.reporterUid, x.targetUid, x.settleUpId, x.note]),
      [["bob", "alice", r.id, "paid twice"], ["alice", "bob", r.id, ""]],
    );
    const saved = store.records.get(r.id);
    assert.deepEqual(saved?.reportedBy, ["payer", "payee"]);
    assert.equal(saved?.status, "open", "a report does not change the state");
    assert.deepEqual(saved?.events.slice(-2).map((e) => e.type), ["reported", "reported"]);
  });

  it("the threshold is a setting; outsiders cannot report", async () => {
    deps.limits = { ...DEFAULT_SETTLE_LIMITS, reportAfter: 1 };
    const r = await bounced(1);
    await rejects(reportSettleUp(deps, as("cara"), { id: r.id }), "not-found");
    await reportSettleUp(deps, as("alice"), { id: r.id });
    assert.equal(canReport({ ...r, notReceived: 0, reportedBy: [] }, "payee", 1), "report-too-early");
  });
});

// --------------------------------------------------------------------------
// Feature switch
// --------------------------------------------------------------------------

describe("settle up: the feature switch", () => {
  it("off: every flow refuses with FeatureOffError and nothing is read or written", async () => {
    const r = await request();
    deps.features = async () => ({ ...ALL_ON, settleUp: false });
    const reads = store.addressReads.length;
    const off = (e: unknown) => e instanceof FeatureOffError && e.feature === "settleUp";
    await assert.rejects(getProfile(deps, as("alice")), off);
    await assert.rejects(saveAddress(deps, as("alice"), { address: "x.test@instapay" }), off);
    await assert.rejects(removeAddress(deps, as("alice")), off);
    await assert.rejects(contacts(deps, as("alice"), {}), off);
    await assert.rejects(request(), off);
    await assert.rejects(act("bob", r.id, "paid"), off);
    await assert.rejects(getAddressFor(deps, as("bob"), { id: r.id }), off);
    await assert.rejects(reportSettleUp(deps, as("bob"), { id: r.id }), off);
    await assert.rejects(adminListSettleUps(deps, "admin1", "alice", "report", null), off);
    assert.equal(store.records.size, 1);
    assert.equal(store.records.get(r.id)?.status, "open");
    assert.equal(store.addressReads.length, reads);
    assert.equal(store.audits.length, 0);
    // Back on (no release): the open record continues.
    deps.features = async () => ALL_ON;
    assert.equal((await act("bob", r.id, "paid")).record.status, "paid");
  });
});

// --------------------------------------------------------------------------
// Admin panel
// --------------------------------------------------------------------------

describe("settle up: admin panel (read only, logged reason)", () => {
  it("lists one parent's records after writing the audit entry; no address, no note", async () => {
    const r = await request({ note: "private words" });
    await createSettleUp(deps, as("bob"), { requestId: rid(), kind: "paid", otherUid: "alice", carpoolId: "k1", amount: 20 * EGP, reason: "fuel" });
    await request({ otherUid: "cara" });
    const view = await adminListSettleUps(deps, "admin1", "bob", "investigation", "10.0.0.9");
    assert.equal(view.records.length, 2, "only Bob's");
    assert.deepEqual(store.audits, [{ actorUid: "admin1", action: "settle-up.view", target: "users/bob", reasonCode: "investigation", ip: "10.0.0.9" }]);
    const mine = view.records.find((x) => x.id === r.id);
    assert.equal(mine?.role, "payer");
    assert.equal(mine?.otherFirstName, "Alice");
    assert.equal(mine?.amount, 150 * EGP);
    assert.equal(mine?.status, "open");
    assert.doesNotMatch(JSON.stringify(view), /private words|instapay/);
    assert.deepEqual(Object.keys(view.records[0]).sort(), ["amount", "createdAtMs", "finished", "id", "notReceived", "otherFirstName", "reason", "reported", "role", "status", "updatedAtMs"]);
  });
});

// --------------------------------------------------------------------------
// Privacy: export, deletion, retention
// --------------------------------------------------------------------------

describe("settle up: account deletion and retention", () => {
  const input: CreateInput = { requestId: "req-0000000000000001", kind: "request", otherUid: "bob", carpoolId: "k1", amount: 100 * EGP, reason: "fuel", note: "our words" };
  const base = (): SettleRecord => newRecord(input, { uid: "alice", firstName: "Alice" }, { uid: "bob", firstName: "Bob" }, NOW);
  const YEAR = SETTLE_KEEP_AFTER_CLOSE_MS;

  it("the kept time is one year after closure, like trips", () => {
    assert.equal(YEAR, 365 * DAY);
  });

  it("a deleted payer becomes an initial, leaves the parties, and an unfinished record ends", () => {
    const closedAt = NOW + 5 * DAY;
    const r = anonymiseSettleUp(base(), "bob", closedAt);
    assert.ok(r);
    assert.equal(r.payerUid, DELETED_ID);
    assert.equal(r.payerFirstName, "B.");
    assert.equal(r.payeeUid, "alice");
    assert.equal(r.payeeFirstName, "Alice");
    assert.deepEqual(r.parties, ["alice"], "Alice still reads it; Bob's uid is gone");
    assert.equal(r.note, "");
    assert.equal(r.status, "cancelled");
    assert.deepEqual(r.events[r.events.length - 1], { type: "account-closed", by: "system", atMs: closedAt });
    assert.equal(r.events.length, 2, "the history before it stays");
    assert.equal(r.keptUntilMs, closedAt + YEAR);
    assert.equal(r.amount, 100 * EGP);
  });

  it("a finished record keeps its outcome; a stranger's deletion changes nothing; a second run finds nothing", () => {
    const done = applyAction(applyAction(base(), "payer", "paid", NOW + 1), "payee", "received", NOW + 2);
    const r = anonymiseSettleUp(done, "alice", NOW + DAY);
    assert.ok(r);
    assert.equal(r.status, "closed");
    assert.equal(r.payeeUid, DELETED_ID);
    assert.equal(r.payeeFirstName, "A.");
    assert.equal(r.events.length, done.events.length);
    assert.equal(anonymiseSettleUp(base(), "cara", NOW), null);
    assert.equal(anonymiseSettleUp(r, "alice", NOW + 2 * DAY), null, "idempotent: a retried deletion step");
  });

  it("both deleted: an initial each, nobody reads it, kept until the later closure + 1 year", () => {
    const first = anonymiseSettleUp(base(), "bob", NOW);
    assert.ok(first);
    const both = anonymiseSettleUp(first, "alice", NOW + 100 * DAY);
    assert.ok(both);
    assert.deepEqual(both.parties, []);
    assert.equal(both.payeeFirstName, "A.");
    assert.equal(both.payerFirstName, "B.");
    assert.equal(both.keptUntilMs, NOW + 100 * DAY + YEAR);
    assert.equal(both.events.filter((e) => e.type === "account-closed").length, 1, "ended once");
  });

  it("retention: kept while either party's account is active, then one year after the last closure", () => {
    const active = (...uids: string[]) => new Set(uids);
    // Nobody deleted: no date, kept.
    assert.equal(planRetention(base(), active("alice", "bob"), NOW + 10 * YEAR), "keep");
    // Bob deleted; Alice active.
    const one = anonymiseSettleUp(base(), "bob", NOW);
    assert.ok(one);
    assert.equal(planRetention(one, active("alice"), NOW + YEAR - 1), "keep");
    assert.equal(planRetention(one, active("alice"), NOW + YEAR), "clear", "Bob's year is over but Alice's account still holds it");
    // Alice deletes later: a new date.
    const cleared = { ...one, keptUntilMs: null };
    assert.equal(planRetention(cleared, active("alice"), NOW + 5 * YEAR), "keep");
    const both = anonymiseSettleUp(cleared, "alice", NOW + 2 * YEAR);
    assert.ok(both);
    assert.equal(planRetention(both, active(), NOW + 3 * YEAR - 1), "keep");
    assert.equal(planRetention(both, active(), NOW + 3 * YEAR), "delete");
    // A party whose account is gone without the deletion having run (should not happen) does not hold it.
    assert.equal(planRetention(one, active(), NOW + YEAR), "delete");
  });

  it("stored and read back unchanged (the document the two parties read)", () => {
    const r = applyAction(applyAction(base(), "payer", "paid", NOW + 1000), "payee", "notReceived", NOW + 2000);
    const doc = settleToDoc(r);
    assert.equal(doc.finished, false);
    assert.deepEqual(doc.parties, ["alice", "bob"]);
    assert.equal(settleToDoc(applyAction(base(), "payee", "cancel", NOW)).finished, true);
    // Timestamps here are the build stubs or the real class: only shape is checked.
    assert.equal(doc.events.length, 3);
    assert.equal(doc.amount, 100 * EGP);
    const odd = settleFromDoc("s_x", { status: "weird", reason: "loan", amount: "5", parties: ["a", 5], events: [{ type: "nope" }, null], reportedBy: ["payee", "x"] });
    assert.equal(odd.status, "cancelled", "an unreadable state is never shown as open");
    assert.equal(odd.reason, "other");
    assert.equal(odd.amount, 0);
    assert.deepEqual(odd.parties, ["a"]);
    assert.deepEqual(odd.events, []);
    assert.deepEqual(odd.reportedBy, ["payee"]);
  });

  it("deletion: the address and the counters go at once; the records are classified as kept", () => {
    const paths = IMMEDIATE_TARGETS.map((t) => (t.target.kind === "doc" ? t.target.path : ""));
    assert.ok(paths.includes("settleUpAddresses/{uid}"));
    assert.ok(paths.includes("settleUpLimits/{uid}"));
    assert.match(NOT_DELETED.settleUps, /initial/);
    // Before the user record (the last target).
    assert.ok(paths.indexOf("settleUpAddresses/{uid}") < paths.indexOf("users/{uid}"));
  });

  it("the export has a Settle up section; the retention table says active + 1 year", () => {
    assert.ok((DATA_TYPES as readonly string[]).includes("settleUp"));
    const r = rule("settleUp");
    assert.equal(r.days, 365);
    assert.equal(r.from, "accountClosed");
    assert.deepEqual(r.enforcedBy, ["accountDeletion", "retentionDaily"]);
    // The owner's own address is theirs to export; internal keys are still removed.
    assert.deepEqual(redact({ instaPayAddress: ALICE_IPA, records: [{ id: "s_1", requestTokenHash: "x" }] }), { instaPayAddress: ALICE_IPA, records: [{ id: "s_1" }] });
  });
});

describe("settle up: input parsing", () => {
  it("parseCreate returns exactly the fields the flow uses", () => {
    const parsed = parseCreate({ requestId: "req-0000000000000001", kind: "paid", otherUid: "bob", carpoolId: "k1", amount: 500, reason: "other", note: " hi ", extra: "ignored", address: "x@instapay" }, DEFAULT_SETTLE_SETTINGS);
    assert.deepEqual(parsed, { requestId: "req-0000000000000001", kind: "paid", otherUid: "bob", carpoolId: "k1", amount: 500, reason: "other", note: "hi" });
  });
});
