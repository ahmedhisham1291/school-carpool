// R5: production closed to new real parents until the PDPC licences are granted.
import { strict as assert } from "node:assert";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import type { AuditEntry } from "../src/admin_panel/types";
import { getLaunch, mayEnter, setLaunch, type LaunchStore } from "../src/launch/flow";
import { LAUNCH_DOC, launchFrom, LaunchError, parseLaunchChange, signUpOpen, type LaunchSettings } from "../src/launch/model";

const ROOT = join(__dirname, "..", "..", "..");

class MemoryLaunch implements LaunchStore {
  settings: LaunchSettings = { pdpcLicensed: false, updatedBy: null, updatedAtMs: null };
  audits: AuditEntry[] = [];
  async read() {
    return { ...this.settings };
  }
  async write(pdpcLicensed: boolean, adminUid: string, nowMs: number, audit: AuditEntry) {
    this.settings = { pdpcLicensed, updatedBy: adminUid, updatedAtMs: nowMs };
    this.audits.push(audit);
  }
}

describe("launch gate (R5)", () => {
  it("prod is closed by default; dev and staging are always open", () => {
    const missing = launchFrom(null, () => null);
    assert.equal(missing.pdpcLicensed, false);
    assert.equal(launchFrom({ pdpcLicensed: "yes" }, () => null).pdpcLicensed, false, "only a real true opens it");
    assert.equal(signUpOpen("prod", missing), false);
    assert.equal(signUpOpen("prod", { pdpcLicensed: true }), true);
    assert.equal(signUpOpen("staging", missing), true);
    assert.equal(signUpOpen("dev", missing), true);
    assert.equal(LAUNCH_DOC, "config/launch");
  });

  it("existing accounts and App Review demo phones always come in; new numbers only when open", () => {
    assert.equal(mayEnter(false, false, false), false);
    assert.equal(mayEnter(false, true, false), true);
    assert.equal(mayEnter(false, false, true), true);
    assert.equal(mayEnter(true, false, false), true);
  });

  it("a super admin opens it with the licence references (audited) and closes it again", async () => {
    const store = new MemoryLaunch();
    const deps = { store, env: "prod", now: () => 1000 };
    assert.equal((await getLaunch(deps)).signUpOpen, false);
    assert.throws(() => parseLaunchChange({ pdpcLicensed: true }), LaunchError, "opening needs the licence numbers");
    assert.throws(() => parseLaunchChange({ pdpcLicensed: "true", licenceRefs: "PDPC-1" }), LaunchError);
    const opened = await setLaunch(deps, { uid: "super1", role: "superAdmin" }, { pdpcLicensed: true, licenceRefs: "PDPC C-123, S-456, T-789" }, "10.0.0.1");
    assert.equal(opened.signUpOpen, true);
    assert.equal(opened.updatedBy, "super1");
    assert.deepEqual(store.audits[0], {
      actorUid: "super1",
      action: "launch.open",
      target: "config/launch",
      reasonCode: "pdpcLicensed",
      details: { licenceRefs: "PDPC C-123, S-456, T-789" },
      ip: "10.0.0.1",
    });
    const closed = await setLaunch(deps, { uid: "super1", role: "superAdmin" }, { pdpcLicensed: false }, null);
    assert.equal(closed.signUpOpen, false);
    assert.equal(store.audits[1].action, "launch.close");
  });

  it("wired: super admin + fresh sign-in, exported, rules closed to clients, verifyCode checks it", () => {
    const callables = readFileSync(join(ROOT, "functions", "src", "launch", "callables.ts"), "utf8");
    assert.ok(callables.includes("superAdmin: true, recentSignIn: true"));
    const index = readFileSync(join(ROOT, "functions", "src", "index.ts"), "utf8");
    assert.ok(index.includes("adminGetLaunch, adminSetLaunch"));
    const rules = readFileSync(join(ROOT, "firestore.rules"), "utf8");
    assert.match(rules, /match \/config\/\{name\} \{\s*allow get: if name == 'features' && sessionValid\(\);/, "config/launch is not readable by the app");
    const auth = readFileSync(join(ROOT, "functions", "src", "auth", "callables.ts"), "utf8");
    assert.ok(auth.includes("open: signUpOpenNow"));
  });
});
