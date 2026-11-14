// Verification flow (F2, F3, F18): submission checks, duplicate and banned
// IDs, admin-only verification, and the image deletion job. Run: npm test.
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import {
  casePrefix,
  DAY_MS,
  decideVerification,
  IMAGE_RETENTION_MS,
  openVerificationCase,
  pendingPath,
  purgeVerificationImages,
  removeChild,
  submitVerification,
  withdrawVerification,
  type VerificationDeps,
} from "../src/verification/flow";
import { FakeKycProvider, type KycResult } from "../src/verification/kyc";
import { nationalIdHash } from "../src/verification/national_id";
import {
  cairoDate,
  IDENTITY_FILES,
  parseDecision,
  parseSubmission,
  VERIFICATION_CONSENT_VERSIONS,
  VerificationError,
} from "../src/verification/submission";
import { MemoryClaims, MemoryFiles, MemoryVerificationStore } from "./helpers/memory_verification";

const KEY = "test-national-id-key";
const NOW = Date.parse("2026-11-13T10:00:00Z");
const NID = "29001150123456";

function submission(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    identity: {
      firstName: "Mona",
      lastName: "Hassan",
      nationalId: NID,
      idExpiry: "2030-05-01",
      livenessChallenge: "left",
    },
    children: [{ ref: "c1", firstName: "Omar", age: 8, grade: "g3", schoolId: "nile", schoolName: "Nile School" }],
    driver: null,
    consents: { ...VERIFICATION_CONSENT_VERSIONS },
    ...overrides,
  };
}

const driver = {
  plate: "ق ط ر 1234",
  model: "Toyota Corolla",
  color: "White",
  seats: 4,
  licenseExpiry: "2029-01-01",
  carLicenseExpiry: "2027-06-30",
};

function expectReason(reason: string) {
  return (error: unknown) => error instanceof VerificationError && error.reason === reason;
}

let clock: number;
let store: MemoryVerificationStore;
let files: MemoryFiles;
let claims: MemoryClaims;
let kycSetting: KycResult;
let deps: VerificationDeps;
let errors: unknown[];

function addUser(uid: string, status: "unverified" | "verified" | "rejected" | "suspended" = "unverified"): void {
  store.users.set(uid, { status, emailVerified: true, termsAccepted: true, caseOpen: false });
}

function uploadAll(uid: string, names: string[] = [...IDENTITY_FILES, "school_id_c1.jpg"]): void {
  for (const name of names) files.put(pendingPath(uid, name));
}

beforeEach(() => {
  clock = NOW;
  store = new MemoryVerificationStore();
  files = new MemoryFiles(() => clock);
  claims = new MemoryClaims(store.events);
  kycSetting = "match";
  errors = [];
  deps = {
    store,
    files,
    kyc: new FakeKycProvider(async () => kycSetting),
    claims,
    nationalIdKey: KEY,
    now: () => clock,
    reportError: (e) => errors.push(e),
  };
  addUser("alice");
  addUser("bob");
});

