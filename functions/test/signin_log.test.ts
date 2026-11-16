import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { NOT_DELETED, IMMEDIATE_TARGETS, EVIDENCE_TARGETS, CONSENT_TARGETS } from "../src/privacy/account_deletion";
import { DELETED_WITH_ACCOUNT, KEPT_AFTER_DELETION, DAY_MS } from "../src/privacy/retention";
import {
  appVersionOf,
  discloseSignInLog,
  newSignInEntry,
  openText,
  parseDisclosure,
  sealText,
  SIGN_IN_LOG_DAYS,
  SIGN_IN_LOG_FIELDS,
  SignInLogError,
  signInPhoneKey,
  type SignInLogEntry,
  type SignInLogStore,
} from "../src/privacy/signin_log";

const KEY = "test-signin-log-key-0123456789";
const NOW = Date.UTC(2026, 10, 16, 9);
const ROOT = join(__dirname, "..", "..", "..");

class MemoryLog implements SignInLogStore {
  lines: SignInLogEntry[] = [];
  audits: Array<Record<string, unknown>> = [];
  failAudit = false;
  async add(e: SignInLogEntry) {
    this.lines.push(e);
  }
  async byUid(uid: string, limit: number) {
    return this.lines.filter((l) => l.uid === uid).slice(0, limit);
  }
  async byPhoneKey(k: string, limit: number) {
    return this.lines.filter((l) => l.phoneKey === k).slice(0, limit);
  }
  async audit(a: Record<string, unknown>) {
    if (this.failAudit) throw new Error("audit down");
    this.audits.push(a);
  }
}

const order = { orderRef: "2026/1234 جنح", authority: "نيابة مصر الجديدة", orderDate: "2026-11-15" };

