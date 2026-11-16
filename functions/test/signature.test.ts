// Written consent for sensitive data (R3). Run: npm test.
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import { CONSENT_TEXT_KEYS, CONSENT_TEXTS, consentText } from "../src/auth/consent_texts";
import { CONSENT_VERSIONS } from "../src/auth/consents";
import {
  checkMethod,
  nameHash,
  nameLooksFull,
  nameMatches,
  normaliseName,
  parseSignature,
  RECENT_SIGN_IN_MS,
  SignatureError,
  signatureRecord,
  textHash,
} from "../src/auth/signature";
import { VERIFICATION_CONSENT_VERSIONS } from "../src/verification/submission";
import { consentCopy, consentCopyFile, consentCopyPath } from "../src/privacy/consent_copy";
import { consentViews } from "../src/privacy/requests";

const ROOT = join(__dirname, "..", "..", "..");
const NOW = Date.UTC(2026, 10, 16, 9);

function arb(lang: "ar" | "en"): Record<string, string> {
  return JSON.parse(readFileSync(join(ROOT, "lib", "l10n", `app_${lang}.arb`), "utf8")) as Record<string, string>;
}

describe("signature: names (R3)", () => {
  it("normalises Arabic the way people type it", () => {
    assert.equal(normaliseName("  أحمـــد   إبراهيم  "), "احمد ابراهيم");
    assert.equal(normaliseName("فاطمة"), normaliseName("فاطمه"));
    assert.equal(normaliseName("مُصطفى"), "مصطفي");
    assert.equal(normaliseName("عبد الله"), normaliseName("عبدالله"));
    assert.equal(normaliseName("José  O'Neil"), "jose o neil");
    assert.equal(normaliseName("Abd El Rahman"), normaliseName("Abdel Rahman").replace("abdelrahman", "abdelrahman"));
  });

  it("a full name has two words of letters", () => {
    assert.ok(nameLooksFull("Omar Hassan"));
    assert.ok(nameLooksFull("عمر حسن"));
    assert.ok(!nameLooksFull("Omar"));
    assert.ok(!nameLooksFull("12 34"));
    assert.ok(!nameLooksFull("x".repeat(90) + " y"));
  });

  it("matches the ID name, also with the father's and grandfather's names in between", () => {
    assert.ok(nameMatches("عمر حسن", "عمر", "حسن"));
    assert.ok(nameMatches("عُمر محمد أحمد حسن", "عمر", "حسن"));
    assert.ok(nameMatches("Omar Mohamed Hassan", "omar", "Hassan"));
    assert.ok(nameMatches("عبدالله محمد", "عبد الله", "محمد"));
    assert.ok(!nameMatches("حسن عمر", "عمر", "حسن"), "first name first");
    assert.ok(!nameMatches("عمر علي", "عمر", "حسن"));
    assert.ok(!nameMatches("", "عمر", "حسن"));
  });
});

describe("signature: input, method and record (R3)", () => {
  const raw = { fullName: " Omar   Hassan ", method: "deviceAuth", deviceId: "0123456789abcdef", platform: "android", appVersion: "1.2.0+3", language: "en" };

  it("parses what the app sends, safely", () => {
    const s = parseSignature(raw);
    assert.deepEqual(s, { fullName: "Omar Hassan", method: "deviceAuth", deviceId: "0123456789abcdef", platform: "android", appVersion: "1.2.0+3", language: "en" });
    assert.equal(parseSignature({ ...raw, deviceId: "IMEI-123", appVersion: "<b>", language: "fr", platform: "x" }).deviceId, null);
    assert.equal(parseSignature({ ...raw, appVersion: "<b>" }).appVersion, "unknown");
    assert.equal(parseSignature({ ...raw, language: "fr" }).language, "ar");
    assert.throws(() => parseSignature(null), (e: unknown) => e instanceof SignatureError && e.reason === "signature-required");
    assert.throws(() => parseSignature({ ...raw, method: "checkbox" }), SignatureError);
  });

  it("a phone without a passcode signs with a sign-in less than 10 minutes old", () => {
    assert.doesNotThrow(() => checkMethod("deviceAuth", null, NOW));
    assert.doesNotThrow(() => checkMethod("recentSignIn", (NOW - RECENT_SIGN_IN_MS + 1000) / 1000, NOW));
    assert.throws(() => checkMethod("recentSignIn", (NOW - RECENT_SIGN_IN_MS - 1000) / 1000, NOW), (e: unknown) => e instanceof SignatureError && e.reason === "reauth-required");
    assert.throws(() => checkMethod("recentSignIn", null, NOW), SignatureError);
  });

  it("the kept record holds a keyed name hash, never the name", () => {
    const s = parseSignature(raw);
    const r = signatureRecord("key-0123456789abcdef", "u1", s, "the text", true, "s_abc");
    assert.ok(!JSON.stringify(r).includes("Omar"));
    assert.equal(r.nameHash, nameHash("key-0123456789abcdef", "u1", "omar   HASSAN"), "the hash is of the normalised name");
    assert.notEqual(r.nameHash, nameHash("key-0123456789abcdef", "u2", "Omar Hassan"), "bound to the account");
    assert.equal(r.textHash, textHash("the text"));
    assert.deepEqual([r.method, r.nameMatched, r.deviceKey, r.platform, r.appVersion, r.language], ["deviceAuth", true, "s_abc", "android", "1.2.0+3", "en"]);
  });
});