describe("parseSubmission", () => {
  const today = "2026-11-13";

  it("accepts a first submission and trims names", () => {
    const parsed = parseSubmission(submission({ driver }), { today, verified: false });
    assert.equal(parsed.identity?.firstName, "Mona");
    assert.equal(parsed.children.length, 1);
    assert.equal(parsed.driver?.seats, 4);
    assert.deepEqual(parsed.consents, ["id", "face", "childData"]);
    const spaced = parseSubmission(
      submission({ identity: { ...(submission().identity as object), firstName: "  منى   أحمد " } }),
      { today, verified: false },
    );
    assert.equal(spaced.identity?.firstName, "منى أحمد");
  });

  it("needs at least one child with the identity part", () => {
    assert.throws(() => parseSubmission(submission({ children: [] }), { today, verified: false }), expectReason("missing-children"));
  });

  it("refuses an expired ID and a bad expiry date", () => {
    const id = submission().identity as Record<string, unknown>;
    assert.throws(() => parseSubmission(submission({ identity: { ...id, idExpiry: "2026-11-12" } }), { today, verified: false }), expectReason("id-expired"));
    assert.throws(() => parseSubmission(submission({ identity: { ...id, idExpiry: "2026-02-30" } }), { today, verified: false }), expectReason("invalid-expiry"));
    assert.throws(() => parseSubmission(submission({ identity: { ...id, idExpiry: "2040-01-01" } }), { today, verified: false }), expectReason("invalid-expiry"));
  });

  it("refuses an invalid national ID, names with digits, and a bad liveness challenge", () => {
    const id = submission().identity as Record<string, unknown>;
    assert.throws(() => parseSubmission(submission({ identity: { ...id, nationalId: "123" } }), { today, verified: false }), expectReason("invalid-national-id"));
    assert.throws(() => parseSubmission(submission({ identity: { ...id, firstName: "M0na" } }), { today, verified: false }), expectReason("invalid-name"));
    assert.throws(() => parseSubmission(submission({ identity: { ...id, livenessChallenge: "up" } }), { today, verified: false }), expectReason("invalid-request"));
  });

  it("checks children: age, grade, refs, count", () => {
    const child = { ref: "c1", firstName: "Omar", age: 8, grade: "g3", schoolId: "nile", schoolName: "Nile School" };
    for (const bad of [{ age: 1 }, { age: 20 }, { age: 7.5 }, { grade: "g13" }, { ref: "C 1" }, { ref: "c11" }, { ref: "c0" }, { schoolName: "x" }, { schoolId: "a/b" }, { schoolId: undefined }, { schoolId: "" }, { childId: "a/b" }]) {
      assert.throws(() => parseSubmission(submission({ children: [{ ...child, ...bad }] }), { today, verified: false }), expectReason("invalid-child"));
    }
    assert.throws(() => parseSubmission(submission({ children: [child, child] }), { today, verified: false }), expectReason("invalid-child"));
    const many = Array.from({ length: 11 }, (_, i) => ({ ...child, ref: `c${i}` }));
    assert.throws(() => parseSubmission(submission({ children: many }), { today, verified: false }), expectReason("too-many-children"));
  });

  it("checks driving details and expired licenses", () => {
    assert.throws(() => parseSubmission(submission({ driver: { ...driver, seats: 9 } }), { today, verified: false }), expectReason("invalid-driver"));
    assert.throws(() => parseSubmission(submission({ driver: { ...driver, carLicenseExpiry: "2026-01-01" } }), { today, verified: false }), expectReason("license-expired"));
  });

  it("needs the current consent versions", () => {
    assert.throws(() => parseSubmission(submission({ consents: { id: "2020-01-01", face: "x", childData: "x" } }), { today, verified: false }), expectReason("outdated-consent"));
  });

  it("a verified parent sends no identity part, only children or driving", () => {
    assert.throws(() => parseSubmission(submission(), { today, verified: true }), expectReason("invalid-request"));
    const update = parseSubmission({ children: [], driver, consents: {} }, { today, verified: true });
    assert.equal(update.identity, null);
    assert.deepEqual(update.consents, []);
    assert.throws(() => parseSubmission({ children: [], consents: {} }, { today, verified: true }), expectReason("invalid-request"));
    assert.throws(() => parseSubmission(submission({ identity: null }), { today, verified: false }), expectReason("invalid-request"));
  });

  it("Cairo date is used for today", () => {
    assert.equal(cairoDate(Date.parse("2026-11-13T22:30:00Z")), "2026-11-14");
  });
});

