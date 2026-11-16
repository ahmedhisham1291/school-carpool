// Admin panel logic (F14): access, users, schools, admins, lists. Run: npm test.
import { strict as assert } from "node:assert";
import { beforeEach, describe, it } from "node:test";
import { createAdmin, listAdmins, parseNewAdmin, setAdminDisabled } from "../src/admin_panel/admins";
import { AdminError, type AdminErrorReason } from "../src/admin_panel/errors";
import {
  ADMIN_IDLE_MS,
  ADMIN_SESSION_MAX_SECONDS,
  ADMIN_STEP_UP_SECONDS,
  adminAccess,
  hasTotpFactor,
  adminRecordAccess,
  adminRoleOf,
  shouldTouch,
  type AdminCaller,
} from "../src/admin_panel/guard";
import { listAuditLog, listReports } from "../src/admin_panel/lists";
import {
  approveSchool,
  getSchool,
  listSchools,
  mergeSchool,
  parsePoint,
  parseSchool,
  saveArea,
  saveSchool,
  type SchoolsDeps,
} from "../src/admin_panel/schools";
import { getUserDetail, maskEmail, moderateUser, planSearch, searchUsers, type UsersDeps } from "../src/admin_panel/users";
import { nameSearchFields, normalizeText } from "../src/text/normalize";
import {
  MemoryAdminAccounts,
  MemoryAdminsStore,
  MemoryClaims,
  MemoryListsStore,
  MemorySchoolsStore,
  MemoryUsersStore,
} from "./helpers/memory_admin";

const expectReason = (reason: AdminErrorReason) => (error: unknown) =>
  error instanceof AdminError && error.reason === reason;

const ADMIN: AdminCaller = { uid: "admin1", role: "admin" };
const SUPER: AdminCaller = { uid: "super1", role: "superAdmin" };
const NOW_S = 1_800_000_000;
const MFA = { sign_in_second_factor: "totp" };

