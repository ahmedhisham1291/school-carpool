/**
 * App Review: the scheduled refresh of the demo carpool's runs
 * (src/auth/review_demo_refresh.ts). Fake parents and data only.
 */
import { strict as assert } from "node:assert";
import { describe, it } from "node:test";
import { reviewAccessFor, type ReviewAccess } from "../src/auth/otp_flow";
import { REVIEW_DEMO_FIELD, REVIEW_DEMO_MARK } from "../src/auth/review_access";
import { DEMO_IDS } from "../src/auth/review_demo";
import { DEMO_CONFIRM_MAX, refreshReviewDemoRuns, type DemoRefreshDeps } from "../src/auth/review_demo_refresh";
import { createCarpool, decideJoinRequest, DEFAULT_CARPOOL_LIMITS, requestToJoin, setDriverConsent, type CarpoolDeps } from "../src/carpools/flow";
import { DEFAULT_DEADLINES } from "../src/schedule/model";
import { MemoryCarpoolStore } from "./helpers/memory_carpools";

const KEY = "k".repeat(40);
const DAY = 24 * 3600 * 1000;
const NOW = Date.UTC(2026, 10, 14, 8); // Saturday 14 Nov 2026, 10:00 in Cairo

function world(opts: { carpoolId?: string; schoolId?: string } = {}) {
  const store = new MemoryCarpoolStore();
  const clock = { now: NOW };
  let next = 0;
  store.newCarpoolId = () => (next++ === 0 ? (opts.carpoolId ?? DEMO_IDS.carpool) : `other-${next}`);
  const carpools: CarpoolDeps = {
    store,
    now: () => clock.now,
    limits: { ...DEFAULT_CARPOOL_LIMITS },
    newCode: () => "ABCDEFGH22",
    linkBase: "https://links.example",
    deadlines: DEFAULT_DEADLINES,
  };
  const schoolId = opts.schoolId ?? DEMO_IDS.school;
  store.schools.set(schoolId, { id: schoolId, nameAr: "تجريبية", nameEn: "Demo", status: "active" });
  store.areas.set(DEMO_IDS.area, { id: DEMO_IDS.area, schoolId, nameAr: "المعادي", nameEn: "Maadi" });
  store.accounts.set("demo-driver", { status: "verified", firstName: "Mona" });
  store.accounts.set("demo-parent", { status: "verified", firstName: "Karim" });
  store.children.set("demo-driver", [{ id: DEMO_IDS.childOfDriver, firstName: "Youssef", grade: "g3", schoolId }]);
  store.children.set("demo-parent", [{ id: DEMO_IDS.childOfParent, firstName: "Laila", grade: "g2", schoolId }]);
  store.vehicles.set("demo-driver", { status: "approved", seats: 4, licenseExpiry: "2030-01-01", carLicenseExpiry: "2030-01-01" });
  const users = new Map<string, Record<string, unknown>>();
  for (const uid of ["demo-driver", "demo-parent"]) users.set(uid, { status: "verified", [REVIEW_DEMO_MARK]: true, [REVIEW_DEMO_FIELD]: NOW + 10 * DAY });
  let review: ReviewAccess | null = { ...reviewAccessFor(KEY, "+201012345678", "482913", NOW + 10 * DAY), demoUids: ["demo-driver", "demo-parent"] };
  const deps: DemoRefreshDeps = {
    carpools,
    readReview: async () => review,
    readUser: async (uid) => users.get(uid),
  };
  return {
    store,
    clock,
    carpools,
    users,
    deps,
    setReview: (r: ReviewAccess | null) => {
      review = r;
    },
    async seedCarpool(): Promise<string> {
      const driver = { uid: "demo-driver", verifiedClaim: true };
      const parent = { uid: "demo-parent", verifiedClaim: true };
      const { carpoolId } = await createCarpool(carpools, driver, {
        kind: "school",
        schoolId,
        areaId: DEMO_IDS.area,
        morning: "07:30",
        afternoon: "14:30",
        days: ["sun", "mon", "tue", "wed", "thu"],
        driveDays: ["sun", "mon", "tue", "wed", "thu"],
        seats: 4,
        childIds: [DEMO_IDS.childOfDriver],
        rules: [],
        acceptVolunteer: true,
      });
      await requestToJoin(carpools, parent, { carpoolId, childIds: [DEMO_IDS.childOfParent], acceptRules: true, acceptVolunteer: true });
      await decideJoinRequest(carpools, driver, { carpoolId, uid: "demo-parent", approve: true });
      await setDriverConsent(carpools, parent, { carpoolId, driverUid: "demo-driver", accept: true });
      return carpoolId;
    },
  };
}

