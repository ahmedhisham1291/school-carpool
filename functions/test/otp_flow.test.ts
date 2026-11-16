// Sign-in codes (F1): hashing, expiry, limits and lockout. Run: npm test.
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import {
  activeReview,
  DEFAULT_OTP_LIMITS,
  OtpError,
  phoneKey,
  requestCode,
  reviewAccessFor,
  verifyCode,
  type AccountService,
  type OtpDeps,
  type ReviewAccess,
} from "../src/auth/otp_flow";
import { weakCode } from "../src/auth/review_access";
import type { Language, WhatsAppSender } from "../src/whatsapp/sender";
import { MemoryOtpStore } from "./helpers/memory_otp_store";

const PHONE = "01012345678";
const E164 = "+201012345678";
const DEVICE = "0123456789abcdef0123456789abcdef";
const KEY = "test-hmac-key";

class RecordingSender implements WhatsAppSender {
  readonly kind = "fake";
  readonly sent: Array<{ to: string; code: string; language: Language }> = [];
  fail = false;
  async sendCode(to: string, code: string, language: Language): Promise<void> {
    if (this.fail) throw new Error("down");
    this.sent.push({ to, code, language });
  }
}

class FakeAccounts implements AccountService {
  readonly signIns: string[] = [];
  suspended = false;
  async signInWithPhone(phone: string): Promise<{ uid: string; suspended: boolean }> {
    this.signIns.push(phone);
    return { uid: "uid-1", suspended: this.suspended };
  }
  async createToken(uid: string): Promise<string> {
    return `token-for-${uid}`;
  }
}

async function expectReason(promise: Promise<unknown>, reason: string): Promise<OtpError> {
  try {
    await promise;
  } catch (error) {
    assert.ok(error instanceof OtpError, String(error));
    assert.equal(error.reason, reason);
    return error;
  }
  assert.fail(`expected ${reason}`);
}