describe("submitVerification", () => {
  it("queues the case, sets pending, stores only the ID hash, runs the fake check, deletes pending uploads", async () => {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    const record = store.cases.get(caseId);
    assert.ok(record);
    assert.equal(record.status, "awaiting_review");
    assert.equal(record.kyc?.result, "match");
    assert.equal(record.nationalIdHash, nationalIdHash(KEY, NID));
    assert.ok(!JSON.stringify(record).includes(NID), "national ID number must not be stored");
    assert.equal(store.users.get("alice")?.status, "pending");
    assert.equal(store.nationalIds.get(nationalIdHash(KEY, NID)), "alice");
    assert.deepEqual((await files.list(pendingPath("alice", ""))).length, 0);
    assert.equal((await files.list(casePrefix("alice", caseId))).length, 5);
    assert.deepEqual(store.consents.map((c) => c.type), ["id", "face", "childData"]);
    assert.equal(claims.verified.size, 0, "submitting never verifies");
    assert.equal(files.reads, 0, "the fake provider does not read images");
  });

  it("records no_match from the test setting and still queues for a person", async () => {
    kycSetting = "no_match";
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    assert.equal(store.cases.get(caseId)?.kyc?.result, "no_match");
    assert.equal(store.cases.get(caseId)?.status, "awaiting_review");
  });

  it("refuses a second account with the same national ID", async () => {
    uploadAll("alice");
    uploadAll("bob");
    await submitVerification(deps, "alice", submission());
    await assert.rejects(submitVerification(deps, "bob", submission()), expectReason("duplicate-id"));
    assert.equal(store.users.get("bob")?.status, "unverified");
  });

  it("refuses an ID on the ban list", async () => {
    store.banned.add(nationalIdHash(KEY, NID));
    uploadAll("alice");
    await assert.rejects(submitVerification(deps, "alice", submission()), expectReason("banned-id"));
  });

  it("lists missing uploads", async () => {
    uploadAll("alice", ["id_front.jpg", "selfie.jpg"]);
    await assert.rejects(submitVerification(deps, "alice", submission()), (error: unknown) => {
      assert.ok(error instanceof VerificationError);
      assert.equal(error.reason, "missing-upload");
      assert.deepEqual(error.details.missing, ["id_back.jpg", "selfie_turn.jpg", "school_id_c1.jpg"]);
      return true;
    });
    assert.equal(store.cases.size, 0);
  });

  it("refuses while a case is open, when suspended, and before sign-up is complete", async () => {
    uploadAll("alice");
    await submitVerification(deps, "alice", submission());
    uploadAll("alice");
    await assert.rejects(submitVerification(deps, "alice", submission()), expectReason("case-open"));
    addUser("sus", "suspended");
    await assert.rejects(submitVerification(deps, "sus", submission()), expectReason("suspended"));
    store.users.set("new", { status: "unverified", emailVerified: false, termsAccepted: true, caseOpen: false });
    await assert.rejects(submitVerification(deps, "new", submission()), expectReason("signup-incomplete"));
    await assert.rejects(submitVerification(deps, "ghost", submission()), expectReason("no-account"));
  });

  it("a KYC failure becomes result error and is reported, not thrown", async () => {
    deps.kyc = { kind: "broken", check: async () => { throw new Error("down"); } };
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    assert.equal(store.cases.get(caseId)?.kyc?.result, "error");
    assert.equal(errors.length, 1);
  });
});

