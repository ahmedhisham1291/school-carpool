// Sign-in policy: WhatsApp code (custom token) only. Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import {
  creationAllowed,
  adminLinkAllowed,
  emailAllowed,
  emailConfirmationIsNew,
  isAdminAccount,
  signInAllowed,
  signInMethodAllowed,
} from "../src/auth/sign_in_policy";

describe("signInMethodAllowed", () => {
  it("refuses password, email link, SMS and anonymous sign-in", () => {
    for (const method of ["password", "emailLink", "phone", "anonymous"]) {
      assert.equal(signInMethodAllowed(method), false, method);
    }
  });
  it("allows the custom token from verifyCode", () => {
    assert.equal(signInMethodAllowed("custom"), true);
    assert.equal(signInMethodAllowed(undefined), true);
  });
});

describe("emailAllowed", () => {
  it("never sends password reset or email sign-in links", () => {
    assert.equal(emailAllowed("PASSWORD_RESET"), false);
    assert.equal(emailAllowed("EMAIL_SIGN_IN"), false);
    assert.equal(emailAllowed(undefined), true);
  });
});

describe("emailConfirmationIsNew", () => {
  it("is new when the record has no confirmed email or another one", () => {
    assert.equal(emailConfirmationIsNew({ email: null, emailVerified: false }, "a@example.com"), true);
    assert.equal(emailConfirmationIsNew({ email: "old@example.com", emailVerified: true }, "a@example.com"), true);
  });
  it("is not new on a repeat call, so no second token is issued", () => {
    assert.equal(emailConfirmationIsNew({ email: "a@example.com", emailVerified: true }, "a@example.com"), false);
  });
});

describe("admin sign-in (F14)", () => {
  const admin = { customClaims: { admin: true }, phoneNumber: undefined, disabled: false };
  it("allows a password only for an admin account: admin claim, no phone number, not disabled", () => {
    assert.equal(isAdminAccount(admin), true);
    assert.equal(signInAllowed("password", admin), true);
    assert.equal(signInAllowed("password", { customClaims: { admin: true, superAdmin: true } }), true);
  });
  it("refuses a password for parents, even one who set a password on their own account", () => {
    assert.equal(signInAllowed("password", { phoneNumber: "+201000000001", customClaims: { verified: true } }), false);
    assert.equal(signInAllowed("password", { phoneNumber: "+201000000001", customClaims: { admin: true } }), false);
    assert.equal(signInAllowed("password", { customClaims: { verified: true } }), false);
    assert.equal(signInAllowed("password", { customClaims: null }), false);
    assert.equal(signInAllowed("password", undefined), false);
  });
  it("refuses a disabled admin and keeps email links, SMS and anonymous closed for admins too", () => {
    assert.equal(signInAllowed("password", { ...admin, disabled: true }), false);
    for (const method of ["emailLink", "phone", "anonymous"]) assert.equal(signInAllowed(method, admin), false, method);
  });
  it("still allows the parents' custom token", () => {
    assert.equal(signInAllowed("custom", { phoneNumber: "+201000000001" }), true);
  });
});

describe("creationAllowed (beforeUserCreated)", () => {
  it("refuses every account a client tries to create", () => {
    for (const method of ["password", "emailLink", "phone", "anonymous", "google.com", "apple.com"]) {
      assert.equal(creationAllowed(method), false, method);
    }
  });
  it("allows accounts made on the server with the Admin SDK (no client credential)", () => {
    assert.equal(creationAllowed(undefined), true);
    assert.equal(creationAllowed("custom"), true);
  });
});

describe("adminLinkAllowed", () => {
  const now = 1_000_000;
  const note = { email: "Owner@Example.com", expiresAtMs: now + 60_000 };
  it("lets one admin set-password link through while the note is fresh", () => {
    assert.equal(adminLinkAllowed("PASSWORD_RESET", note, "owner@example.com", now), true);
    assert.equal(adminLinkAllowed("PASSWORD_RESET", note, undefined, now), true);
  });
  it("refuses without a note, after it expires, or with a far-future expiry", () => {
    assert.equal(adminLinkAllowed("PASSWORD_RESET", null, "owner@example.com", now), false);
    assert.equal(adminLinkAllowed("PASSWORD_RESET", { ...note, expiresAtMs: now }, "owner@example.com", now), false);
    assert.equal(adminLinkAllowed("PASSWORD_RESET", { ...note, expiresAtMs: now + 10 * 60_000 }, "owner@example.com", now), false);
    assert.equal(adminLinkAllowed("PASSWORD_RESET", { email: 5, expiresAtMs: now + 1 }, undefined, now), false);
  });
  it("refuses another address and every other email type", () => {
    assert.equal(adminLinkAllowed("PASSWORD_RESET", note, "parent@example.com", now), false);
    assert.equal(adminLinkAllowed("EMAIL_SIGN_IN", note, "owner@example.com", now), false);
    assert.equal(adminLinkAllowed(undefined, note, "owner@example.com", now), false);
  });
});