describe("adminAccess", () => {
  const token = (extra: Record<string, unknown>) => ({ uid: "a", token: { auth_time: NOW_S - 60, firebase: MFA, ...extra } });

  it("lets in an admin with a second factor and a fresh session", () => {
    assert.deepEqual(adminAccess(token({ admin: true }), NOW_S, { requireMfa: true }), { uid: "a", role: "admin" });
    assert.deepEqual(adminAccess(token({ admin: true, superAdmin: true }), NOW_S, { requireMfa: true, superAdmin: true }), {
      uid: "a",
      role: "superAdmin",
    });
  });

  it("refuses parents, signed-out callers and a superAdmin claim without admin", () => {
    assert.equal(adminAccess(undefined, NOW_S, { requireMfa: true }), "unauthenticated");
    assert.equal(adminAccess(token({ verified: true }), NOW_S, { requireMfa: true }), "not-admin");
    assert.equal(adminAccess(token({ superAdmin: true }), NOW_S, { requireMfa: true }), "not-admin");
    assert.equal(adminAccess(token({ admin: "true" }), NOW_S, { requireMfa: true }), "not-admin");
  });

  it("needs the second factor (except when the emulator turns it off)", () => {
    const noMfa = { uid: "a", token: { admin: true, auth_time: NOW_S, firebase: { sign_in_provider: "password" } } };
    assert.equal(adminAccess(noMfa, NOW_S, { requireMfa: true }), "mfa-required");
    assert.deepEqual(adminAccess(noMfa, NOW_S, { requireMfa: false }), { uid: "a", role: "admin" });
  });

  it("accepts only TOTP as the second factor (an SMS factor can be taken over with the SIM)", () => {
    const sms = { uid: "a", token: { admin: true, auth_time: NOW_S - 60, firebase: { sign_in_provider: "password", sign_in_second_factor: "phone" } } };
    assert.equal(adminAccess(sms, NOW_S, { requireMfa: true }), "mfa-required");
    const odd = { uid: "a", token: { admin: true, auth_time: NOW_S - 60, firebase: { sign_in_second_factor: ["totp"] } } };
    assert.equal(adminAccess(odd, NOW_S, { requireMfa: true }), "mfa-required");
    assert.equal(hasTotpFactor({ firebase: MFA }), true);
    assert.equal(hasTotpFactor({ firebase: { sign_in_second_factor: "phone" } }), false);
    assert.equal(hasTotpFactor({}), false);
  });

  it("sensitive actions need a sign-in less than 30 minutes old (step-up)", () => {
    assert.equal(ADMIN_STEP_UP_SECONDS, 30 * 60);
    const fresh = token({ admin: true, auth_time: NOW_S - ADMIN_STEP_UP_SECONDS });
    assert.deepEqual(adminAccess(fresh, NOW_S, { requireMfa: true, recentSignIn: true }), { uid: "a", role: "admin" });
    const older = token({ admin: true, auth_time: NOW_S - ADMIN_STEP_UP_SECONDS - 1 });
    assert.equal(adminAccess(older, NOW_S, { requireMfa: true, recentSignIn: true }), "reauth-required");
    assert.deepEqual(adminAccess(older, NOW_S, { requireMfa: true }), { uid: "a", role: "admin" }, "ordinary calls keep the 8-hour session");
    // The role check comes first: an ordinary admin is told "not-super-admin", not "sign in again".
    assert.equal(adminAccess(older, NOW_S, { requireMfa: true, superAdmin: true, recentSignIn: true }), "not-super-admin");
  });

  it("the sensitive callables ask for the step-up", () => {
    const { readFileSync } = require("node:fs") as typeof import("node:fs");
    const { join } = require("node:path") as typeof import("node:path");
    const src = (f: string) => readFileSync(join(__dirname, "..", "..", "src", f), "utf8");
    const stepUp = (file: string, name: string) => {
      const text = src(file);
      const start = text.indexOf(`export const ${name}`);
      assert.ok(start >= 0, name);
      const next = text.indexOf("export const ", start + 10);
      assert.match(text.slice(start, next < 0 ? undefined : next), /recentSignIn: true/, `${name} must require a recent sign-in`);
    };
    for (const name of ["adminCreateAdmin", "adminSetAdminDisabled", "adminModerateUser"]) stepUp("admin_panel/callables.ts", name);
    stepUp("features/callables.ts", "adminSetFeature");
    for (const name of ["adminOpenUserPhotos", "adminOpenRouteArchive", "adminClearDeviceCheck"]) stepUp("privacy/callables.ts", name);
  });

  it("ends the session after 8 hours", () => {
    const old = token({ admin: true, auth_time: NOW_S - ADMIN_SESSION_MAX_SECONDS - 1 });
    assert.equal(adminAccess(old, NOW_S, { requireMfa: true }), "session-expired");
    assert.equal(adminAccess(token({ admin: true, auth_time: undefined }), NOW_S, { requireMfa: true }), "session-expired");
  });

  it("keeps the admin account functions for super admins", () => {
    assert.equal(adminAccess(token({ admin: true }), NOW_S, { requireMfa: true, superAdmin: true }), "not-super-admin");
    assert.equal(adminRoleOf(null), null);
  });
});

describe("adminRecordAccess (disabled, revoked, idle)", () => {
  const NOW_MS = NOW_S * 1000;
  const token = { iat: NOW_S - 120, auth_time: NOW_S - 600 };
  const active = { disabled: false, revokedAtMs: null, lastActiveAtMs: NOW_MS - 60_000 };

  it("lets an active admin in", () => {
    assert.equal(adminRecordAccess(active, token, NOW_MS), null);
  });

  it("refuses a missing or disabled admin record at once", () => {
    assert.equal(adminRecordAccess(undefined, token, NOW_MS), "not-admin");
    assert.equal(adminRecordAccess({ ...active, disabled: true }, token, NOW_MS), "not-admin");
  });

  it("refuses tokens issued before the revocation, accepts a newer sign-in", () => {
    assert.equal(adminRecordAccess({ ...active, revokedAtMs: NOW_MS - 30_000 }, token, NOW_MS), "session-revoked");
    assert.equal(adminRecordAccess({ ...active, revokedAtMs: NOW_MS - 900_000 }, token, NOW_MS), null);
  });

  it("ends a session idle for 15 minutes; a fresh sign-in counts as activity", () => {
    const idle = { ...active, lastActiveAtMs: NOW_MS - ADMIN_IDLE_MS - 1 };
    assert.equal(adminRecordAccess(idle, { iat: NOW_S, auth_time: NOW_S - 3600 }, NOW_MS), "session-idle");
    assert.equal(adminRecordAccess(idle, { iat: NOW_S, auth_time: NOW_S - 60 }, NOW_MS), null);
    assert.equal(adminRecordAccess({ ...active, lastActiveAtMs: null }, { iat: NOW_S, auth_time: NOW_S - 3600 }, NOW_MS), "session-idle");
  });

  it("records activity at most once a minute", () => {
    assert.equal(shouldTouch(active, NOW_MS), true);
    assert.equal(shouldTouch({ ...active, lastActiveAtMs: NOW_MS - 10_000 }, NOW_MS), false);
  });
});

