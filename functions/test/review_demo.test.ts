/**
 * App Review access (docs/apple-review/audit.md, guideline 2.1): a second
 * allow-listed demo phone, audited demo sign-ins, and the demo parents'
 * self-ending exemption from the new-phone selfie and the driver face
 * reference.
 */
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import {
  activeReview,
  isReviewPhone,
  OtpError,
  phoneKey,
  requestCode,
  REVIEW_ACCESS_MAX_DAYS,
  reviewAccessFor,
  verifyCode,
  type AccountService,
  type OtpDeps,
  type ReviewAccess,
} from "../src/auth/otp_flow";
import { REVIEW_DEMO_FIELD, reviewDemoActive } from "../src/auth/review_access";
import { demoPlan, DEMO_IDS, demoWindowMs } from "../src/auth/review_demo";
import type { Language, WhatsAppSender } from "../src/whatsapp/sender";
import { MemoryOtpStore } from "./helpers/memory_otp_store";

const KEY = "k".repeat(40);
const PHONE_1 = "+201012345678";
const PHONE_2 = "+201112345678";
const CODE_1 = "482913";
const CODE_2 = "730215";
const DEVICE = "0123456789abcdef0123456789abcdef";
const DAY = 24 * 3600 * 1000;

class Sender implements WhatsAppSender {
  readonly kind = "fake";
  sent: string[] = [];
  async sendCode(to: string, _code: string, _language: Language): Promise<void> {
    this.sent.push(to);
  }
}

class Accounts implements AccountService {
  uids = new Map<string, string>();
  async signInWithPhone(phone: string): Promise<{ uid: string; suspended: boolean }> {
    if (!this.uids.has(phone)) this.uids.set(phone, `uid-${this.uids.size + 1}`);
    return { uid: this.uids.get(phone) as string, suspended: false };
  }
  async createToken(uid: string): Promise<string> {
    return `token-for-${uid}`;
  }
}

async function reasonOf(p: Promise<unknown>): Promise<string> {
  try {
    await p;
  } catch (error) {
    if (error instanceof OtpError) return error.reason;
    throw error;
  }
  return "ok";
}

describe("App Review: two demo phones", () => {
  let now: number;
  let review: ReviewAccess | null;
  let sender: Sender;
  let audited: string[];
  let reported: unknown[];
  let deps: OtpDeps;

  beforeEach(() => {
    now = 1_800_000_000_000;
    const first = reviewAccessFor(KEY, PHONE_1, CODE_1, now + 7 * DAY);
    const second = reviewAccessFor(KEY, PHONE_2, CODE_2, now + 7 * DAY);
    review = { ...first, extra: [{ phoneKey: second.phoneKey, codeHash: second.codeHash }] };
    sender = new Sender();
    audited = [];
    reported = [];
    deps = {
      store: new MemoryOtpStore(),
      sender,
      accounts: new Accounts(),
      hmacKey: KEY,
      now: () => now,
      newCode: () => "111222",
      review: async () => review,
      onReviewSignIn: async (uid) => void audited.push(uid),
      reportError: (e) => void reported.push(e),
    };
  });

  const ask = (phone: string) => requestCode(deps, { phone, deviceId: DEVICE, ip: "10.0.0.1", language: "en" });
  const check = (phone: string, code: string) => verifyCode(deps, { phone, code, deviceId: DEVICE, language: "en" });

  it("each demo phone signs in with its own code only; nothing is sent; both are audited", async () => {
    await ask(PHONE_1);
    assert.equal((await check(PHONE_1, CODE_1)).uid, "uid-1");
    now += 61_000;
    await ask(PHONE_2);
    assert.equal(await reasonOf(check(PHONE_2, CODE_1)), "wrong-code", "the first phone's code does not open the second");
    assert.equal((await check(PHONE_2, CODE_2)).uid, "uid-2");
    assert.equal(sender.sent.length, 0);
    assert.deepEqual(audited, ["uid-1", "uid-2"]);
  });

  it("a normal parent is not audited as a demo sign-in and gets a WhatsApp code", async () => {
    await ask("+201212345678");
    assert.deepEqual(sender.sent, ["+201212345678"]);
    assert.equal(await reasonOf(check("+201212345678", CODE_1)), "wrong-code");
    assert.equal((await check("+201212345678", "111222")).uid, "uid-1");
    assert.deepEqual(audited, []);
  });

  it("only one extra phone counts, and a malformed extra entry is ignored", () => {
    const r = review as ReviewAccess;
    const third = reviewAccessFor(KEY, "+201512345678", "905172", now + 7 * DAY);
    const many: ReviewAccess = { ...r, extra: [...(r.extra ?? []), { phoneKey: third.phoneKey, codeHash: third.codeHash }] };
    assert.ok(activeReview(many, phoneKey(KEY, PHONE_2), now));
    assert.equal(activeReview(many, third.phoneKey, now), null);
    const bad: ReviewAccess = { ...r, extra: [{ phoneKey: "p_short", codeHash: "x" }] };
    assert.equal(activeReview(bad, phoneKey(KEY, PHONE_2), now), null);
    assert.ok(activeReview(bad, phoneKey(KEY, PHONE_1), now));
  });

  it("off, expired or too long a window closes both phones", () => {
    const r = review as ReviewAccess;
    for (const closed of [{ ...r, enabled: false }, { ...r, expiresAtMs: now - 1 }, { ...r, expiresAtMs: now + (REVIEW_ACCESS_MAX_DAYS + 1) * DAY }, null]) {
      assert.equal(isReviewPhone(closed, KEY, PHONE_1, now), false);
      assert.equal(isReviewPhone(closed, KEY, PHONE_2, now), false);
    }
    assert.equal(isReviewPhone(r, KEY, PHONE_2, now), true);
  });

  it("a failing audit write never blocks the reviewer; it is reported", async () => {
    deps.onReviewSignIn = async () => {
      throw new Error("audit down");
    };
    await ask(PHONE_1);
    assert.equal((await check(PHONE_1, CODE_1)).uid, "uid-1");
    assert.equal(reported.length, 1);
  });
});

