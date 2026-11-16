// Security review (16 Nov 2026): environment fails closed, sessions revoked on suspension. Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { appEnv } from "../src/config";

describe("appEnv (fails closed)", () => {
  it("takes the three known values as they are", () => {
    assert.equal(appEnv({ APP_ENV: "dev" }), "dev");
    assert.equal(appEnv({ APP_ENV: "staging" }), "staging");
    assert.equal(appEnv({ APP_ENV: "prod" }), "prod");
  });

  it("a cloud project without APP_ENV, or with an unknown value, counts as prod (fakes refused)", () => {
    assert.equal(appEnv({}), "prod");
    assert.equal(appEnv({ APP_ENV: "" }), "prod");
    assert.equal(appEnv({ APP_ENV: "Dev" }), "prod");
    assert.equal(appEnv({ APP_ENV: "production" }), "prod");
  });

  it("only the local emulators default to dev", () => {
    assert.equal(appEnv({ FUNCTIONS_EMULATOR: "true" }), "dev");
    assert.equal(appEnv({ FUNCTIONS_EMULATOR: "true", APP_ENV: "staging" }), "staging");
    assert.equal(appEnv({ FUNCTIONS_EMULATOR: "false" }), "prod");
  });

  it("no source reads APP_ENV with a dev default any more", () => {
    const { readdirSync, readFileSync, statSync } = require("node:fs") as typeof import("node:fs");
    const { join } = require("node:path") as typeof import("node:path");
    const root = join(__dirname, "..", "..", "src");
    const walk = (dir: string): string[] =>
      readdirSync(dir).flatMap((n) => (statSync(join(dir, n)).isDirectory() ? walk(join(dir, n)) : n.endsWith(".ts") ? [join(dir, n)] : []));
    for (const file of walk(root)) {
      assert.doesNotMatch(readFileSync(file, "utf8"), /APP_ENV\s*\?\?\s*"dev"/, file);
    }
  });
});

describe("FirebaseClaimsService.revokeSessions (suspension, ban)", () => {
  it("revokes refresh tokens AND writes sessionsValidAfter, so the rules refuse old ID tokens at once", async () => {
    const { FirebaseClaimsService, sessionsValidAfterSeconds } = require("../src/verification/store") as typeof import("../src/verification/store");
    const calls: string[] = [];
    const updates: Array<{ path: string; data: Record<string, unknown> }> = [];
    const auth = {
      revokeRefreshTokens: async (uid: string) => void calls.push(`revoke:${uid}`),
      getUser: async () => ({ tokensValidAfterTime: "Tue, 17 Nov 2026 08:00:00 GMT" }),
    };
    const db = {
      collection: (name: string) => ({
        doc: (id: string) => ({ update: async (data: Record<string, unknown>) => void updates.push({ path: `${name}/${id}`, data }) }),
      }),
    };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await new FirebaseClaimsService(auth as any, db as any).revokeSessions("mallory");
    assert.deepEqual(calls, ["revoke:mallory"]);
    assert.deepEqual(updates, [{ path: "users/mallory", data: { sessionsValidAfter: Date.UTC(2026, 10, 17, 8) / 1000 } }]);
    assert.equal(sessionsValidAfterSeconds(undefined, 1_800_000_000_500), 1_800_000_000);
  });

  it("both callables that suspend or ban build it with Firestore", () => {
    const { readFileSync } = require("node:fs") as typeof import("node:fs");
    const { join } = require("node:path") as typeof import("node:path");
    for (const file of ["admin_panel/callables.ts", "verification/callables.ts"]) {
      const text = readFileSync(join(__dirname, "..", "..", "src", file), "utf8");
      assert.doesNotMatch(text, /new FirebaseClaimsService\(adminAuth\(\)\)/, file);
      assert.match(text, /new FirebaseClaimsService\(adminAuth\(\), adminDb\(\)\)/, file);
    }
  });
});
