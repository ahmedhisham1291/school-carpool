// Pilot feature switches (owner decision 14 Nov 2026). Fake data only. Run: npm test.
// Loading the callable modules registers Storage triggers, which need a
// bucket name; outside Firebase none is set.
process.env.FIREBASE_CONFIG ??= JSON.stringify({ projectId: "demo-school-carpool", storageBucket: "demo-school-carpool.firebasestorage.app" });
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { afterEach, describe, it } from "node:test";
import { AdminError } from "../src/admin_panel/errors";
import type { AuditEntry } from "../src/admin_panel/types";
import { drivingPaused } from "../src/carpools/model";
import { getFeatures, setFeature, type FeatureAdminDeps } from "../src/features/admin";
import { clearFeatureCache, featureOn, features, requireFeature, setFeatureReaderForTests, skipWhenOff } from "../src/features/gate";
import {
  ALL_ON,
  FEATURE_CACHE_MS,
  FEATURE_KEYS,
  FEATURE_MAX_FAILED_READS,
  FeatureCache,
  FeatureOffError,
  FEATURES_DOC,
  GATED_FUNCTIONS,
  GATED_NOTIFICATIONS,
  notificationFeature,
  parseFeatureChange,
  MONEY_FEATURES,
  PILOT_DEFAULTS,
  switchesFrom,
  type FeatureKey,
} from "../src/features/model";
import { NOTIFICATION_TYPES } from "../src/notifications/catalog";
import { dispatchEvent, type DispatchDeps } from "../src/notifications/dispatch";
import { newEvent } from "../src/notifications/model";
import { deleteAccount, pathFor, type ClosedAccount, type DeletionRunner } from "../src/privacy/account_deletion";
import { buildExport } from "../src/privacy/export";
import { DATA_TYPES } from "../src/privacy/retention";
import { MemoryNotifyStore, RecordingPush, RecordingWhatsApp } from "./helpers/memory_notifications";

const NOW = Date.UTC(2026, 10, 14, 8);

afterEach(() => setFeatureReaderForTests(null));

describe("feature switches: the document", () => {
  it("pilot defaults: everything off, the money features (wallet, Settle up, contributions) included", () => {
    assert.deepEqual([...MONEY_FEATURES], ["wallet", "settleUp", "contributions"]);
    for (const key of MONEY_FEATURES) assert.equal(PILOT_DEFAULTS[key], false, key);
    assert.deepEqual(PILOT_DEFAULTS, { wallet: false, ratingsAndVouching: false, yearlyChecks: false, settleUp: false, contributions: false, activityCarpools: false });
    assert.deepEqual([...FEATURE_KEYS], ["wallet", "ratingsAndVouching", "yearlyChecks", "settleUp", "contributions", "activityCarpools"]);
    assert.equal(FEATURES_DOC, "config/features");
  });

  it("a missing document reads as the pilot defaults", () => {
    assert.deepEqual(switchesFrom(null), PILOT_DEFAULTS);
    assert.deepEqual(switchesFrom(undefined), PILOT_DEFAULTS);
    assert.deepEqual(switchesFrom({}), PILOT_DEFAULTS);
  });

  it("only real booleans count; anything else keeps the default; unknown keys are ignored", () => {
    assert.deepEqual(switchesFrom({ wallet: true, settleUp: false }), { wallet: true, ratingsAndVouching: false, yearlyChecks: false, settleUp: false, contributions: false, activityCarpools: false });
    assert.deepEqual(switchesFrom({ wallet: "true", ratingsAndVouching: 1, yearlyChecks: null, settleUp: "no", chat: false }), PILOT_DEFAULTS);
  });

  it("core features have no switch", () => {
    for (const core of ["signIn", "verification", "carpools", "schedule", "trips", "alerts", "chat"]) {
      assert.equal((FEATURE_KEYS as readonly string[]).includes(core), false, core);
    }
  });
});

