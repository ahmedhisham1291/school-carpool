// Sign-in codes (F1): hashing, expiry, limits and lockout. Run: npm test.
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import {
  DEFAULT_OTP_LIMITS,
  OtpError,
  phoneKey,
  requestCode,
  verifyCode,
  type AccountService,
  type OtpDeps,
} from "../src/auth/otp_flow";
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
  const check = (code: string) => verifyCode(deps, { phone: PHONE, code, language: "ar" });

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
    await expectReason(verifyCode(deps, { phone: PHONE, code: "12ab56", language: "ar" }), "invalid-request");
    assert.equal(store.limits.size, 0);
  });

  it("reports a WhatsApp failure as send-failed", async () => {
    sender.fail = true;
    const reported: unknown[] = [];
    deps.reportError = (error) => reported.push(error);
    await expectReason(ask(), "send-failed");
    assert.equal(reported.length, 1);
  });

  it("refuses a suspended account after a right code", async () => {
    accounts.suspended = true;
    await ask();
    await expectReason(check("123456"), "suspended");
  });
});