describe("App Review: the demo parents' exemption ends by itself", () => {
  const now = 1_800_000_000_000;

  it("active only for a future time at most 30 days ahead", () => {
    assert.equal(reviewDemoActive(now + DAY, now), true);
    assert.equal(reviewDemoActive(now + REVIEW_ACCESS_MAX_DAYS * DAY, now), true);
    assert.equal(reviewDemoActive(now, now), false);
    assert.equal(reviewDemoActive(now - 1, now), false);
    assert.equal(reviewDemoActive(now + (REVIEW_ACCESS_MAX_DAYS + 1) * DAY, now), false, "a far-future value is off, not forever");
    for (const odd of [true, "1900000000000", null, undefined, Number.NaN, Number.POSITIVE_INFINITY, {}]) assert.equal(reviewDemoActive(odd, now), false);
    assert.equal(REVIEW_DEMO_FIELD, "reviewDemoUntilMs");
  });

  it("the window follows the review access and is capped", () => {
    assert.equal(demoWindowMs(now + 5 * DAY, now), now + 5 * DAY);
    assert.equal(demoWindowMs(now + 90 * DAY, now), now + REVIEW_ACCESS_MAX_DAYS * DAY);
    assert.equal(demoWindowMs(now - 1, now), null);
    assert.equal(demoWindowMs(null, now), null);
  });
});

describe("App Review: demo data plan (fake data only)", () => {
  const plan = demoPlan({ driverUid: "uA", parentUid: "uB", nowMs: 1_800_000_000_000, untilMs: 1_800_000_000_000 + 7 * 24 * 3600 * 1000, today: "2027-01-17" });

  it("two verified parents, one child each, one car, one hidden school and one carpool", () => {
    assert.deepEqual(plan.users.map((u) => u.uid), ["uA", "uB"]);
    for (const u of plan.users) {
      assert.equal(u.fields.status, "verified");
      assert.equal(u.fields[REVIEW_DEMO_FIELD], 1_800_000_000_000 + 7 * 24 * 3600 * 1000);
      assert.equal(u.fields.emailVerified, true);
      assert.ok(String(u.fields.email).endsWith("@example.com"), "a reserved address: no mail reaches a real person");
      assert.equal(u.fields.newDeviceCheck, null);
    }
    assert.equal(plan.children.length, 2);
    assert.deepEqual(plan.children.map((c) => c.fields.ownerUid), ["uA", "uB"]);
    assert.equal(plan.vehicles.length, 1);
    assert.equal(plan.vehicles[0].uid, "uA");
    assert.equal(plan.school.fields.searchHidden, true);
    assert.equal(plan.school.fields.source, "review-demo");
    assert.equal(plan.carpool.id, DEMO_IDS.carpool);
    assert.equal(plan.carpool.record.memberCount, 2);
    assert.deepEqual(plan.members.map((m) => [m.uid, m.role]), [["uA", "admin"], ["uB", "member"]]);
  });

  it("the driver drives every school day, so there is a run on any review day", () => {
    assert.deepEqual(plan.members[0].drivingDays, ["sun", "mon", "tue", "wed", "thu"]);
    assert.deepEqual(plan.carpool.record.days, ["sun", "mon", "tue", "wed", "thu"]);
  });

  it("every name says it is a demo and no real-looking personal data is used", () => {
    const text = JSON.stringify(plan);
    assert.ok(plan.carpool.record.schoolNameEn.includes("Demo"));
    assert.ok(!/\+20\d{10}/.test(text), "no phone number in the plan");
    assert.ok(!/\b\d{14}\b/.test(text), "no national ID in the plan");
  });

  it("every document the removal deletes is one the seed writes", () => {
    const seeded = new Set(plan.paths);
    for (const p of plan.removePaths) assert.ok(seeded.has(p), p);
    assert.ok(plan.removePaths.includes(`carpools/${DEMO_IDS.carpool}`));
    assert.ok(!plan.removePaths.some((p) => p.startsWith("users/")), "accounts are closed through account deletion, not by path");
  });
});