describe("feature switches: the per-instance cache", () => {
  it("reads once, then answers from memory until the short time is over", async () => {
    let reads = 0;
    let now = NOW;
    let doc: Record<string, unknown> = { wallet: true };
    const cache = new FeatureCache(async () => {
      reads += 1;
      return doc;
    }, () => now);
    assert.equal(await cache.isOn("wallet"), true);
    assert.equal(await cache.isOn("settleUp"), false, "not stored: the default (off)");
    await cache.get();
    assert.equal(reads, 1, "one read for many calls");
    doc = { wallet: false };
    now += FEATURE_CACHE_MS - 1;
    assert.equal(await cache.isOn("wallet"), true, "still the cached value");
    now += 2;
    assert.equal(await cache.isOn("wallet"), false, "a change reaches the instance within the cache time: no deploy, no app release");
    assert.equal(reads, 2);
  });

  it("calls that arrive together share one read", async () => {
    let reads = 0;
    const cache = new FeatureCache(async () => {
      reads += 1;
      await new Promise((r) => setTimeout(r, 5));
      return {};
    });
    await Promise.all([cache.get(), cache.get(), cache.get()]);
    assert.equal(reads, 1);
  });

  it("a failed read uses the last known value, or the pilot defaults (never everything on)", async () => {
    let fail = true;
    let now = NOW;
    const errors: unknown[] = [];
    const cache = new FeatureCache(
      async () => {
        if (fail) throw new Error("firestore down");
        return { wallet: true };
      },
      () => now,
      FEATURE_CACHE_MS,
      (e) => errors.push(e),
    );
    assert.deepEqual(await cache.get(), PILOT_DEFAULTS);
    assert.equal(errors.length, 1);
    fail = false;
    now += FEATURE_CACHE_MS + 1;
    assert.equal(await cache.isOn("wallet"), true);
    fail = true;
    now += FEATURE_CACHE_MS + 1;
    assert.equal(await cache.isOn("wallet"), true, "the last known value");
  });

  it("fails closed: after 3 failed reads in a row a stale ON is dropped for the pilot defaults, until a read works", async () => {
    let fail = false;
    let now = NOW;
    const cache = new FeatureCache(
      async () => {
        if (fail) throw new Error("firestore down");
        return { wallet: true, ratingsAndVouching: true, yearlyChecks: true, settleUp: true, contributions: true, activityCarpools: true };
      },
      () => now,
    );
    assert.equal(await cache.isOn("wallet"), true);
    fail = true;
    for (let i = 1; i < FEATURE_MAX_FAILED_READS; i++) {
      now += FEATURE_CACHE_MS + 1;
      assert.equal(await cache.isOn("wallet"), true, `failed read ${i}: the last known value`);
    }
    now += FEATURE_CACHE_MS + 1;
    assert.deepEqual(await cache.get(), PILOT_DEFAULTS, "every switch is back to its default: all off");
    assert.equal(await cache.isOn("wallet"), false);
    await assert.rejects(cache.require("wallet"), (e: unknown) => e instanceof FeatureOffError);
    // Firestore answers again: the stored values are back.
    fail = false;
    now += FEATURE_CACHE_MS + 1;
    assert.equal(await cache.isOn("wallet"), true);
    // The count starts again after a good read.
    fail = true;
    now += FEATURE_CACHE_MS + 1;
    assert.equal(await cache.isOn("wallet"), true);
    assert.equal(FEATURE_MAX_FAILED_READS, 3);
  });

  it("require throws FeatureOffError with the feature; clear reads again", async () => {
    let doc: Record<string, unknown> = {};
    const cache = new FeatureCache(async () => doc);
    await assert.rejects(cache.require("wallet"), (e: unknown) => e instanceof FeatureOffError && e.feature === "wallet");
    await assert.rejects(cache.require("settleUp"), (e: unknown) => e instanceof FeatureOffError && e.feature === "settleUp");
    doc = { wallet: true };
    cache.clear();
    await cache.require("wallet");
  });
});