describe("decideVerification", () => {
  async function submitted(): Promise<string> {
    uploadAll("alice", [...IDENTITY_FILES, "school_id_c1.jpg", "license.jpg", "car_license.jpg"]);
    return (await submitVerification(deps, "alice", submission({ driver }))).caseId;
  }

  it("approve: verified status, claim set, children and vehicle approved, images kept until the purge time", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    assert.equal(store.users.get("alice")?.status, "verified");
    assert.equal(claims.verified.get("alice"), true);
    assert.ok([...store.children.values()].every((c) => c.status === "approved"));
    assert.equal(store.vehicles.get("alice")?.status, "approved");
    assert.equal(store.cases.get(caseId)?.purgeAtMs, NOW + IMAGE_RETENTION_MS);
    assert.ok(IMAGE_RETENTION_MS + DAY_MS <= 7 * DAY_MS, "deleted within 7 days of the decision");
    assert.deepEqual(store.audit.at(-1), { actorUid: "admin1", action: "verification.approved", target: `verifications/${caseId}` });
  });

  it("Prompt 8: the decision writes one outbox event for the parent, with a fixed ID", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    assert.equal(store.notifications.length, 1);
    const e = store.notifications[0];
    assert.equal(e.id, `verification_${caseId}`);
    assert.equal(e.type, "verification-approved");
    assert.deepEqual(e.recipients, ["alice"]);
    assert.equal(e.status, "pending");
  });

  it("reject: rejected status with reason, claim cleared, ID released so the parent can resubmit", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "reject", reasonCode: "photo_unclear" });
    assert.equal(store.users.get("alice")?.status, "rejected");
    assert.equal(store.users.get("alice")?.caseOpen, false);
    assert.equal(claims.verified.get("alice"), false);
    assert.equal(store.nationalIds.has(nationalIdHash(KEY, NID)), false);

    uploadAll("alice");
    const second = await submitVerification(deps, "alice", submission());
    assert.equal(store.users.get("alice")?.status, "pending");
    assert.equal([...store.children.values()].filter((c) => c.ownerUid === "alice").length, 1, "children replaced");
    assert.ok(store.cases.get(second.caseId));
  });

  it("reject with ban: ID banned, account suspended and signed out; the same ID is refused later", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "reject", reasonCode: "id_mismatch", ban: true });
    assert.equal(store.users.get("alice")?.status, "suspended");
    assert.deepEqual(claims.revoked, ["alice"]);
    uploadAll("bob");
    await assert.rejects(submitVerification(deps, "bob", submission()), expectReason("banned-id"));
  });

  it("approve needs the parent and child name check when the case has children (spec section 3)", async () => {
    const caseId = await submitted();
    await assert.rejects(decideVerification(deps, "admin1", { caseId, decision: "approve" }), expectReason("name-check-missing"));
    assert.equal(store.users.get("alice")?.status, "pending");
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "birth_certificate" });
    assert.equal(store.users.get("alice")?.status, "verified");
  });

  it("cannot decide twice, decide an own case, or decide an unknown case", async () => {
    const caseId = await submitted();
    await assert.rejects(decideVerification(deps, "alice", { caseId, decision: "approve", nameCheck: "match" }), expectReason("own-case"));
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    await assert.rejects(decideVerification(deps, "admin1", { caseId, decision: "reject", reasonCode: "other", note: "x" }), expectReason("already-decided"));
    await assert.rejects(decideVerification(deps, "admin1", { caseId: "nope", decision: "approve", nameCheck: "match" }), expectReason("not-found"));
  });

  it("validates the decision", () => {
    assert.throws(() => parseDecision({ caseId: "c1", decision: "maybe" }), expectReason("invalid-decision"));
    assert.throws(() => parseDecision({ caseId: "c1", decision: "reject" }), expectReason("invalid-decision"));
    assert.throws(() => parseDecision({ caseId: "c1", decision: "reject", reasonCode: "other" }), expectReason("invalid-decision"));
    assert.throws(() => parseDecision({ caseId: "c1", decision: "approve", ban: true }), expectReason("invalid-decision"));
    assert.throws(() => parseDecision({ caseId: "c1", decision: "approve", nameCheck: "maybe" }), expectReason("invalid-decision"));
    assert.throws(
      () => parseDecision({ caseId: "c1", decision: "reject", reasonCode: "other", note: "x", nameCheck: "match" }),
      expectReason("invalid-decision"),
    );
    assert.equal(parseDecision({ caseId: "c1", decision: "approve", nameCheck: "birth_certificate" }).nameCheck, "birth_certificate");
    assert.deepEqual(parseDecision({ caseId: "c1", decision: "reject", reasonCode: "other", note: " Blurry back " }), {
      caseId: "c1",
      nameCheck: null,
      approve: false,
      reasonCode: "other",
      note: "Blurry back",
      ban: false,
    });
  });

  it("the admin view gives short-lived links and logs the view", async () => {
    const caseId = await submitted();
    const view = await openVerificationCase(deps, "admin1", { caseId });
    assert.equal(Object.keys(view.images).length, 7);
    assert.match(view.images["id_front.jpg"], /expires=/);
    assert.ok(view.children[0].imageUrl);
    assert.equal(store.audit.at(-1)?.action, "verification.view");
    assert.ok(!JSON.stringify(view).includes(NID));
  });
});

