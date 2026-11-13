// National ID checks and keyed hash (F2). Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { nationalIdHash, normalizeDigits, parseNationalId } from "../src/verification/national_id";

const TODAY = "2026-11-13";
// Fake numbers: valid shape only.
const VALID = "29001150123456"; // born 1990-01-15, Cairo

describe("parseNationalId", () => {
  it("accepts a valid number, with spaces or Arabic digits", () => {
    assert.equal(parseNationalId(VALID, TODAY), VALID);
    assert.equal(parseNationalId("2 900115 01 23456", TODAY), VALID);
    assert.equal(parseNationalId("٢٩٠٠١١٥٠١٢٣٤٥٦", TODAY), VALID);
  });

  it("refuses wrong length, century, date or governorate", () => {
    assert.equal(parseNationalId("2900115012345", TODAY), null);
    assert.equal(parseNationalId("19001150123456", TODAY), null);
    assert.equal(parseNationalId("29002300123456", TODAY), null); // 30 February
    assert.equal(parseNationalId("29013150123456", TODAY), null); // month 13
    assert.equal(parseNationalId("29001159923456", TODAY), null); // governorate 99
    assert.equal(parseNationalId(12345678901234, TODAY), null);
  });

  it("accepts born abroad (88) and the 2000s century", () => {
    assert.equal(parseNationalId("29001158812345", TODAY), "29001158812345");
    assert.equal(parseNationalId("30001150112345", TODAY), "30001150112345");
  });

  it("refuses a parent younger than 18", () => {
    assert.equal(parseNationalId("30811140112345", TODAY), null); // 2008-11-14: 17
    assert.equal(parseNationalId("30811130112345", TODAY), "30811130112345"); // 18 today
  });

  it("normalizes Persian digits too", () => {
    assert.equal(normalizeDigits("۱۲۳-45"), "12345");
  });
});

describe("nationalIdHash", () => {
  it("is keyed: same number and key give the same hash, another key does not", () => {
    const a = nationalIdHash("key-1", VALID);
    assert.equal(a, nationalIdHash("key-1", VALID));
    assert.notEqual(a, nationalIdHash("key-2", VALID));
    assert.match(a, /^[0-9a-f]{64}$/);
    assert.ok(!a.includes(VALID));
  });
});
