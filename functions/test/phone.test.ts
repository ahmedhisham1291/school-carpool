// Egyptian phone numbers and masking. Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { asciiDigits, maskPhone, toEgyptE164 } from "../src/auth/phone";

describe("toEgyptE164", () => {
  const valid: Record<string, string> = {
    "01012345678": "+201012345678",
    "1112345678": "+201112345678",
    "+20 122 123 4567": "+201221234567",
    "00201512345678": "+201512345678",
    "201012345678": "+201012345678",
    "010-1234-5678": "+201012345678",
    "٠١٠١٢٣٤٥٦٧٨": "+201012345678",
    "۰۱۰۱۲۳۴۵۶۷۸": "+201012345678",
  };
  for (const [input, expected] of Object.entries(valid)) {
    it(`accepts ${input}`, () => assert.equal(toEgyptE164(input), expected));
  }

  for (const input of ["", "0101234567", "010123456789", "01312345678", "0221234567", "+966501234567", "abc", "0".repeat(40)]) {
    it(`rejects ${JSON.stringify(input)}`, () => assert.equal(toEgyptE164(input), null));
  }

  it("rejects non-strings", () => {
    assert.equal(toEgyptE164(1012345678), null);
    assert.equal(toEgyptE164(undefined), null);
  });
});

describe("maskPhone", () => {
  it("keeps only the country code and the last two digits", () => {
    const masked = maskPhone("+201012345678");
    assert.equal(masked, "+20********78");
    assert.ok(!/\d{3,}/.test(masked.slice(3)), masked);
  });

  it("asciiDigits converts Arabic-Indic digits", () => {
    assert.equal(asciiDigits("٠١٢٣٤٥٦٧٨٩"), "0123456789");
  });
});