describe("sign-in codes", () => {
  let store: MemoryOtpStore;
  let sender: RecordingSender;
  let accounts: FakeAccounts;
  let now: number;
  let codes: string[];
  let deps: OtpDeps;

  beforeEach(() => {
    store = new MemoryOtpStore();
    sender = new RecordingSender();
    accounts = new FakeAccounts();
    now = 1_800_000_000_000;
    codes = ["123456", "234567", "345678", "456789", "567890", "678901", "789012", "890123"];
    deps = {
      store,
      sender,
      accounts,
      hmacKey: KEY,
      now: () => now,
      newCode: () => codes.shift() ?? "999999",
    };
  });

  const ask = (overrides: Partial<{ phone: unknown; deviceId: unknown; ip: string }> = {}) =>
    requestCode(deps, { phone: PHONE, deviceId: DEVICE, ip: "10.0.0.1", language: "ar", ...overrides });
  const check = (code: string, deviceId: string = DEVICE) => verifyCode(deps, { phone: PHONE, code, deviceId, language: "ar" });

  it("sends a 6-digit code by WhatsApp and stores only its hash", async () => {
    deps.newCode = undefined;
    const result = await ask();
    assert.deepEqual(result, { expiresInSeconds: 300, resendAfterSeconds: 60 });
    assert.equal(sender.sent.length, 1);
    const { to, code } = sender.sent[0];
    assert.equal(to, E164);
    assert.match(code, /^\d{6}$/);
    const stored = JSON.stringify([...store.codes.entries(), ...store.limits.entries()]);
    assert.ok(!stored.includes(code), "plain code stored");
    assert.ok(!stored.includes("1012345678"), "plain phone stored");
    assert.ok(!stored.includes(DEVICE), "plain device ID stored");
    assert.ok(!stored.includes("10.0.0.1"), "plain IP stored");
    assert.equal(store.codes.get(phoneKey(KEY, E164))?.expiresAtMs, now + 300_000);
  });

  it("accepts the right code once and returns a custom token", async () => {
    await ask();
    assert.deepEqual(await check("123456"), { uid: "uid-1", token: "token-for-uid-1" });
    assert.deepEqual(accounts.signIns, [E164]);
    await expectReason(check("123456"), "expired");
  });

  it("R5: prod closed to new real parents - a new number gets launch-closed after a right code, nothing is created", async () => {
    const existing = new Set<string>();
    let open = false;
    deps.launch = { open: async () => open, hasAccount: async (p) => existing.has(p) };
    await ask();
    await expectReason(check("123456"), "launch-closed");
    assert.deepEqual(accounts.signIns, [], "no account created");
    // An existing account (staff, testers) keeps signing in.
    existing.add(E164);
    now += 61_000;
    await ask();
    assert.equal((await check("234567")).uid, "uid-1");
    // Once the licences are granted, new numbers come in.
    existing.clear();
    open = true;
    now += 61_000;
    await ask();
    assert.equal((await check("345678")).uid, "uid-1");
  });

  it("refuses a wrong code and says how many tries are left", async () => {
    await ask();
    const error = await expectReason(check("000000"), "wrong-code");
    assert.equal(error.details.attemptsLeft, DEFAULT_OTP_LIMITS.maxAttemptsPerCode - 1);
    assert.equal(accounts.signIns.length, 0);
  });

  it("refuses an expired code", async () => {
    await ask();
    now += 300_000;
    await expectReason(check("123456"), "expired");
    assert.equal(accounts.signIns.length, 0);
  });

  it("refuses when no code was requested", async () => {
    await expectReason(check("123456"), "expired");
  });

  it("a new code replaces the previous one", async () => {
    await ask();
    now += 61_000;
    await ask();
    await expectReason(check("123456"), "wrong-code");
    assert.equal((await check("234567")).token, "token-for-uid-1");
  });

  it("ends a code after too many wrong tries", async () => {
    await ask();
    for (let i = 1; i < DEFAULT_OTP_LIMITS.maxAttemptsPerCode; i++) await expectReason(check("000000"), "wrong-code");
    await expectReason(check("000000"), "too-many-attempts");
    await expectReason(check("123456"), "expired");
  });

  it("locks the number after repeated failures, for codes and checks", async () => {
    let failures = 0;
    let locked = false;
    while (!locked) {
      now += 61_000;
      await ask();
      for (let i = 0; i < 2 && !locked; i++) {
        try {
          await check("000000");
        } catch (error) {
          assert.ok(error instanceof OtpError);
          failures++;
          locked = error.reason === "locked";
        }
      }
    }
    assert.equal(failures, DEFAULT_OTP_LIMITS.maxFailuresBeforeLock);
    now += 61_000;
    await expectReason(ask(), "locked");
    await expectReason(check("123456"), "locked");
    now += DEFAULT_OTP_LIMITS.lockSeconds * 1000;
    await ask();
    assert.ok((await check(sender.sent[sender.sent.length - 1].code)).token);
  });

  it("a lock on one device does not lock the number on the parent's phone", async () => {
    const STRANGER = "eeeeeeeeeeeeeeee";
    // The stranger fails 10 times from their device (2 codes, 5 tries each).
    for (let round = 0; round < 2; round++) {
      now += 61_000;
      await ask({ deviceId: STRANGER });
      for (let i = 0; i < DEFAULT_OTP_LIMITS.maxAttemptsPerCode; i++) {
        await check("000000", STRANGER).catch(() => undefined);
      }
    }
    now += 61_000;
    await expectReason(ask({ deviceId: STRANGER }), "locked");
    // The parent asks for a code on their own phone and signs in.
    await ask();
    assert.ok((await check(sender.sent[sender.sent.length - 1].code)).token);
  });

  it("waits a minute between two codes for the same number", async () => {
    await ask();
    now += 30_000;
    const error = await expectReason(ask(), "too-soon");
    assert.equal(error.details.retryAfterSeconds, 30);
  });

  it("caps codes per number per hour", async () => {
    for (let i = 0; i < DEFAULT_OTP_LIMITS.maxSendsPerPhone; i++) {
      await ask();
      now += 61_000;
    }
    await expectReason(ask(), "rate-limited");
    now += 3600_000;
    await ask();
  });

  it("caps codes per device across numbers", async () => {
    for (let i = 0; i < DEFAULT_OTP_LIMITS.maxSendsPerDevice; i++) {
      await ask({ phone: `010000000${String(i).padStart(2, "0")}` });
    }
    await expectReason(ask({ phone: "01199999999" }), "rate-limited");
    await ask({ phone: "01199999999", deviceId: "ffffffffffffffff" });
  });

  it("caps codes per IP across numbers and devices", async () => {
    for (let i = 0; i < DEFAULT_OTP_LIMITS.maxSendsPerIp; i++) {
      await ask({ phone: `0100000${String(i).padStart(4, "0")}`, deviceId: `${String(i).padStart(4, "0")}aaaaaaaaaaaaaaaa` });
    }
    await expectReason(ask({ phone: "01199999999", deviceId: "bbbbbbbbbbbbbbbb" }), "rate-limited");
    await ask({ phone: "01199999999", deviceId: "bbbbbbbbbbbbbbbb", ip: "10.0.0.2" });
  });

  it("refuses bad input before touching the store", async () => {
    await expectReason(ask({ phone: "12345" }), "invalid-phone");
    await expectReason(ask({ deviceId: "not-hex!" }), "invalid-request");
    await expectReason(verifyCode(deps, { phone: PHONE, code: "12ab56", deviceId: DEVICE, language: "ar" }), "invalid-request");
    await expectReason(verifyCode(deps, { phone: PHONE, code: "123456", deviceId: "nope", language: "ar" }), "invalid-request");
    assert.equal(store.limits.size, 0);
  });

  it("reports a WhatsApp failure as send-failed", async () => {
    sender.fail = true;
    const reported: unknown[] = [];
    deps.reportError = (error) => reported.push(error);
    await expectReason(ask(), "send-failed");
    assert.equal(reported.length, 1);
  });

  it("closes the number for the day after too many wrong codes across devices", async () => {
    let failures = 0;
    let device = 0;
    while (failures < DEFAULT_OTP_LIMITS.maxFailuresPerPhonePerDay) {
      now += 3600_000; // next hour: fresh send window and device lock
      const id = `${String(device++).padStart(4, "0")}cccccccccccccccc`;
      await ask({ deviceId: id });
      for (let i = 0; i < DEFAULT_OTP_LIMITS.maxAttemptsPerCode && failures < DEFAULT_OTP_LIMITS.maxFailuresPerPhonePerDay; i++) {
        await check("000000", id).catch(() => undefined);
        failures++;
      }
    }
    now += 61_000;
    await expectReason(ask({ deviceId: "dddddddddddddddd" }), "locked");
    await expectReason(check("123456", "dddddddddddddddd"), "locked");
    now += 24 * 3600_000;
    await ask({ deviceId: "dddddddddddddddd" });
  });

  it("a device where the number signed in before is not closed by strangers' wrong codes (review 2, N1)", async () => {
    // The parent signs in once on their own phone: it becomes known.
    await ask();
    await check("123456");
    assert.equal(store.known.size, 1);
    assert.ok(!JSON.stringify([...store.known.keys()]).includes(DEVICE));
    // A stranger rotates device IDs until the number is closed for the day.
    let failures = 0;
    let device = 0;
    while (failures < DEFAULT_OTP_LIMITS.maxFailuresPerPhonePerDay) {
      now += 3600_000;
      const id = `${String(device++).padStart(4, "0")}eeeeeeeeeeeeeeee`;
      await ask({ deviceId: id });
      for (let i = 0; i < DEFAULT_OTP_LIMITS.maxAttemptsPerCode && failures < DEFAULT_OTP_LIMITS.maxFailuresPerPhonePerDay; i++) {
        await check("000000", id).catch(() => undefined);
        failures++;
      }
    }
    now += 61_000;
    await expectReason(ask({ deviceId: "ffffffffffffffff" }), "locked");
    // The parent's own phone still gets a code and signs in.
    codes = ["135790"];
    await ask();
    assert.deepEqual(await check("135790"), { uid: "uid-1", token: "token-for-uid-1" });
    // Known only for knownDeviceDays.
    now += (DEFAULT_OTP_LIMITS.knownDeviceDays + 1) * 24 * 3600_000;
    assert.ok([...store.known.values()].every((until) => until < now));
  });

  it("strangers spending the number's hourly codes do not keep the parent out of their own phone (security review)", async () => {
    // The parent's phone is known after one sign-in.
    await ask();
    await check("123456");
    now += 3600_000;
    // Strangers use up the number's codes for this hour from other devices.
    for (let i = 0; i < DEFAULT_OTP_LIMITS.maxSendsPerPhone; i++) {
      await ask({ deviceId: `${String(i).padStart(4, "0")}aaaaaaaaaaaaaaaa`, ip: `10.0.0.${i}` });
      now += 61_000;
    }
    await expectReason(ask({ deviceId: "bbbbbbbbbbbbbbbb", ip: "10.0.1.1" }), "rate-limited");
    // The parent's own phone still gets a code at once (no cooldown from the strangers) and signs in.
    now += 1_000;
    codes = ["246802"];
    await ask();
    assert.deepEqual(await check("246802"), { uid: "uid-1", token: "token-for-uid-1" });
  });

  it("a known device keeps its own cooldown and hourly cap", async () => {
    await ask();
    await check("123456");
    now += 3600_000;
    await ask();
    now += 30_000;
    await expectReason(ask(), "too-soon");
    now += 31_000;
    for (let i = 1; i < DEFAULT_OTP_LIMITS.maxSendsPerPhone; i++) {
      await ask();
      now += 61_000;
    }
    await expectReason(ask(), "rate-limited");
  });

  it("stores no plain value in the lock key either", async () => {
    await ask();
    await expectReason(check("000000"), "wrong-code");
    const stored = JSON.stringify([...store.limits.keys()]);
    assert.ok(!stored.includes("1012345678") && !stored.includes(DEVICE));
  });

  it("refuses a suspended account after a right code", async () => {
    accounts.suspended = true;
    await ask();
    await expectReason(check("123456"), "suspended");
  });
});