describe("normalizeText", () => {
  it("matches Arabic spelling variants and case", () => {
    assert.equal(normalizeText("أحمد"), normalizeText("احمد"));
    assert.equal(normalizeText("إيمان"), normalizeText("ايمان"));
    assert.equal(normalizeText("مدرسة"), normalizeText("مدرسه"));
    assert.equal(normalizeText("مصطفى"), normalizeText("مصطفي"));
    assert.equal(normalizeText("مُحَمَّد"), "محمد");
    assert.equal(normalizeText("  Mona   ALI "), "mona ali");
    assert.equal(normalizeText("٠١٢"), "012");
  });

  it("builds name search fields", () => {
    assert.deepEqual(nameSearchFields("Mona", "Ali Ali"), { nameKey: "mona ali ali", nameTokens: ["mona", "ali"] });
  });
});

describe("users", () => {
  let store: MemoryUsersStore;
  let claims: MemoryClaims;
  let deps: UsersDeps;
  let now: number;

  beforeEach(() => {
    store = new MemoryUsersStore();
    claims = new MemoryClaims();
    now = 1_000_000;
    deps = { store, claims, now: () => now, searchLimit: 3, searchWindowMs: 60_000 };
    store.addUser({ uid: "u1", parentId: "ABCD2345", firstName: "Mona", lastName: "Ali", phone: "+201000000001", email: "mona@example.com" });
    store.addUser({ uid: "u2", parentId: "WXYZ6789", firstName: "أحمد", lastName: "حسن", phone: "+201000000002", status: "pending" });
  });

  it("works out what was typed", () => {
    assert.deepEqual(planSearch("abcd-2345"), { parentId: "ABCD2345", phone: null, name: null });
    assert.deepEqual(planSearch("01000000001"), { parentId: null, phone: "+201000000001", name: null });
    assert.deepEqual(planSearch(" Mona "), { parentId: null, phone: null, name: "mona" });
    assert.equal(planSearch("MONAMONA").name, "monamona", "an 8-letter text is also tried as a name");
    assert.throws(() => planSearch("a"), expectReason("invalid-request"));
    assert.throws(() => planSearch("12"), expectReason("invalid-request"));
    assert.throws(() => planSearch(42), expectReason("invalid-request"));
  });

  it("finds by parent ID, phone and name (Arabic spelling tolerant) with the phone masked", async () => {
    assert.deepEqual((await searchUsers(deps, ADMIN, { query: "ABCD2345" }, null)).users.map((u) => u.uid), ["u1"]);
    const byPhone = (await searchUsers(deps, ADMIN, { query: "+20 100 000 0002" }, null)).users;
    assert.deepEqual(byPhone.map((u) => u.uid), ["u2"]);
    assert.equal(byPhone[0].phone, "+20********02");
    assert.deepEqual((await searchUsers(deps, ADMIN, { query: "احمد" }, null)).users.map((u) => u.uid), ["u2"]);
  });

  it("never returns or logs a phone number in clear", async () => {
    const result = await searchUsers(deps, ADMIN, { query: "01000000001" }, "1.2.3.4");
    assert.doesNotMatch(JSON.stringify(result), /1000000001/);
    assert.doesNotMatch(JSON.stringify(store.log.entries), /1000000001/);
    assert.deepEqual(store.log.entries.at(-1), {
      actorUid: "admin1",
      action: "user.search",
      target: "users",
      details: { by: "phone", results: 1 },
      ip: "1.2.3.4",
    });
  });

  it("rate limits searches per admin and window", async () => {
    for (let i = 0; i < 3; i++) await searchUsers(deps, ADMIN, { query: "Mona" }, null);
    await assert.rejects(searchUsers(deps, ADMIN, { query: "Mona" }, null), expectReason("rate-limited"));
    await searchUsers(deps, { uid: "admin2", role: "admin" }, { query: "Mona" }, null);
    now += 60_000;
    await searchUsers(deps, ADMIN, { query: "Mona" }, null);
  });

  it("shows the detail with masked contact and logs the view", async () => {
    const detail = await getUserDetail(deps, ADMIN, { uid: "u1" }, null);
    assert.equal(detail.phone, "+20********01");
    assert.equal(detail.email, "m***@example.com");
    assert.equal(store.log.entries.at(-1)?.action, "user.view");
    await assert.rejects(getUserDetail(deps, ADMIN, { uid: "nope" }, null), expectReason("not-found"));
    assert.equal(maskEmail(null), null);
  });

  it("suspends (signed out, claim cleared) and unsuspends back to the earlier status", async () => {
    assert.deepEqual(await moderateUser(deps, ADMIN, { uid: "u1", action: "suspend", reasonCode: "reports" }, null), {
      status: "suspended",
    });
    assert.equal(store.users.get("u1")?.statusBeforeSuspension, "verified");
    assert.equal(claims.verified.get("u1"), false);
    assert.deepEqual(claims.revoked, ["u1"]);
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "u1", action: "suspend", reasonCode: "reports" }, null), expectReason("invalid-state"));

    assert.deepEqual(await moderateUser(deps, ADMIN, { uid: "u1", action: "unsuspend", reasonCode: "other", note: "Cleared" }, null), {
      status: "verified",
    });
    assert.equal(claims.verified.get("u1"), true);
    const history = await getUserDetail(deps, ADMIN, { uid: "u1" }, null);
    assert.deepEqual(history.actions.map((a) => a.action), ["user.suspend", "user.unsuspend"]);
  });

  it("changes the claim before the status, and puts it back if the write fails", async () => {
    const order: string[] = [];
    const setVerified = claims.setVerified.bind(claims);
    claims.setVerified = async (uid, verified) => {
      order.push(`claim:${verified}`);
      await setVerified(uid, verified);
    };
    const apply = store.applyModeration.bind(store);
    store.applyModeration = async (write, expected) => {
      order.push(`status:${write.status}`);
      await apply(write, expected);
    };
    await moderateUser(deps, ADMIN, { uid: "u1", action: "suspend", reasonCode: "reports" }, null);
    assert.deepEqual(order, ["claim:false", "status:suspended"]);

    store.applyModeration = async () => {
      throw new AdminError("invalid-state");
    };
    await assert.rejects(
      moderateUser(deps, ADMIN, { uid: "u1", action: "unsuspend", reasonCode: "other", note: "x" }, null),
      expectReason("invalid-state"),
    );
    assert.equal(claims.verified.get("u1"), false, "claim put back");
  });

  it("bans: suspended, ID hash on the ban list, cannot be unsuspended", async () => {
    store.nationalIds.set("hash-u2", "u2");
    await moderateUser(deps, ADMIN, { uid: "u2", action: "ban", reasonCode: "fake_documents" }, null);
    assert.equal(store.users.get("u2")?.status, "suspended");
    assert.equal(store.users.get("u2")?.banned, true);
    assert.ok(store.banned.has("hash-u2"));
    assert.deepEqual(store.log.entries.at(-1)?.details, { idBanned: true });
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "u2", action: "unsuspend", reasonCode: "other", note: "x" }, null), expectReason("invalid-state"));
  });

  it("refuses the caller's own account, admin accounts and bad input", async () => {
    store.addUser({ uid: "admin1" });
    store.addUser({ uid: "admin2" });
    store.admins.add("admin2");
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "admin1", action: "suspend", reasonCode: "reports" }, null), expectReason("own-account"));
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "admin2", action: "ban", reasonCode: "reports" }, null), expectReason("target-is-admin"));
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "u1", action: "delete", reasonCode: "reports" }, null), expectReason("invalid-request"));
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "u1", action: "suspend", reasonCode: "other" }, null), expectReason("invalid-request"));
    await assert.rejects(moderateUser(deps, ADMIN, { uid: "u1", action: "suspend", reasonCode: "mood" }, null), expectReason("invalid-request"));
  });
});

