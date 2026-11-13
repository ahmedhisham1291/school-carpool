// Parent ID (F44). Run: npm test (Node's built-in runner).
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import {
  PARENT_ID_ALPHABET,
  PARENT_ID_LENGTH,
  generateParentId,
  isParentId,
  pickFreeParentId,
} from "../src/auth/parent_id";

/** Random source that returns the given byte sequences in turn. */
function scripted(...sequences: number[][]): (size: number) => Buffer {
  let call = 0;
  return (size) => {
    const bytes = sequences[Math.min(call, sequences.length - 1)];
    call++;
    return Buffer.from(bytes.slice(0, size));
  };
}

describe("parent ID alphabet", () => {
  it("has 32 symbols and none of 0, O, 1 or I", () => {
    assert.equal(PARENT_ID_ALPHABET.length, 32);
    assert.equal(new Set(PARENT_ID_ALPHABET).size, 32);
    for (const banned of ["0", "O", "1", "I"]) {
      assert.ok(!PARENT_ID_ALPHABET.includes(banned), `contains ${banned}`);
    }
  });
});

describe("generateParentId", () => {
  it("makes 8 symbols from the alphabet", () => {
    for (let i = 0; i < 1000; i++) {
      const id = generateParentId();
      assert.equal(id.length, PARENT_ID_LENGTH);
      assert.ok(isParentId(id), id);
      assert.ok(!/[01OI]/.test(id), id);
    }
  });

  it("uses every symbol (no symbol is unreachable)", () => {
    const seen = new Set<string>();
    for (let i = 0; i < 2000; i++) for (const ch of generateParentId()) seen.add(ch);
    assert.equal(seen.size, 32);
  });

  it("maps bytes with a 5-bit mask", () => {
    assert.equal(generateParentId(scripted([0, 1, 2, 3, 31, 32, 255, 224])), "2345Z2Z2");
  });

  it("isParentId rejects confusable or wrong-length IDs", () => {
    for (const bad of ["ABCDEFG", "ABCDEFGHJ", "ABCDEFG0", "ABCDEFGO", "ABCDEFG1", "ABCDEFGI", "abcdefgh", 12345678, null]) {
      assert.ok(!isParentId(bad), String(bad));
    }
    assert.ok(isParentId("ABCD2345"));
  });
});

describe("pickFreeParentId", () => {
  it("creates 10,000 parent IDs with no repeat", async () => {
    const reserved = new Set<string>();
    for (let i = 0; i < 10_000; i++) {
      const id = await pickFreeParentId(async (candidate) => reserved.has(candidate));
      assert.ok(isParentId(id), id);
      assert.ok(!reserved.has(id), `repeat: ${id}`);
      reserved.add(id);
    }
    assert.equal(reserved.size, 10_000);
  });

  it("skips an ID that is already reserved", async () => {
    const random = scripted([0, 0, 0, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0], [1, 1, 1, 1, 1, 1, 1, 1]);
    const id = await pickFreeParentId(async (candidate) => candidate === "22222222", random);
    assert.equal(id, "33333333");
  });

  it("gives up after maxTries instead of looping forever", async () => {
    await assert.rejects(
      pickFreeParentId(async () => true, scripted([5, 5, 5, 5, 5, 5, 5, 5]), 3),
      /No free parent ID after 3 tries/,
    );
  });
});