describe("feature switches: the gate used by Cloud Functions", () => {
  it("requireFeature refuses with failed-precondition and details { reason: feature-off, feature }", async () => {
    setFeatureReaderForTests(async () => null);
    await assert.rejects(requireFeature("wallet"), (e: unknown) => {
      const err = e as { code?: string; message?: string; details?: { reason?: string; feature?: string } };
      return err.code === "failed-precondition" && err.message === "feature-off" && err.details?.reason === "feature-off" && err.details?.feature === "wallet";
    });
    await assert.rejects(requireFeature("settleUp"), (e: unknown) => (e as { details?: { feature?: string } }).details?.feature === "settleUp");
    await assert.rejects(requireFeature("contributions"), (e: unknown) => (e as { details?: { feature?: string } }).details?.feature === "contributions");
    assert.deepEqual(await features(), PILOT_DEFAULTS);
  });

  it("turning a feature on in the document turns it on for the functions", async () => {
    let doc: Record<string, unknown> = {};
    setFeatureReaderForTests(async () => doc);
    assert.equal(await featureOn("ratingsAndVouching"), false);
    doc = { ratingsAndVouching: true };
    clearFeatureCache();
    assert.equal(await featureOn("ratingsAndVouching"), true);
  });

  it("skipWhenOff: a job of a switched-off feature does nothing", async () => {
    setFeatureReaderForTests(async () => ({ wallet: false, settleUp: true }));
    assert.equal(await skipWhenOff("wallet", "walletReconcile"), true);
    assert.equal(await skipWhenOff("settleUp", "x"), false);
  });
});

// The callables as the app reaches them. firebase-functions gives each
// one a `run` (the handler); the local build stubs return the handler.
type Handler = (request: unknown) => Promise<unknown>;
function handlerOf(fn: unknown): Handler {
  const f = fn as { run?: Handler };
  return typeof f.run === "function" ? (r) => (f.run as Handler)(r) : (fn as Handler);
}

const request = (uid: string, data: unknown = {}) => ({ auth: { uid, token: { verified: true, auth_time: Math.floor(NOW / 1000) } }, data, rawRequest: { headers: {}, ip: "127.0.0.1" } });

function isFeatureOff(feature: FeatureKey) {
  return (e: unknown) => {
    const err = e as { code?: string; details?: { reason?: string; feature?: string } };
    return err.code === "failed-precondition" && err.details?.reason === "feature-off" && err.details?.feature === feature;
  };
}