describe("schools", () => {
  let store: MemorySchoolsStore;
  let deps: SchoolsDeps;
  const school = {
    nameAr: "مدرسة النيل",
    nameEn: "Nile School",
    governorate: "cairo",
    city: "Maadi",
    location: { lat: 29.96021234, lng: 31.2569 },
  };

  beforeEach(() => {
    store = new MemorySchoolsStore();
    deps = { store, now: () => 5 };
  });

  it("validates names, governorate and a pin inside Egypt", () => {
    assert.equal(parseSchool(school).location.lat, 29.96021);
    assert.throws(() => parseSchool({ ...school, governorate: "paris" }), (e) => e instanceof AdminError && e.details.field === "governorate");
    assert.throws(() => parseSchool({ ...school, nameEn: " " }), (e) => e instanceof AdminError && e.details.field === "nameEn");
    assert.throws(() => parsePoint({ lat: 48.85, lng: 2.35 }), (e) => e instanceof AdminError && e.details.field === "location");
    assert.throws(() => parsePoint({ lat: "29", lng: 31 }), expectReason("invalid-request"));
  });

  it("adds and edits a school with a pin and areas; every change is audited", async () => {
    const { id } = await saveSchool(deps, ADMIN, school, null);
    assert.equal(store.schools.get(id)?.status, "active");
    // No uid on a school every parent can read; the audit log keeps the admin.
    assert.equal(store.schools.get(id)?.addedBy, null);
    await saveSchool(deps, ADMIN, { ...school, id, city: "Degla" }, null);
    assert.equal(store.schools.get(id)?.city, "Degla");
    const area = await saveArea(deps, ADMIN, { schoolId: id, nameAr: "دجلة", nameEn: "Degla", center: { lat: 29.959, lng: 31.27 } }, null);
    assert.deepEqual((await getSchool(deps, { id })).areas.map((a) => a.id), [area.id]);
    assert.deepEqual(store.log.entries.map((e) => e.action), ["school.create", "school.update", "area.create"]);
    await assert.rejects(saveSchool(deps, ADMIN, { ...school, id: "missing" }, null), expectReason("not-found"));
    await assert.rejects(saveArea(deps, ADMIN, { schoolId: "missing", nameAr: "اا", nameEn: "aa", center: school.location }, null), expectReason("not-found"));
  });

  it("lists by status and governorate", async () => {
    await saveSchool(deps, ADMIN, school, null);
    await saveSchool(deps, ADMIN, { ...school, governorate: "giza", nameEn: "Giza School" }, null);
    assert.equal((await listSchools(deps, {})).schools.length, 2);
    assert.equal((await listSchools(deps, { governorate: "giza" })).schools.length, 1);
    assert.equal((await listSchools(deps, { status: "awaiting_review" })).schools.length, 0);
    await assert.rejects(listSchools(deps, { status: "merged" }), expectReason("invalid-request"));
  });

  it('"Other" queue: approve as new, or merge into an existing school (children move)', async () => {
    const pending = (id: string) =>
      store.schools.set(id, {
        id,
        nameAr: "مدرسه النيل",
        nameEn: "nile school",
        governorate: "cairo",
        city: "maadi",
        location: null,
        status: "awaiting_review",
        source: "parent",
        addedBy: "u1",
        mergedInto: null,
        createdAtMs: 1,
      });
    pending("p1");
    pending("p2");
    store.children.set("k1", "p2");
    assert.deepEqual((await listSchools(deps, { status: "awaiting_review" })).schools.map((s) => s.id), ["p1", "p2"]);

    await approveSchool(deps, ADMIN, { ...school, id: "p1" }, null);
    assert.equal(store.schools.get("p1")?.status, "active");
    assert.equal(store.schools.get("p1")?.nameEn, "Nile School");
    // The parent's uid leaves the school once every parent can read it.
    assert.equal(store.schools.get("p1")?.addedBy, null);

    assert.deepEqual(await mergeSchool(deps, ADMIN, { schoolId: "p2", intoId: "p1" }, null), { id: "p1", childrenMoved: 1 });
    assert.equal(store.schools.get("p2")?.status, "merged");
    assert.equal(store.children.get("k1"), "p1");
    await assert.rejects(mergeSchool(deps, ADMIN, { schoolId: "p2", intoId: "p1" }, null), expectReason("invalid-state"));
    await assert.rejects(approveSchool(deps, ADMIN, { ...school, id: "p1" }, null), expectReason("invalid-state"));
    await assert.rejects(saveSchool(deps, ADMIN, { ...school, id: "p2" }, null), expectReason("invalid-state"));
    assert.deepEqual(store.log.entries.map((e) => e.action), ["school.approve", "school.merge"]);
  });
});

