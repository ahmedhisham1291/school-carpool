// Unit tests for the PII scrubber. Run: npm test (Node's built-in runner).
// In the build workspace these 11 tests were run against src/scrub.ts with
// Node 22 type stripping (all pass); the tsc build and `npm test` were not
// run here (no npm registry). CI runs `npm test`.
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { areaOf, REDACTED, isSensitiveKey, scrubEvent, scrubString, scrubValue } from "../src/scrub";

describe("scrubString", () => {
  const cases: Record<string, string> = {
    "international phone": "call +20 100 123 4567 now",
    "local phone": "phone 01012345678",
    "national ID": "id 29001011234567 failed",
    "Arabic-Indic digits": "رقم ٠١٠١٢٣٤٥٦٧٨",
    "coordinate pair": "at 30.0444, 31.2357",
    "precise decimal": "lat=30.044420",
    email: "mail parent@example.com",
  };
  for (const [name, input] of Object.entries(cases)) {
    it(`removes ${name}`, () => {
      const out = scrubString(input);
      assert.ok(out.includes(REDACTED), out);
      assert.ok(!/[0-9٠-٩]{7,}/.test(out), out);
      assert.ok(!out.includes("@example.com"));
      assert.ok(!out.includes("31.2357"));
    });
  }

  it("removes an InstaPay address (name@instapay has no dot, so it is not an email)", () => {
    for (const input of ["pay mona.ali@instapay now", "MONA_92@InstaPay", "to a-b.c@instapay."]) {
      const out = scrubString(input);
      assert.ok(out.includes(REDACTED), out);
      assert.ok(!/instapay/i.test(out), out);
      assert.ok(!/mona|a-b/i.test(out), out);
    }
    assert.equal(isSensitiveKey("instaPayAddress"), true);
    assert.equal(isSensitiveKey("address"), true);
    assert.deepEqual(scrubValue({ address: "mona.ali@instapay", reason: "invalid-address" }), { address: REDACTED, reason: "invalid-address" });
  });

  it("keeps error codes and short numbers", () => {
    const input = "permission-denied on step 3 (HTTP 404)";
    assert.equal(scrubString(input), input);
  });
});

describe("scrubValue", () => {
  it("drops sensitive keys at any depth", () => {
    const out = scrubValue({
      phoneNumber: "+201001234567",
      national_id: "29001011234567",
      lat: 30.0444,
      screen: "home",
      nested: { text: "see you at the gate", list: ["ok", "+201001234567"] },
    }) as Record<string, unknown>;
    assert.equal(out.phoneNumber, REDACTED);
    assert.equal(out.national_id, REDACTED);
    assert.equal(out.lat, REDACTED);
    assert.equal(out.screen, "home");
    const nested = out.nested as Record<string, unknown>;
    assert.equal(nested.text, REDACTED);
    assert.deepEqual(nested.list, ["ok", REDACTED]);
  });

  it("normalizes key spelling", () => {
    assert.ok(isSensitiveKey("Phone-Number"));
    assert.ok(isSensitiveKey("national_id"));
    assert.ok(!isSensitiveKey("route"));
  });
});

describe("scrubEvent", () => {
  it("leaves no phone, ID, coordinate, email or message text", () => {
    const event = {
      event_id: "abc",
      message: "could not send code to +201001234567",
      user: { id: "uid-1", email: "parent@example.com", ip_address: "10.1.2.3" },
      request: { url: "https://x.test/?phone=01012345678", data: { text: "hi" } },
      server_name: "instance-1",
      tags: { phone: "01012345678", screen: "home" },
      extra: { body: "secret message", count: 3 },
      exception: { values: [{ type: "Error", value: "bad id 29001011234567 at 30.0444,31.2357" }] },
      breadcrumbs: [{ message: "map at 30.0444, 31.2357", data: { text: "hello", route: "/home" } }],
    };
    const out = scrubEvent(event) as unknown as Record<string, any>;
    const json = JSON.stringify(out);
    for (const leaked of ["1001234567", "1012345678", "29001011234567", "30.0444", "31.2357", "@example.com", "secret message", "hello"]) {
      assert.ok(!json.includes(leaked), `leaked ${leaked}: ${json}`);
    }
    assert.deepEqual(out.user, { id: "uid-1" });
    assert.equal(out.request, undefined);
    assert.equal(out.server_name, undefined);
    assert.equal(out.tags.screen, "home");
    assert.equal(out.extra.count, 3);
    assert.equal(out.breadcrumbs[0].data.route, "/home");
    assert.equal(out.event_id, "abc");
  });
});

describe("Prompt 12: nothing personal reaches Sentry", () => {
  it("cleans the exception mechanism, frame variables, contexts and breadcrumbs", () => {
    const phone = "+201001234567";
    const nid = "29001011234567";
    const event = {
      message: `send failed for ${phone}`,
      user: { id: "uid-1", email: "p@example.com", ip_address: "10.0.0.1" },
      request: { data: { phone } },
      contexts: { trip: { lat: 30.0444, lng: 31.2357 }, app: { app_name: "carpool" }, device: { name: "Hoda's iPhone" } },
      exception: {
        values: [
          {
            type: "Error",
            value: `bad id ${nid} at 30.0444, 31.2357`,
            mechanism: { type: "generic", handled: true, data: { phoneNumber: phone, text: "my message", step: 3 }, description: `called ${phone}` },
            stacktrace: { frames: [{ filename: "flow.js", lineno: 3, vars: { phone, message: "hello there" } }] },
          },
        ],
      },
      breadcrumbs: [{ message: `opened ${phone}`, data: { text: "secret message", location: { lat: 1, lng: 2 } } }],
      extra: { body: "message text", national_id: nid },
    };
    const out = scrubEvent(event) as unknown as Record<string, unknown>;
    const json = JSON.stringify(out);
    for (const secret of ["1001234567", nid, "31.2357", "30.0444", "my message", "hello there", "secret message", "message text", "p@example.com", "10.0.0.1", "Hoda"]) {
      assert.ok(!json.includes(secret), `${secret} leaked: ${json}`);
    }
    assert.ok(json.includes("uid-1"));
    assert.ok(json.includes('"step":3'), "harmless values stay");
  });

  it("tags errors by area for the alert rules", () => {
    assert.equal(areaOf("verifyCode"), "signin");
    assert.equal(areaOf("requestCode"), "signin");
    assert.equal(areaOf("startTrip"), "trips");
    assert.equal(areaOf("tripLocation"), "trips");
    assert.equal(areaOf("sendMoney"), "wallet");
    assert.equal(areaOf("walletReconcile"), "wallet");
    assert.equal(areaOf("lookupParentId"), "wallet");
    assert.equal(areaOf("exportMyData"), "privacy");
    assert.equal(areaOf("createCarpool"), "other");
  });
});
