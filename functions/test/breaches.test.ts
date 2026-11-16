import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";
import type { AuditEntry } from "../src/admin_panel/types";
import { listIncidents, reportIncident, updateIncident, type BreachDeps, type BreachStore } from "../src/privacy/breach_callables";
import { addWorkingDays, applyBreachUpdate, BreachError, breachView, newBreach, pdpcDeadline, type BreachRecord } from "../src/privacy/breaches";
import { DAY_MS } from "../src/privacy/retention";

/**
 * Breach register (Law 151 of 2020 Art. 7; Decree 816/2025 Art. 5;
 * docs/legal/breach-runbook.md): PDPC within 72 hours (immediately for
 * national security; safe side: also for children's or biometric data),
 * parents within 3 working days of the PDPC notice, every step audited.
 */

const HOUR = 3_600_000;
// Sunday 15 Nov 2026, 10:00 Cairo (08:00 UTC).
const SUN = Date.UTC(2026, 10, 15, 8);

const input = (extra: Record<string, unknown> = {}) => ({
  awareAtMs: SUN,
  occurredAtMs: SUN - 2 * HOUR,
  kind: "unauthorisedAccess",
  categories: ["contact"],
  source: "us",
  approxRecords: 120,
  approxPeople: 40,
  nationalSecurity: false,
  summary: "Test: a leaked staging key (fake data)",
  ...extra,
});

class MemoryBreachStore implements BreachStore {
  records = new Map<string, BreachRecord>();
  audit: AuditEntry[] = [];
  private n = 0;
  newId(): string {
    this.n += 1;
    return `b${this.n}`;
  }
  async get(id: string) {
    return this.records.get(id) ?? null;
  }
  async put(r: BreachRecord, a: AuditEntry) {
    this.records.set(r.id, structuredClone(r));
    this.audit.push(a);
  }
  async list() {
    return [...this.records.values()].sort((a, b) => b.awareAtMs - a.awareAtMs);
  }
}

describe("breach register: deadlines", () => {
  it("PDPC: 72 hours after awareness; immediately for national security or sensitive data", () => {
    assert.deepEqual(pdpcDeadline(SUN, false, false), { dueAtMs: SUN + 72 * HOUR, immediate: false });
    assert.deepEqual(pdpcDeadline(SUN, true, false), { dueAtMs: SUN, immediate: true });
    assert.deepEqual(pdpcDeadline(SUN, false, true), { dueAtMs: SUN, immediate: true });
  });

  it("children's or biometric data makes the breach sensitive", () => {
    assert.equal(newBreach("b", input(), "a", SUN).sensitive, false);
    assert.equal(newBreach("b", input({ categories: ["children", "location"] }), "a", SUN).sensitive, true);
    assert.equal(newBreach("b", input({ categories: ["biometric"] }), "a", SUN).immediate, true);
  });

  it("parents: 3 Cairo working days after the PDPC notice (Fri and Sat skipped)", () => {
    // Wednesday notice -> Thu (1), Sun (2), Mon (3).
    const wed = SUN + 3 * DAY_MS;
    assert.equal(addWorkingDays(wed, 3), wed + 5 * DAY_MS);
    const r = newBreach("b", input(), "a", SUN);
    const v = breachView({ ...r, pdpcNotifiedAtMs: wed }, wed);
    assert.equal(v.subjectsDueAtMs, wed + 5 * DAY_MS);
  });

  it("states move from onTime to dueSoon to overdue; 'now' while an immediate notice is not sent", () => {
    const r = newBreach("b", input(), "a", SUN);
    assert.equal(breachView(r, SUN).pdpcState, "onTime");
    assert.equal(breachView(r, SUN + 61 * HOUR).pdpcState, "dueSoon");
    assert.equal(breachView(r, SUN + 73 * HOUR).pdpcState, "overdue");
    const late = applyBreachUpdate(r, { action: "pdpcNotified", atMs: SUN + 80 * HOUR }, "a", SUN + 80 * HOUR);
    assert.equal(breachView(late, SUN + 80 * HOUR).pdpcState, "overdue", "a late notice stays visible as late");
    const kids = newBreach("k", input({ categories: ["children"] }), "a", SUN);
    assert.equal(breachView(kids, SUN).pdpcState, "now");
  });
});