describe("admin accounts", () => {
  let store: MemoryAdminsStore;
  let accounts: MemoryAdminAccounts;
  const deps = () => ({ store, accounts, now: () => 9 });

  beforeEach(() => {
    store = new MemoryAdminsStore();
    accounts = new MemoryAdminAccounts();
  });

  it("validates the new admin", () => {
    assert.deepEqual(parseNewAdmin({ email: " Rev@Example.com ", displayName: "Reviewer One", role: "admin" }), {
      email: "rev@example.com",
      displayName: "Reviewer One",
      role: "admin",
    });
    assert.throws(() => parseNewAdmin({ email: "nope", displayName: "R1", role: "admin" }), (e) => e instanceof AdminError && e.details.field === "email");
    assert.throws(() => parseNewAdmin({ email: "a@b.co", displayName: "R1", role: "owner" }), (e) => e instanceof AdminError && e.details.field === "role");
  });

  it("creates an admin with the role claim and a one-time setup link, never stored", async () => {
    const result = await createAdmin(deps(), SUPER, { email: "rev@example.com", displayName: "Reviewer", role: "admin" }, null);
    assert.equal(accounts.roles.get(result.uid), "admin");
    assert.match(result.setupLink, /^https:/);
    assert.equal(store.admins.get(result.uid)?.email, "rev@example.com");
    assert.doesNotMatch(JSON.stringify([...store.admins.values(), store.log.entries]), /reset\?/);
    assert.deepEqual(store.log.entries.at(-1), {
      actorUid: "super1",
      action: "admin.create",
      target: `admins/${result.uid}`,
      details: { role: "admin" },
      ip: null,
    });
    await assert.rejects(
      createAdmin(deps(), SUPER, { email: "rev@example.com", displayName: "Again", role: "admin" }, null),
      expectReason("already-exists"),
    );
    assert.equal((await listAdmins(deps(), SUPER, "1.2.3.4")).admins.length, 1);
    assert.deepEqual(store.log.entries.at(-1), {
      actorUid: "super1",
      action: "admin.list",
      target: "admins",
      details: { results: 1 },
      ip: "1.2.3.4",
    });
  });

  it("a creation that fails part way leaves no account behind", async () => {
    accounts.failLink = true;
    await assert.rejects(createAdmin(deps(), SUPER, { email: "rev@example.com", displayName: "Reviewer", role: "admin" }, null));
    assert.equal(accounts.removed.length, 1);
    assert.equal(store.admins.size, 0);
    const again = await createAdmin(deps(), SUPER, { email: "rev@example.com", displayName: "Reviewer", role: "admin" }, null);
    assert.match(again.setupLink, /^https:/);
  });

  it("disables and enables another admin, never the caller", async () => {
    const { uid } = await createAdmin(deps(), SUPER, { email: "rev@example.com", displayName: "Reviewer", role: "admin" }, null);
    await setAdminDisabled(deps(), SUPER, { uid, disabled: true }, null);
    assert.ok(accounts.disabled.has(uid));
    assert.ok(store.revoked.has(uid), "revokedAt set so open tokens stop at once");
    assert.equal(store.admins.get(uid)?.disabled, true);
    await setAdminDisabled(deps(), SUPER, { uid, disabled: false }, null);
    assert.equal(accounts.disabled.has(uid), false);
    await assert.rejects(setAdminDisabled(deps(), SUPER, { uid: "super1", disabled: true }, null), expectReason("own-account"));
    await assert.rejects(setAdminDisabled(deps(), SUPER, { uid: "ghost", disabled: true }, null), expectReason("not-found"));
  });
});

