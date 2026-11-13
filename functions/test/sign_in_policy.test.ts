// Sign-in policy: WhatsApp code (custom token) only. Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { emailAllowed, emailConfirmationIsNew, signInMethodAllowed } from "../src/auth/sign_in_policy";

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