function runsOf(store: MemoryCarpoolStore, carpoolId: string) {
  return [...(store.runs.get(carpoolId)?.values() ?? [])];
}

describe("App Review: the demo runs stay fresh during the window", () => {
  it("plans this week and the next and confirms the demo driver's runs", async () => {
    const w = world();
    const k = await w.seedCarpool();
    assert.equal(k, DEMO_IDS.carpool);
    const result = await refreshReviewDemoRuns(w.deps);
    assert.equal(result.status, "done");
    assert.equal(result.planned, 2);
    const runs = runsOf(w.store, k);
    assert.ok(runs.length >= 10, "two weeks of school runs");
    assert.ok(result.confirmed > 0 && result.confirmed <= DEMO_CONFIRM_MAX);
    assert.ok(runs.filter((r) => r.driverUid === "demo-driver").some((r) => r.status === "confirmed"));
    // A day later it runs again without harm: confirmed runs stay confirmed.
    w.clock.now += DAY;
    const again = await refreshReviewDemoRuns(w.deps);
    assert.equal(again.status, "done");
    assert.ok(runsOf(w.store, k).filter((r) => r.status === "confirmed").length >= result.confirmed - 2);
  });

  it("does nothing when review access is off, expired or lists no demo parent", async () => {
    const w = world();
    const k = await w.seedCarpool();
    w.setReview(null);
    assert.deepEqual(await refreshReviewDemoRuns(w.deps), { status: "off", planned: 0, confirmed: 0 });
    w.setReview({ ...reviewAccessFor(KEY, "+201012345678", "482913", NOW - 1), demoUids: ["demo-driver"] });
    assert.equal((await refreshReviewDemoRuns(w.deps)).status, "off");
    w.setReview(reviewAccessFor(KEY, "+201012345678", "482913", NOW + DAY));
    assert.equal((await refreshReviewDemoRuns(w.deps)).status, "not-ready");
    assert.equal(runsOf(w.store, k).length, 0);
  });

  it("does nothing for an account that is not a demo account in its window", async () => {
    const w = world();
    const k = await w.seedCarpool();
    w.users.set("demo-parent", { status: "verified" }); // a real parent listed by mistake
    assert.equal((await refreshReviewDemoRuns(w.deps)).status, "not-ready");
    w.users.set("demo-parent", { status: "verified", [REVIEW_DEMO_MARK]: true, [REVIEW_DEMO_FIELD]: NOW - 1 });
    assert.equal((await refreshReviewDemoRuns(w.deps)).status, "not-ready");
    assert.equal(runsOf(w.store, k).length, 0);
  });

  it("never touches a carpool outside the demo school", async () => {
    const w = world({ schoolId: "real-school" });
    const k = await w.seedCarpool();
    assert.equal((await refreshReviewDemoRuns(w.deps)).status, "not-ready");
    assert.equal(runsOf(w.store, k).length, 0);
  });

  it("does nothing without the demo carpool", async () => {
    const w = world({ carpoolId: "some-other-carpool" });
    await w.seedCarpool();
    assert.equal((await refreshReviewDemoRuns(w.deps)).status, "not-ready");
  });
});