describe("App Review sign-in (Prompt 13)", () => {
  const REVIEW_CODE = "482913";
  let store: MemoryOtpStore;
  let sender: RecordingSender;
  let accounts: FakeAccounts;
  let now: number;
  let review: ReviewAccess | null;
  let deps: OtpDeps;

  beforeEach(() => {
    store = new MemoryOtpStore();
    sender = new RecordingSender();
    accounts = new FakeAccounts();
    now = 1_800_000_000_000;
    review = reviewAccessFor(KEY, E164, REVIEW_CODE, now + 7 * 24 * 3600 * 1000);
    deps = { store, sender, accounts, hmacKey: KEY, now: () => now, newCode: () => "111222", review: async () => review };
  });

  const ask = (phone: string = PHONE) => requestCode(deps, { phone, deviceId: DEVICE, ip: "10.0.0.1", language: "en" });
  const check = (code: string, phone: string = PHONE) => verifyCode(deps, { phone, code, deviceId: DEVICE, language: "en" });

  it("the allow-listed number signs in with the fixed code; no WhatsApp is sent", async () => {
    await ask();
    assert.equal(sender.sent.length, 0);
    assert.deepEqual(await check(REVIEW_CODE), { uid: "uid-1", token: "token-for-uid-1" });
    const stored = JSON.stringify([...store.codes.entries(), ...store.limits.entries(), review]);
    assert.ok(!stored.includes(REVIEW_CODE), "plain code stored");
    assert.ok(!stored.includes("1012345678"), "plain phone stored");
  });

  it("R5: the App Review demo phone signs in while prod is closed to new parents", async () => {
    deps.launch = { open: async () => false, hasAccount: async () => false };
    await ask();
    assert.equal((await check(REVIEW_CODE)).uid, "uid-1");
  });

  it("the code is single use, and every limit and lock still applies", async () => {
    await ask();
    await check(REVIEW_CODE);
    await expectReason(check(REVIEW_CODE), "expired");
    now += 61_000;
    await ask();
    for (let i = 0; i < DEFAULT_OTP_LIMITS.maxAttemptsPerCode - 1; i++) await expectReason(check("000000"), "wrong-code");
    await expectReason(check("000001"), "too-many-attempts");
  });

  it("any other number gets a normal WhatsApp code; the review code does not work for it", async () => {
    await ask("01098765432");
    assert.equal(sender.sent.length, 1);
    await expectReason(check(REVIEW_CODE, "01098765432"), "wrong-code");
  });

  it("off, expired, too long, malformed or unreadable: a normal WhatsApp code (fails closed)", async () => {
    const cases: Array<ReviewAccess | null> = [
      null,
      { ...(review as ReviewAccess), enabled: false },
      { ...(review as ReviewAccess), expiresAtMs: now - 1 },
      { ...(review as ReviewAccess), expiresAtMs: now + 31 * 24 * 3600 * 1000 },
      { ...(review as ReviewAccess), codeHash: "not-a-hash" },
    ];
    for (const c of cases) {
      store = new MemoryOtpStore();
      deps.store = store;
      review = c;
      sender.sent.length = 0;
      await ask();
      assert.equal(sender.sent.length, 1, JSON.stringify(c));
      await expectReason(check(REVIEW_CODE), "wrong-code");
    }
    deps.review = async () => {
      throw new Error("firestore down");
    };
    store = new MemoryOtpStore();
    deps.store = store;
    sender.sent.length = 0;
    await ask();
    assert.equal(sender.sent.length, 1);
  });

  it("activeReview matches only the hashed phone key", () => {
    const r = review as ReviewAccess;
    assert.equal(activeReview(r, phoneKey(KEY, E164), now), r);
    assert.equal(activeReview(r, phoneKey(KEY, "+201098765432"), now), null);
    assert.equal(activeReview(r, phoneKey("other-key", E164), now), null);
  });

  it("weak review codes are refused by the script", () => {
    for (const c of ["000000", "111111", "123456", "234567", "987654"]) assert.equal(weakCode(c), true, c);
    for (const c of ["482913", "730215"]) assert.equal(weakCode(c), false, c);
  });
});
