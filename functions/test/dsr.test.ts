import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { DAY_MS, PRIVACY_REQUEST_DAYS } from "../src/privacy/retention";
import { adminQueue, DSR_RESPONSE_WORKING_DAYS, isCairoWorkingDay, newRequest, responseDueAt, slaOf } from "../src/privacy/requests";

/**
 * Data subject requests: the answer is due within 6 working days (Law 151
 * of 2020; docs/legal/dsr-procedure.md). Cairo weekend is Friday and
 * Saturday; public holidays count as working days (earlier deadline, safe
 * side).
 */

// Sunday 15 Nov 2026, 10:00 Cairo (08:00 UTC).
const SUN = Date.UTC(2026, 10, 15, 8);

describe("data subject requests: 6 working days", () => {
  it("Cairo working days are Sunday to Thursday", () => {
    for (let i = 0; i < 7; i++) {
      const at = SUN + i * DAY_MS;
      assert.equal(isCairoWorkingDay(at), i <= 4, new Date(at).toISOString());
    }
  });

  it("a Sunday request is due on Monday of the next week at the same time (Fri and Sat skipped)", () => {
    assert.equal(DSR_RESPONSE_WORKING_DAYS, 6);
    assert.equal(responseDueAt(SUN), SUN + 8 * DAY_MS);
  });

  it("a Thursday request is due 10 calendar days later; any request within 8 to 10 days, on a working day", () => {
    const thu = SUN + 4 * DAY_MS;
    // Sun to Thu, then Sun: the weekend is skipped twice.
    assert.equal(responseDueAt(thu), thu + 10 * DAY_MS);
    for (let i = 0; i < 7; i++) {
      const created = SUN + i * DAY_MS;
      const days = (responseDueAt(created) - created) / DAY_MS;
      assert.ok(days >= 8 && days <= 10, `${i}: ${days}`);
      assert.ok(isCairoWorkingDay(responseDueAt(created)), "the deadline is a working day");
    }
  });

  it("a Friday request (weekend) is due 6 working days later", () => {
    const fri = SUN + 5 * DAY_MS;
    // Sun..Thu (5) + Sun (6): 9 calendar days.
    assert.equal(responseDueAt(fri), fri + 9 * DAY_MS);
  });

  it("every new request carries its deadline and the 3-year proof period", () => {
    const r = newRequest("r1", "alice", "correct", "name", SUN);
    assert.equal(r.dueAtMs, SUN + 8 * DAY_MS);
    assert.equal(r.expiresAtMs, SUN + PRIVACY_REQUEST_DAYS * DAY_MS);
    assert.equal(r.status, "open");
  });

  it("states: on time, due within a day, overdue; a closed request is done", () => {
    const r = newRequest("r1", "alice", "photoCopy", null, SUN);
    assert.equal(slaOf(r, SUN).state, "onTime");
    assert.equal(slaOf(r, SUN + 7 * DAY_MS + 1).state, "dueSoon");
    assert.equal(slaOf(r, SUN + 8 * DAY_MS + 1).state, "overdue");
    assert.equal(slaOf({ ...r, status: "done", doneAtMs: SUN + DAY_MS }, SUN + 30 * DAY_MS).state, "done");
    // An old record without dueAtMs gets it computed.
    assert.equal(slaOf({ ...r, dueAtMs: undefined }, SUN).dueAtMs, SUN + 8 * DAY_MS);
  });

  it("the admin queue lists open requests only, most urgent first", () => {
    const old = newRequest("old", "a", "correct", "name", SUN - 14 * DAY_MS);
    const fresh = newRequest("fresh", "b", "photoCopy", null, SUN);
    const done = { ...newRequest("done", "c", "export", null, SUN - 20 * DAY_MS), status: "done" as const, doneAtMs: SUN };
    const q = adminQueue([fresh, done, old], SUN);
    assert.deepEqual(q.map((x) => x.id), ["old", "fresh"]);
    assert.equal(q[0].sla, "overdue");
    assert.equal(q[1].sla, "onTime");
  });
});