// ---------------------------------------------------------------------------
// Validator review (docs/reviews/apple-review.md, B1 and B2): the demo
// accounts are no backdoor.
// ---------------------------------------------------------------------------
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { isReviewDemoAccount, REVIEW_DEMO_MARK, REVIEW_DEMO_MAX_UIDS, reviewDemoState } from "../src/auth/review_access";
import { reviewWindowOpen } from "../src/auth/otp_flow";

describe("App Review: the exemption is bound to the two listed accounts and the open window", () => {
  const now = 1_800_000_000_000;
  const open: ReviewAccess = { ...reviewAccessFor(KEY, PHONE_1, CODE_1, now + 7 * DAY), demoUids: ["uA", "uB"] };
  const demoUser = { [REVIEW_DEMO_FIELD]: now + 7 * DAY, [REVIEW_DEMO_MARK]: true, status: "verified" };

  it("a real parent is never a demo account, whatever the review access says", () => {
    assert.equal(reviewDemoState({ status: "verified" }, "uReal", open, now), "none");
    assert.equal(reviewDemoState(undefined, "uReal", open, now), "none");
    // Listed by mistake but not marked: still nothing.
    assert.equal(reviewDemoState({ status: "verified" }, "uA", open, now), "none");
  });

  it("open only for a listed, marked account with a live date while the access is on", () => {
    assert.equal(reviewDemoState(demoUser, "uA", open, now), "open");
    assert.equal(reviewDemoState(demoUser, "uB", open, now), "open");
  });

  it("the exemption date on an account that is not listed does nothing (closed, not open)", () => {
    assert.equal(reviewDemoState(demoUser, "uOther", open, now), "closed");
    assert.equal(reviewDemoState({ [REVIEW_DEMO_FIELD]: now + DAY }, "uOther", open, now), "closed");
    assert.equal(reviewDemoState(demoUser, "uA", { ...open, demoUids: [] }, now), "closed");
    const { demoUids: _none, ...unlisted } = open;
    assert.equal(reviewDemoState(demoUser, "uA", unlisted, now), "closed");
  });

  it("ends at once when the access is switched off, expires or is missing", () => {
    assert.equal(reviewDemoState(demoUser, "uA", { ...open, enabled: false }, now), "closed");
    assert.equal(reviewDemoState(demoUser, "uA", { ...open, expiresAtMs: now - 1 }, now), "closed");
    assert.equal(reviewDemoState(demoUser, "uA", { ...open, expiresAtMs: now + (REVIEW_ACCESS_MAX_DAYS + 1) * DAY }, now), "closed");
    assert.equal(reviewDemoState(demoUser, "uA", null, now), "closed");
    // The account's own date passed while the access is still on.
    assert.equal(reviewDemoState({ ...demoUser, [REVIEW_DEMO_FIELD]: now - 1 }, "uA", open, now), "closed");
    // After `remove` the date is gone and the mark stays: closed for good.
    assert.equal(reviewDemoState({ [REVIEW_DEMO_MARK]: true, status: "unverified" }, "uA", open, now), "closed");
  });

  it("at most two accounts are ever listed", () => {
    assert.equal(REVIEW_DEMO_MAX_UIDS, 2);
    assert.equal(reviewDemoState(demoUser, "uC", { ...open, demoUids: ["uA", "uB", "uC"] }, now), "closed");
  });

  it("the mark is permanent: an account stays a demo account without the date", () => {
    assert.equal(isReviewDemoAccount({ [REVIEW_DEMO_MARK]: true }), true);
    assert.equal(isReviewDemoAccount({ [REVIEW_DEMO_FIELD]: 1 }), true);
    assert.equal(isReviewDemoAccount({ [REVIEW_DEMO_MARK]: "true" }), false);
    assert.equal(isReviewDemoAccount({}), false);
    assert.equal(isReviewDemoAccount(null), false);
  });

  it("a malformed access document is closed", () => {
    for (const bad of [{ ...open, phoneKey: "p_short" }, { ...open, codeHash: "zz" }, { ...open, expiresAtMs: Number.NaN }, { ...open, expiresAtMs: "soon" as unknown as number }]) {
      assert.equal(reviewWindowOpen(bad, now), false);
      assert.equal(reviewDemoState(demoUser, "uA", bad, now), "closed");
    }
  });

  it("the seed plan marks both demo parents", () => {
    const plan = demoPlan({ driverUid: "uA", parentUid: "uB", nowMs: now, untilMs: now + 7 * DAY, today: "2027-01-17" });
    for (const u of plan.users) assert.equal(u.fields[REVIEW_DEMO_MARK], true);
  });
});