describe("reports and audit log", () => {
  it("lists open reports", async () => {
    const store = new MemoryListsStore();
    store.reports = [
      { id: "r1", reporterUid: "u1", targetType: "user", targetId: "u2", reason: "spam", status: "open", createdAtMs: 1, urgent: false, kind: "" },
      { id: "r2", reporterUid: "u1", targetType: "user", targetId: "u3", reason: "spam", status: "handled", createdAtMs: 2, urgent: true, kind: "carpool" },
    ];
    assert.deepEqual((await listReports(store, {})).reports.map((r) => r.id), ["r1"]);
    await assert.rejects(listReports(store, { status: "x" }), expectReason("invalid-request"));
  });

  it("names the actor and shows IP addresses to super admins only", async () => {
    const store = new MemoryListsStore();
    store.auditItems = [{ id: "l1", actorUid: "admin1", action: "user.view", target: "users/u1", reasonCode: null, ip: "1.2.3.4", timeMs: 1 }];
    store.names.set("admin1", "Reviewer");
    const forAdmin = await listAuditLog(store, ADMIN, {});
    assert.equal(forAdmin.entries[0].actorName, "Reviewer");
    assert.equal(forAdmin.entries[0].ip, null);
    assert.equal((await listAuditLog(store, SUPER, {})).entries[0].ip, "1.2.3.4");
    assert.equal(forAdmin.nextAfterId, null);
    assert.equal(store.logged.filter((e) => e.action === "audit.view").length, 2, "one entry per opening");
  });
});
