// Security review (16 Nov 2026): the environment fails closed. Run: npm test.
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