describe("breach register: the record", () => {
  it("keeps what the PDPC notice needs; rejects bad input", () => {
    const r = newBreach("b1", input({ effects: "Phone numbers may be used for spam", measures: "Key rotated" }), "admin1", SUN + HOUR);
    assert.equal(r.awareAtMs, SUN);
    assert.equal(r.reportedAtMs, SUN + HOUR);
    assert.equal(r.approxRecords, 120);
    assert.equal(r.status, "open");
    assert.deepEqual(r.events.map((e) => e.action), ["reported"]);
    const bad = (extra: Record<string, unknown>) => assert.throws(() => newBreach("b", input(extra), "a", SUN), BreachError);
    bad({ awareAtMs: SUN + DAY_MS }); // in the future
    bad({ occurredAtMs: SUN + HOUR }); // after awareness
    bad({ categories: [] });
    bad({ categories: ["nope"] });
    bad({ kind: "x" });
    bad({ source: "x" });
    bad({ approxPeople: -1 });
    bad({ nationalSecurity: "no" });
    bad({ summary: "" });
    bad({ summary: "x".repeat(1001) });
  });

  it("steps in order: PDPC once, parents after the PDPC, closed only after both; nothing rewritten", () => {
    let r = newBreach("b1", input(), "a", SUN);
    assert.throws(() => applyBreachUpdate(r, { action: "subjectsNotified" }, "a", SUN + HOUR), BreachError);
    assert.throws(() => applyBreachUpdate(r, { action: "closed" }, "a", SUN + HOUR), BreachError);
    assert.throws(() => applyBreachUpdate(r, { action: "note" }, "a", SUN + HOUR), BreachError, "a note needs text");
    r = applyBreachUpdate(r, { action: "contained", text: "Key revoked" }, "a", SUN + 2 * HOUR);
    r = applyBreachUpdate(r, { action: "pdpcNotified", reference: "PDPC-123" }, "a", SUN + 20 * HOUR);
    assert.equal(r.pdpcNotifiedAtMs, SUN + 20 * HOUR);
    assert.equal(r.pdpcReference, "PDPC-123");
    assert.throws(() => applyBreachUpdate(r, { action: "pdpcNotified" }, "a", SUN + 21 * HOUR), BreachError, "only once");
    r = applyBreachUpdate(r, { action: "subjectsNotified" }, "a", SUN + DAY_MS);
    r = applyBreachUpdate(r, { action: "closed", text: "Root cause fixed" }, "a", SUN + 2 * DAY_MS);
    assert.equal(r.status, "closed");
    assert.deepEqual(r.events.map((e) => e.action), ["reported", "contained", "pdpcNotified", "subjectsNotified", "closed"]);
    assert.throws(() => applyBreachUpdate(r, { action: "note", text: "x" }, "a", SUN + 3 * DAY_MS), BreachError, "closed is final");
  });
});

describe("breach register: admin callables (flows)", () => {
  const caller = { uid: "admin1", role: "admin" as const };

  it("reporting, updating and listing each write one audit entry with non-personal details", async () => {
    const store = new MemoryBreachStore();
    let now = SUN + HOUR;
    const deps: BreachDeps = { store, now: () => now };
    const reported = await reportIncident(deps, caller, input({ categories: ["children"] }), "10.0.0.1");
    assert.equal(reported.id, "b1");
    assert.equal(reported.pdpcState, "now");
    assert.equal(store.audit[0].action, "breach.report");
    assert.equal(store.audit[0].target, "breachRegister/b1");
    assert.deepEqual(store.audit[0].details, { sensitive: true, nationalSecurity: false, approxPeople: 40 });
    assert.equal(JSON.stringify(store.audit).includes("leaked"), false, "the summary text never goes into the audit log");
    now += HOUR;
    const updated = await updateIncident(deps, caller, { id: "b1", action: "pdpcNotified", reference: "R-1" }, null);
    assert.equal(updated.status, "pdpcNotified");
    assert.equal(store.audit[1].action, "breach.pdpcNotified");
    await assert.rejects(updateIncident(deps, caller, { id: "nope", action: "note", text: "x" }, null), (e: unknown) => e instanceof BreachError && e.reason === "not-found");
    await assert.rejects(updateIncident(deps, caller, { id: "../x", action: "note" }, null), BreachError);
    const list = await listIncidents(deps);
    assert.equal(list.open, 1);
    assert.equal(list.incidents[0].subjectsDueAtMs > now, true);
  });

  it("the three callables are exported, and firestore.rules closes the register to every client", () => {
    const index = readFileSync(join(__dirname, "..", "..", "src", "index.ts"), "utf8");
    for (const name of ["adminReportIncident", "adminUpdateIncident", "adminListIncidents"]) assert.match(index, new RegExp(`\\b${name}\\b`));
    const rules = readFileSync(join(__dirname, "..", "..", "..", "firestore.rules"), "utf8");
    assert.match(rules, /match \/breachRegister\/\{incidentId\} \{\s*allow read, write: if false;/);
  });
});