describe("verified parent updates (F3)", () => {
  async function verifiedAlice(): Promise<string> {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    return [...store.children.values()].find((c) => c.ownerUid === "alice")!.id;
  }

  it("adds a child, edits one, and a rejected update does not unverify the parent", async () => {
    const childId = await verifiedAlice();
    files.put(pendingPath("alice", "school_id_c2.jpg"));
    files.put(pendingPath("alice", "school_id_c3.jpg"));
    const { caseId } = await submitVerification(deps, "alice", {
      children: [
        { ref: "c2", firstName: "Laila", age: 5, grade: "kg2", schoolId: "nile", schoolName: "Nile School" },
        { ref: "c3", childId, firstName: "Omar", age: 9, grade: "g4", schoolId: "nile", schoolName: "Nile School" },
      ],
      consents: { childData: VERIFICATION_CONSENT_VERSIONS.childData },
    });
    assert.equal(store.children.get(childId)?.status, "pending");
    assert.equal(store.users.get("alice")?.status, "verified");
    await assert.rejects(removeChild(deps, "alice", { childId }), expectReason("case-open"));
    await decideVerification(deps, "admin1", { caseId, decision: "reject", reasonCode: "school_id_unclear" });
    assert.equal(store.users.get("alice")?.status, "verified");
    assert.equal(claims.verified.get("alice"), true);
    assert.equal(store.children.get(childId)?.status, "rejected");
  });

  it("removes a child; nobody else can", async () => {
    const childId = await verifiedAlice();
    await assert.rejects(removeChild(deps, "bob", { childId }), expectReason("not-found"));
    await removeChild(deps, "alice", { childId });
    assert.equal(store.children.has(childId), false);
  });

  it("cannot edit a child of another parent", async () => {
    const childId = await verifiedAlice();
    addUser("carol", "verified");
    files.put(pendingPath("carol", "school_id_c1.jpg"));
    await assert.rejects(
      submitVerification(deps, "carol", {
        children: [{ ref: "c1", childId, firstName: "Omar", age: 9, grade: "g4", schoolId: "nile", schoolName: "Nile School" }],
        consents: { childData: VERIFICATION_CONSENT_VERSIONS.childData },
      }),
      expectReason("not-found"),
    );
  });
});