describe("sign-in log (R2, Law 175/2018 Art. 2)", () => {
  it("a line holds only the listed fields, the number and IP encrypted, and lives 180 days from the sign-in", () => {
    const e = newSignInEntry(KEY, { uid: "u1", phoneE164: "+201001234567", ip: "41.33.1.2", deviceKey: "s_abc", platform: "ios", appVersion: "1.4.0+12", atMs: NOW });
    assert.equal(SIGN_IN_LOG_DAYS, 180);
    assert.equal(e.expiresAtMs, NOW + 180 * DAY_MS);
    assert.equal(e.event, "signIn");
    assert.ok(!JSON.stringify(e).includes("201001234567"), "no number in clear");
    assert.ok(!JSON.stringify(e).includes("41.33.1.2"), "no IP in clear");
    assert.equal(openText(KEY, e.phoneEnc), "+201001234567");
    assert.equal(openText(KEY, e.ipEnc!), "41.33.1.2");
    assert.equal(e.phoneKey, signInPhoneKey(KEY, "+201001234567"));
    // Every stored field (store toDoc) is justified, and nothing else.
    const stored = ["uid", "phoneKey", "phoneEnc", "event", "at", "ipEnc", "deviceKey", "platform", "appVersion", "expiresAt"];
    assert.deepEqual(Object.keys(SIGN_IN_LOG_FIELDS).sort(), [...stored].sort());
    const store = readFileSync(join(ROOT, "functions", "src", "privacy", "signin_log_store.ts"), "utf8");
    const toDoc = store.slice(store.indexOf("function toDoc"), store.indexOf("function millis"));
    for (const f of stored) assert.ok(toDoc.includes(`${f}:`), `store writes ${f}`);
    for (const never of ["name", "email", "nationalId", "message", "text", "location", "lat", "lng", "point", "route"]) {
      assert.ok(!Object.keys(SIGN_IN_LOG_FIELDS).includes(never), `no ${never}`);
    }
  });

  it("unknown IP, bad app versions and changed ciphertexts are handled safely", () => {
    const e = newSignInEntry(KEY, { uid: "u1", phoneE164: "+201001234567", ip: "unknown", deviceKey: null, platform: "web", appVersion: "<script>", atMs: NOW });
    assert.equal(e.ipEnc, null);
    assert.equal(e.appVersion, "unknown");
    assert.equal(appVersionOf("2.0.1+7"), "2.0.1+7");
    const sealed = sealText(KEY, "+201001234567");
    assert.notEqual(sealed, sealText(KEY, "+201001234567"), "a fresh IV each time");
    assert.equal(openText("another-key-0123456789", sealed), null);
    const tampered = sealed.slice(0, -4) + (sealed.endsWith("AAAA") ? "BBBB" : "AAAA");
    assert.equal(openText(KEY, tampered), null);
    assert.equal(openText(KEY, "plain"), null);
  });

  it("disclosure needs an order reference, the authority and the order date; one subject", () => {
    assert.throws(() => parseDisclosure({ uid: "u1" }, NOW), (e: unknown) => e instanceof SignInLogError && e.reason === "order-required");
    assert.throws(() => parseDisclosure({ ...order, authority: "" , uid: "u1" }, NOW), (e: unknown) => e instanceof SignInLogError && e.reason === "order-required");
    assert.throws(() => parseDisclosure({ ...order }, NOW), (e: unknown) => e instanceof SignInLogError && e.reason === "invalid-request");
    assert.throws(() => parseDisclosure({ ...order, uid: "u1", phone: "+201001234567" }, NOW), SignInLogError);
    assert.throws(() => parseDisclosure({ ...order, phone: "01001234567" }, NOW), SignInLogError);
    assert.throws(() => parseDisclosure({ ...order, orderDate: "2030-01-01", uid: "u1" }, NOW), SignInLogError);
    assert.throws(() => parseDisclosure({ ...order, orderRef: "<x>", uid: "u1" }, NOW), SignInLogError);
    assert.deepEqual(parseDisclosure({ ...order, phone: "+201001234567" }, NOW).subject, { phone: "+201001234567" });
  });

  it("answers a judicial order for an account or a number (also after deletion), audit first, expired lines left out", async () => {
    const store = new MemoryLog();
    const deps = { store, secret: KEY, now: () => NOW };
    store.lines.push(
      newSignInEntry(KEY, { uid: "gone", phoneE164: "+201001234567", ip: "41.33.1.2", deviceKey: "s_1", platform: "ios", appVersion: "1.0.0", atMs: NOW - 10 * DAY_MS }),
      newSignInEntry(KEY, { uid: "gone", phoneE164: "+201001234567", ip: "41.33.1.3", deviceKey: "s_1", platform: "ios", appVersion: "1.0.1", atMs: NOW - DAY_MS }),
      newSignInEntry(KEY, { uid: "gone", phoneE164: "+201001234567", ip: "41.33.1.4", deviceKey: "s_1", platform: "ios", appVersion: "0.9.0", atMs: NOW - 181 * DAY_MS }),
      newSignInEntry(KEY, { uid: "other", phoneE164: "+201112223334", ip: "41.33.9.9", deviceKey: "s_2", platform: "android", appVersion: "1.0.0", atMs: NOW }),
    );
    const byPhone = await discloseSignInLog(deps, { uid: "super1", ip: "10.0.0.1" }, { ...order, phone: "+201001234567" });
    assert.equal(byPhone.count, 2, "the 181-day-old line is past its 180 days");
    assert.deepEqual(byPhone.lines.map((l) => l.ip), ["41.33.1.3", "41.33.1.2"], "newest first, decrypted for the court");
    assert.equal(byPhone.lines[0].phone, "+201001234567");
    const audit = store.audits[0];
    assert.equal(audit.orderRef, order.orderRef);
    assert.equal(audit.authority, order.authority);
    assert.equal(audit.count, 2);
    assert.ok(!JSON.stringify(audit).includes("201001234567"), "the audit entry never holds the number");
    const byUid = await discloseSignInLog(deps, { uid: "super1", ip: "10.0.0.1" }, { ...order, uid: "other" });
    assert.equal(byUid.count, 1);
    store.failAudit = true;
    await assert.rejects(discloseSignInLog(deps, { uid: "super1", ip: "10.0.0.1" }, { ...order, uid: "other" }), /audit down/, "no audit, no answer");
  });

  it("survives account deletion: not a deletion target, listed as kept, and the pages say so", () => {
    const targets = [...IMMEDIATE_TARGETS, ...EVIDENCE_TARGETS, ...CONSENT_TARGETS].map((t) => t.collection);
    assert.ok(!targets.includes("signInLog"));
    assert.ok(NOT_DELETED.signInLog.includes("180 days"));
    assert.ok(KEPT_AFTER_DELETION.some((k) => k.what === "signInLog"));
    assert.ok(!DELETED_WITH_ACCOUNT.some((d) => /^devices, sign-in history/.test(d)));
    const rules = readFileSync(join(ROOT, "firestore.rules"), "utf8");
    assert.match(rules, /match \/signInLog\/\{lineId\} \{\s*allow read, write: if false;/);
    const ttl = readFileSync(join(ROOT, "tool", "setup_retention.sh"), "utf8");
    assert.ok(ttl.includes("ttl expiresAt signInLog"));
    const callables = readFileSync(join(ROOT, "functions", "src", "privacy", "signin_log_callables.ts"), "utf8");
    assert.ok(callables.includes("superAdmin: true, recentSignIn: true"), "super admins with a fresh sign-in only");
    const index = readFileSync(join(ROOT, "functions", "src", "index.ts"), "utf8");
    assert.ok(index.includes("adminDiscloseSignInLog"));
    const auth = readFileSync(join(ROOT, "functions", "src", "auth", "callables.ts"), "utf8");
    assert.ok(auth.includes("await logSignIn("), "verifyCode writes a line");
  });
});