describe("feature switches: every gated entry point", () => {
  const modules: Record<FeatureKey, () => Record<string, unknown>> = {
    wallet: () => require("../src/wallet/callables") as Record<string, unknown>,
    ratingsAndVouching: () => require("../src/trust/callables") as Record<string, unknown>,
    yearlyChecks: () => require("../src/trust/callables") as Record<string, unknown>,
    settleUp: () => require("../src/settle_up/callables") as Record<string, unknown>,
    contributions: () => require("../src/carpools/callables") as Record<string, unknown>,
    activityCarpools: () => require("../src/carpools/callables") as Record<string, unknown>,
  };
  const ALL_OFF = { wallet: false, ratingsAndVouching: false, yearlyChecks: false, settleUp: false, contributions: false, activityCarpools: false };

  it("every gated function is exported from index.ts under that name", () => {
    const index = readFileSync(join(__dirname, "..", "..", "src", "index.ts"), "utf8");
    for (const key of FEATURE_KEYS) {
      for (const name of [...GATED_FUNCTIONS[key].callables, ...GATED_FUNCTIONS[key].jobs]) {
        assert.match(index, new RegExp(`\\b${name},`), `${name} (${key})`);
        assert.equal(typeof modules[key]()[name], "function", `${name} is defined in the ${key} module`);
      }
    }
  });

  it("every wallet function of index.ts is gated (nothing of the wallet stays reachable while it is off)", () => {
    const exported = Object.keys(modules.wallet()).filter((k) => !["walletProvider"].includes(k));
    const gated = [...GATED_FUNCTIONS.wallet.callables, ...GATED_FUNCTIONS.wallet.jobs];
    assert.deepEqual(exported.sort(), gated.sort());
  });

  it("every settle-up function is gated", () => {
    const exported = Object.keys(modules.settleUp()).filter((k) => k !== "settleDeps");
    assert.deepEqual(exported.sort(), [...GATED_FUNCTIONS.settleUp.callables].sort());
  });

  for (const key of FEATURE_KEYS) {
    for (const name of GATED_FUNCTIONS[key].callables) {
      it(`${name} refuses with "feature-off" while ${key} is off, before anything else`, async () => {
        setFeatureReaderForTests(async () => ALL_OFF);
        const fn = handlerOf(modules[key]()[name]);
        await assert.rejects(fn(request("alice")), isFeatureOff(key));
        // Signed out as well: the switch answers first.
        await assert.rejects(fn({ data: {}, rawRequest: { headers: {} } }), isFeatureOff(key));
      });
    }
    for (const name of GATED_FUNCTIONS[key].jobs) {
      it(`${name} does nothing while ${key} is off`, async () => {
        setFeatureReaderForTests(async () => ALL_OFF);
        await handlerOf(modules[key]()[name])({});
      });
    }
  }

  it("with the pilot defaults the wallet, ratings and the yearly check refuse; nothing else is touched", async () => {
    setFeatureReaderForTests(async () => null);
    await assert.rejects(handlerOf(modules.wallet().sendMoney)(request("alice", { amount: 100 })), isFeatureOff("wallet"));
    await assert.rejects(handlerOf(modules.ratingsAndVouching().rateParent)(request("alice")), isFeatureOff("ratingsAndVouching"));
    await assert.rejects(handlerOf(modules.yearlyChecks().confirmSchoolYear)(request("alice")), isFeatureOff("yearlyChecks"));
    // No money in the app (owner, 16 Nov 2026): Settle up refuses too.
    await assert.rejects(handlerOf(modules.settleUp().createSettleUp)(request("alice", { amount: 100 })), isFeatureOff("settleUp"));
    await assert.rejects(handlerOf(modules.settleUp().getSettleUpAddress)(request("alice")), isFeatureOff("settleUp"));
    await assert.rejects(handlerOf(modules.wallet().getWallet)(request("alice")), isFeatureOff("wallet"));
  });
});

describe("feature switches: driver eligibility stays on", () => {
  it("the yearly check's overdue mark blocks driving only while yearlyChecks is on", () => {
    assert.equal(drivingPaused({ yearCheckOverdue: true }, true), true);
    assert.equal(drivingPaused({ yearCheckOverdue: true }, false), false, "pilot: nobody is blocked for a missing yearly check");
    assert.equal(drivingPaused({}, true), false);
  });

  it("pauses for an urgent report or a failed selfie check have no switch", () => {
    for (const on of [true, false]) {
      assert.equal(drivingPaused({ drivingPaused: true }, on), true);
      assert.equal(drivingPaused({ drivingPaused: { reason: "selfie" } }, on), true);
      assert.equal(drivingPaused({ drivingPaused: false }, on), false);
      assert.equal(drivingPaused({ drivingPaused: true, yearCheckOverdue: true }, on), true);
    }
  });
});