describe("the child's school (F4)", () => {
  const pending = (id: string, addedBy: string, status = "awaiting_review", mergedInto: string | null = null) =>
    store.schools.set(id, { id, nameAr: "مدرسة الزهور", nameEn: "مدرسة الزهور", status, addedBy, mergedInto });
  const withSchool = (schoolId: string, schoolName = "Nile School") =>
    submission({ children: [{ ref: "c1", firstName: "Omar", age: 8, grade: "g3", schoolId, schoolName }] });

  it("links the child to the school and keeps the name the app showed", async () => {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", withSchool("nile"));
    assert.deepEqual(
      [store.cases.get(caseId)?.children[0].schoolId, store.cases.get(caseId)?.children[0].schoolName],
      ["nile", "Nile School"],
    );
  });

  it("a name that is not the school's is replaced by the school's Arabic name", async () => {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", withSchool("nile", "Something Else"));
    assert.equal(store.cases.get(caseId)?.children[0].schoolName, "مدرسة النيل");
  });

  it("the parent's own school awaiting review is allowed; another parent's is not", async () => {
    pending("p-alice", "alice");
    pending("p-bob", "bob");
    uploadAll("alice");
    await assert.rejects(submitVerification(deps, "alice", withSchool("p-bob")), expectReason("unknown-school"));
    await assert.rejects(submitVerification(deps, "alice", withSchool("missing")), expectReason("unknown-school"));
    assert.equal(store.nationalIds.size, 0);
    const { caseId } = await submitVerification(deps, "alice", withSchool("p-alice", "مدرسة الزهور"));
    assert.equal(store.cases.get(caseId)?.children[0].schoolId, "p-alice");
  });

  it("a school merged meanwhile is followed to the school it was merged into", async () => {
    pending("p-old", "alice", "merged", "nile");
    pending("p-gone", "alice", "merged", "missing");
    uploadAll("alice");
    await assert.rejects(submitVerification(deps, "alice", withSchool("p-gone")), expectReason("unknown-school"));
    const { caseId } = await submitVerification(deps, "alice", withSchool("p-old", "مدرسة الزهور"));
    assert.deepEqual(
      [store.cases.get(caseId)?.children[0].schoolId, store.cases.get(caseId)?.children[0].schoolName],
      ["nile", "مدرسة النيل"],
    );
  });
});

describe("purgeVerificationImages (retention job)", () => {
  it("removes the images of decided cases within 7 days of the decision, and nothing earlier", async () => {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    const prefix = casePrefix("alice", caseId);
    assert.equal((await files.list(prefix)).length, 5);

    // Waiting for review: the job keeps the images.
    clock = NOW + 30 * DAY_MS;
    assert.deepEqual(await purgeVerificationImages(deps), { cases: 0, files: 0 });
    assert.equal((await files.list(prefix)).length, 5);

    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    const decidedAt = clock;

    clock = decidedAt + 4 * DAY_MS;
    await purgeVerificationImages(deps);
    assert.equal((await files.list(prefix)).length, 5, "kept for a few days after the decision");

    clock = decidedAt + 6 * DAY_MS;
    const result = await purgeVerificationImages(deps);
    assert.deepEqual(result, { cases: 1, files: 5 });
    assert.equal((await files.list(prefix)).length, 0);
    assert.equal(store.cases.get(caseId)?.imagesDeleted, true);

    // Runs again without work, and the admin view has no links any more.
    assert.deepEqual(await purgeVerificationImages(deps), { cases: 0, files: 0 });
    assert.deepEqual((await openVerificationCase(deps, "admin1", { caseId })).images, {});
  });

  it("removes rejected cases' images too", async () => {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    await decideVerification(deps, "admin1", { caseId, decision: "reject", reasonCode: "selfie_mismatch" });
    clock += 7 * DAY_MS;
    await purgeVerificationImages(deps);
    assert.equal((await files.list(casePrefix("alice", caseId))).length, 0);
  });

  it("removes old uploads never submitted and orphaned case folders, keeps fresh ones", async () => {
    files.put(pendingPath("bob", "id_front.jpg"), "x", NOW - 4 * DAY_MS);
    files.put(pendingPath("bob", "selfie.jpg"), "x", NOW - DAY_MS);
    files.put("verification/bob/cases/ghost/id_front.jpg", "x", NOW - 2 * DAY_MS);
    const result = await purgeVerificationImages(deps);
    assert.equal(result.files, 2);
    assert.equal(await files.exists(pendingPath("bob", "selfie.jpg")), true);
    assert.equal(await files.exists(pendingPath("bob", "id_front.jpg")), false);
    assert.equal(await files.exists("verification/bob/cases/ghost/id_front.jpg"), false);
  });
});