describe("signature: consent texts match the app (R3)", () => {
  it("every signed consent of the current versions has its text, equal to the ARB files", () => {
    const ar = arb("ar");
    const en = arb("en");
    const current: Record<string, string> = { transferAbroad: CONSENT_VERSIONS.transferAbroad, ...VERIFICATION_CONSENT_VERSIONS };
    for (const [type, keys] of Object.entries(CONSENT_TEXT_KEYS)) {
      const version = current[type];
      assert.ok(version, `${type} has a current version`);
      const texts = CONSENT_TEXTS[type][version];
      assert.ok(texts, `${type} ${version} has a text`);
      assert.equal(texts.ar, keys.map((k) => ar[k]).join("\n\n"), `${type} (ar) equals the ARB text; regenerate and raise the version`);
      assert.equal(texts.en, keys.map((k) => en[k]).join("\n\n"), `${type} (en)`);
      assert.equal(consentText(type, version, "en"), texts.en);
    }
    assert.equal(consentText("transferAbroad", "2026-11-16", "ar"), null, "older unsigned versions have no copy");
  });
});

describe("consent copy for the parent (R3)", () => {
  it("built from the latest signed record: exact text, typed name, method; older unsigned versions have none", () => {
    const sig = signatureRecord("k-0123456789abcdef", "u1", parseSignature({ fullName: "Mona Hassan", method: "deviceAuth", platform: "ios", appVersion: "1.0.0", language: "ar" }), consentText("face", VERIFICATION_CONSENT_VERSIONS.face, "ar")!, true, null);
    const rows = [
      { type: "face", version: "2026-11-16", acceptedAtMs: NOW - 1000, withdrawnAtMs: null, signature: null },
      { type: "face", version: VERIFICATION_CONSENT_VERSIONS.face, acceptedAtMs: NOW, withdrawnAtMs: null, signature: sig },
    ];
    const copy = consentCopy(rows, "face", "Mona Hassan")!;
    assert.equal(copy.text, consentText("face", VERIFICATION_CONSENT_VERSIONS.face, "ar"));
    assert.equal(textHash(copy.text), copy.textHash, "the text shown is the text signed");
    assert.equal(copy.fingerprint, copy.textHash.slice(0, 12));
    assert.equal(copy.signedName, "Mona Hassan");
    const file = consentCopyFile(copy);
    assert.ok(file.includes("Mona Hassan") && file.includes(copy.textHash) && file.includes(copy.text));
    assert.match(consentCopyPath("u1", "face", NOW), /^exports\/u1\/consent-face-\d+\.txt$/, "in the exports folder (1 day)");
    assert.equal(consentCopy([rows[0]], "face", null), null, "given before signed copies");
    assert.equal(consentCopy(rows, "nope", null), null);
    const views = consentViews(rows, { showOnMap: false, analytics: null });
    assert.equal(views.find((v) => v.kind === "face")?.signed, true);
    assert.equal(views.find((v) => v.kind === "terms")?.signed, false);
  });
});
