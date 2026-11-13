// Client IP extraction for the per-IP limit. Run: npm test.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { clientIp } from "../src/auth/client_ip";

describe("clientIp", () => {
  it("takes the entry the platform appended (last)", () => {
    assert.equal(clientIp({ "x-forwarded-for": "203.0.113.7" }), "203.0.113.7");
  });

  it("ignores entries a caller put in front", () => {
    assert.equal(clientIp({ "x-forwarded-for": "1.1.1.1, 2.2.2.2, 203.0.113.7" }), "203.0.113.7");
  });

  it("can take the hop before a load balancer", () => {
    assert.equal(clientIp({ "x-forwarded-for": "1.1.1.1, 203.0.113.7, 35.191.0.1" }, undefined, 2), "203.0.113.7");
  });

  it("handles repeated headers", () => {
    assert.equal(clientIp({ "x-forwarded-for": ["9.9.9.9", "203.0.113.7"] }), "203.0.113.7");
  });

  it("falls back to the socket address, then to unknown", () => {
    assert.equal(clientIp({}, "127.0.0.1"), "127.0.0.1");
    assert.equal(clientIp({ "x-forwarded-for": "203.0.113.7" }, "127.0.0.1", 3), "127.0.0.1");
    assert.equal(clientIp({}), "unknown");
  });
});