describe("feature switches: notifications", () => {
  it("every gated type is a real notification type", () => {
    for (const type of Object.keys(GATED_NOTIFICATIONS)) assert.ok((NOTIFICATION_TYPES as readonly string[]).includes(type), type);
    assert.equal(notificationFeature("wallet-received"), "wallet");
    assert.equal(notificationFeature("year-check-due"), "yearlyChecks");
    assert.equal(notificationFeature("settle-requested"), "settleUp");
    // Driver eligibility and core alerts are never gated.
    for (const type of ["licence-expiring", "licence-expired", "driver-unavailable", "no-driver", "guardian-requested", "emergency"]) {
      assert.equal(notificationFeature(type), null, type);
    }
  });

  it("the sender closes an event of a switched-off feature without a record, a push or WhatsApp", async () => {
    const store = new MemoryNotifyStore();
    const push = new RecordingPush();
    const whatsapp = new RecordingWhatsApp();
    for (const uid of ["alice", "bob"]) store.addParent(uid);
    const off = new Set(["wallet-received", "year-check-due"]);
    const deps: DispatchDeps = { store, push, whatsapp, now: () => NOW, log: () => undefined, typeAllowed: async (type) => !off.has(type) };
    const gated = await dispatchEvent(deps, newEvent("e-wallet", "wallet-received", ["bob"], NOW));
    assert.equal(gated.reason, "feature-off");
    assert.equal(gated.records, 0);
    assert.deepEqual(store.recordsOf("bob"), []);
    assert.equal(push.sent.length, 0);
    const year = await dispatchEvent(deps, newEvent("e-year", "year-check-due", ["bob"], NOW));
    assert.equal(year.reason, "feature-off");
    // A papers reminder (driver eligibility) is still sent.
    const papers = await dispatchEvent(deps, newEvent("e-papers", "licence-expired", ["bob"], NOW));
    assert.equal(papers.records, 1);
  });
});

describe("admin panel: Settings (feature switches)", () => {
  function setup(initial: Record<string, unknown> | null = null) {
    let doc = initial;
    const audit: AuditEntry[] = [];
    const writes: Array<{ feature: string; on: boolean; adminUid: string }> = [];
    let cleared = 0;
    let failWrite = false;
    const deps: FeatureAdminDeps = {
      store: {
        read: async () => doc,
        // One batch on the server: the switch and its audit entry together.
        write: async (feature, on, adminUid, _nowMs, entry) => {
          if (failWrite) throw new Error("batch failed");
          doc = { ...(doc ?? {}), [feature]: on };
          writes.push({ feature, on, adminUid });
          audit.push(entry);
        },
      },
      now: () => NOW,
      changed: () => void (cleared += 1),
    };
    return { deps, audit, writes, cleared: () => cleared, failNextWrites: () => void (failWrite = true) };
  }
  const superAdmin = { uid: "root", role: "superAdmin" as const };
  const admin = { uid: "ops", role: "admin" as const };

  it("shows the switches with the pilot defaults when nothing is stored", async () => {
    const t = setup();
    const view = await getFeatures(t.deps);
    assert.deepEqual(view.features, PILOT_DEFAULTS);
    assert.deepEqual(view.defaults, PILOT_DEFAULTS);
    assert.deepEqual([...view.keys], [...FEATURE_KEYS]);
  });

  it("a super admin turns one switch on: stored, audited (who, which, the new value), cache cleared", async () => {
    const t = setup();
    const view = await setFeature(t.deps, superAdmin, { feature: "wallet", on: true }, "10.0.0.1");
    assert.equal(view.features.wallet, true);
    assert.equal(view.features.settleUp, false, "the others keep their value");
    assert.deepEqual(t.writes, [{ feature: "wallet", on: true, adminUid: "root" }]);
    assert.equal(t.audit.length, 1);
    assert.equal(t.audit[0].action, "feature.on");
    assert.equal(t.audit[0].actorUid, "root");
    assert.equal(t.audit[0].target, "config/features#wallet");
    assert.deepEqual(t.audit[0].details, { feature: "wallet", on: true });
    assert.equal(t.audit[0].ip, "10.0.0.1");
    assert.equal(t.cleared(), 1);
    const off = await setFeature(t.deps, superAdmin, { feature: "wallet", on: false }, null);
    assert.equal(off.features.wallet, false);
    assert.equal(t.audit[1].action, "feature.off");
  });

  it("the switch and its audit entry are one write: when it fails neither stands", async () => {
    const t = setup();
    t.failNextWrites();
    await assert.rejects(setFeature(t.deps, superAdmin, { feature: "wallet", on: true }, null), /batch failed/);
    assert.equal(t.writes.length, 0);
    assert.equal(t.audit.length, 0);
    assert.equal((await getFeatures(t.deps)).features.wallet, false);
    assert.equal(t.cleared(), 0);
  });

  it("setting a switch to the value it has writes nothing and logs nothing", async () => {
    const t = setup();
    await setFeature(t.deps, superAdmin, { feature: "settleUp", on: false }, null);
    assert.equal(t.writes.length, 0);
    assert.equal(t.audit.length, 0);
  });

  it("refuses an ordinary admin, an unknown switch, a core feature and a value that is not a boolean", async () => {
    const t = setup();
    const refused = (reason: string) => (e: unknown) => e instanceof AdminError && e.reason === reason;
    await assert.rejects(setFeature(t.deps, admin, { feature: "wallet", on: true }, null), refused("invalid-state"));
    await assert.rejects(setFeature(t.deps, superAdmin, { feature: "chat", on: false }, null), refused("invalid-request"));
    await assert.rejects(setFeature(t.deps, superAdmin, { feature: "wallet", on: "yes" }, null), refused("invalid-request"));
    await assert.rejects(setFeature(t.deps, superAdmin, null, null), refused("invalid-request"));
    assert.equal(t.writes.length, 0);
    assert.equal(parseFeatureChange({ feature: "yearlyChecks", on: false })?.feature, "yearlyChecks");
    assert.equal(parseFeatureChange({ feature: "trips", on: false }), null);
  });

  it("ALL_ON is what the features' own unit tests run with", () => {
    assert.ok(FEATURE_KEYS.every((k) => ALL_ON[k]));
  });
});