describe("no ID squatting (review fix)", () => {
  it("a submission refused for missing uploads claims nothing; another account can then use the ID", async () => {
    // A squatter sends a real number with no images.
    await assert.rejects(submitVerification(deps, "bob", submission()), expectReason("missing-upload"));
    assert.equal(store.nationalIds.size, 0);
    uploadAll("alice");
    await submitVerification(deps, "alice", submission());
    assert.equal(store.nationalIds.get(nationalIdHash(KEY, NID)), "alice");
  });

  it("refusals for bad children or a pending case claim nothing either", async () => {
    uploadAll("bob");
    await assert.rejects(
      submitVerification(deps, "bob", submission({ children: [{ ref: "c1", firstName: "O", age: 8, grade: "g3", schoolId: "nile", schoolName: "x" }] })),
      expectReason("invalid-child"),
    );
    assert.equal(store.nationalIds.size, 0);
  });

  it("the ID is claimed in the same commit as the case: a claim made meanwhile wins, and the copies are removed", async () => {
    uploadAll("alice");
    store.beforeCommit = () => store.nationalIds.set(nationalIdHash(KEY, NID), "bob");
    await assert.rejects(submitVerification(deps, "alice", submission()), expectReason("duplicate-id"));
    assert.equal(store.cases.size, 0);
    assert.equal((await files.list("verification/alice/cases/")).length, 0);
    assert.equal(store.users.get("alice")?.status, "unverified");
  });

  it("withdrawing a case releases the ID, resets the status and lets the job delete the images", async () => {
    uploadAll("alice");
    const { caseId } = await submitVerification(deps, "alice", submission());
    await assert.rejects(withdrawVerification(deps, "bob", { caseId }), expectReason("not-found"));
    await withdrawVerification(deps, "alice", { caseId });
    assert.equal(store.nationalIds.has(nationalIdHash(KEY, NID)), false);
    assert.equal(store.users.get("alice")?.status, "unverified");
    assert.equal([...store.children.values()].filter((c) => c.ownerUid === "alice").length, 0);
    await assert.rejects(withdrawVerification(deps, "alice", { caseId }), expectReason("already-decided"));
    await purgeVerificationImages(deps);
    assert.equal((await files.list(casePrefix("alice", caseId))).length, 0);

    uploadAll("bob");
    await submitVerification(deps, "bob", submission());
    assert.equal(store.nationalIds.get(nationalIdHash(KEY, NID)), "bob");
  });
});

describe("claim before status (review fix)", () => {
  async function submitted(uid = "alice"): Promise<string> {
    uploadAll(uid);
    return (await submitVerification(deps, uid, submission())).caseId;
  }

  it("approve: the verified claim is set before the status and the claimsUpdatedAt marker", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    assert.deepEqual(store.events, ["claim:true", "status:verified", "marker:claimsUpdatedAt"]);
  });

  it("reject: the claim is cleared first too", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "reject", reasonCode: "photo_unclear" });
    assert.deepEqual(store.events, ["claim:false", "status:rejected", "marker:claimsUpdatedAt"]);
  });

  it("an update case of a verified parent changes no claim and writes no marker", async () => {
    const caseId = await submitted();
    await decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" });
    store.events.length = 0;
    files.put(pendingPath("alice", "school_id_c2.jpg"));
    const update = await submitVerification(deps, "alice", {
      children: [{ ref: "c2", firstName: "Laila", age: 5, grade: "kg2", schoolId: "nile", schoolName: "Nile School" }],
      consents: { childData: VERIFICATION_CONSENT_VERSIONS.childData },
    });
    await decideVerification(deps, "admin1", { caseId: update.caseId, decision: "approve", nameCheck: "match" });
    assert.deepEqual(store.events, ["status:unchanged"]);
  });

  it("if the case was decided meanwhile, an approval's claim is put back", async () => {
    const caseId = await submitted();
    const save = store.saveDecision.bind(store);
    store.saveDecision = async () => {
      throw new VerificationError("already-decided");
    };
    await assert.rejects(decideVerification(deps, "admin1", { caseId, decision: "approve", nameCheck: "match" }), expectReason("already-decided"));
    assert.equal(claims.verified.get("alice"), false);
    store.saveDecision = save;
  });
});
