// The shared callable wrapper (src/common/callable.ts). Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { HttpsError } from "firebase-functions/v2/https";
import { callerOf, classesMapper, reasonErrorMapper, requireUid, runCallable, unavailable } from "../src/common/callable";

class DemoError extends Error {
  constructor(
    readonly reason: "too-many" | "bad",
    readonly retryAfterMs = 0,
    readonly details: Record<string, unknown> = {},
  ) {
    super(reason);
  }
}
const CODES = { "too-many": "resource-exhausted", bad: "invalid-argument" } as const;

async function caught(p: Promise<unknown>): Promise<HttpsError> {
  try {
    await p;
  } catch (error) {
    assert.ok(error instanceof HttpsError, "expected an HttpsError");
    return error;
  }
  assert.fail("expected a rejection");
}

describe("runCallable", () => {
  it("returns the body's value", async () => {
    assert.equal(await runCallable("t", async () => 7), 7);
  });

  it("passes an HttpsError through unchanged", async () => {
    const original = new HttpsError("not-found", "x", { reason: "x" });
    assert.equal(await caught(runCallable("t", async () => Promise.reject(original))), original);
  });

  it("maps a domain error with reason only", async () => {
    const e = await caught(runCallable("t", async () => Promise.reject(new DemoError("bad")), { map: [reasonErrorMapper(DemoError, CODES)] }));
    assert.equal(e.code, "invalid-argument");
    assert.equal(e.message, "bad");
    assert.deepEqual(e.details, { reason: "bad" });
  });

  it("adds retryAfterSeconds (rounded up) for rate limits", async () => {
    const e = await caught(
      runCallable("t", async () => Promise.reject(new DemoError("too-many", 1500)), { map: [reasonErrorMapper(DemoError, CODES, "retryAfter")] }),
    );
    assert.equal(e.code, "resource-exhausted");
    assert.deepEqual(e.details, { reason: "too-many", retryAfterSeconds: 2 });
  });

  it("spreads the error's details after the reason", async () => {
    const e = await caught(
      runCallable("t", async () => Promise.reject(new DemoError("bad", 0, { field: "name" })), { map: [reasonErrorMapper(DemoError, CODES, "details")] }),
    );
    assert.deepEqual(e.details, { reason: "bad", field: "name" });
  });

  it("uses the first mapper that answers", async () => {
    const e = await caught(
      runCallable("t", async () => Promise.reject(new DemoError("bad")), {
        map: [() => undefined, classesMapper([DemoError], () => new HttpsError("aborted", "first")), reasonErrorMapper(DemoError, CODES)],
      }),
    );
    assert.equal(e.code, "aborted");
  });

  it("answers an unexpected error with internal by default", async () => {
    const e = await caught(runCallable("t", async () => Promise.reject(new Error("boom 01001234567"))));
    assert.equal(e.code, "internal");
    assert.equal(e.message, "Something went wrong.");
  });

  it("answers an unexpected error with the fallback", async () => {
    const e = await caught(runCallable("t", async () => Promise.reject(new Error("boom")), { fallback: unavailable("wallet-unavailable") }));
    assert.equal(e.code, "unavailable");
    assert.deepEqual(e.details, { reason: "wallet-unavailable" });
  });
});

describe("requireUid and callerOf", () => {
  const req = (auth: unknown) => ({ auth, data: {}, rawRequest: {} }) as unknown as Parameters<typeof requireUid>[0];

  it("refuses a signed-out caller", () => {
    assert.throws(() => requireUid(req(undefined)), (e: unknown) => e instanceof HttpsError && e.code === "unauthenticated");
    assert.throws(() => callerOf(req({ uid: "" })), (e: unknown) => e instanceof HttpsError && e.code === "unauthenticated");
  });

  it("reads the verified claim strictly", () => {
    assert.deepEqual(callerOf(req({ uid: "u1", token: { verified: true } })), { uid: "u1", verifiedClaim: true });
    assert.deepEqual(callerOf(req({ uid: "u1", token: { verified: "true" } })), { uid: "u1", verifiedClaim: false });
    assert.deepEqual(callerOf(req({ uid: "u1" })), { uid: "u1", verifiedClaim: false });
  });
});
