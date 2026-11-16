// Consent requests and new user records (F1, F44). Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { newUserRecord, verifiedEmail } from "../src/auth/accounts";
import { CONSENT_VERSIONS, ConsentError, parseConsentRequest } from "../src/auth/consents";

const current = { terms: CONSENT_VERSIONS.terms, privacy: CONSENT_VERSIONS.privacy, conduct: CONSENT_VERSIONS.conduct, transferAbroad: CONSENT_VERSIONS.transferAbroad };

function reason(fn: () => unknown): string {
  try {
    fn();
  } catch (error) {
    assert.ok(error instanceof ConsentError);
    return error.reason;
  }
  return "none";
}

describe("parseConsentRequest", () => {
  it("records terms, privacy and conduct, plus WhatsApp when chosen", () => {
    assert.deepEqual(parseConsentRequest({ documents: current, whatsapp: true }).accepted, ["terms", "privacy", "conduct", "transferAbroad", "whatsapp"]);
    assert.deepEqual(parseConsentRequest({ documents: current, whatsapp: false }).accepted, ["terms", "privacy", "conduct", "transferAbroad"]);
  });

  it("needs every required document", () => {
    assert.equal(reason(() => parseConsentRequest({ documents: { terms: current.terms, privacy: current.privacy }, whatsapp: false })), "missing-consent");
  });

  it("refuses an old document version", () => {
    assert.equal(reason(() => parseConsentRequest({ documents: { ...current, privacy: "2020-01-01" }, whatsapp: false })), "outdated-terms");
    // The transfer-abroad consent is separate and required (Law 151/2020, Arts. 14-15).
    const { transferAbroad: _omitted, ...withoutTransfer } = current;
    assert.equal(reason(() => parseConsentRequest({ documents: withoutTransfer, whatsapp: false })), "missing-consent");
    // An app build from before the legal review sends the old privacy version: it is asked to update.
    assert.equal(reason(() => parseConsentRequest({ documents: { terms: "2026-11-13", privacy: "2026-11-14", conduct: CONSENT_VERSIONS.conduct }, whatsapp: false })), "outdated-terms");
  });

  it("refuses malformed input", () => {
    assert.equal(reason(() => parseConsentRequest(null)), "invalid-request");
    assert.equal(reason(() => parseConsentRequest({ documents: current })), "invalid-request");
    assert.equal(reason(() => parseConsentRequest({ documents: "yes", whatsapp: true })), "invalid-request");
  });
});

describe("newUserRecord", () => {
  it("starts unverified, as a parent, with no email or consents", () => {
    const record = newUserRecord("ABCD2345", "+201012345678", "en");
    assert.equal(record.status, "unverified");
    assert.equal(record.role, "parent");
    assert.equal(record.parentId, "ABCD2345");
    assert.equal(record.emailVerified, false);
    assert.equal(record.termsAcceptedAt, null);
    assert.equal(record.language, "en");
  });
});

describe("verifiedEmail", () => {
  it("copies an email only once Auth marks it verified", () => {
    assert.equal(verifiedEmail({ email: "parent@example.com", emailVerified: true }), "parent@example.com");
    assert.equal(verifiedEmail({ email: "parent@example.com", emailVerified: false }), null);
    assert.equal(verifiedEmail({ email: undefined, emailVerified: true }), null);
  });
});