describe("App Review: demo parents are confined by the server (wiring)", () => {
  // Compiled tests run from functions/lib/test: the sources are two folders up.
  const src = (file: string) => readFileSync(join(__dirname, "..", "..", "src", file), "utf8");
  const wrapperOf = (text: string, name: string): string => {
    const m = new RegExp(`export const ${name} = (\\w+)\\(`).exec(text);
    assert.ok(m, `${name} not found`);
    return m[1];
  };

  it("callables that reach real parents or leave the demo school refuse a demo parent", () => {
    const expected: Array<[string, string[], string]> = [
      ["maps/callables.ts", ["setDrivingSchools"], "realParentCall"],
      ["carpools/callables.ts", ["requestToJoinCarpool", "openCarpoolInvite", "saveCarpoolWanted"], "realParentCall"],
      ["trust/callables.ts", ["requestGuardianLink", "answerGuardianRequest", "requestPhoneChange", "confirmPhoneChange"], "realParentCall"],
      ["verification/callables.ts", ["submitVerification"], "realParentCall"],
      ["schools/callables.ts", ["addOtherSchool"], "realParentSessionCall"],
    ];
    for (const [file, names, wrapper] of expected) {
      const text = src(file);
      for (const name of names) assert.equal(wrapperOf(text, name), wrapper, `${file}: ${name}`);
    }
  });

  it("creating and searching carpools is school-only for a demo parent", () => {
    const text = src("carpools/callables.ts");
    for (const name of ["createCarpool", "searchCarpools"]) {
      const start = text.indexOf(`export const ${name} = `);
      const body = text.slice(start, text.indexOf("\n);", start));
      assert.ok(body.includes("schoolKindOnlyForReviewDemo(r)"), name);
    }
  });

  it("every wallet callable refuses a demo parent; the gate runs for every parent callable", () => {
    const gate = src("features/gate.ts");
    assert.ok(/REAL_PARENTS_ONLY[^\n]*\["wallet"\]/.test(gate));
    assert.equal((gate.match(/if \(REAL_PARENTS_ONLY\.has\(key\)\) refuseReviewDemo\(request\);/g) ?? []).length, 2);
    const wallet = src("wallet/callables.ts");
    for (const name of ["getWallet", "openWallet", "lookupParentId", "walletContacts", "sendMoney", "addMoney", "withdrawMoney", "listWalletHistory", "getTransfer"]) {
      assert.equal(wrapperOf(wallet, name), "featureGatedCall", name);
    }
    assert.equal(wrapperOf(wallet, "reportTransfer"), "featureSessionCall");
  });

  it("outside the window the gate refuses a demo parent everything but deleting the account", () => {
    const gate = src("privacy/device_gate.ts");
    assert.ok(gate.includes('if (demo === "closed") throw new HttpsError("permission-denied", "demo-closed"'));
    assert.equal(wrapperOf(src("privacy/callables.ts"), "deleteMyAccount"), "gatedCallAlsoClosedDemo");
    // No other callable uses the exception.
    for (const file of ["carpools/callables.ts", "maps/callables.ts", "trips/callables.ts", "chat/callables.ts", "trust/callables.ts", "schedule/callables.ts", "settle_up/callables.ts", "wallet/callables.ts"]) {
      assert.ok(!src(file).includes("gatedCallAlsoClosedDemo"), file);
    }
  });

  it("the stores take the exemption from reviewDemoState, never from the date alone", () => {
    for (const file of ["privacy/firestore_store.ts", "trips/store.ts"]) {
      const text = src(file);
      assert.ok(text.includes('readReviewDemoState(this.db, uid,'), file);
      assert.ok(!text.includes("reviewDemoActive("), file);
    }
  });
});

describe("App Review: real parents never pick the demo school", () => {
  it("a driving-schools request naming the demo school is recognised", () => {
    // Read from the source: importing maps/callables would start the Admin SDK.
    const text = readFileSync(join(__dirname, "..", "..", "src", "maps", "callables.ts"), "utf8");
    assert.ok(text.includes('if (namesReviewDemoSchool(request.data)) throw new HttpsError("invalid-argument", "invalid-school"'));
    assert.ok(text.includes("ids.includes(DEMO_IDS.school)"));
    assert.equal(DEMO_IDS.school, "review-demo-school");
  });
});