describe("wallet switched off: account deletion and export still work with no wallet", () => {
  it("a parent who never opened a wallet deletes the account: no wallet call, the InstaPay address goes", async () => {
    const ran: string[] = [];
    const walletCalls: string[] = [];
    const closed = new Map<string, ClosedAccount>();
    const runner: DeletionRunner = {
      facts: async () => ({ exists: true, drivingNow: false, parentId: "ABCD2345", banned: false, openCase: false }),
      // No wallets/{uid} document (the pilot): nothing to lock.
      lockWallet: async () => null,
      walletFacts: async () => {
        walletCalls.push("facts");
        return { balance: 0, pending: 0 };
      },
      unlockWallet: async () => void walletCalls.push("unlock"),
      saveClosed: async (c) => void closed.set(c.uid, c),
      closed: async (uid) => closed.get(uid) ?? null,
      runFlowStep: async (_uid, step) => void ran.push(`flow:${step}`),
      runTarget: async (uid, target) => {
        ran.push(target.kind === "doc" || target.kind === "subcollection" ? pathFor(target.path, uid) : target.kind === "storage" ? pathFor(target.prefix, uid) : `${target.collection}.${target.field}`);
        return 1;
      },
      runPurgeStep: async () => undefined,
    };
    const result = await deleteAccount(runner, "alice", NOW, () => assert.fail("no step may fail"));
    assert.equal(result.closed, true);
    assert.equal(result.failed, 0);
    assert.deepEqual(walletCalls, [], "the partner is never asked when there is no wallet");
    assert.ok(ran.includes("settleUpAddresses/alice"), "the InstaPay address is deleted at once");
    assert.ok(ran.includes("settleUpLimits/alice"));
    assert.ok(ran.includes("flow:anonymise"), "settle-up records keep an initial only");
    assert.ok(ran.indexOf("settleUpAddresses/alice") < ran.indexOf("users/alice"));
  });

  it("the export has every section when the wallet section is empty, and a Settle up section", async () => {
    const file = await buildExport(
      {
        section: async (_uid, id) => (id === "wallet" ? { wallet: null, transfers: [] } : id === "settleUp" ? { instaPayAddress: "alice.test@instapay", records: [] } : { id }),
      },
      "alice",
      NOW,
      () => assert.fail("no section may fail"),
    );
    assert.deepEqual(file.missing, []);
    assert.deepEqual(file.sections.wallet, { wallet: null, transfers: [] });
    assert.deepEqual(file.sections.settleUp, { instaPayAddress: "alice.test@instapay", records: [] });
    assert.deepEqual(Object.keys(file.sections), [...DATA_TYPES]);
  });
});
